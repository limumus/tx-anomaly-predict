import os
from datetime import datetime
import pandas as pd
import chardet
import requests
import json
import time
import re
from typing import List, Dict, Any, Optional

from dotenv import load_dotenv
from collections import deque
from langchain_core.documents import Document
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

# 加载环境变量
load_dotenv()

# ============== 系统配置 ==============
CONFIG = {
    "JSON_FOLDER_PATH": "./output_de",
    "PERSIST_DIR": "./vector_store_realtime_0",
    "INTERMEDIATE_FOLDER": "./intermediate_data",  # 新增保存中间数据的文件夹
    "CSV_PATH": "./extracted_data2.csv",
    "REASULT_FOLDER": "./test_result/1",
    
    "HTTP_PROXY": "http://127.0.0.1:65151",
    "HTTPS_PROXY": "http://127.0.0.1:65151",

}

# ============== 百度文心ERNIE模型封装 ==============
class BaiduErnieAI:
    def __init__(self):
        self.access_key = CONFIG["BAIDU_ACCESS_KEY"]
        self.secret_key = CONFIG["BAIDU_SECRET_KEY"]
        self.api_url = "https://aip.baidubce.com/rpc/2.0/ai_custom/v1/wenxinworkshop/chat/ernie-speed-128k"

    def get_access_token(self):
        url = f"https://aip.baidubce.com/oauth/2.0/token?grant_type=client_credentials&client_id={self.access_key}&client_secret={self.secret_key}"
        try:
            response = requests.post(url, headers={'Content-Type': 'application/json'}, timeout=10)
            response.raise_for_status()
            return response.json().get("access_token")
        except Exception as e:
            print(f"获取访问令牌失败: {str(e)}")
            return None

    def generate_response(self, messages: List[Dict[str, str]]) -> str:
        try:
            access_token = self.get_access_token()
            if not access_token:
                return "无法获取访问令牌"
                
            url = f"{self.api_url}?access_token={access_token}"
            payload = json.dumps({"messages": messages})
            
            response = requests.post(url,
                                    headers={'Content-Type': 'application/json'},
                                    data=payload,
                                    timeout=30)
            response.raise_for_status()
            response_data = response.json()

            if "error_code" in response_data:
                return f"API错误: {response_data.get('error_msg')}"
            return response_data.get("result", "未能获取回答")

        except requests.exceptions.Timeout:
            return "API请求超时"
        except Exception as e:
            return f"API调用异常: {str(e)}"

# ============== 嵌入服务封装 ==============
class JinaEmbedding(Embeddings):
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
                    "input": [text[:8192]]
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
    def __init__(self, ernie_ai: BaiduErnieAI):
        super().__init__()
        self.ernie_ai = ernie_ai

    def invoke(self, input_data: Any, config: Optional[Dict] = None) -> AIMessage:
        try:
            if isinstance(input_data, dict):
                query = input_data.get("input", "")
                reference = input_data.get("reference_text", "")
            elif hasattr(input_data, "messages"):
                messages = input_data.messages
                query = next((msg.content for msg in messages if isinstance(msg, HumanMessage)), "")
                reference = next((msg.content for msg in messages if isinstance(msg, SystemMessage)), "")
            else:
                return AIMessage(content="无效的输入格式")

            messages = []
            if reference:
                messages.append({"role": "user", "content": f"参考内容: {reference[:1000]}"})
            messages.append({"role": "user", "content": query})

            response = self.ernie_ai.generate_response(messages)
            return AIMessage(content=response)

        except Exception as e:
            return AIMessage(content=f"处理错误: {str(e)}")

# ============== 向量数据库管理 ==============
def load_or_create_vector_store(persist_dir: str, embedding: Embeddings) -> Chroma:
    if os.path.exists(persist_dir):
        return Chroma(persist_directory=persist_dir, embedding_function=embedding)
    else:
        return Chroma(persist_directory=persist_dir, embedding_function=embedding)

