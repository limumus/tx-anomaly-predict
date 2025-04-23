import os
from datetime import datetime
import pandas as pd
import chardet
import requests
import json

from dotenv import load_dotenv
from collections import deque
from langchain_core.documents import Document
from typing import List, Dict, Any, Optional
from tqdm import tqdm

# LangChain相关模块
from langchain.chains import create_history_aware_retriever, create_retrieval_chain
from langchain.chains.combine_documents import create_stuff_documents_chain
from langchain_core.prompts import ChatPromptTemplate, MessagesPlaceholder
from langchain_core.messages import AIMessage, HumanMessage, SystemMessage
from langchain_chroma import Chroma
from langchain.embeddings.base import Embeddings
from langchain_core.runnables import Runnable, RunnableLambda, RunnablePassthrough
from langchain_core.output_parsers import StrOutputParser


# ============== 系统配置 ==============
CONFIG = {
    "JSON_FOLDER_PATH": "output_de",
    "PERSIST_DIR": "vector_store_realtime_0",
    "INTERMEDIATE_FOLDER": "intermediate_data",  # 新增保存中间数据的文件夹
    "CSV_PATH": "extracted_data2.csv",

    "HTTP_PROXY": "http://127.0.0.1:65151",
    "HTTPS_PROXY": "http://127.0.0.1:65151",

    "JINA_API_KEY": "jina_a60e90b9537440739995b0bfae0b8468xf3mIgPUeB2TCH9Ahnyu1NjbQ9sL",
    "EMBEDDING_MODEL": "jina-embeddings-v3",
}

# ============== 百度文心ERNIE模型封装 ==============
class BaiduErnieAI:
    def __init__(self):
        self.access_key = CONFIG["BAIDU_ACCESS_KEY"]
        self.secret_key = CONFIG["BAIDU_SECRET_KEY"]
        self.api_url = "https://aip.baidubce.com/rpc/2.0/ai_custom/v1/wenxinworkshop/chat/ernie-speed-128k"

    def get_access_token(self):
        url = f"https://aip.baidubce.com/oauth/2.0/token?grant_type=client_credentials&client_id={self.access_key}&client_secret={self.secret_key}"
        response = requests.post(url, headers={'Content-Type': 'application/json'})
        return response.json().get("access_token")

    def generate_response(self, messages: List[Dict[str, str]]) -> str:
        """修正后的API调用方法，只接受消息列表"""
        try:
            access_token = self.get_access_token()
            url = f"{self.api_url}?access_token={access_token}"

            payload = json.dumps({"messages": messages})
            response = requests.post(url,
                                     headers={'Content-Type': 'application/json'},
                                     data=payload)
            response_data = response.json()

            if "error_code" in response_data:
                print(f"API错误: {response_data.get('error_msg')}")
                return f"API错误: {response_data.get('error_msg')}"
            return response_data.get("result", "未能获取回答")

        except Exception as e:
            print(f"API调用异常: {str(e)}")
            return "API调用异常"

    def simple_query(self, query: str, context: str = None) -> str:
        """新增的简化查询方法，用于测试"""
        messages = []
        if context:
            messages.append({"role": "user", "content": context})
        messages.append({"role": "user", "content": query})
        return self.generate_response(messages)

# ============== 嵌入服务封装 ==============
class JinaEmbedding(Embeddings):
    """实时嵌入服务"""

    def __init__(self):
        self.api_url = "https://api.jina.ai/v1/embeddings"
        self.headers = {
            "Authorization": f"Bearer {CONFIG['JINA_API_KEY']}",
            "Content-Type": "application/json"
        }

    def embed_documents(self, texts: List[str]) -> List[List[float]]:
        return [self._get_embedding(text) for text in texts]

    def embed_query(self, text: str) -> List[float]:
        return self._get_embedding(text)

    def _get_embedding(self, text: str) -> List[float]:
        try:
            response = requests.post(
                self.api_url,
                headers=self.headers,
                json={
                    "model": CONFIG["EMBEDDING_MODEL"],
                    "input": [text[:8192]]  # 截断超长文本
                },
                timeout=15
            )
            response.raise_for_status()
            return response.json()['data'][0]['embedding']
        except Exception as e:
            print(f"⚠️ 嵌入失败: {str(e)}")
            return []


