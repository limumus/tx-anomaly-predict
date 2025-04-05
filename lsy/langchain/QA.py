import os
from datetime import datetime

import requests
import json
from dotenv import load_dotenv
from collections import deque
from typing import List, Dict, Any, Optional
from tqdm import tqdm

# LangChain相关模块
from langchain.chains import create_history_aware_retriever, create_retrieval_chain
from langchain.chains.combine_documents import create_stuff_documents_chain
from langchain_core.prompts import ChatPromptTemplate, MessagesPlaceholder
from langchain_core.messages import AIMessage, HumanMessage, SystemMessage
from langchain_chroma import Chroma
from langchain.embeddings.base import Embeddings
from langchain_core.runnables import Runnable,RunnableLambda
from langchain_core.output_parsers import StrOutputParser

# ============== 系统配置 ==============
CONFIG = {
    "JSON_FOLDER_PATH": "output_de",
    "PERSIST_DIR": "vector_store_realtime_0",
    "INTERMEDIATE_FOLDER": "intermediate_data",  # 新增保存中间数据的文件夹

    "HTTP_PROXY": "http://127.0.0.1:65151",
    "HTTPS_PROXY": "http://127.0.0.1:65151",

}

# 加载环境变量
load_dotenv()


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


# ============== 对话链构建 ==============
'''
def create_conversational_chain(vector_store: Chroma, llm: Runnable) -> Runnable:
    """创建带文档比对的对话式检索链"""

    # 1. 改进的上下文感知检索器prompt
    contextualize_q_prompt = ChatPromptTemplate.from_messages([
        ("system", """你是一个问题优化助手，请根据对话历史和提供的参考文档优化问题。

        参考文档片段:
        {reference_text}

        对话历史:
        {chat_history}

        原始问题: {input}

        请输出优化后的问题:""")
    ])

    # 2. 改进的问答prompt
    qa_prompt = ChatPromptTemplate.from_messages([
        ("system", """你是一个智能合约分析专家，请根据以下信息回答问题:

        相关文档内容:
        {context}

        参考比对文本:
        {reference_text}

        """),

        MessagesPlaceholder("chat_history"),
        ("user", "{input}")
    ])
    retriever = vector_store.as_retriever()

    # 3. 创建带文档比对的检索链
    def add_reference_text(input_dict: Dict):
        """从输入中提取参考文本"""
        # 这里可以从输入中提取或生成参考文本
        # 示例：简单使用前300字符作为参考
        reference = input_dict.get("input", "")[:300]
        return {**input_dict, "reference_text": reference}

    # 修改后的完整链条
    retrieval_chain = (
            RunnableLambda(add_reference_text)
            | {
                "input": lambda x: x["input"],
                "chat_history": lambda x: x.get("chat_history", []),
                "reference_text": lambda x: x["reference_text"]
            }
            | create_history_aware_retriever(llm, retriever, contextualize_q_prompt)
    )

    # 包装最终结果为字典格式
    full_chain = (
            {
                "input": lambda x: x["input"],
                "chat_history": lambda x: x.get("chat_history", []),
                "context": retrieval_chain,
                "reference_text": lambda x: x.get("reference_text", "")
            }
            | create_stuff_documents_chain(llm, qa_prompt)
            | {
                "answer": lambda x: x,
                "context": lambda x: x  # 这里需要从retrieval_chain获取上下文
            }
    )

    return full_chain
'''

def create_conversational_chain(vector_store: Chroma, llm: Runnable) -> Runnable:
    contextualize_q_prompt = ChatPromptTemplate.from_messages([
        ("human", """请基于以下参考文本优化问题：
        参考文本：{reference_text}
        原始问题：{input}
        优化后的问题：""")
    ])
    # 问答prompt
    qa_prompt = ChatPromptTemplate.from_messages([
        ("human", """请基于以下信息回答问题：
        相关上下文：
        {context}
        参考文本：
        {reference_text}
        问题：
        {input}""")
    ])

    retriever = vector_store.as_retriever(search_kwargs={"k": 3})
    # 历史感知检索
    history_aware_retriever = create_history_aware_retriever(
        llm, retriever, contextualize_q_prompt
    )
    # 文档处理
    question_answer_chain = create_stuff_documents_chain(llm, qa_prompt)
    return create_retrieval_chain(history_aware_retriever, question_answer_chain)