def create_conversational_chain(vector_store: Chroma, llm: Runnable, csv_file_path: str) -> Runnable:
    csv_data = pd.read_csv(csv_file_path, usecols=['id', 'original_code', 'description'], encoding="MacRoman")

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
        ("human", """You are an expert in smart contract attack detection. Evaluate whether the current transaction is malicious, using the following inputs:

    1. Current transaction (system_input):
    {system_input}

    2. Historical attack examples (context):
    {context}

    3. Matching background information (reference_text): 
    {reference_text}

    Key Analysis Focus:
    - Your task is to critically evaluate `system_input`, not merely match context.
    - Focus on:
      - Logical function call flow
      - Inter-contract calls
      - Abnormal fund transfers
    - Ignore function names like `testExploit`; focus solely on execution logic.

    Question:
    {query}

    Strict Answer Rules:
    - You must begin your answer with one of: `Attack` or `Benign`.
    - Follow this structured format:

    [Attack | Benign]

    1. Behavior Summary:
    - Describe the transaction's overall behavior, including contract interactions and fund movements.

    2. Call Sequence Analysis:
    - Analyze the function call sequence and highlight any abnormal or suspicious patterns.

    3. Malicious Indicators:
    - Identify specific behaviors that indicate an attack, referencing historical examples if relevant.

    - Limit your answer to 200 words.
    """)
    ])

    retriever = vector_store.as_retriever(search_kwargs={"k": 3})

    def enhanced_retriever(input_data: Dict) -> List[Document]:
        try:
            # 使用 similarity_search_with_score 获取带分数的文档
            docs_with_scores = vector_store.similarity_search_with_score(
                input_data["input"], 
                k=3  # 获取前3个最相似的结果
            )
            
            # 分离文档和分数
            docs = [doc for doc, score in docs_with_scores]
            similarity_scores = [score for doc, score in docs_with_scores]
            
            print(f"检索到 {len(docs)} 个文档，相似度分数: {similarity_scores}")
            
            # 将分数添加到文档元数据中
            for i, (doc, score) in enumerate(docs_with_scores):
                doc.metadata['similarity_score'] = float(score)
                print(f"文档 {i+1} 分数: {score:.4f}")
            
        except Exception as e:
            print(f"带分数搜索失败，使用普通搜索: {e}")
            # 回退到普通搜索
            docs = vector_store.similarity_search(input_data["input"], k=3)
            similarity_scores = [0.8] * len(docs)  # 默认分数
        
        doc_ids = []
        for doc in docs:
            try:
                json_data = json.loads(doc.page_content)
                doc_ids.extend([item['id'] for item in json_data])
            except json.JSONDecodeError:
                continue

        csv_data["id"] = csv_data["id"].astype(str)
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

        for doc in docs:
            doc.metadata["reference_text"] = reference_text

        # 存储相似度信息供后续使用
        input_data["_similarity_scores"] = similarity_scores
        
        return docs

    history_aware_retriever = create_history_aware_retriever(
        llm,
        RunnableLambda(lambda x: {"input": x}) | enhanced_retriever,
        contextualize_q_prompt
    )

    def format_inputs(inputs: Dict) -> Dict:
        context_docs = inputs.get("context", [])
        reference_from_csv = ""
        attack_cases_text = []

        for doc in context_docs:
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

        return full_query

    question_answer_chain = (
        RunnablePassthrough.assign(context=history_aware_retriever) |
        RunnableLambda(format_inputs) |
        qa_prompt |
        llm
    )

    return create_retrieval_chain(history_aware_retriever, question_answer_chain)