# ============== ERNIE模型包装器 ==============
class ErnieLLMWrapper(Runnable):
    """兼容LangChain Runnable接口的ERNIE模型包装器"""

    def __init__(self, ernie_ai: BaiduErnieAI):
        super().__init__()
        self.ernie_ai = ernie_ai

    def invoke(self, input_data: Any, config: Optional[Dict] = None) -> AIMessage:
        """处理单次调用，兼容多种输入类型"""
        try:
            # 处理不同类型的输入
            if isinstance(input_data, dict):
                # 字典输入
                query = input_data.get("input", "")
                reference = input_data.get("reference_text", "")
            elif hasattr(input_data, "messages"):
                # ChatPromptValue输入
                messages = input_data.messages
                query = next((msg.content for msg in messages if isinstance(msg, HumanMessage)), "")
                reference = next((msg.content for msg in messages if isinstance(msg, SystemMessage)), "")
            else:
                return AIMessage(content="无效的输入格式")

            # 构建ERNIE API需要的消息格式
            messages = []
            if reference:
                messages.append({"role": "user", "content": f"参考内容: {reference[:1000]}"})
            messages.append({"role": "user", "content": query})

            # 调用ERNIE API
            response = self.ernie_ai.generate_response(messages)
            return AIMessage(content=response)

        except Exception as e:
            print(f"调用ERNIE API出错: {str(e)}")
            return AIMessage(content=f"处理错误: {str(e)}")

    async def ainvoke(self, input_data: Any, config: Optional[Dict] = None) -> AIMessage:
        """异步调用"""
        return self.invoke(input_data, config)

    def stream(self, input_data: Any, config: Optional[Dict] = None):
        """流式处理"""
        result = self.invoke(input_data, config)
        yield result

    async def astream(self, input_data: Any, config: Optional[Dict] = None):
        """异步流式处理"""
        async for chunk in self.stream(input_data, config):
            yield chunk


# ============== 向量数据库管理 ==============
def load_or_create_vector_store(persist_dir: str, embedding: Embeddings) -> Chroma:
    """加载或创建向量数据库"""
    if os.path.exists(persist_dir):
        print(f"🔍 加载已有向量数据库: {persist_dir}")
        return Chroma(persist_directory=persist_dir, embedding_function=embedding)
    else:
        print(f"🆕 创建新向量数据库: {persist_dir}")
        return Chroma(persist_directory=persist_dir, embedding_function=embedding)


def create_conversational_chain(vector_store: Chroma, llm: Runnable, csv_file_path: str) -> Runnable:
    csv_data = pd.read_csv(csv_file_path, usecols=['id', 'original_code', 'description'], encoding="MacRoman")

    # Step 1: Prompt 设计
    contextualize_q_prompt = ChatPromptTemplate.from_messages([
        ("human", """Refine the following question based on the reference text:
        Reference Text: {reference_text}
        Original Question: {input}
        Optimized Question:
        - Ensure the refined question focuses on function call sequences, not specific function names.
        - Emphasize contract interactions and attack logic.
        """)
    ])

    qa_prompt = ChatPromptTemplate.from_messages([
        ("human", """You are an expert in analyzing smart contract attack patterns. Based on the following information, assess whether the current transaction exhibits malicious contract behavior:

        1. Current transaction behavior (system_input): This is the function call flow of the contract transaction.
        {system_input}

        2. Historical attack transaction examples (context):
        {context}

        3. Background details of the matching transactions (reference_text):
        {reference_text}

        Key Analysis Directions:
        - Context provides past examples of contract attacks—all of them involved malicious behavior.
        - Your task is not to simply match context, but to critically analyze system_input.
        - Examine the function call flow, contract interactions, and fund movements to determine anomalies.
        - Ignore function names like testExploit—focus solely on the logical execution flow.

        Question (query):
        {query}

        Strict Answering Rules:
        - Clearly state whether system_input represents an attack contract.
        - Provide logical reasoning for your classification (matched or unmatched).
        - If the information is insufficient, explicitly state "Uncertain."
        """)
    ])

    retriever = vector_store.as_retriever(search_kwargs={"k": 1})

    # Step 2: Retriever 改造，加上 CSV reference_text
    def enhanced_retriever(input_data: Dict) -> List[Document]:
        docs = retriever.invoke(input_data["input"])
        print(f"检索到的文档数量: {len(docs)}")
        #print(f"检索到的文档内容: {[doc.page_content[:200] for doc in docs]}")

        # 将每个文档的内容解析为 JSON
        doc_ids = []
        for doc in docs:
            try:
                json_data = json.loads(doc.page_content)  # 假设 doc.page_content 是 JSON 字符串
                doc_ids.extend([item['id'] for item in json_data])  # 使用 extend 来添加多个 id
            except json.JSONDecodeError as e:
                print(f"无法解析文档内容为 JSON: {doc.page_content[:100]}... 错误: {e}")

        print(f"doc_ids: {doc_ids}")  # 打印 doc_ids，确保是一个列表

        # 匹配 CSV 中的行
        csv_data["id"] = csv_data["id"].astype(str)  # 强制转换为字符串
        matched_rows = csv_data[csv_data["id"].isin(doc_ids)]

        reference_texts = []
        for _, row in matched_rows.iterrows():
            ref_text = (
                f"ID: {row['id']}\n"
                f"original_code: {row['original_code']}\n"
                f"description: {row['description']}\n"
                "------"
            )
            reference_texts.append(ref_text)

        reference_text = "\n\n".join(reference_texts)
        #print("匹配的 reference_text:", reference_text)  # 输出参考文本

        # 将匹配到的 reference_text 添加到文档元数据中
        for doc in docs:
            doc.metadata["reference_text"] = reference_text

        return docs

    # Step 3: 将历史输入融入向量检索器
    history_aware_retriever = create_history_aware_retriever(
        llm,
        RunnableLambda(lambda x: {"input": x}) | enhanced_retriever,
        contextualize_q_prompt
    )

    # Step 4: 构造 Prompt 输入字段
    def format_inputs(inputs: Dict) -> Dict:
        # 将 Document 对象转换为字典格式
        def document_to_dict(doc):
            return {
                "metadata": doc.metadata,
                "content": doc.page_content
            }

        # 处理 inputs 中的文档
        if isinstance(inputs, dict):
            for key, value in inputs.items():
                if isinstance(value, list):
                    inputs[key] = [document_to_dict(doc) if isinstance(doc, Document) else doc for doc in value]
                elif isinstance(value, Document):
                    inputs[key] = document_to_dict(value)

        # print("输入的数据:", json.dumps(inputs, indent=2, ensure_ascii=False))  # 打印处理后的 inputs


        context_docs = inputs.get("context", [])
        reference_from_csv = ""
        attack_cases_text = []

        for doc in context_docs:
            # 如果 doc 是字典类型，直接检查 "metadata" 键
            if isinstance(doc, dict) and "metadata" in doc:
                if "reference_text" in doc["metadata"]:
                    reference_from_csv = doc["metadata"]["reference_text"]
                    attack_cases_text.append(doc["content"])

        full_query = {
            "query": inputs.get("input", ""),
            "system_input": inputs.get("system_input", ""),
            "context": "\n\n".join(attack_cases_text),
            "reference_text": reference_from_csv
        }

        print("完整传入大模型的查询:", json.dumps(full_query, indent=2, ensure_ascii=False))
        return full_query


    # Step 5: 构造最终 QA Chain
    question_answer_chain = (
        RunnablePassthrough.assign(context=history_aware_retriever) |
        RunnableLambda(format_inputs) |
        qa_prompt |
        llm
    )

    return create_retrieval_chain(history_aware_retriever, question_answer_chain)


