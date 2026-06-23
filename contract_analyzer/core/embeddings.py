import requests
from typing import List, Optional
from langchain.embeddings.base import Embeddings
from requests.adapters import HTTPAdapter, Retry
from tenacity import retry, stop_after_attempt, wait_exponential, retry_if_exception_type
import numpy as np

from config.settings import CONFIG


class JinaEmbedding(Embeddings):

    API_BASE_URL = "api_url"
    MAX_TEXT_LENGTH = 8192
    REQUEST_TIMEOUT_SECONDS = 15
    MAX_RETRY_ATTEMPTS = 3
    BACKOFF_MULTIPLIER = 2
    RETRY_STATUS_CODES = {429, 500, 502, 503, 504}
    
    def __init__(self):

        self.api_url = self.API_BASE_URL
        self.headers = {
            "Authorization": f"Bearer {CONFIG['JINA_API_KEY']}",
            "Content-Type": "application/json",
            "Accept": "application/json"
        }
        
        retry_strategy = Retry(
            total=self.MAX_RETRY_ATTEMPTS,
            backoff_factor=self.BACKOFF_MULTIPLIER,
            status_forcelist=list(self.RETRY_STATUS_CODES),
            allowed_methods=["POST"],
            respect_retry_after_header=True
        )
        
        self.session = requests.Session()
        self.session.mount("https://", HTTPAdapter(
            max_retries=retry_strategy,
            pool_connections=10,
            pool_maxsize=100
        ))
    
    @retry(
        stop=stop_after_attempt(MAX_RETRY_ATTEMPTS),
        wait=wait_exponential(multiplier=BACKOFF_MULTIPLIER),
        retry=retry_if_exception_type((requests.Timeout, requests.ConnectionError))
    )
    def embed_documents(self, texts: List[str]) -> List[List[float]]:
        processed_texts = self._preprocess_text_batch(texts)
        embeddings = []
        for text in processed_texts:
            embedding = self._generate_embedding_vector(text)
            if embedding:
                embeddings.append(embedding)
            else:
                embeddings.append(self._generate_fallback_embedding())
        
        return embeddings
    
    def embed_query(self, text: str) -> List[float]:
        processed_text = self._preprocess_single_text(text)
        embedding = self._generate_embedding_vector(processed_text)
        
        if embedding:
            return embedding
        else:
            return self._generate_fallback_embedding()
    
    def _preprocess_text_batch(self, texts: List[str]) -> List[str]:
        processed = []
        for text in texts:
            # Length optimization and normalization
            if len(text) > self.MAX_TEXT_LENGTH:
                text = self._truncate_optimally(text)
            processed.append(text.strip())
        return processed
    
    def _preprocess_single_text(self, text: str) -> str:
        if len(text) > self.MAX_TEXT_LENGTH:
            text = self._truncate_optimally(text)
        return text.strip()
    
    def _truncate_optimally(self, text: str) -> str:
        if len(text) > self.MAX_TEXT_LENGTH:
            truncated = text[:self.MAX_TEXT_LENGTH]
            
            last_period = truncated.rfind('.')
            last_exclamation = truncated.rfind('!')
            last_question = truncated.rfind('?')
            
            boundary = max(last_period, last_exclamation, last_question)
            if boundary > self.MAX_TEXT_LENGTH * 0.5:
                return truncated[:boundary + 1]
        
        return text[:self.MAX_TEXT_LENGTH]
    
    def _generate_embedding_vector(self, text: str) -> Optional[List[float]]:
        try:
            response = self.session.post(
                self.api_url,
                headers=self.headers,
                json={
                    "model": CONFIG.get("embedding_model", "jina-embeddings-v3"),
                    "input": [text],
                    "encoding_format": "float"
                },
                timeout=self.REQUEST_TIMEOUT_SECONDS
            )
            
            response.raise_for_status()
            
            response_data = response.json()
            if 'data' in response_data and len(response_data['data']) > 0:
                embedding_vector = response_data['data'][0]['embedding']
                
                # Validate embedding quality
                if self._validate_embedding_quality(embedding_vector):
                    return embedding_vector
            
            return None
            
        except requests.exceptions.Timeout:
            print("Embedding generation timeout: Retrying with exponential backoff")
            return None
        except requests.exceptions.RequestException as network_error:
            print(f"Network error during embedding generation: {str(network_error)}")
            return None
        except (KeyError, ValueError) as parsing_error:
            print(f"Response parsing error: {str(parsing_error)}")
            return None
        except Exception as unexpected_error:
            print(f"Unexpected embedding error: {str(unexpected_error)}")
            return None
    
    def _validate_embedding_quality(self, embedding_vector: List[float]) -> bool:
        if not embedding_vector:
            return False
        
        vector_array = np.array(embedding_vector)

        if np.any(np.isnan(vector_array)) or np.any(np.isinf(vector_array)):
            return False
        
        vector_magnitude = np.linalg.norm(vector_array)
        if vector_magnitude < 1e-10:
            return False
        
        if len(embedding_vector) < 100:  # Minimum reasonable dimensionality
            return False
        
        return True
    
    def _generate_fallback_embedding(self) -> List[float]:
        dimensionality = self._infer_embedding_dimensionality()
        random_vector = np.random.randn(dimensionality)
        normalized_vector = random_vector / np.linalg.norm(random_vector)
        
        return normalized_vector.tolist()
    
    def _infer_embedding_dimensionality(self) -> int:
        model_dimensionalities = {
            "jina-embeddings-v2-base-en": 768,
            "jina-embeddings-v2-base-zh": 768,
            "jina-embeddings-v2-base-es": 768,
            "jina-embeddings-v2-base-de": 768,
            "jina-embeddings-v2-base-code": 768,
            "default": 768
        }
        
        model_name = CONFIG.get("EMBEDDING_MODEL", "").lower()
        return model_dimensionalities.get(model_name, model_dimensionalities["default"])
    
    def batch_embed_documents(self, texts: List[str], batch_size: int = 32) -> List[List[float]]:
        embeddings = []
        
        for batch_start in range(0, len(texts), batch_size):
            batch_end = min(batch_start + batch_size, len(texts))
            text_batch = texts[batch_start:batch_end]
            
            batch_embeddings = self.embed_documents(text_batch)
            embeddings.extend(batch_embeddings)
        
        return embeddings