# ============== 结果处理工具 ==============
class ResultSaver:
    def __init__(self, output_dir: str = "results"):
        self.output_dir = output_dir
        if not os.path.exists(output_dir):
            os.makedirs(output_dir)

    def save_result(self, query: str, result: Dict, source_file: str):
        """改进的结果保存方法"""
        # 调试输出
        print("完整结果结构:", json.dumps(result, indent=2, ensure_ascii=False))

        # 检查有效答案的条件
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
                    }
                    for doc in result.get("context", [])
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

    # 检查服务可用性
    print("=== 服务检查 ===")
    print(f"向量数据库记录: {vector_store._collection.count()}")
    #print(f"ERNIE测试: {ernie_ai.simple_query('测试', '测试上下文')}")

    conversational_chain = create_conversational_chain(vector_store, llm)

    # 6. 示例对话
    chat_history = []
    query = "Vector databases contain only attack contracts. Please analyze the current input in the context of the preceding and following text to determine whether it pertains to attack contracts?"
    system_input = r"G:\safe\pythonProject\output\output\2018-04\BEC_exp.sol\0xad89ff16fd1ebe3a0a7cf4ed282302c06626c1af33221ebe0d3a470aba4a660f.txt.json"
    print("\n=== 开始测试流程 ===")

    result = conversational_chain.invoke({
        "input": query,
        "chat_history": [],
        "reference_text": json.dumps(system_input, ensure_ascii=False)[:1000]  # 确保参考文本传入
    })

    # 处理结果
    print("\n=== 查询结果 ===")
    if isinstance(result, dict) and "answer" in result:
        print(f"答案: {result['answer']}")
        if "context" in result:
            print("\n参考文档:")
            for doc in result["context"]:
                print(f"- {doc.metadata.get('source_file', '未知来源')}")
    else:
        print(f"原始结果: {result}")

    '''
    # 调试输出
    print("\n=== 调试信息 ===")
    print("1. 向量数据库检索测试:")
    print(vector_store.similarity_search(test_query, k=1)[0].metadata)

    print("\n2. ERNIE API测试:")
    print(ernie_ai.generate_response(test_query, "测试上下文"))

    print("\n3. 完整链路测试结果:")
    print(test_result)

    # 批量处理
    #print("\n=== 开始批量处理 ===")
    #processor = BatchProcessor(
    #    base_dir=r"G:\safe\pythonProject\output\output",
    #    result_dir="processed_results"
    #)
    #processor.process_all(query)

    # 初始化结果保存器
    #result_saver = ResultSaver()

    # 遍历处理所有JSON文件
    base_dir = r"G:\safe\pythonProject\output\output"
    total_files = 0
    processed_files = 0

    print(f"开始处理目录: {base_dir}")

    for root, _, files in os.walk(base_dir):
        for file in files:
            if file.endswith(".txt.json"):
                total_files += 1
                file_path = os.path.join(root, file)

                try:
                    with open(file_path, 'r', encoding='utf-8') as f:
                        reference_text = json.load(f)

                    # 执行查询
                    result = conversational_chain.invoke({
                        "input": query,
                        "chat_history": [],
                        "reference_text": json.dumps(reference_text, ensure_ascii=False)[:1000]
                    })

                    # 保存有答案的结果
                    if result_saver.save_result(query, result, file_path):
                        processed_files += 1
                        print(f"✅ 已保存结果: {file_path}")
                    else:
                        print(f"⚠️ 无有效答案: {file_path}")

                except Exception as e:
                    print(f"❌ 处理失败 {file_path}: {str(e)}")

    print(f"\n处理完成! 共处理 {total_files} 个文件，其中 {processed_files} 个包含有效答案")
    print(f"结果保存至: {result_saver.output_dir}")

    # 执行查询
    result = conversational_chain.invoke({
        "input": query,
        "chat_history": chat_history,
        "reference_text": json.dumps(reference_text, ensure_ascii=False)[:1000]  # 限制长度
    })


    # 处理结果输出
    if isinstance(result, dict):
        print(f"✅ 答案: {result.get('answer', '无答案')}")
        if "context" in result:
            print("\n来源文档:")
            if isinstance(result["context"], list):
                for doc in result["context"]:
                    print(f"- {doc.metadata.get('source_file', '未知来源')}")
            else:
                print("- 无上下文文档")
    else:
        print(f"✅ 答案: {result}")
'''