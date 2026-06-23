from .ernie_model import BaiduErnieAI, ErnieLLMWrapper
from .llama_model import LlamaInstructAI
from .deepseek_model import DeepSeekAPI
from .gitee_wrapper import GiteeQwenAI
from .embedding_model import JinaEmbedding
from .base_model import BaseAIModel
from .local_model_manager import (
    LocalLLMManager,
    LocalLLMImplementation,
    LocalEmbeddingModel,
    BaseLocalModel,
    ModelConfiguration,
    ModelType
)
from .model_registry import (
    ModelRegistry,
    ModelSelector,
    LoadBalancingStrategy,
    PerformanceMetrics
)

__version__ = "1.0.0"
__author__ = "AI Integration Framework Team"
__license__ = "Apache 2.0"


__all__ = [
    'BaiduErnieAI',
    'ErnieLLMWrapper',
    'LlamaInstructAI', 
    'DeepSeekAPI',
    'GiteeQwenAI',
    'JinaEmbedding',
    'BaseAIModel',
    'LocalLLMManager',
    'LocalLLMImplementation',
    'LocalEmbeddingModel',
    'BaseLocalModel',
    'ModelConfiguration',
    'ModelType',
    'ModelRegistry',
    'ModelSelector',
    'LoadBalancingStrategy',
    'PerformanceMetrics',
]