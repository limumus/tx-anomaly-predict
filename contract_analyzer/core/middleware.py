import os
import json
import re
from typing import List, Dict, Optional, Set, Tuple
from collections import defaultdict
import hashlib
from pathlib import Path


class IntelligentExclusionSystem:
    MIDDLEWARE_DIRECTORY = "exclusion_middleware_fixed"
    TRANSACTION_HASH_LENGTH = 64
    HEXADECIMAL_PATTERN = r'^0x[a-fA-F0-9]{64}$'
    SOLIDITY_FILE_EXTENSION = '.sol'
    JSON_FILE_EXTENSION = '.json'
    EXCLUSION_RULES_FILE = "exclusion_rules.json"
    SEMANTIC_MAPPING_FILE = "simplified_mapping.json"
    
    def __init__(self, middleware_dir: str = MIDDLEWARE_DIRECTORY):
        self.middleware_dir = middleware_dir
        self.exclusion_patterns = {}
        self.semantic_mappings = {}
        self.knowledge_base_to_transactions = defaultdict(list)
        self.contract_to_knowledge_base = {}
        self._initialize_exclusion_configuration()
    
    def _initialize_exclusion_configuration(self) -> bool:
        try:
            exclusion_patterns_path = Path(self.middleware_dir) / self.EXCLUSION_RULES_FILE
            if exclusion_patterns_path.exists():
                with open(exclusion_patterns_path, 'r', encoding='utf-8') as config_file:
                    self.exclusion_patterns = json.load(config_file)
                
                configuration_status = f"Loaded {len(self.exclusion_patterns)} exclusion patterns"
                print(configuration_status)
            else:
                print(f"Exclusion patterns configuration not found: {exclusion_patterns_path}")
                return False
            
            semantic_mappings_path = Path(self.middleware_dir) / self.SEMANTIC_MAPPING_FILE
            if semantic_mappings_path.exists():
                with open(semantic_mappings_path, 'r', encoding='utf-8') as mapping_file:
                    self.semantic_mappings = json.load(mapping_file)
        
                self.contract_to_knowledge_base = self.semantic_mappings.get(
                    "contract_to_kb_file", 
                    {}
                )
                
                kb_transaction_mappings = self.semantic_mappings.get(
                    "kb_file_to_contracts", 
                    {}
                )
                self.knowledge_base_to_transactions = defaultdict(list, kb_transaction_mappings)
                
                mapping_status = f"Loaded semantic mappings: {len(self.contract_to_knowledge_base)} contract relationships"
                print(mapping_status)
            
            return True
            
        except Exception as configuration_error:
            print(f"Configuration initialization failed: {configuration_error}")
            return False
    
    def analyze_file_path_patterns(self, file_path: str) -> Dict[str, Optional[str]]:
        try:
            normalized_path = file_path.replace('\\', '/')
            path_components = normalized_path.split('/')
            
            analysis_results = {
                "contract_identifier": None,
                "transaction_hash": None,
                "structural_pattern": None
            }
            
            # Pattern 1: Solidity contract extraction
            for path_component in path_components:
                if path_component.endswith(self.SOLIDITY_FILE_EXTENSION):
                    contract_identifier = path_component.replace(self.SOLIDITY_FILE_EXTENSION, '')
                    analysis_results["contract_identifier"] = contract_identifier
                    break
            
            # Pattern 2: Transaction hash extraction
            hash_analysis = self._extract_transaction_signature(file_path)
            analysis_results["transaction_hash"] = hash_analysis
            
            # Pattern 3: Structural pattern classification
            structural_pattern = self._classify_path_structure(path_components)
            analysis_results["structural_pattern"] = structural_pattern
            
            return analysis_results
            
        except Exception as analysis_error:
            print(f"Path pattern analysis failed: {analysis_error}")
            return {"contract_identifier": None, "transaction_hash": None, "structural_pattern": None}
    
    def _extract_transaction_signature(self, file_path: str) -> Optional[str]:
        try:
            file_identifier = os.path.basename(file_path)
            
            # Strategy 1: Direct hexadecimal pattern matching
            if file_identifier.startswith('0x'):
                if file_identifier.endswith('.txt.json'):
                    transaction_signature = file_identifier[:-9]
                    return transaction_signature
                elif file_identifier.endswith(self.JSON_FILE_EXTENSION):
                    transaction_signature = file_identifier[:-5]
                    return transaction_signature
                elif '.' not in file_identifier:
                    return file_identifier
            
            # Strategy 2: Regular expression pattern extraction
            hash_pattern = r'0x[a-fA-F0-9]{64}'
            pattern_matches = re.findall(hash_pattern, file_path)
            
            if pattern_matches:
                return pattern_matches[0]
            
            return None
            
        except Exception as extraction_error:
            print(f"Transaction signature extraction failed: {extraction_error}")
            return None
    
    def _classify_path_structure(self, path_components: List[str]) -> str:
        component_count = len(path_components)
        
        if component_count < 3:
            return "minimal_structure"
        elif component_count < 5:
            return "standard_structure"
        elif component_count < 8:
            return "nested_structure"
        else:
            return "deeply_nested_structure"
    
    def construct_transaction_identifier(self, file_path: str) -> Optional[str]:
        path_analysis = self.analyze_file_path_patterns(file_path)
        
        contract_identifier = path_analysis["contract_identifier"]
        transaction_signature = path_analysis["transaction_hash"]
        
        if contract_identifier and transaction_signature:
            transaction_identifier = f"{contract_identifier}_{transaction_signature}"
            if self._validate_identifier_structure(transaction_identifier):
                return transaction_identifier
        
        return None
    
    def _validate_identifier_structure(self, identifier: str) -> bool:
        if '_' not in identifier:
            return False
        
        parts = identifier.split('_')
        if len(parts) != 2:
            return False
        
        contract_part = parts[0]
        hash_part = parts[1]
        
        if not contract_part or len(contract_part) < 3:
            return False
        
        if not re.match(self.HEXADECIMAL_PATTERN, hash_part):
            return False
        
        return True
    
    def identify_exclusion_targets(self, analysis_target_path: str) -> List[str]:
        # Strategy 1: Direct transaction identifier matching
        transaction_identifier = self.construct_transaction_identifier(analysis_target_path)
        
        if transaction_identifier and transaction_identifier in self.exclusion_patterns:
            exclusion_rules = self.exclusion_patterns[transaction_identifier]
            knowledge_base_targets = [
                exclusion_rule["kb_file"] 
                for exclusion_rule in exclusion_rules
            ]
            
            return knowledge_base_targets
        
        # Strategy 2: Contract-based pattern matching
        path_analysis = self.analyze_file_path_patterns(analysis_target_path)
        contract_identifier = path_analysis["contract_identifier"]
        
        if contract_identifier and contract_identifier in self.contract_to_knowledge_base:
            knowledge_base_file = self.contract_to_knowledge_base[contract_identifier]
            return [knowledge_base_file]
        
        # Strategy 3: Semantic mapping analysis
        if contract_identifier and "exclusion_rules_by_contract" in self.semantic_mappings:
            contract_rules = self.semantic_mappings["exclusion_rules_by_contract"].get(
                contract_identifier, 
                []
            )
            
            if contract_rules:
                knowledge_base_targets = list(set(
                    rule["kb_file"] 
                    for rule in contract_rules
                ))
                return knowledge_base_targets
        
        return []
    
    def evaluate_document_exclusion(
        self, 
        document_source: str, 
        analysis_target_path: str
    ) -> bool:

        knowledge_base_targets = self.identify_exclusion_targets(analysis_target_path)
        
        if not knowledge_base_targets:
            return False
        
        document_identifier = os.path.basename(document_source) if document_source else ""
        
        for target in knowledge_base_targets:
            if self._match_document_identifier(document_identifier, target):
                return True
        
        return False
    
    def _match_document_identifier(self, document_id: str, target_id: str) -> bool:
        if document_id == target_id:
            return True
        
        document_base = document_id.replace(self.JSON_FILE_EXTENSION, '')
        target_base = target_id.replace(self.JSON_FILE_EXTENSION, '')
        
        if document_base == target_base:
            return True
        
        if self._calculate_semantic_similarity(document_id, target_id) > 0.85:
            return True
        
        return False
    
    def _calculate_semantic_similarity(self, str1: str, str2: str) -> float:

        # Simple Jaccard similarity for demonstration
        # In production, implement more sophisticated semantic similarity
        set1 = set(str1.lower().split('_'))
        set2 = set(str2.lower().split('_'))
        
        if not set1 or not set2:
            return 0.0
        
        intersection = len(set1.intersection(set2))
        union = len(set1.union(set2))
        
        return intersection / union if union > 0 else 0.0
    
    def filter_documents_by_pattern(
        self, 
        documents: List, 
        analysis_target_path: str
    ) -> List:

        if not documents:
            return documents
        
        knowledge_base_targets = self.identify_exclusion_targets(analysis_target_path)
        
        if not knowledge_base_targets:
            return documents
        
        filtered_collection = []
        exclusion_count = 0
        
        for document in documents:
            document_source = self._extract_document_source(document)
            
            should_exclude = False
            if document_source:
                document_identifier = os.path.basename(document_source)
                
                for target in knowledge_base_targets:
                    if self._match_document_identifier(document_identifier, target):
                        should_exclude = True
                        exclusion_count += 1
                        break
            
            if not should_exclude:
                filtered_collection.append(document)
        
        return filtered_collection
    
    def _extract_document_source(self, document) -> Optional[str]:
        try:
            if hasattr(document, 'metadata') and document.metadata and 'source_file' in document.metadata:
                return document.metadata['source_file']
            elif isinstance(document, dict) and 'metadata' in document and 'source_file' in document['metadata']:
                return document['metadata']['source_file']
            
            return None
        except Exception:
            return None
    
    def analyze_target_metadata(self, analysis_target_path: str) -> Dict[str, Any]:
        path_analysis = self.analyze_file_path_patterns(analysis_target_path)
        
        metadata = {
            "contract_identifier": path_analysis["contract_identifier"],
            "transaction_signature": path_analysis["transaction_hash"],
            "structural_pattern": path_analysis["structural_pattern"],
            "exclusion_rules_present": False,
            "exclusion_targets": [],
            "associated_knowledge_base": None
        }
        
        transaction_identifier = self.construct_transaction_identifier(analysis_target_path)
        metadata["transaction_identifier"] = transaction_identifier
        
        # Check for exclusion patterns
        if transaction_identifier and transaction_identifier in self.exclusion_patterns:
            metadata["exclusion_rules_present"] = True
            metadata["exclusion_targets"] = [
                rule["kb_file"] 
                for rule in self.exclusion_patterns[transaction_identifier]
            ]
        
        # Identify associated knowledge base
        contract_id = path_analysis["contract_identifier"]
        if contract_id and contract_id in self.contract_to_knowledge_base:
            metadata["associated_knowledge_base"] = self.contract_to_knowledge_base[contract_id]
        
        return metadata