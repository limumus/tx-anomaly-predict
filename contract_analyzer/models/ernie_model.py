import requests
import json
import time
from .base_model import BaseAIModel
from config import CONFIG
from typing import List, Dict, Any, Optional, Tuple
from langchain_core.runnables import Runnable
from langchain_core.messages import AIMessage
from core.message_manager import MessageManager


class BaiduErnieAI(BaseAIModel):
    def __init__(self):
        super().__init__(CONFIG)
        self.access_key = CONFIG["BAIDU_ACCESS_KEY"]
        self.secret_key = CONFIG["BAIDU_SECRET_KEY"]
        self.api_url = "api_url"
        
        # Configuration parameters
        self.AUTH_TIMEOUT = 10
        self.API_TIMEOUT = 60
        self.DEFAULT_MAX_COMPRESSION_LEVEL = 3

    def get_access_token(self) -> Optional[str]:
        auth_url = f"https://aip.baidubce.com/oauth/2.0/token"
        params = {
            "grant_type": "client_credentials",
            "client_id": self.access_key,
            "client_secret": self.secret_key
        }
        
        try:
            response = requests.post(
                auth_url,
                params=params,
                timeout=self.AUTH_TIMEOUT
            )
            response.raise_for_status()
            return response.json().get("access_token")
        except requests.exceptions.RequestException:
            return None

    def generate_response(self, messages: List[Dict[str, str]]) -> str:
        error_context = None
        
        for attempt in range(self.max_retries + 1):
            try:
                access_token = self.get_access_token()
                if not access_token:
                    if attempt < self.max_retries:
                        time.sleep(self._calculate_backoff_delay(attempt))
                        continue
                    return "Authentication token acquisition failed"

                api_endpoint = f"{self.api_url}?access_token={access_token}"
                payload = json.dumps({"messages": messages}, ensure_ascii=False)

                response = requests.post(
                    api_endpoint,
                    headers={'Content-Type': 'application/json'},
                    data=payload,
                    timeout=self.API_TIMEOUT
                )
                response.raise_for_status()
                response_data = response.json()

                if "error_code" in response_data:
                    error_message = response_data.get("error_msg", "")
                    
                    if self._check_input_too_long_error(error_message):
                        return f"INPUT_TOO_LONG_ERROR: {error_message}"
                    
                    if attempt < self.max_retries:
                        time.sleep(self._calculate_backoff_delay(attempt))
                        continue
                    
                    return f"API error: {error_message}"

                return response_data.get("result", "Response generation failed")

            except requests.exceptions.Timeout:
                error_context = "API request timeout"
                if attempt < self.max_retries:
                    time.sleep(self._calculate_backoff_delay(attempt))
                else:
                    break
                    
            except requests.exceptions.RequestException as e:
                error_context = f"Network error: {e}"
                if attempt < self.max_retries:
                    time.sleep(self._calculate_backoff_delay(attempt))
                else:
                    break
                    
            except Exception as e:
                error_context = f"Unexpected error: {e}"
                break

        return f"API invocation failed: {error_context}"

    def _calculate_backoff_delay(self, attempt: int) -> float:
        return self.retry_delay * (2 ** attempt)


