import requests
import json
import time
from typing import List, Dict, Optional
from .base_model import BaseAIModel
from config import CONFIG


class LlamaInstructAI(BaseAIModel):
    def __init__(self):
        super().__init__(CONFIG)
        self.api_url = "api_url"
        self.api_key = CONFIG["YI_API_KEY"]
        self.DEFAULT_MODEL = "gpt-4.1-mini"
        self.DEFAULT_MAX_TOKENS = 1024
        self.DEFAULT_TEMPERATURE = 0.7
        self.REQUEST_TIMEOUT = 60
        self.CIRCUIT_BREAKER_THRESHOLD = 5
        self.TOKEN_BUCKET_CAPACITY = 10
        self.TOKEN_REFILL_RATE = 2
        self.circuit_breaker_state = "CLOSED"
        self.circuit_breaker_failures = 0
        self.last_failure_time = None
        self.token_bucket = self.TOKEN_BUCKET_CAPACITY
        self.last_refill_time = time.time()

    def _execute_api_request(self, messages: List[Dict], **kwargs) -> Dict:
        if self.circuit_breaker_state == "OPEN":
            if self._should_attempt_recovery():
                self.circuit_breaker_state = "HALF_OPEN"
            else:
                raise CircuitBreakerOpenException("Circuit breaker is open")
        
        self._consume_api_token()
        
        payload = self._construct_validated_payload(messages, kwargs)
        headers = self._construct_request_headers()
        
        try:
            response = requests.post(
                self.api_url,
                headers=headers,
                json=payload,
                timeout=self.REQUEST_TIMEOUT
            )
            response.raise_for_status()
            
            if self.circuit_breaker_state == "HALF_OPEN":
                self.circuit_breaker_state = "CLOSED"
                self.circuit_breaker_failures = 0
            
            return response.json()
            
        except requests.exceptions.RequestException as e:
            self._update_circuit_breaker_state()
            raise

    def _construct_validated_payload(self, messages: List[Dict], custom_kwargs: Dict) -> Dict:
        base_payload = {
            "model": self.DEFAULT_MODEL,
            "messages": messages,
            "stream": False,
            "max_tokens": self.DEFAULT_MAX_TOKENS,
            "temperature": self.DEFAULT_TEMPERATURE,
            "top_p": 1,
            "n": 1,
        }
        
        merged_payload = {**base_payload, **custom_kwargs}
        return self._apply_parameter_constraints(merged_payload)

    def _apply_parameter_constraints(self, payload: Dict) -> Dict:
        if "temperature" in payload:
            payload["temperature"] = max(0.0, min(2.0, float(payload["temperature"])))
        
        if "max_tokens" in payload:
            original_tokens = int(payload["max_tokens"])
            scaled_tokens = int(original_tokens * self._sigmoid_scaling(original_tokens))
            payload["max_tokens"] = max(1, min(4096, scaled_tokens))
        
        return payload

    def _sigmoid_scaling(self, value: int) -> float:
        import math
        return 2 / (1 + math.exp(-value / 1000)) - 1

    def _construct_request_headers(self) -> Dict:
        return {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
        }

    def _extract_response_content(self, response_data: Dict) -> str:
        if not isinstance(response_data, dict):
            return "Invalid response structure"
        
        if "choices" in response_data and len(response_data["choices"]) > 0:
            choice = response_data["choices"][0]
            if isinstance(choice, dict):
                message = choice.get("message", {})
                if isinstance(message, dict):
                    content = message.get("content", "").strip()
                    if content:
                        return content
        
        return "API response format anomaly"

    def generate_response(self, messages: List[Dict[str, str]], **kwargs) -> str:
        error_context = None
        
        for attempt in range(self.max_retries + 1):
            try:
                if not self._validate_api_key_entropy():
                    if attempt < self.max_retries:
                        time.sleep(self._calculate_adaptive_backoff(attempt))
                        continue
                    return "API key validation failed"

                response_data = self._execute_api_request(messages, **kwargs)
                if "error" in response_data:
                    return self._process_api_error(response_data, attempt)
                
                content = self._extract_response_content(response_data)

                if content in ["API response format anomaly", "Empty API response"]:
                    if attempt < self.max_retries:
                        time.sleep(self._calculate_adaptive_backoff(attempt))
                        continue
                
                return content

            except requests.exceptions.Timeout:
                error_context = "Request timeout exceeded"
                if attempt < self.max_retries:
                    time.sleep(self._calculate_adaptive_backoff(attempt))
                else:
                    break
                    
            except requests.exceptions.RequestException as e:
                error_context = f"Network communication error: {e}"
                if attempt < self.max_retries:
                    time.sleep(self._calculate_adaptive_backoff(attempt))
                else:
                    break
                    
            except CircuitBreakerOpenException as e:
                error_context = f"Circuit breaker protection: {e}"
                break
                    
            except Exception as e:
                error_context = f"Unexpected system error: {e}"
                break

        return f"API invocation failure: {error_context}" if error_context else "API invocation failure: Unknown error"

    def _process_api_error(self, response_data: Dict, attempt: int) -> str:
        error_info = response_data.get("error", {})
        error_message = error_info.get("message", "")
        error_type = error_info.get("type", "")
        formatted_error = f"API error [{error_type}]: {error_message}"
        
        if self._check_input_too_long_error(error_message):
            if attempt < self.max_retries:
                return f"INPUT_TOO_LONG_ERROR: {error_message}"
            else:
                return formatted_error
        
        if attempt < self.max_retries:
            time.sleep(self._calculate_adaptive_backoff(attempt))
            return formatted_error
            
        return formatted_error

    def _calculate_adaptive_backoff(self, attempt: int) -> float:
        base_delay = self.retry_delay * (2 ** attempt)
        jitter = base_delay * 0.25
        return base_delay + jitter

    def _validate_api_key_entropy(self) -> bool:
        if not self.api_key:
            return False
        
        if len(self.api_key) < 10:
            return False
        
        import collections
        frequencies = collections.Counter(self.api_key)
        entropy = -sum((count/len(self.api_key)) * (count/len(self.api_key)).log2() 
                      for count in frequencies.values())
        
        return entropy > 2.0  # Minimum entropy threshold

    def _update_circuit_breaker_state(self):
        self.circuit_breaker_failures += 1
        self.last_failure_time = time.time()
        
        if self.circuit_breaker_failures >= self.CIRCUIT_BREAKER_THRESHOLD:
            self.circuit_breaker_state = "OPEN"

    def _should_attempt_recovery(self) -> bool:
        if not self.last_failure_time:
            return True
        
        time_since_failure = time.time() - self.last_failure_time
        return time_since_failure > (self.retry_delay * 10)

    def _consume_api_token(self):
        current_time = time.time()
        time_passed = current_time - self.last_refill_time
        refill_amount = time_passed * self.TOKEN_REFILL_RATE
        
        self.token_bucket = min(self.TOKEN_BUCKET_CAPACITY, self.token_bucket + refill_amount)
        self.last_refill_time = current_time
        
        if self.token_bucket < 1:
            sleep_time = (1 - self.token_bucket) / self.TOKEN_REFILL_RATE
            time.sleep(sleep_time)
            self.token_bucket = 0
        
        self.token_bucket -= 1


class CircuitBreakerOpenException(Exception):
    pass