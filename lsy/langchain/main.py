import os
from collections import deque
from typing import List
import requests
import json
from dotenv import load_dotenv
from langchain.chains import ConversationalRetrievalChain
from langchain.embeddings.base import Embeddings
from langchain.memory import ConversationBufferWindowMemory
from langchain.prompts import PromptTemplate
from langchain.schema import Document
from langchain_chroma import Chroma
from langchain_deepseek import ChatDeepSeek
from openai import OpenAI
from tqdm import tqdm

CONFIG = {
    "JSON_FOLDER_PATH": "output_de_1",
    "PERSIST_DIR": "vector_store3",
    "HTTP_PROXY": "http://127.0.0.1:65151",
    "HTTPS_PROXY": "http://127.0.0.1:65151",
    "TARGET_IP": "192.168.1.100",
    "GEO_LOCATION": "US",
    "JINA_API_KEY": "jina_bfabb5e8e91f442e988bd6cfb5eaeca4f2kUOjoZzEECKzSYb2DsqHNA0-pj",
    "open_API": "sk-e084123b2698f0935a575c437bb02062",
}

load_dotenv()

class JinaEmbedding(Embeddings):

    def __init__(self):
        pass

    def embed_content_with_jina(self, content: str) -> list:
        try:
            url = "https://api.jina.ai/v1/embeddings"
            headers = {
                "Authorization": f"Bearer {CONFIG['JINA_API_KEY']}",
                "Content-Type": "application/json"
            }
            input_data = [{"text": content}]
            payload = {"model": "jina-embeddings-v3", "input": input_data}

            response = requests.post(url, json=payload, headers=headers)

            if response.status_code == 200:
                response_json = response.json()
                if 'data' in response_json and len(response_json['data']) > 0:
                    return response_json['data'][0]['embedding']
        except Exception as e:
            return []

    def embed_documents(self, documents: List[Document]) -> list:
        embeddings = []
        for doc in tqdm(documents, desc="📚 嵌入处理中", unit="文档"):
            content = doc.page_content if isinstance(doc, Document) else doc
            embeddings.append(self.embed_content_with_jina(content))
        return embeddings

    def embed_query(self, query: str) -> list:
        return self.embed_content_with_jina(query)

def initialize_jina_client():
    try:
        print("✅ Jina客户端初始化成功！")
        return JinaEmbedding()
    except Exception as e:
        print(f"⚠️ Jina客户端初始化失败：{str(e)}")
        return None

class JSONDocumentProcessor:

    @staticmethod
    def process_calls(calls: List[dict]) -> List[dict]:
        queue = deque(calls)
        all_slices, temp_slice = [], []

        while queue:
            node = queue.popleft()
            temp_slice.append({
                "id": node.get("id"),
                "contract": node.get("contract"),
                "function": node.get("function"),
                "depth": node.get("depth")
            })
            if len(temp_slice) >= 5:
                all_slices.append(temp_slice)
                temp_slice = []
            queue.extend(node.get("internal_calls", []))
        if temp_slice:
            all_slices.append(temp_slice)
        return all_slices

    @staticmethod
    def load_json_data(folder_path: str, progress_file="processing_progress.json") -> List[Document]:
        file_paths = [
            os.path.join(root, file)
            for root, _, files in os.walk(folder_path)
            for file in files if file.endswith(".json")
        ]
        documents = []
        for index, file_path in enumerate(tqdm(file_paths, desc="📁 process file", unit="docx")):
            try:
                with open(file_path, "r", encoding="utf-8") as f:
                    data = json.load(f)

                calls = data.get("calls", [])
                all_slices = JSONDocumentProcessor.process_calls(calls)

                for item in all_slices:
                    documents.append(Document(
                        page_content=json.dumps(item, ensure_ascii=False, indent=2),
                        metadata={"slice_id": index + 1, "source_file": file_path}
                    ))
            except Exception as e:
                print(f"⚠️ 文件处理失败 {file_path}: {str(e)}")
        print(f"✅ 成功处理 {len(documents)} 个文档")
        return documents

