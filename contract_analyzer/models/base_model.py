from abc import ABC, abstractmethod
from typing import List, Dict, Any, Optional
import requests
import time
import json

class BaseAIModel(ABC):
    def __init__(self, config: Dict[str, Any]):
        self.config = config
        self.max_retries = config.get("MAX_RETRIES", 5)
        self.retry_delay = config.get("RETRY_DELAY", 10)
    
    @abstractmethod
    def generate_response(self, messages: List[Dict[str, str]], **kwargs) -> str:
        pass
    
    def _make_request_with_retry(self, url: str, headers: Dict, data: Dict, 
                                timeout: int = 60) -> requests.Response:
        for attempt in range(self.max_retries + 1):
            try:
                response = requests.post(
                    url,
                    headers=headers,
                    json=data,
                    timeout=timeout
                )
                return response
            except requests.exceptions.Timeout:
                if attempt < self.max_retries:
                    time.sleep(self._calculate_backoff_delay(attempt))
                    continue
                raise
            except requests.exceptions.RequestException:
                if attempt < self.max_retries:
                    time.sleep(self._calculate_backoff_delay(attempt))
                    continue
                raise
    
    def _calculate_backoff_delay(self, attempt: int) -> float:
        base_delay = self.retry_delay * (2 ** attempt)
        jitter = base_delay * 0.1
        return base_delay + jitter
    
    def _check_input_too_long_error(self, error_msg: str) -> bool:
        LENGTH_VALIDATION_PATTERNS = {
            "max input characters",
            "prompt tokens too long", 
            "input too long",
            "tokens too long",
            "content too long",
            "max_tokens",
            "token_limit",
            "too_long",
            "length",
            "exceed",
            "limit"
        }
        
        normalized_message = error_msg.lower()
        return any(pattern in normalized_message for pattern in LENGTH_VALIDATION_PATTERNS)