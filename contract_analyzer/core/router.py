from typing import Dict, Any, Optional
from .message_manager import MessageManager
from global_instances import get_skip_rag_manager


class PromptRouter:
    def __init__(self):
        self.strategy_controller = None
        self.performance_metrics = {}
    
    def _initialize_strategy_controller(self):
        if self.strategy_controller is None:
            self.strategy_controller = get_skip_rag_manager()
        return self.strategy_controller
    
    def analyze_contextual_strategy(self, input_data: Dict) -> Dict:
        strategy_controller = self._initialize_strategy_controller()
        
        if not strategy_controller:
            return {
                "error": "Strategy controller initialization failed",
                "strategy": "fallback"
            }
        
        contextual_strategy = strategy_controller.get_skip_rag()
        
        if contextual_strategy:
            prompt_strategy = "direct"
            strategy_explanation = "Direct analysis strategy selected: No contextual enhancement required"
        else:
            prompt_strategy = "rag"
            strategy_explanation = "Contextual enhancement strategy selected: Historical context available"
        
        analysis_query = input_data.get("query", "")
        system_context = input_data.get("system_input", "")
        historical_context = input_data.get("reference_text", "")
        
        prompt_parameters = {
            "analysis_query": analysis_query,
            "system_context": system_context,
            "historical_context": historical_context,
            "contextual_strategy": contextual_strategy,
            "prompt_strategy": prompt_strategy
        }
        
        contextual_messages = MessageManager.construct_analysis_messages(
            query=analysis_query,
            system_input=system_context,
            reference_text=historical_context,
            skip_rag=contextual_strategy,
            prompt_type=prompt_strategy
        )
        
        if contextual_messages:
            prompt_content = contextual_messages[0]["content"]
            prompt_parameters["content_validation"] = {
                "length_verification": len(prompt_content),
                "content_preview": prompt_content[:100] + "..." if len(prompt_content) > 100 else prompt_content
            }
        
        prompt_parameters["strategy_metadata"] = {
            "strategy_selection": prompt_strategy,
            "strategy_explanation": strategy_explanation,
            "contextual_analysis": "enabled" if not contextual_strategy else "disabled"
        }
        
        return prompt_parameters
    
    def route_to_optimized_prompt(self, input_data: Dict) -> Dict:
        try:
            strategy_analysis = self.analyze_contextual_strategy(input_data)
            
            if "error" in strategy_analysis:
                return {"error": strategy_analysis["error"]}
            
            analysis_query = strategy_analysis.get("analysis_query", "")
            system_context = strategy_analysis.get("system_context", "")
            historical_context = strategy_analysis.get("historical_context", "")
            contextual_strategy = strategy_analysis.get("contextual_strategy", True)
            prompt_strategy = strategy_analysis.get("prompt_strategy", "direct_analysis")
            
            optimized_parameters = {
                "query": analysis_query,
                "system_input": system_context,
                "reference_text": historical_context,
                "skip_rag": contextual_strategy,
                "prompt_type": prompt_strategy
            }
            
            optimized_parameters["performance_metrics"] = {
                "strategy_efficiency": "optimized",
                "context_utilization": "full" if not contextual_strategy else "minimal",
                "prompt_complexity": "enhanced" if not contextual_strategy else "simplified"
            }
            
            return optimized_parameters
            
        except Exception as processing_error:
            return {
                "error": f"Prompt routing processing error: {str(processing_error)}",
                "fallback_strategy": "direct_analysis"
            }