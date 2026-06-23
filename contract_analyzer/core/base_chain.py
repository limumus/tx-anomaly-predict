import pandas as pd
import os
import json
from typing import Dict, Any, List, Tuple
from langchain.chains import create_history_aware_retriever
from langchain_core.prompts import ChatPromptTemplate
from langchain_core.runnables import RunnableLambda
from langchain_core.documents import Document
from config import CONFIG

from global_instances import get_skip_rag_manager, get_exclusion_middleware


class BaseChain:
    SIMILARITY_SEARCH_LIMIT = 5
    SIMILARITY_THRESHOLD_KEY = "SIMILARITY_THRESHOLD"
    DEFAULT_SIMILARITY_THRESHOLD = 0.15 #SIMILARITY_THRESHOLD_SCORE
    MAX_RETRIEVAL_RESULTS = 5
    RESPONSE_LENGTH_LIMIT = 200
    QUERY_TEXT_TRUNCATION_LENGTH = 100
    
    def __init__(self, vector_store, llm, csv_file_path: str, original_input: Dict):
        self.vector_store = vector_store
        self.llm = llm
        self.csv_file_path = csv_file_path
        self.original_input = original_input
        self.skip_rag_manager = None
        self.exclusion_middleware = None
    
    def _lazy_load_skip_rag_manager(self):
        if self.skip_rag_manager is None:
            self.skip_rag_manager = get_skip_rag_manager()
        return self.skip_rag_manager
    
    def _lazy_load_exclusion_middleware(self):
        if self.exclusion_middleware is None:
            self.exclusion_middleware = get_exclusion_middleware()
        return self.exclusion_middleware
    
    def _construct_analysis_prompts(self) -> Tuple[ChatPromptTemplate, ...]:

        contextual_refinement_prompt = ChatPromptTemplate.from_messages([
            ("human", """Refine the following question based on the reference text:
            Reference Text: {reference_text}
            Original Question: {input}
            Optimized Question:
            - Ensure the refined question focuses on function call sequences, not specific function names.
            - Emphasize contract interactions and attack logic.
            """)
        ])
        
        # Context-aware analysis prompt with historical patterns
        contextual_analysis_prompt = ChatPromptTemplate.from_messages([
            ("human", """You are an expert in smart contract attack detection. Your task is to analyze the `Current transaction` against `Historical attack examples` provided in the context to determine malicious intent.
            Core Directive: The historical examples were retrieved due to high behavioral similarity to the current transaction. Therefore, you must assume malicious intent initially and focus on validating the attack pattern.
            1. Current transaction (system_input):{system_input}
            2. Historical attack examples (context):{context}

            Key Analysis Focus:
            - Bias: Start with the assumption that this is an Attack executing a known pattern.
            - Comparison: Directly compare the execution flow and fund transfers in `system_input` with the logic of the historical examples.
            - Logic: Ignore function names; focus on the operational sequence, state changes, and security implications.
            - Focus Points: Inter-contract calls, abnormal fund movements, and state manipulation patterns.
            Question:{query}

            Strict Answer Rules:
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
            - Limit your answer to 200 words.
            """.format(
                response_limit=self.RESPONSE_LENGTH_LIMIT
            ))
        ])
        
        # Direct analysis prompt without historical context
        direct_analysis_prompt = ChatPromptTemplate.from_messages([
            ("human", """You are an expert in smart contract attack detection. Evaluate whether the current transaction is malicious based *only* on the provided transaction data.
            Current transaction (system_input):{system_input}
            Question:{query}
            Core Guiding Principle: There is no prior knowledge or historical context provided. Your judgment must be based purely on the internal logic, security best practices, and execution behavior of the current transaction. Assume the transaction is Benign unless verifiable security flaws or abnormal logic are evident in the input.
            Strict Answer Rules:
            - You must begin your answer with one of: `Attack` or `Benign`.
            - Follow this structured format:

            [Attack || Benign]
            1. Behavior Summary:
            - Describe the transaction's overall behavior, including contract interactions and fund movements.
            2. Call Sequence Analysis:
            - Analyze the function call sequence. Highlight any unusual order of operations or patterns that violate established smart contract security practices (e.g., state change before external call).
            3. Malicious Indicators:
            - Identify specific behaviors that directly indicate an attack (e.g., reentrancy, unprivileged function calls, unauthorized balance changes) OR explicitly state why the transaction is logically sound and adheres to expected security norms (if Benign).
            - Limit your answer to 200 words.
            """.format(
                response_limit=self.RESPONSE_LENGTH_LIMIT
            ))
        ])
        
        return (
            contextual_refinement_prompt,
            contextual_analysis_prompt,
            direct_analysis_prompt
        )
    
    def intelligent_context_retrieval(self, input_data: Dict) -> List[Document]:

        try:
            skip_rag_manager = self._lazy_load_skip_rag_manager()
            
            if input_data.get("skip_rag", False):
                print("RAG bypass activated: Direct analysis mode")
                skip_rag_manager.set_skip_rag(True)
                return []
            
            analysis_target_path = input_data.get("system_input_path", "")
            
            if analysis_target_path:
                print(f"\nSecurity Context Analysis:")
                print(f"Analysis Target: {os.path.basename(analysis_target_path)}")
                
                exclusion_middleware = self._lazy_load_exclusion_middleware()
                if exclusion_middleware:
                    self._apply_security_context_analysis(
                        exclusion_middleware, 
                        analysis_target_path
                    )
            
            query_text = self._extract_analytical_query(input_data)
            print(f"Semantic Query: {query_text[:self.QUERY_TEXT_TRUNCATION_LENGTH]}...")

            retrieval_results = self._perform_semantic_retrieval(query_text)
            filtered_documents = self._apply_intelligent_filtering(
                retrieval_results, 
                input_data, 
                analysis_target_path
            )
            
            self._determine_rag_strategy(filtered_documents, input_data, skip_rag_manager)
            
            return filtered_documents
            
        except Exception as analysis_error:
            print(f"Context retrieval error: {str(analysis_error)}")
            import traceback
            traceback.print_exc()
            
            self._activate_direct_analysis_fallback(input_data)
            return []
    
    def _apply_security_context_analysis(self, middleware, target_path: str):

        security_context = middleware.get_contract_info(target_path)
        
        analysis_summary = [
            f"Contract Security Context: {security_context.get('contract_name', 'Unknown')}",
            f"Transaction Identifier: {security_context.get('transaction_hash', 'Unknown')[:20]}...",
            f"Security Knowledge Base: {security_context.get('kb_file', 'Not Available')}",
            f"Exclusion Patterns: {security_context.get('has_exclusion_rules', False)}"
        ]
        
        for line in analysis_summary:
            print(f"  {line}")
    
    def _extract_analytical_query(self, input_data: Dict) -> str:

        if "system_input" in input_data and input_data["system_input"]:
            return input_data["system_input"]
        elif "input" in input_data and input_data["input"]:
            return input_data["input"]
        else:
            return str(input_data)
    
    def _perform_semantic_retrieval(self, query_text: str) -> Dict[str, Any]:

        retrieval_results = self.vector_store.similarity_search_with_score(
            query_text,
            k=self.SIMILARITY_SEARCH_LIMIT
        )
        
        documents = [document for document, score in retrieval_results]
        similarity_metrics = [score for document, score in retrieval_results]
        
        print(f"Initial Retrieval: {len(documents)} documents, "
              f"Similarity Metrics: {[f'{score:.4f}' for score in similarity_metrics[:5]]}...")
        
        return {
            "documents": documents,
            "similarity_metrics": similarity_metrics,
            "retrieval_results": retrieval_results
        }
    
    def _apply_intelligent_filtering(
        self, 
        retrieval_results: Dict[str, Any],
        input_data: Dict,
        analysis_target_path: str
    ) -> List[Document]:

        documents = retrieval_results["documents"]
        retrieval_pairs = retrieval_results["retrieval_results"]
        similarity_metrics = retrieval_results["similarity_metrics"]

        if analysis_target_path and documents:
            exclusion_middleware = self._lazy_load_exclusion_middleware()
            if exclusion_middleware:
                documents = exclusion_middleware.filter_documents_by_pattern(
                    documents, 
                    analysis_target_path
                )
        
        similarity_threshold = CONFIG.get(
            self.SIMILARITY_THRESHOLD_KEY, 
            self.DEFAULT_SIMILARITY_THRESHOLD
        )
        
        filtered_documents = []
        filtered_metrics = []
        
        for document, similarity_score in retrieval_pairs:
            if document in documents and similarity_score <= similarity_threshold:
                filtered_documents.append(document)
                filtered_metrics.append(similarity_score)
                self._enhance_document_analytics(document, similarity_score)
        
        print(f"Filtered Retrieval: {len(filtered_documents)} documents")
        
        input_data["_similarity_analytics"] = filtered_metrics
        input_data["_retrieval_analytics"] = list(zip(filtered_documents, filtered_metrics))
        
        return filtered_documents
    
    def _enhance_document_analytics(self, document: Document, similarity_score: float):

        if not hasattr(document, 'metadata') or document.metadata is None:
            document.metadata = {}
        elif not isinstance(document.metadata, dict):
            document.metadata = dict(document.metadata)
        
        document.metadata['similarity_metric'] = float(similarity_score)
        document.metadata['relevance_confidence'] = 1.0 - similarity_score
        document.metadata['analytical_weight'] = max(0.0, 1.0 - similarity_score * 2)
    
    def _determine_rag_strategy(
        self, 
        filtered_documents: List[Document], 
        input_data: Dict,
        skip_rag_manager
    ):

        if not filtered_documents:
            print("Insufficient relevant context: Activating direct analysis mode")
            input_data["skip_rag"] = True
            skip_rag_manager.set_skip_rag(True)
            input_data["_retrieved_documents"] = []
        else:
            input_data["skip_rag"] = False
            input_data["_retrieved_documents"] = filtered_documents
            skip_rag_manager.set_skip_rag(False)
    
    def _activate_direct_analysis_fallback(self, input_data: Dict):

        input_data["skip_rag"] = True
        try:
            skip_rag_manager = self._lazy_load_skip_rag_manager()
            if skip_rag_manager:
                skip_rag_manager.set_skip_rag(True)
        except Exception:
            pass