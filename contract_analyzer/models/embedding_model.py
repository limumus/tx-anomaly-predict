import requests
from typing import List
from langchain.embeddings.base import Embeddings
from requests.adapters import HTTPAdapter, Retry
from config.settings import CONFIG


class JinaEmbedding(Embeddings):
    def __init__(self):
        self.api_url = "api_url"
        self.headers = {
            "Authorization": f"Bearer {CONFIG.JINA_API_KEY}",
            "Content-Type": "application/json"
        }
        
        retry_strategy = Retry(
            total=CONFIG.RETRY_ATTEMPTS,
            backoff_factor=CONFIG.BACKOFF_FACTOR,
            status_forcelist=[429, 500, 502, 503, 504],
            allowed_methods=["POST"],
            respect_retry_after_header=True
        )
        
        self.session = requests.Session()
        adapter = HTTPAdapter(
            max_retries=retry_strategy,
            pool_connections=CONFIG.POOL_CONNECTIONS,
            pool_maxsize=CONFIG.POOL_MAXSIZE
        )
        self.session.mount("https://", adapter)
        
        self.MAX_INPUT_LENGTH = 8192
        self.REQUEST_TIMEOUT = 15
        self.DEFAULT_MODEL = CONFIG.EMBEDDING_MODEL

    def embed_documents(self, texts: List[str]) -> List[List[float]]:
        return [self._generate_embedding(text) for text in texts]

    def embed_query(self, text: str) -> List[float]:
        return self._generate_embedding(text)

    def _generate_embedding(self, text: str) -> List[float]:
        try:
            response = self.session.post(
                self.api_url,
                headers=self.headers,
                json={
                    "model": self.DEFAULT_MODEL,
                    "input": [self._preprocess_text(text)]
                },
                timeout=self.REQUEST_TIMEOUT
            )
            response.raise_for_status()
            
            return self._extract_embedding_vector(response)
            
        except requests.exceptions.HTTPError as e:
            return self._handle_http_error(e)
        except Exception as e:
            return self._handle_unexpected_error(e)

    def _preprocess_text(self, text: str) -> str:
        truncated_text = text[:self.MAX_INPUT_LENGTH]
        return truncated_text.strip()

    def _extract_embedding_vector(self, response: requests.Response) -> List[float]:
        response_data = response.json()
        
        if 'data' in response_data and len(response_data['data']) > 0:
            embedding_data = response_data['data'][0]
            if 'embedding' in embedding_data:
                return embedding_data['embedding']
        
        raise ValueError("Invalid response structure from embedding API")

    def _handle_http_error(self, error: requests.exceptions.HTTPError) -> List[float]:
        error_message = f"Embedding generation failed: {str(error)}"
        return []

    def _handle_unexpected_error(self, error: Exception) -> List[float]:
        error_message = f"Unexpected error during embedding generation: {str(error)}"
        return []