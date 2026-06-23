import os
import json
from typing import Dict, Any, Optional, List
from langchain_chroma import Chroma


def load_system_input(file_path: str) -> str:
    try:
        with open(file_path, 'r', encoding='utf-8') as file:
            config_data = json.load(file)
            return json.dumps(config_data, ensure_ascii=False)
    except Exception as load_error:
        return ""


def load_or_create_vector_store(
    persist_dir: str, 
    embedding_function: Any
) -> Chroma:
    return Chroma(
        persist_directory=persist_dir,
        embedding_function=embedding_function
    )


def extract_similarity_metrics(
    analysis_result: Dict[str, Any],
    input_metadata: Optional[Dict] = None
) -> Optional[Dict[str, Any]]:
    similarity_metrics = []
    
    if input_metadata and "_similarity_scores" in input_metadata:
        stored_scores = input_metadata["_similarity_scores"]
        if stored_scores:
            similarity_metrics = [float(score) for score in stored_scores]
    
    if not similarity_metrics and "context" in analysis_result:
        context_documents = analysis_result["context"]
        if context_documents:
            for document in context_documents:
                document_score = extract_document_similarity(document)
                if document_score is not None:
                    similarity_metrics.append(document_score)
    
    if similarity_metrics:
        return compute_statistical_summary(similarity_metrics)
    
    return None


def extract_document_similarity(document: Any) -> Optional[float]:
    metadata = extract_document_metadata(document)
    if not metadata:
        return None
    
    similarity_keys = [
        'similarity_score', 
        'score', 
        'similarity', 
        'distance'
    ]
    
    for key in similarity_keys:
        if key in metadata:
            score_value = metadata[key]
            try:
                return float(score_value)
            except (ValueError, TypeError):
                continue
    
    return None


def extract_document_metadata(document: Any) -> Optional[Dict]:
    if hasattr(document, 'metadata'):
        return document.metadata
    elif isinstance(document, dict) and 'metadata' in document:
        return document['metadata']
    return None


def compute_statistical_summary(
    scores: List[float]
) -> Dict[str, Any]:
    return {
        "minimum_score": min(scores),
        "maximum_score": max(scores),
        "average_score": sum(scores) / len(scores),
        "document_count": len(scores),
        "score_distribution": scores
    }


def save_analysis_results(
    results: Dict[str, Any], 
    output_path: str,
    indent_level: int = 2
) -> bool:
    try:
        with open(output_path, 'w', encoding='utf-8') as output_file:
            json.dump(results, output_file, ensure_ascii=False, indent=indent_level)
        return True
    except Exception as save_error:
        return False


def load_analysis_results(file_path: str) -> Optional[Dict[str, Any]]:
    try:
        with open(file_path, 'r', encoding='utf-8') as input_file:
            return json.load(input_file)
    except Exception as load_error:
        return None