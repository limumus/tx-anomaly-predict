import requests
import json
import time
from typing import List, Dict, Any
from config.settings import CONFIG


class DeepSeekAPI:   
    def __init__(self):
        self.api_url = "api_url"
        self.api_key = CONFIG.DEEPSEEK_API_KEY
        self.max_retries = CONFIG.MAX_RETRIES
        self.retry_delay = CONFIG.RETRY_DELAY
        
        self.DEFAULT_MODEL = "deepseek-v3.2-exp"
        self.DEFAULT_MAX_TOKENS = 1024
        self.DEFAULT_TEMPERATURE = 0.7
        self.REQUEST_TIMEOUT = 60
        
        self.BACKOFF_BASE = 2
        self.JITTER_FACTOR = 0.1

    def generate_response_with_retry(self, messages: List[Dict], query_id: str = "unknown", **kwargs) -> str:
        error_context = None
        
        for attempt in range(self.max_retries + 1):
            try:
                result = self._make_api_call(messages, **kwargs)

                if self._should_retry(result):
                    if attempt < self.max_retries:
                        backoff_delay = self._calculate_backoff_delay(attempt)
                        time.sleep(backoff_delay)
                        continue
                    else:
                        return result

                return result

            except requests.exceptions.Timeout as e:
                error_context = f"Request timeout: {str(e)}"
                if attempt < self.max_retries:
                    backoff_delay = self._calculate_backoff_delay(attempt)
                    time.sleep(backoff_delay)
                else:
                    break

            except requests.exceptions.RequestException as e:
                error_context = f"Request exception: {str(e)}"
                if attempt < self.max_retries:
                    backoff_delay = self._calculate_backoff_delay(attempt)
                    time.sleep(backoff_delay)
                else:
                    break

            except Exception as e:
                error_context = f"Unexpected error: {str(e)}"
                break

        error_data = {
            "query_id": query_id,
            "error_type": "API_CALL_FAILED",
            "error_message": error_context,
            "attempts": attempt + 1,
            "messages_preview": self._truncate_messages_preview(messages)
        }

        return f"API request failed after {attempt + 1} attempts: {error_context}"

    def _make_api_call(self, messages: List[Dict], **kwargs) -> str:
        payload = {
            "model": self.DEFAULT_MODEL,
            "messages": messages,
            "stream": False,
            "max_tokens": self.DEFAULT_MAX_TOKENS,
            "temperature": self.DEFAULT_TEMPERATURE,
            "top_p": 1,
            "n": 1,
            "enable_thinking": True
        }
        
        payload.update(kwargs)

        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json"
        }

        response = requests.post(
            self.api_url,
            headers=headers,
            json=payload,
            timeout=self.REQUEST_TIMEOUT
        )
        response.raise_for_status()

        response_data = response.json()

        if "choices" in response_data and len(response_data["choices"]) > 0:
            message = response_data["choices"][0].get("message", {})
            content = message.get("content", "").strip()
            
            if not content:
                return "API returned empty content"
                
            return content
        else:
            error_message = f"Unexpected API response format: {response_data}"
            return error_message

    def _calculate_backoff_delay(self, attempt: int) -> float:
        delay = self.retry_delay * (self.BACKOFF_BASE ** attempt)
        jitter = delay * self.JITTER_FACTOR
        return delay + jitter

    def _should_retry(self, result: str) -> bool:
        RETRYABLE_PATTERNS = [
            "Request timeout",
            "Request exception",
            "Unexpected error",
            "API returned empty content",
            "Unexpected API response format",
            "Authentication failed"
        ]
        
        return any(pattern in result for pattern in RETRYABLE_PATTERNS)

    def _truncate_messages_preview(self, messages: List[Dict], max_length: int = 500) -> str:
        if not messages:
            return "No messages"
        
        preview = str(messages)
        return preview[:max_length] + "..." if len(preview) > max_length else preview

    def generate_response(self, messages: List[Dict], **kwargs) -> str:
        return self.generate_response_with_retry(messages, "unknown", **kwargs)