class ErnieLLMWrapper(Runnable):
    def __init__(self, ernie_ai: BaiduErnieAI):
        super().__init__()
        self.ernie_ai = ernie_ai
        self.COMPRESSION_LEVELS = [
            (0, "none", 0),
            (1, "moderate", 8000),
            (2, "aggressive", 5000),
            (3, "maximum", 3000)
        ]
        self.MAX_RETRIES_PER_LEVEL = 3
        self.compression_history = []

    def invoke(self, input_data: Any, config: Optional[Dict] = None) -> AIMessage:
        try:
            if not isinstance(input_data, dict):
                return AIMessage(content="Error: Invalid input format for LLM wrapper")

            query = input_data.get("query", "Please analyze whether this transaction constitutes a malicious attack.")
            system_input = input_data.get("system_input", "")
            reference_text = input_data.get("reference_text", "")
            skip_rag = input_data.get("skip_rag", False)
            prompt_type = input_data.get("prompt_type", "rag")

            compression_context = {
                "query": query,
                "system_input": system_input,
                "reference_text": reference_text,
                "skip_rag": skip_rag,
                "prompt_type": prompt_type,
                "compression_level": 0,
                "original_system_input_length": len(system_input),
                "original_reference_text_length": len(reference_text)
            }

            for level, level_name, target_chars in self.COMPRESSION_LEVELS:
                compression_context = self._apply_compression_level(
                    compression_context, level, level_name, target_chars
                )

                prompt_content = self._construct_prompt(
                    query=compression_context["query"],
                    system_input=compression_context["system_input"],
                    reference_text=compression_context["reference_text"],
                    skip_rag=compression_context["skip_rag"],
                    prompt_type=compression_context["prompt_type"]
                )

                api_response = self._attempt_api_call_with_retry(prompt_content, level)
                if api_response["status"] == "success":
                    return AIMessage(
                        content=api_response["content"],
                        additional_kwargs={
                            "_full_prompt_content": prompt_content,
                            "_compression_level": level
                        }
                    )
                elif api_response["status"] == "length_error" and level < len(self.COMPRESSION_LEVELS) - 1:
                    continue  # Try next compression level
                elif api_response["status"] == "fatal_error":
                    break  # Stop processing on fatal error

            return AIMessage(
                content="[Unknown]\n\nAnalysis function fault: Unable to process due to excessive input length after multiple compression attempts."
            )
        except Exception as e:
            return AIMessage(
                content=f"[Unknown]\n\nAnalysis function fault: {str(e)}"
            )

    def _apply_compression_level(
        self, 
        context: Dict[str, Any], 
        level: int, 
        level_name: str, 
        target_chars: int
    ) -> Dict[str, Any]:

        if level > 0:
            compressed_system_input = MessageManager.compress_system_input(
                context["system_input"],
                max_chars=target_chars
            )
            
            context.update({
                "system_input": compressed_system_input,
                "compression_level": level
            })
            
            # Record compression metrics
            self.compression_history.append({
                "level": level,
                "name": level_name,
                "target_chars": target_chars,
                "compressed_length": len(compressed_system_input),
                "compression_ratio": len(compressed_system_input) / max(context["original_system_input_length"], 1)
            })
        
        return context

    def _attempt_api_call_with_retry(self, prompt_content: str, compression_level: int) -> Dict[str, Any]:
        api_messages = [{"role": "user", "content": prompt_content}]
        
        for retry_attempt in range(self.MAX_RETRIES_PER_LEVEL):
            try:
                response = self.ernie_ai.generate_response(api_messages)
                
                if "INPUT_TOO_LONG_ERROR" in response:
                    return {"status": "length_error", "content": response}
                
                if any(keyword in response for keyword in ["API error", "API invocation failed", "Network error"]):
                    if retry_attempt < self.MAX_RETRIES_PER_LEVEL - 1:
                        continue
                    else:
                        return {"status": "api_error", "content": response}
                
                return {"status": "success", "content": response}
                
            except Exception as e:
                if retry_attempt < self.MAX_RETRIES_PER_LEVEL - 1:
                    continue
                else:
                    return {"status": "fatal_error", "content": f"API call failed: {str(e)}"}

    def _construct_prompt(
        self,
        query: str,
        system_input: str,
        reference_text: str = "",
        skip_rag: bool = False,
        prompt_type: str = "rag"
    ) -> str:

        if prompt_type == "rag":
            if not skip_rag and reference_text.strip():
                context_content = f"Historical attack examples (context):\n{reference_text}\n\nCurrent transaction (system_input):\n{system_input}"
            else:
                context_content = f"Current transaction (system_input):\n{system_input}"
            
            prompt_content = f"""You are an expert in smart contract attack detection. Your task is to analyze the current transaction to determine malicious intent.
            {context_content}
            Question: {query}
            You MUST respond in ENGLISH only
            Core Directive: The historical examples were retrieved due to high behavioral similarity to the current transaction. Therefore, you must assume malicious intent initially and focus on validating the attack pattern.
            Key Analysis Focus:
                - Bias: Start with the assumption that this is an Attack executing a known pattern.
                - Comparison: Directly compare the execution flow and fund transfers in `system_input` with the logic of the historical examples.
                - Logic: Ignore function names; focus on the operational sequence, state changes, and security implications.
                - Focus Points: Inter-contract calls, abnormal fund movements, and state manipulation patterns.
            Strict Answer Rules:
            - Start with: `Attack` or `Benign`.
            - Follow this structured format:
            [Attack || Benign]
            1. Behavior Summary:
            - Describe the transaction's overall contract interactions, fund movements, and final goal.
            2. Call Sequence Analysis:
            - Analyze the call sequence and highlight any unusual patterns.
            3. Malicious Indicators:
            - Identify specific behaviors that indicate an attack OR explain why the transaction is safe.
            - Limit your answer to 200 words."""
            
        else:
            prompt_content = f"""You are an expert in smart contract attack detection. Evaluate whether the current transaction is malicious based *only* on the provided transaction data.
            Current transaction (system_input):\n{system_input}
            Question: {query}
            You MUST respond in ENGLISH only     
            Core Guiding Principle: There is no prior knowledge or historical context provided. Your judgment must be based purely on the internal logic, security best practices, and execution behavior of the current transaction. Assume the transaction is Benign unless verifiable security flaws or abnormal logic are evident in the input.
            Strict Answer Rules:
            - You must begin your answer with one of: `Attack` or `Benign`.
            - Follow this structured format:

            [Attack || Benign]
            1. Behavior Summary:
            - Describe the transaction's overall behavior, including contract interactions and fund movements.
            2. Call Sequence Analysis:
            - Analyze the function call sequence. Highlight any unusual order of operations or patterns that violate established smart contract security practices.
            3. Malicious Indicators:
            - Identify specific behaviors that directly indicate an attack OR explicitly state why the transaction is logically sound.
            - Limit your answer to 200 words."""
        
        return prompt_content