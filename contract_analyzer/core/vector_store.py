import os
from typing import List, Dict, Any, Optional, Tuple
from langchain_chroma import Chroma
from langchain_core.documents import Document
from langchain.embeddings.base import Embeddings
from config.settings import CONFIG


class VectorStoreManager:
    DEFAULT_SEARCH_LIMIT = 5
    SIMILARITY_THRESHOLD_KEY = "SIMILARITY_THRESHOLD"
    DEFAULT_SIMILARITY_THRESHOLD = SIMILARITY_THRESHOLD_SCORE
    MIN_SIMILARITY_SCORE = 0.0
    MAX_SIMILARITY_SCORE = 1.0
    
    @staticmethod
    def initialize_vector_store(
        persistence_directory: str, 
        embedding_model: Embeddings
    ) -> Chroma:

        if os.path.exists(persistence_directory):
            initialization_status = (
                f"Loading existing vector store from persistence directory: "
                f"{persistence_directory}"
            )
            print(initialization_status)
            
            return Chroma(
                persist_directory=persistence_directory,
                embedding_function=embedding_model
            )
        else:
            initialization_status = (
                f"Creating new vector store in persistence directory: "
                f"{persistence_directory}"
            )
            print(initialization_status)
            
            return Chroma(
                persist_directory=persistence_directory,
                embedding_function=embedding_model
            )
    
    @staticmethod
    def store_documents_with_metadata(
        vector_store: Chroma,
        document_collection: List[Document],
        metadata_collection: Optional[List[Dict[str, Any]]] = None
    ) -> None:

        if not document_collection:
            print("Document collection empty: No storage operation performed")
            return
        
        storage_status = (
            f"Storing {len(document_collection)} documents in vector database"
        )
        print(storage_status)
        
        if metadata_collection and len(metadata_collection) == len(document_collection):
            enhanced_documents = []
            for document, metadata in zip(document_collection, metadata_collection):
                if not hasattr(document, 'metadata') or document.metadata is None:
                    document.metadata = {}
                document.metadata.update(metadata)
                enhanced_documents.append(document)
            
            vector_store.add_documents(enhanced_documents)
        else:
            vector_store.add_documents(document_collection)
        
        print("Document storage operation completed successfully")
    
    @staticmethod
    def perform_semantic_retrieval(
        vector_store: Chroma,
        semantic_query: str,
        retrieval_limit: int = DEFAULT_SEARCH_LIMIT,
        filter_conditions: Optional[Dict[str, Any]] = None
    ) -> List[Document]:

        query_preview = semantic_query[:100] + "..." if len(semantic_query) > 100 else semantic_query
        print(f"Performing semantic retrieval for query: {query_preview}")
        
        retrieval_parameters = {"k": retrieval_limit}
        if filter_conditions:
            retrieval_parameters["filter"] = filter_conditions
        
        try:
            retrieved_documents = vector_store.similarity_search(
                query=semantic_query,
                **retrieval_parameters
            )
            
            retrieval_summary = (
                f"Semantic retrieval completed: "
                f"{len(retrieved_documents)} relevant documents identified"
            )
            print(retrieval_summary)
            
            return retrieved_documents
            
        except Exception as retrieval_error:
            print(f"Semantic retrieval operation failed: {retrieval_error}")
            return []
    
    @staticmethod
    def retrieve_with_similarity_metrics(
        vector_store: Chroma,
        semantic_query: str,
        retrieval_limit: int = DEFAULT_SEARCH_LIMIT,
        similarity_threshold: Optional[float] = None
    ) -> List[Tuple[Document, float]]:

        query_preview = semantic_query[:100] + "..." if len(semantic_query) > 100 else semantic_query
        print(f"Executing similarity-based retrieval for query: {query_preview}")
        
        try:
            retrieval_results = vector_store.similarity_search_with_score(
                query=semantic_query,
                k=retrieval_limit
            )
            
            if similarity_threshold is not None:
                filtered_results = [
                    (document, similarity_metric) 
                    for document, similarity_metric in retrieval_results 
                    if similarity_metric <= similarity_threshold
                ]
                
                retrieval_summary = (
                    f"Similarity retrieval with threshold filtering: "
                    f"Original results: {len(retrieval_results)}, "
                    f"Filtered results: {len(filtered_results)}"
                )
                print(retrieval_summary)
                
                return filtered_results
            else:
                retrieval_summary = (
                    f"Similarity retrieval completed: "
                    f"{len(retrieval_results)} documents retrieved with similarity metrics"
                )
                print(retrieval_summary)
                
                return retrieval_results
                
        except Exception as similarity_error:
            print(f"Similarity-based retrieval operation failed: {similarity_error}")
            return []
    
    @staticmethod
    def analyze_vector_store_metrics(vector_store: Chroma) -> Dict[str, Any]:
        try:
            document_count = vector_store._collection.count()
            
            # Analyze embedding dimensions
            embedding_dimension = None
            try:
                if hasattr(vector_store, '_embedding_function'):
                    if hasattr(vector_store._embedding_function, 'embed_query'):
                        test_embedding = vector_store._embedding_function.embed_query("dimensional_analysis")
                        if test_embedding:
                            embedding_dimension = len(test_embedding)
            except Exception as dimension_error:
                print(f"Embedding dimension analysis incomplete: {dimension_error}")
            
            # Construct comprehensive metrics
            store_metrics = {
                "total_document_count": document_count,
                "embedding_dimension_analysis": embedding_dimension,
                "persistence_configuration": vector_store._persist_directory,
                "collection_identifier": (
                    vector_store._collection.name 
                    if hasattr(vector_store._collection, 'name') 
                    else "default_collection"
                )
            }
            
            return store_metrics
            
        except Exception as analysis_error:
            print(f"Vector store metrics analysis failed: {analysis_error}")
            return {}
    
    @staticmethod
    def perform_collection_reset(vector_store: Chroma) -> bool:
        try:
            vector_store.delete_collection()
            print("Vector store collection reset completed successfully")
            return True
        except Exception as reset_error:
            print(f"Vector store collection reset failed: {reset_error}")
            return False

def load_or_create_vector_store(persist_dir: str, embedding: Embeddings) -> Chroma:
    return VectorStoreManager.initialize_vector_store(persist_dir, embedding)