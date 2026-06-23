import os
import json
import glob
import pandas as pd
from typing import List, Dict, Any, Optional
from dataclasses import dataclass
from pathlib import Path


@dataclass
class DatasetEntry:
    file_path: str
    file_name: str
    label: str
    size: int


class DataLoader:
    
    @staticmethod
    def load_json_file(file_path: str) -> Dict[str, Any]:
        try:
            with open(file_path, 'r', encoding='utf-8') as f:
                return json.load(f)
        except Exception as e:
            print(f"Failed to load JSON file {file_path}: {e}")
            return {}
    
    @staticmethod
    def serialize_transaction_data(file_path: str) -> str:
        data = DataLoader.load_json_file(file_path)
        return json.dumps(data, ensure_ascii=False, indent=2)
    
    @staticmethod
    def discover_files(
        directory: str, 
        pattern: str = "**/*.json",
        recursive: bool = True
    ) -> List[str]:
        search_pattern = os.path.join(directory, pattern)
        return sorted(glob.glob(search_pattern, recursive=recursive))
    
    @staticmethod
    def create_labeled_dataset(
        files: List[str], 
        max_files: Optional[int] = None,
        balance_classes: bool = True
    ) -> List[DatasetEntry]:
        if not files:
            return []
        
        if max_files and max_files > 0:
            files = files[:max_files]
        
        dataset = []
        for file_path in files:
            # Classify based on filename patterns
            if any(keyword in file_path.lower() 
                   for keyword in ["_exp.sol", "_attack", "exploit"]):
                label = "Attack"
            else:
                label = "Benign"
            
            size = os.path.getsize(file_path) if os.path.exists(file_path) else 0
            dataset.append(DatasetEntry(
                file_path=file_path,
                file_name=os.path.basename(file_path),
                label=label,
                size=size
            ))
        
        # Optional class balancing
        if balance_classes and len(dataset) > 1:
            attack_entries = [d for d in dataset if d.label == "Attack"]
            benign_entries = [d for d in dataset if d.label == "Benign"]
            
            min_count = min(len(attack_entries), len(benign_entries))
            if min_count > 0:
                balanced_dataset = attack_entries[:min_count] + benign_entries[:min_count]
                return balanced_dataset
        
        return dataset
    
    @staticmethod
    def load_analysis_results(directory: str) -> List[Dict[str, Any]]:
        result_files = DataLoader.discover_files(directory, pattern="*.json")
        
        aggregated_results = []
        for result_file in result_files:
            try:
                with open(result_file, 'r', encoding='utf-8') as f:
                    data = json.load(f)
                    if isinstance(data, dict) and "results" in data:
                        aggregated_results.extend(data["results"])
                    elif isinstance(data, list):
                        aggregated_results.extend(data)
            except Exception as e:
                print(f"Failed to load result file {result_file}: {e}")
        
        return aggregated_results
    
    @staticmethod
    def to_dataframe(dataset: List[DatasetEntry]) -> pd.DataFrame:
        data_dicts = [
            {
                "file_path": entry.file_path,
                "file_name": entry.file_name,
                "label": entry.label,
                "size_kb": entry.size / 1024
            }
            for entry in dataset
        ]
        return pd.DataFrame(data_dicts)


# Utility functions for common operations
def load_transaction_batch(file_paths: List[str]) -> List[str]:
    return [DataLoader.serialize_transaction_data(fp) for fp in file_paths]


def validate_dataset(dataset: List[DatasetEntry]) -> bool:
    if not dataset:
        return False
    
    labels = set(entry.label for entry in dataset)
    required_labels = {"Attack", "Benign"}
    
    return required_labels.issubset(labels)