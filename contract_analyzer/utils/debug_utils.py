from typing import Any, Dict, Optional, Union
from dataclasses import dataclass, field
from langchain.callbacks.base import BaseCallbackHandler

@dataclass
class PipelineState:
    skip_rag: bool = False
    metadata: Dict[str, Any] = field(default_factory=dict)
    
    def update(self, **kwargs) -> None:
        self.metadata.update(kwargs)
    
    def clear(self) -> None:
        self.skip_rag = False
        self.metadata.clear()


class StateManager: 
    def __init__(self):
        self._state = PipelineState()
    
    def set_skip_rag(self, value: bool) -> None:
        self._state.skip_rag = value
    
    def get_skip_rag(self) -> bool:
        return self._state.skip_rag
    
    def reset_state(self) -> None:
        self._state.clear()
    
    def get_state(self) -> PipelineState:
        return self._state
    
    def update_metadata(self, **kwargs) -> None:
        self._state.update(**kwargs)


class ExecutionTracker:
    
    @staticmethod
    def trace_execution(input_data: Any, component: str) -> Any:
        """Monitor data transformation through pipeline components"""
        if isinstance(input_data, dict):
            rag_status = input_data.get('skip_rag', 'not_set')
            
            print(f"[{component}] RAG Status: {rag_status}")
            
            if 'context' in input_data:
                context = input_data['context']
                if isinstance(context, list):
                    print(f"   Context Documents: {len(context)}")
        return input_data


class PipelineMonitor(BaseCallbackHandler):
    
    def on_llm_start(
        self, 
        serialized: Dict[str, Any], 
        prompts: list, 
        **kwargs: Any
    ) -> None:
        """Capture and display prompts sent to LLM"""
        print("\n" + "=" * 80)
        print("LLM Inference Request")
        print("=" * 80)
        
        for idx, prompt in enumerate(prompts, 1):
            print(f"\n[Prompt {idx}]")
            print("-" * 40)
            print(prompt)
        
        print("=" * 80)
    
    def on_llm_end(
        self, 
        response: Any, 
        **kwargs: Any
    ) -> None:
        print("\n" + "=" * 80)
        print("LLM Inference Response")
        print("=" * 80)
        
        if hasattr(response, 'content'):
            print(response.content)
        elif hasattr(response, 'generations'):
            for generation in response.generations:
                for item in generation:
                    print(item.text)
        
        print("=" * 80)


# Global instance management
_state_manager_instance: Optional[StateManager] = None

def get_state_manager() -> StateManager:
    global _state_manager_instance
    if _state_manager_instance is None:
        _state_manager_instance = StateManager()
    return _state_manager_instance

def get_skip_rag_manager() -> StateManager:
    return get_state_manager()