class ResultSaver:
    def __init__(self, output_dir: str = "results"):
        self.output_dir = output_dir
        os.makedirs(output_dir, exist_ok=True)

    def save_result(self, query: str, result: dict, source_file: str):
        print("完整结果结构:", json.dumps(result, indent=2, ensure_ascii=False))
        is_valid = (
            isinstance(result, dict) and
            result.get("answer") and
            not result["answer"].startswith(("未能获取", "API调用异常"))
        )

        if is_valid:
            filename = os.path.join(
                self.output_dir,
                f"result_{os.path.basename(source_file)}"
            )
            data = {
                "query": query,
                "answer": result["answer"],
                "source": source_file,
                "context": [
                    {
                        "content": doc.page_content[:200] + "...",
                        "source": doc.metadata.get("source_file", "unknown")
                    } for doc in result.get("context", [])
                ],
                "timestamp": datetime.now().isoformat()
            }
            with open(filename, 'w', encoding='utf-8') as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
            return True
        return False


# ============== 主执行流程 ==============
if __name__ == "__main__":
    embedding = JinaEmbedding()
    vector_store = load_or_create_vector_store(CONFIG["PERSIST_DIR"], embedding)
    ernie_ai = BaiduErnieAI()
    llm = ErnieLLMWrapper(ernie_ai)

    print("=== 服务检查 ===")
    print(f"向量数据库记录: {vector_store._collection.count()}")

    conversational_chain = create_conversational_chain(
        vector_store,
        llm,
        csv_file_path=CONFIG["CSV_PATH"]
    )

    # 示例输入
    query = "Please analyze the current input in the context of the preceding and following text to determine whether it pertains to attack contracts?and please answer in chinese."
    system_input_path = r"G:\safe\pythonProject\output\output\2024-12\Moonhacker_exp.sol\0xd12016b25d7aef681ade3dc3c9d1a1cc12f35b2c99953ff0e0ee23a59454c4fe.txt.json"

    def load_system_input(file_path):
        try:
            with open(file_path, 'r', encoding='utf-8') as f:
                return json.dumps(json.load(f), ensure_ascii=False)
        except Exception as e:
            print(f"错误: 无法读取 JSON 文件: {e}")
            return ""

    # 加载并准备好系统输入（当前交易流）
    reference_text = load_system_input(system_input_path)

    # 执行大模型推理，注意 context 是由向量库搜索自动获得的，无需手动传入
    result = conversational_chain.invoke({
        "input": query,
        "system_input": reference_text,
        "chat_history": [],
    })

    print("\n=== 查询结果 ===")
    if isinstance(result, dict) and "answer" in result:
        print(f"答案: {result['answer']}")
        if "context" in result:
            print("\n参考文档:")
            for doc in result["context"]:
                print(f"- {doc.metadata.get('source_file', '未知来源')}")
    else:
        print(f"原始结果: {result}")
