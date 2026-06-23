import json
from typing import Dict, Any, Set, List, Tuple
from dataclasses import dataclass
from collections import defaultdict, Counter
import hashlib


@dataclass
class CallSignature:
    call_type: str
    contract_hash: str
    function_hash: str
    
    @classmethod
    def from_call(cls, call: Dict[str, Any]) -> 'CallSignature':
        call_type = call.get("type", "UNKNOWN")
        contract = call.get("contract", "") or call.get("to", "") or "unknown"
        function = call.get("function", "unknown")
        
        # Use consistent hashing for pattern recognition
        contract_hash = hashlib.md5(contract.encode()).hexdigest()[:8]
        function_hash = hashlib.md5(function.encode()).hexdigest()[:8]
        
        return cls(call_type, contract_hash, function_hash)


class CallTreeCompressor:
    @staticmethod
    def compress_large_call_sequence(
        calls: List[Dict[str, Any]], 
        threshold: int = 8
    ) -> Dict[str, Any]:
        
        if len(calls) <= threshold:
            return {"calls": calls}
        
        # Phase 1: Pattern analysis and clustering
        clusters = CallTreeCompressor._cluster_calls_by_pattern(calls)
        
        # Phase 2: Representative sampling from clusters
        representatives = CallTreeCompressor._sample_representatives(clusters)
        
        # Phase 3: Statistical summary generation
        statistics = CallTreeCompressor._generate_compression_statistics(clusters, len(calls))
        
        return {
            "representative_samples": representatives[:5],
            "compression_statistics": statistics,
            "original_count": len(calls),
            "compression_ratio": f"{(len(calls) - 5) / len(calls):.1%}"
        }
    
    @staticmethod
    def _cluster_calls_by_pattern(calls: List[Dict[str, Any]]) -> Dict[str, List[Dict[str, Any]]]:
        clusters = defaultdict(list)
        
        for call in calls:
            signature = CallSignature.from_call(call)
            cluster_key = f"{signature.call_type}_{signature.contract_hash}"
            clusters[cluster_key].append(call)
        
        return dict(clusters)
    
    @staticmethod
    def _sample_representatives(clusters: Dict[str, List[Dict[str, Any]]]) -> List[Dict[str, Any]]:

        representatives = []
        
        for cluster_key, cluster_calls in clusters.items():
            sample_size = min(2, len(cluster_calls))
            
            seen_functions = set()
            for call in cluster_calls:
                if len(representatives) >= 10:  # Global limit
                    break
                    
                function = call.get("function", "")
                if function not in seen_functions:
                    seen_functions.add(function)
                    representatives.append(call)
                    if len(seen_functions) >= sample_size:
                        break
        
        return representatives
    
    @staticmethod
    def _generate_compression_statistics(
        clusters: Dict[str, List[Dict[str, Any]]], 
        total_calls: int
    ) -> Dict[str, Any]:

        unique_patterns = len(clusters)
        avg_cluster_size = total_calls / unique_patterns if unique_patterns > 0 else 0
        
        type_distribution = Counter()
        for cluster_key in clusters:
            call_type = cluster_key.split('_')[0]
            type_distribution[call_type] += len(clusters[cluster_key])
        
        all_functions = set()
        for cluster_calls in clusters.values():
            for call in cluster_calls:
                function = call.get("function", "")
                if function:
                    all_functions.add(function)
        
        return {
            "total_calls": total_calls,
            "unique_patterns": unique_patterns,
            "pattern_density": avg_cluster_size,
            "call_type_distribution": dict(type_distribution),
            "unique_functions": len(all_functions),
            "compression_applied": total_calls > 8
        }


def summarize_call_tree(
    data: Any,
    max_depth: int = 7,
    current_depth: int = 0,
    summarize_threshold: int = 8
) -> Any:

    if current_depth >= max_depth:
        return {
            "summary": f"Depth limit exceeded at level {current_depth}",
            "compression_applied": True,
            "truncated": True
        }

    if isinstance(data, dict):
        result: Dict[str, Any] = {}
        
        for key, value in data.items():
            if key == "internal_calls" and isinstance(value, list):
                compression_result = CallTreeCompressor.compress_large_call_sequence(
                    value, 
                    summarize_threshold
                )
                
                if "compression_statistics" in compression_result:
                    result[key] = [
                        summarize_call_tree(call, max_depth, current_depth + 1)
                        for call in compression_result["representative_samples"]
                    ] + [{
                        "statistical_compression": compression_result["compression_statistics"],
                        "note": f"Original {compression_result['original_count']} calls compressed to 5 samples"
                    }]
                else:
                    deduplicated = CallTreeCompressor._deduplicate_calls(
                        value, max_depth, current_depth
                    )
                    result[key] = deduplicated
            else:
                result[key] = summarize_call_tree(value, max_depth, current_depth + 1)
        
        return result
    
    elif isinstance(data, list):
        compression_threshold = 60
        
        if len(data) > compression_threshold:
            sample_size = min(30, compression_threshold)
            step = max(1, len(data) // sample_size)
            
            sampled_items = [
                summarize_call_tree(data[i], max_depth, current_depth)
                for i in range(0, len(data), step)
            ][:sample_size]
            
            sampled_items.append({
                "compression_note": {
                    "original_size": len(data),
                    "sampled_size": len(sampled_items) - 1,
                    "sampling_strategy": "systematic_sampling"
                }
            })
            
            return sampled_items
        else:
            return [
                summarize_call_tree(item, max_depth, current_depth)
                for item in data
            ]
    
    else:
        return data