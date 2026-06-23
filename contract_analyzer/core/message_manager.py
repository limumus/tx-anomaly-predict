import json
from typing import List, Dict, Any, Optional, Tuple
from utils.compression_utils import summarize_call_tree
import textwrap


class MessageManager:
 
    SYSTEM_INPUT_COMPRESSION_THRESHOLD = 8000
    REFERENCE_TEXT_COMPRESSION_THRESHOLD = 4000
    MAX_TOTAL_CHARACTERS = 15000
    RESPONSE_LENGTH_LIMIT = 200
    MINIMAL_COMPRESSION_RATIO = 0.5
    HIGH_COMPRESSION_MAX_DEPTH = 5
    MEDIUM_COMPRESSION_MAX_DEPTH = 6
    LOW_COMPRESSION_MAX_DEPTH = 7
    
    @staticmethod
    def construct_analysis_messages(
        query: str,
        system_input: str,
        reference_text: str = "",
        skip_rag: bool = False,
        prompt_type: str = "rag",
        xgb_prob: Optional[float] = None          # 新增
    ) -> List[Dict[str, str]]:
        """
        构建分析消息，支持XGBoost概率提示
        """
        optimization_result = MessageManager._optimize_message_content(
            system_input, 
            reference_text, 
            skip_rag
        )
        
        optimized_system_input = optimization_result["system_input"]
        optimized_reference_text = optimization_result["reference_text"]
        
        # 构建XGBoost提示
        xgb_hint = ""
        if xgb_prob is not None:
            xgb_hint = (
                f"\n[ML Preliminary Assessment] XGBoost model outputs attack probability "
                f"{xgb_prob:.3f} (threshold 0.5). This is a corrective hint to avoid "
                f"false positives (over-classifying as attacks), not a final decision.\n"
            )
        
        if prompt_type == "rag":
            prompt_content = MessageManager._construct_contextual_analysis_prompt(
                query,
                optimized_system_input,
                optimized_reference_text,
                skip_rag,
                xgb_hint
            )
        else:
            prompt_content = MessageManager._construct_direct_analysis_prompt(
                query,
                optimized_system_input,
                xgb_hint
            )
        
        return [{
            "role": "user",
            "content": prompt_content,
            "type": "prompt",
            "content_length": len(prompt_content),
            "compression_applied": optimization_result["compression_applied"]
        }]

    @staticmethod
    def _construct_contextual_analysis_prompt(
        query: str,
        system_input: str,
        reference_text: str,
        skip_rag: bool,
        xgb_hint: str = ""
    ) -> str:
        """构建上下文分析提示（包含XGBoost提示）"""
        if not skip_rag and reference_text.strip():
            context_framework = textwrap.dedent(f"""
                Historical attack examples (context):{reference_text}
                Current transaction (system_input):{system_input}
            """)
        else:
            context_framework = textwrap.dedent(f"""
                Current transaction (system_input): {system_input}
            """)
        
        analytical_framework = textwrap.dedent(f"""
            You are an expert in smart contract attack detection. Your task is to analyze the `Current transaction` against `Historical attack examples` provided in the context to determine malicious intent.
            {context_framework}
            
            Key Analysis Focus:
            - Bias: Start with the assumption that this is an Attack executing a known pattern.
            - Comparison: Directly compare the execution flow and fund transfers in `system_input` with the logic of the historical examples.
            - Logic: Ignore function names; focus on the operational sequence, state changes, and security implications.
            - Focus Points: Inter-contract calls, abnormal fund movements, and state manipulation patterns.
            
            Core Directive: The historical examples were retrieved due to high behavioral similarity to the current transaction. Therefore, you must assume malicious intent initially and focus on validating the attack pattern.
            Question: {query}
            
            Strict Answer Rules:{xgb_hint}
            - Start with: `Attack` or `Benign`.
            - Follow this structured format:
            
            [Attack || Benign]
            1. Behavior Summary:
            - Describe the transaction's overall contract interactions, fund movements, and final goal.   
            2. Comparative Call Sequence Analysis:
            - Analyze `system_input`'s call sequence. Directly compare and reference the most similar historical functions from the context.
            - Explicitly state the shared malicious steps linking the transaction to the known pattern.
            3. Malicious Indicators & Similarity Assessment:
            - Identify specific behaviors confirming the attack.
            - Provide a qualitative similarity rating: State if the pattern match is `High`, `Moderate`, or `Low`.
            - Crucially: If the conclusion is `Benign`, you must provide irrefutable evidence that overrides the initial similarity bias and proves the logic is safe.
            
            - Limit your answer to {MessageManager.RESPONSE_LENGTH_LIMIT} words.
        """)
        
        return analytical_framework.strip()

    @staticmethod
    def _construct_direct_analysis_prompt(
        query: str,
        system_input: str,
        xgb_hint: str = ""
    ) -> str:
        """构建直接分析提示（无历史上下文）"""
        analytical_framework = textwrap.dedent(f"""
            You are an expert in smart contract attack detection. Evaluate whether the current transaction is malicious based *only* on the provided transaction data.
            Current transaction (system_input): {system_input} 
            Question: {query}
            
            You MUST respond in ENGLISH only
            Core Guiding Principle: There is no prior knowledge or historical context provided. Your judgment must be based purely on the internal logic, security best practices, and execution behavior of the current transaction. Assume the transaction is Benign unless verifiable security flaws or abnormal logic are evident in the input.
            
            Strict Answer Rules:{xgb_hint}
            - You must begin your answer with one of: `Attack` or `Benign`.
            - Follow this structured format:
            
            [Attack || Benign]
            1. Behavior Summary:
            - Describe the transaction's overall behavior, including contract interactions and fund movements.
            2. Call Sequence Analysis:
            - Analyze the function call sequence. Highlight any unusual order of operations or patterns that violate established smart contract security practices.  
            3. Malicious Indicators:
            - Identify specific behaviors that directly indicate an attack OR explicitly state why the transaction is logically sound.
            - Limit your answer to {MessageManager.RESPONSE_LENGTH_LIMIT} words.
        """)
        
        return analytical_framework.strip()
    
    @staticmethod
    def apply_intelligent_compression(
        system_input: str,
        reference_text: str = "",
        max_total_chars: int = MAX_TOTAL_CHARACTERS,
        system_input_weight: float = 0.7,
        reference_text_weight: float = 0.3
    ) -> Dict[str, str]:

        compression_plan = MessageManager._generate_compression_strategy(
            system_input,
            reference_text,
            max_total_chars,
            system_input_weight,
            reference_text_weight
        )
        
        if not compression_plan["requires_compression"]:
            return {
                "system_input": system_input,
                "reference_text": reference_text,
                "compression_applied": False,
                "compression_strategy": "none"
            }
        
        compressed_content = {
            "system_input": system_input,
            "reference_text": reference_text,
            "compression_applied": True,
            "compression_strategy": compression_plan["strategy"]
        }
        
        if compression_plan["system_input_requires_compression"]:
            compressed_content["system_input"] = MessageManager._compress_transaction_data(
                system_input,
                compression_plan["system_input_budget"]
            )
        
        if compression_plan["reference_text_requires_compression"]:
            compressed_content["reference_text"] = MessageManager._compress_contextual_data(
                reference_text,
                compression_plan["reference_text_budget"]
            )
        
        return compressed_content
    
    @staticmethod
    def _generate_compression_strategy(
        system_input: str,
        reference_text: str,
        max_total_chars: int,
        system_input_weight: float,
        reference_text_weight: float
    ) -> Dict[str, Any]:
        
        system_input_length = len(system_input)
        reference_text_length = len(reference_text)
        total_length = system_input_length + reference_text_length
        
        if total_length <= max_total_chars:
            return {
                "requires_compression": False,
                "strategy": "no_compression_needed"
            }
        
        system_input_budget = int(max_total_chars * system_input_weight)
        reference_text_budget = int(max_total_chars * reference_text_weight)
        
        if system_input_length < system_input_budget:
            surplus = system_input_budget - system_input_length
            reference_text_budget += surplus
            system_input_budget = system_input_length
        
        if reference_text_length < reference_text_budget:
            surplus = reference_text_budget - reference_text_length
            system_input_budget += surplus
            reference_text_budget = reference_text_length
        
        return {
            "requires_compression": True,
            "strategy": "adaptive_budget_allocation",
            "system_input_budget": system_input_budget,
            "reference_text_budget": reference_text_budget,
            "system_input_requires_compression": system_input_length > system_input_budget,
            "reference_text_requires_compression": reference_text_length > reference_text_budget,
            "original_lengths": {
                "system_input": system_input_length,
                "reference_text": reference_text_length,
                "total": total_length
            },
            "target_lengths": {
                "system_input": system_input_budget,
                "reference_text": reference_text_budget,
                "total": max_total_chars
            }
        }
    
    @staticmethod
    def _compress_transaction_data(
        transaction_data: str,
        max_chars: int = SYSTEM_INPUT_COMPRESSION_THRESHOLD
    ) -> str:

        if not transaction_data or len(transaction_data) <= max_chars:
            return transaction_data
        
        try:
            parsed_data = json.loads(transaction_data)
            compression_ratio = max_chars / len(transaction_data)
            
            # Select compression strategy based on required ratio
            if compression_ratio < MessageManager.MINIMAL_COMPRESSION_RATIO:
                compression_depth = MessageManager.HIGH_COMPRESSION_MAX_DEPTH
                summarization_threshold = 5
                strategy = "high_compression"
            elif compression_ratio < 0.7:
                compression_depth = MessageManager.MEDIUM_COMPRESSION_MAX_DEPTH
                summarization_threshold = 8
                strategy = "medium_compression"
            else:
                compression_depth = MessageManager.LOW_COMPRESSION_MAX_DEPTH
                summarization_threshold = 10
                strategy = "low_compression"
            
            compressed_structure = summarize_call_tree(
                parsed_data,
                max_depth=compression_depth,
                summarize_threshold=summarization_threshold
            )
            
            compressed_json = json.dumps(compressed_structure, ensure_ascii=False)
            
            if len(compressed_json) > max_chars:
                compressed_json = MessageManager._apply_fallback_compression(
                    compressed_json,
                    max_chars
                )
            
            return compressed_json
            
        except json.JSONDecodeError:
            return MessageManager._apply_textual_compression(transaction_data, max_chars)
        except Exception:
            return transaction_data[:max_chars] + "\n[Compression applied with fallback]"
    
    @staticmethod
    def _apply_fallback_compression(data: str, max_chars: int) -> str:
        if "{" in data and "}" in data:
            segment_length = max_chars // 2
            beginning_segment = data[:segment_length]
            ending_segment = data[-segment_length:]
            
            structural_break = beginning_segment.rfind("}")
            if structural_break > segment_length - 100:
                beginning_segment = beginning_segment[:structural_break + 1]
            
            structural_start = ending_segment.find("{")
            if structural_start < 100:
                ending_segment = ending_segment[structural_start:]
            
            return f"{beginning_segment}\n... [Content optimized for length] ...\n{ending_segment}"[:max_chars]
        
        return data[:max_chars]
    
    @staticmethod
    def _apply_textual_compression(text: str, max_chars: int) -> str:
        beginning_segment_length = int(max_chars * 0.6)
        ending_segment_length = max_chars - beginning_segment_length - 50
        
        compressed_text = (
            text[:beginning_segment_length] + 
            "\n\n... [Content optimized for analysis] ...\n\n" + 
            text[-ending_segment_length:]
        )
        
        return compressed_text[:max_chars] + "\n[Content length optimized]"
    
    @staticmethod
    def _compress_contextual_data(
        contextual_data: str,
        max_chars: int = REFERENCE_TEXT_COMPRESSION_THRESHOLD
    ) -> str:

        if not contextual_data or len(contextual_data) <= max_chars:
            return contextual_data
        
        content_segments = contextual_data.split("\n\n")
        
        if len(content_segments) <= 3:
            return contextual_data[:max_chars] + "\n[Content optimized]"
        
        segment_lengths = [len(segment) for segment in content_segments]
        total_content_length = sum(segment_lengths)
        average_segment_length = total_content_length / len(content_segments)
        
        segments_to_retain = max(2, int(max_chars / average_segment_length))
        
        if segments_to_retain >= len(content_segments):
            return contextual_data[:max_chars] + "\n[Content optimized]"
        
        initial_segments = max(1, segments_to_retain // 2)
        concluding_segments = segments_to_retain - initial_segments
        
        compressed_segments = (
            content_segments[:initial_segments] + 
            [f"[Optimized: {len(content_segments) - segments_to_retain} similar cases]"] + 
            content_segments[-concluding_segments:]
        )
        
        compressed_content = "\n\n".join(compressed_segments)
        
        if len(compressed_content) > max_chars:
            compressed_content = compressed_content[:max_chars]
        
        return compressed_content
    
    @staticmethod
    def _optimize_message_content(
        system_input: str,
        reference_text: str,
        skip_rag: bool
    ) -> Dict[str, Any]:

        if skip_rag or not reference_text:
            reference_text = ""
        
        compression_result = MessageManager.apply_intelligent_compression(
            system_input,
            reference_text
        )
        
        return {
            "system_input": compression_result["system_input"],
            "reference_text": compression_result["reference_text"],
            "compression_applied": compression_result["compression_applied"],
            "compression_strategy": compression_result.get("compression_strategy", "none")
        }
    
    @staticmethod
    def compress_system_input(system_input: str, max_chars: int) -> str:
        return MessageManager._compress_transaction_data(system_input, max_chars)