def initialize_vector_store(embedding_function):
    try:
        if os.path.exists(CONFIG["PERSIST_DIR"]) and os.listdir(CONFIG["PERSIST_DIR"]):
            print("✅ 加载已有向量数据库")
            return Chroma(
                persist_directory=CONFIG["PERSIST_DIR"],
                embedding_function=embedding_function
            )
        else:
            print("🆕 创建新向量数据库")
            documents = JSONDocumentProcessor.load_json_data(CONFIG["JSON_FOLDER_PATH"])
            return Chroma.from_documents(
                documents=documents,
                embedding=embedding_function,
                persist_directory=CONFIG["PERSIST_DIR"]
            )
    except Exception as e:
        print(f"⚠️ 向量数据库初始化失败：{str(e)}")
        return None

def create_prompt_template(system_input: str):
    return PromptTemplate(
        template="""系统输入：{{ system_input }}

        基于以下合约调用信息回答问题：
        {% for document in documents %}
        [片段 {{ document.metadata.slice_id }}]
        {{ document.page_content[:300] }}
        {% endfor %}

        问题：{{ query }}
        答案：
        """,
        input_variables=["documents", "query", "system_input"]
    )

def execute_qa_query(qa_chain, query: str, system_input: str):
    print(f"🔍 查询：{query}")
    try:
        response = qa_chain.invoke({"query": query, "system_input": system_input})
        print(f"✅ 答案：{response['answer']}")
    except Exception as e:
        print(f"⚠️ 查询执行异常：{str(e)}")

def gather_json_files(folder_path: str) -> list:
    file_paths = [
        os.path.join(root, file)
        for root, _, files in os.walk(folder_path)
        for file in files if file.endswith(".json")
    ]
    print(f"📁 发现 {len(file_paths)} 个 JSON 文件")
    return file_paths

def process_documents(file_paths: list) -> list:
    documents = []
    for index, file_path in enumerate(tqdm(file_paths, desc="📁 文件处理进度", unit="文件")):
        try:
            with open(file_path, "r", encoding="utf-8") as f:
                data = json.load(f)

            calls = data.get("calls", [])
            all_slices = JSONDocumentProcessor.process_calls(calls)

            for item in all_slices:
                documents.append(Document(
                    page_content=json.dumps(item, ensure_ascii=False, indent=2),
                    metadata={"slice_id": index + 1, "source_file": file_path}
                ))
        except Exception as e:
            print(f"⚠️ 文件处理失败 {file_path}: {str(e)}")
    print(f"✅ 成功处理 {len(documents)} 个文档")
    return documents

if __name__ == "__main__":
    embedding_function = initialize_jina_client()
    if not embedding_function:
        print("\n❌ 嵌入服务初始化失败，程序退出")
        exit()

    vector_store = initialize_vector_store(embedding_function)
    if not vector_store:
        print("\n❌ 向量数据库初始化失败，程序退出")
        exit()

    chat_client = OpenAI(
        api_key=CONFIG["open_API"],
        base_url="https://api.atomecho.cn/v1",
    )

    def chat_with_model(query):
        response = chat_client.chat.completions.create(
            model="Atom-7B-Chat",
            messages=[{"role": "user", "content": query}],
            temperature=0.3,
        )
        return response.choices[0].message

    system_input = "G:\\safe\\pythonProject\\output\\output"
    json_files = gather_json_files(system_input)
    documents = process_documents(json_files)
    prompt_template = create_prompt_template(documents)

    memory = ConversationBufferWindowMemory(k=5, return_messages=True)
    retriever = vector_store.as_retriever()

    from langchain_core.runnables import RunnableLambda
    chat_with_model_runnable = RunnableLambda(func=chat_with_model)

    qa_chain = ConversationalRetrievalChain.from_llm(
        llm=chat_with_model_runnable,
        retriever=retriever,
        memory=memory,
        combine_docs_chain_kwargs={"prompt": prompt_template}
    )

    query = "What is the function of the transfer function in the contract?"
    execute_qa_query(qa_chain, query, system_input)
