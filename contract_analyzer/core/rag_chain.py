import json
import pandas as pd
from typing import Dict, Any, List, Set
from langchain_core.documents import Document
from core.base_chain import BaseChain


class RAGEnhancementChain(BaseChain):
    CSV_ENCODING = "MacRoman"
    REQUIRED_CSV_COLUMNS = ['id', 'description_Security']
    MIN_DESCRIPTIONS_FOR_ENHANCEMENT = 1
    
    def __init__(self, vector_store, llm, csv_file_path: str, original_input: Dict):
        super().__init__(vector_store, llm, csv_file_path, original_input)
        self.semantic_mappings_cache = None
    
    def _load_semantic_mappings(self) -> Dict[str, str]:
        if self.semantic_mappings_cache is not None:
            return self.semantic_mappings_cache
        
        try:
            semantic_data = pd.read_csv(
                self.csv_file_path,
                usecols=self.REQUIRED_CSV_COLUMNS,
                encoding=self.CSV_ENCODING
            )
            
            semantic_data["id"] = semantic_data["id"].astype(str)
            semantic_mappings = dict(zip(
                semantic_data["id"], 
                semantic_data["description_Security"]
            ))
            
            self.semantic_mappings_cache = semantic_mappings
            return semantic_mappings
            
        except Exception as data_loading_error:
            print(f"Semantic mapping initialization failed: {data_loading_error}")
            return {}
    
    def apply_semantic_enrichment(
        self, 
        data_structure: Any, 
        semantic_mappings: Dict[str, str],
        encountered_identifiers: Set[str]
    ) -> Any:
        
        if isinstance(data_structure, list):
            return [
                self.apply_semantic_enrichment(
                    element, 
                    semantic_mappings, 
                    encountered_identifiers
                )
                for element in data_structure
            ]
        
        elif isinstance(data_structure, dict):
            enriched_structure = {}           
            for structural_key, structural_value in data_structure.items():
                if structural_key == 'id':
                    identifier_value = str(structural_value)
                    encountered_identifiers.add(identifier_value)
                    if identifier_value in semantic_mappings:
                        enriched_structure['description_Security'] = (
                            semantic_mappings[identifier_value]
                        )
                else:
                    enriched_structure[structural_key] = (
                        self.apply_semantic_enrichment(
                            structural_value, 
                            semantic_mappings, 
                            encountered_identifiers
                        )
                    )
            
            return enriched_structure
        else:
            return data_structure
    
    def enhance_documents_with_semantic_context(
        self, 
        input_data: Dict[str, Any]
    ) -> Dict[str, Any]:

        contextual_documents: List[Document] = input_data.get("context", [])
        semantic_mappings = self._load_semantic_mappings()
        
        if not semantic_mappings:
            return {
                "query": input_data.get("input", ""),
                "system_input": input_data.get("system_input", ""),
                "context": contextual_documents,
                "reference_text": "Semantic context unavailable for enhancement.",
                "skip_rag": False
            }
        
        enhanced_documents = []
        contextual_accumulator = []
        
        for document in contextual_documents:
            document_identifiers = set()
            
            try:
                document_structure = json.loads(document.page_content)
                enriched_structure = self.apply_semantic_enrichment(
                    document_structure,
                    semantic_mappings,
                    document_identifiers
                )
                
                enhanced_content = json.dumps(
                    enriched_structure, 
                    ensure_ascii=False
                )
                
                enhanced_document = Document(
                    page_content=enhanced_content,
                    metadata=document.metadata.copy() if document.metadata else {}
                )
                enhanced_documents.append(enhanced_document)

                for identifier in document_identifiers:
                    if identifier in semantic_mappings:
                        contextual_entry = (
                            f"Identifier: {identifier}\n"
                            f"Semantic Context: {semantic_mappings[identifier]}\n"
                            "Contextual Boundary"
                        )
                        
                        if contextual_entry not in contextual_accumulator:
                            contextual_accumulator.append(contextual_entry)
                
            except json.JSONDecodeError as parsing_error:
                enhanced_documents.append(document)
                continue
        
        reference_context = (
            "\n\n".join(contextual_accumulator) 
            if contextual_accumulator 
            else "No semantic context available from knowledge base."
        )
        
        return {
            "query": input_data.get("input", ""),
            "system_input": input_data.get("system_input", ""),
            "context": enhanced_documents,
            "reference_text": reference_context,
            "skip_rag": False
        }
    
    def determine_processing_strategy(self, input_data: Dict) -> Dict:
        query_context = input_data.get("input", "")
        system_context = input_data.get("system_input", "")
        
        # Access RAG strategy controller
        strategy_controller = self._get_skip_rag_manager()
        current_strategy = strategy_controller.get_skip_rag()
        
        strategy_status = f"Processing strategy evaluation: Contextual analysis {'disabled' if current_strategy else 'enabled'}"
        print(strategy_status)
        
        if current_strategy:
            return {
                "query": query_context,
                "system_input": system_context,
                "skip_rag": True
            }
        else:
            enhancement_result = self.enhance_documents_with_semantic_context(input_data)
            
            return {
                "query": enhancement_result["query"],
                "system_input": enhancement_result["system_input"],
                "reference_text": enhancement_result["reference_text"],
                "skip_rag": False
            }