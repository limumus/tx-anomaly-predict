import requests
import json
import time
from typing import List, Dict, Optional, Tuple
from .base_model import BaseAIModel
from config import CONFIG


class GiteeQwenAI:
    def __init__(self):
        self.api_url = CONFIG["GITEE_AI_API_URL"]
        self.api_key = CONFIG["GITEE_AI_API_KEY"]
        self.max_retries = CONFIG["MAX_RETRIES"]
        self.retry_delay = CONFIG["RETRY_DELAY"]
        
        self.DEFAULT_MODEL = "Qwen3-8B"
        self.DEFAULT_MAX_TOKENS = 1024
        self.DEFAULT_TEMPERATURE = 0.7
        self.REQUEST_TIMEOUT = 60
        self.EXPONENTIAL_BACKOFF_BASE = 2
        self.JITTER_FACTOR = 0.1

    def generate_response_with_retry(self, messages: List[Dict[str, str]], query_id: str = "unknown", **kwargs) -> str:
        last_error = None
        error_classifier = ErrorClassifier()
        
        for attempt in range(self.max_retries + 1):
            try:
                result = self._execute_api_call(messages, **kwargs)
                
                error_type = error_classifier.classify(result)
                if error_type.should_retry():
                    if attempt < self.max_retries:
                        backoff_delay = self._calculate_backoff_delay(attempt)
                        time.sleep(backoff_delay)
                        continue
                    else:
                        return self._format_failure_result(error_type, result, attempt)
                else:
                    return result
                    
            except requests.exceptions.Timeout as e:
                last_error = f"Request timeout: {str(e)}"
                if attempt < self.max_retries:
                    backoff_delay = self._calculate_backoff_delay(attempt)
                    time.sleep(backoff_delay)
                else:
                    break
                    
            except requests.exceptions.RequestException as e:
                last_error = f"Request exception: {str(e)}"
                if attempt < self.max_retries:
                    backoff_delay = self._calculate_backoff_delay(attempt)
                    time.sleep(backoff_delay)
                else:
                    break
                    
            except Exception as e:
                last_error = f"Unexpected error: {str(e)}"
                break
        
        error_report = self._construct_error_report(query_id, last_error, attempt, messages)
        return f"API call failed after {attempt + 1} attempts: {last_error}"

    def _execute_api_call(self, messages: List[Dict[str, str]], **kwargs) -> str:
        payload = self._construct_request_payload(messages, kwargs)
        headers = self._construct_request_headers()
        
        response = requests.post(
            self.api_url,
            headers=headers,
            json=payload,
            timeout=self.REQUEST_TIMEOUT
        )
        response.raise_for_status()
        
        return self._parse_response(response)

    def _construct_request_payload(self, messages: List[Dict[str, str]], custom_kwargs: Dict) -> Dict:
        base_payload = {
            "model": self.DEFAULT_MODEL,
            "messages": messages,
            "stream": False,
            "max_tokens": self.DEFAULT_MAX_TOKENS,
            "frequency_penalty": 0,
            "presence_penalty": 0,
            "temperature": self.DEFAULT_TEMPERATURE,
            "top_p": 1,
            "top_logprobs": 0,
            "n": 1,
        }
        
        merged_payload = {**base_payload, **custom_kwargs}
        return self._validate_payload(merged_payload)

    def _construct_request_headers(self) -> Dict:
        return {
            'Content-Type': 'application/json',
            'Authorization': f'Bearer {self.api_key}'
        }

    def _parse_response(self, response: requests.Response) -> str:
        response_data = response.json()
        
        if "choices" in response_data and len(response_data["choices"]) > 0:
            message_content = response_data["choices"][0].get("message", {}).get("content", "").strip()
            
            if not message_content:
                return "API returned empty content"
                
            return message_content
            
        return f"Unexpected API response format: {response_data}"

    def _calculate_backoff_delay(self, attempt: int) -> float:
        base_delay = self.retry_delay * (self.EXPONENTIAL_BACKOFF_BASE ** attempt)
        jitter = base_delay * self.JITTER_FACTOR
        return base_delay + jitter

    def _validate_payload(self, payload: Dict) -> Dict:
        # Remove None values to prevent API errors
        sanitized = {k: v for k, v in payload.items() if v is not None}
        
        # Enforce parameter constraints
        sanitized["temperature"] = max(0.0, min(1.0, sanitized.get("temperature", self.DEFAULT_TEMPERATURE)))
        sanitized["max_tokens"] = max(1, min(4096, sanitized.get("max_tokens", self.DEFAULT_MAX_TOKENS)))
        
        return sanitized

    def _construct_error_report(self, query_id: str, error: str, attempts: int, messages: List[Dict]) -> Dict:
        return {
            "query_id": query_id,
            "error_type": "API_CALL_FAILED",
            "error_message": error,
            "attempts": attempts + 1,
            "messages_preview": self._truncate_messages_preview(messages)
        }

    def _truncate_messages_preview(self, messages: List[Dict], max_length: int = 500) -> str:
        if not messages:
            return "No messages"
        
        preview = str(messages)
        if len(preview) > max_length:
            return preview[:max_length] + "..."
        return preview

    def _format_failure_result(self, error_type, result: str, attempts: int) -> str:
        return f"Exhausted retry attempts after {attempts + 1} tries. Classification: {error_type}, Details: {result}"

    def generate_response(self, messages: List[Dict[str, str]], **kwargs) -> str:
        return self.generate_response_with_retry(messages, "unknown", **kwargs)


class ErrorClassifier:
 
    def __init__(self):
        self.retryable_patterns = {
            "Request timeout": 3,
            "Request exception": 3,
            "Unexpected error": 1,
            "API returned empty content": 2,
            "Unexpected API response format": 2,
            "Authentication failed": 1
        }
        
        self.fatal_patterns = [
            "Invalid API key",
            "Rate limit exceeded",
            "Model not found"
        ]

    def classify(self, result: str) -> 'ErrorType':
        for pattern, max_retries in self.retryable_patterns.items():
            if pattern in result:
                return RetryableError(pattern, max_retries)
        
        for pattern in self.fatal_patterns:
            if pattern in result:
                return FatalError(pattern)
        
        return SuccessError()

class ErrorType:
    def should_retry(self) -> bool:
        return False

class RetryableError(ErrorType):
    def __init__(self, pattern: str, max_retries: int):
        self.pattern = pattern
        self.max_retries = max_retries
    
    def should_retry(self) -> bool:
        return True

class FatalError(ErrorType):
    def __init__(self, pattern: str):
        self.pattern = pattern

class SuccessError(ErrorType):
    pass