# ============== 核心推理函数 ==============
'''
def analyze_contract(query: str, system_input_path: str = None, system_input_text: str = None) -> Dict[str, Any]:
    """
    分析智能合约的主要函数
    Args:
        query: 查询文本
        system_input_path: 系统输入文件路径
        system_input_text: 系统输入文本（二选一）
    Returns:
        分析结果字典
    """
    # 初始化组件
    embedding = JinaEmbedding()
    vector_store = load_or_create_vector_store(CONFIG["PERSIST_DIR"], embedding)
    ernie_ai = BaiduErnieAI()
    llm = ErnieLLMWrapper(ernie_ai)
    
    # 创建对话链
    conversational_chain = create_conversational_chain(
        vector_store,
        llm,
        csv_file_path=CONFIG["CSV_PATH"]
    )
    
    # 准备系统输入
    if system_input_path:
        system_input = load_system_input(system_input_path)
    elif system_input_text:
        system_input = system_input_text
    else:
        system_input = ""
    
    # 执行推理
    result = conversational_chain.invoke({
        "input": query,
        "system_input": system_input,
        "chat_history": [],
    })
    
    return result
'''
def analyze_contract(query: str, system_input_path: str = None, system_input_text: str = None) -> Dict[str, Any]:
    try:
        # 初始化组件
        embedding = JinaEmbedding()
        vector_store = load_or_create_vector_store(CONFIG["PERSIST_DIR"], embedding)
        ernie_ai = BaiduErnieAI()
        llm = ErnieLLMWrapper(ernie_ai)
        
        # 创建对话链
        conversational_chain = create_conversational_chain(
            vector_store,
            llm,
            csv_file_path=CONFIG["CSV_PATH"]
        )
        
        # 准备系统输入
        if system_input_path:
            system_input = load_system_input(system_input_path)
        elif system_input_text:
            system_input = system_input_text
        else:
            system_input = ""
        
        # 创建输入数据字典
        input_data = {
            "input": query,
            "system_input": system_input,
            "chat_history": [],
        }
        
        # 执行推理
        result = conversational_chain.invoke(input_data)
        
        # 添加相似度信息到结果
        similarity_info = _extract_similarity_info(result, input_data)
        if similarity_info:
            result["similarity_info"] = similarity_info
            print(f"成功添加相似度信息: {similarity_info}")
        else:
            print("未能获取相似度信息")
        
        return result
        
    except Exception as e:
        print(f"分析过程中出错: {str(e)}")
        import traceback
        traceback.print_exc()
        return {"error": f"分析过程中出错: {str(e)}", "status": "failed"}

def _extract_similarity_info(result: Dict, input_data: Dict = None) -> Optional[Dict]:
    """从结果中提取相似度信息"""
    similarity_scores = []
    
    # 首先尝试从输入数据中获取分数
    if input_data and "_similarity_scores" in input_data:
        similarity_scores = input_data["_similarity_scores"]
        print(f"从输入数据获取相似度分数: {similarity_scores}")
    
    # 然后尝试从文档元数据中获取
    elif isinstance(result, dict) and "context" in result:
        for doc in result["context"]:
            if (hasattr(doc, 'metadata') and 
                hasattr(doc.metadata, 'get') and 
                doc.metadata.get('similarity_score') is not None):
                similarity_scores.append(doc.metadata.get('similarity_score'))
            elif (isinstance(doc, dict) and 
                  'metadata' in doc and 
                  'similarity_score' in doc['metadata']):
                similarity_scores.append(doc['metadata']['similarity_score'])
    
    if similarity_scores:
        return {
            "min_score": min(similarity_scores),
            "max_score": max(similarity_scores),
            "avg_score": sum(similarity_scores) / len(similarity_scores),
            "doc_count": len(similarity_scores),
            "all_scores": similarity_scores
        }
    
    print("无法获取相似度分数")
    return None

def load_system_input(file_path: str) -> str:
    """加载系统输入文件"""
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            return json.dumps(json.load(f), ensure_ascii=False)
    except Exception as e:
        print(f"错误: 无法读取 JSON 文件: {e}")
        return ""

# ============== 简单测试函数 ==============
def simple_test():
    """简单的测试函数"""
    query = "Please analyze the current input in the context of the preceding and following text to determine whether it pertains to attack contracts?"
    system_input_path = r"G:\safe\longchain_RAG\test\data1\0x2a65254b41b42f39331a0bcc9f893518d6b106e80d9a476b8ca3816325f4a150.txt.json"
    
    print("=== 开始简单测试 ===")
    result = analyze_contract(query, system_input_path=system_input_path)
    
    print("\n=== 查询结果 ===")
    if isinstance(result, dict) and "answer" in result:
        print(f"答案: {result['answer']}")
        if "context" in result:
            print("\n参考文档:")
            for doc in result["context"]:
                print(f"- {doc.metadata.get('source_file', '未知来源')}")
    else:
        print(f"原始结果: {result}")
    
    return result

if __name__ == "__main__":
    simple_test()