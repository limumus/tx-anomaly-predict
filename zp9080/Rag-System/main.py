# 安装依赖（需提前安装）
# pip install haystack-ai python-dotxfa sentence-transformers

import os
import json
from dotenv import load_dotenv
from haystack import Pipeline
from haystack.components.builders import PromptBuilder
from haystack.components.generators import OpenAIGenerator
from haystack.components.embedders import SentenceTransformersDocumentEmbedder, SentenceTransformersTextEmbedder
from haystack.components.writers import DocumentWriter
from haystack_integrations.document_stores.chroma import ChromaDocumentStore
from haystack_integrations.components.retrievers.chroma import ChromaEmbeddingRetriever
from haystack import Document
from haystack.utils import Secret
from typing import List, Dict, Any
from collections import deque
from tqdm import tqdm


# 1. 自定义JSON文档处理器
class JSONDocumentProcessor:       
    @staticmethod
    def process_node(calls):
        queue = deque()

        for call in calls:
            queue.append(call)
        cont=[]
        all_slices = []
        count=0
        while queue:
           
            for i in range(len(queue)):
                node = queue.popleft()  # 关键操作：先进先出
                cont.append(
                    {
                        "contract":node.get("contract"),
                        "function":node.get("function"),
                        "args":node.get("args"),
                        "original_code":node.get("original_code"),
                        "description":node.get("description"),
                        "return_value":node.get("return_value"),
                        "depth":node.get("depth")
                    }
                )
                count+=1
                if(count%10==0):
                    #all_slices当前是个列表，元素也是列表，元素这个列表中存的是字典类型
                    all_slices.append(cont)
                    cont=[]

                internal_calls=node.get("internal_calls")
                if internal_calls:
                    for call in internal_calls:
                        queue.append(call)
                
        if(cont!=[]): all_slices.append(cont)

        return all_slices

    @staticmethod
    def load_json_data(folder_path: str) -> List[Document]:
        """增强版JSON处理器，支持深度感知切片"""
        documents = []
        index = 0
        
        # 获取所有文件路径（用于准确统计总数）
        file_paths = []
        for root, dirs, files in os.walk(folder_path):
            for file in files:
                file_paths.append(os.path.join(root, file))
        
        # 主进度条：文件处理进度[6](@ref)
        with tqdm(file_paths, desc="📁 Processing files", unit="file") as file_pbar:
            for file_path in file_pbar:
                try:
                    with open(file_path, 'r', encoding='utf-8') as f:
                        data = json.load(f)
                    
                    # 设置当前文件名的动态显示[4](@ref)
                    file_pbar.set_postfix(file=os.path.basename(file_path)[:15])
                    
                    calls = data.get("logs", {}).get("calls", [])
                    all_slices = JSONDocumentProcessor.process_node(calls)
                    
                    # 子进度条：切片生成进度[3,5](@ref)
                    with tqdm(all_slices, desc="🔧 Generating slices", leave=False, unit="slice") as slice_pbar:
                        for item in slice_pbar:
                            content = json.dumps(item, ensure_ascii=False)
                            meta = {"slice_id": index+1, "source_file": file_path}
                            index += 1
                            documents.append(Document(content=content, meta=meta))
                            
                except Exception as e:
                    tqdm.write(f"⚠️ Error processing {file_path}: {str(e)}")
        
        return documents


# 配置路径
JSON_FOLDER_PATH = "/home/zp9080/Code/tx-anomaly-predict/hst/output_1"
PERSIST_DIR = "/home/zp9080/Code/tx-anomaly-predict/zp9080/Rag-System/vector_store"
MODEL_PATH = "/home/zp9080/models/all-mpnet-base-v2"

# 初始化Chroma文档存储
document_store = ChromaDocumentStore(
    persist_path=PERSIST_DIR,
)

# 索引管道
indexing_pipeline = Pipeline()
indexing_pipeline.add_component(
    "doc_embedder",
    SentenceTransformersDocumentEmbedder(model=MODEL_PATH)
)
indexing_pipeline.add_component(
    "writer",
    DocumentWriter(document_store=document_store)
)
indexing_pipeline.connect("doc_embedder", "writer")

# RAG查询管道
rag_pipeline = Pipeline()
rag_pipeline.add_component(
    "text_embedder",
    SentenceTransformersTextEmbedder(model=MODEL_PATH)
)
rag_pipeline.add_component(
    "retriever",
    ChromaEmbeddingRetriever(document_store) # 使用Chroma内置的检索器
)
rag_pipeline.add_component(
    "prompt_builder",
    PromptBuilder(template="""
        根据以下合约调用信息回答问题：
        {% for document in documents %}
        调用链片段{{ document.meta.slice_id }}: 
        {{ document.content|truncate(300) }}
        {% endfor %}
        问题：{{ query }}
        答案：
    """)
)
rag_pipeline.add_component("llm", OpenAIGenerator(
    model="deepseek/deepseek-r1/community",
    api_base_url="https://api.ppinfra.com/v3/openai",
    generation_kwargs={"temperature": 0.3},
    api_key=Secret.from_token("sk_eevcJPk1gMUEMlBeAaG4Qj-jBP2kEN3N5FYXrkrzEfI")
))

# 连接管道组件
rag_pipeline.connect("text_embedder", "retriever")
rag_pipeline.connect("retriever", "prompt_builder.documents")
rag_pipeline.connect("prompt_builder", "llm")

if __name__ == "__main__":
    # 首次运行或需要更新索引时执行
    if not os.path.exists(PERSIST_DIR):
        print("正在构建向量数据库...")
        documents = JSONDocumentProcessor.load_json_data(JSON_FOLDER_PATH)
        indexing_pipeline.run({"doc_embedder": {"documents": documents}})
        document_store.persist()

    # 执行查询
    query = "请分析合约调用模式中的异常行为"
    result = rag_pipeline.run({
        "text_embedder": {"text": query},
        "prompt_builder": {"query": query}
    })
    
    print("答案：", result["llm"]["replies"][0])