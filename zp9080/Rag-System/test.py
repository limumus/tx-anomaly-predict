
import json
from typing import List, Dict, Any
from haystack import Document
from collections import deque
from transformers import AutoTokenizer
from tqdm import tqdm
import tiktoken
import os

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


def count_tokens_with_tiktoken(text: str, model_name: str = "gpt-3.5-turbo") -> int:
    """使用与模型匹配的tokenizer计算文本token数"""
    try:
        # 获取对应模型的编码器（cl100k_base适用于GPT-3.5/4）
        encoding = tiktoken.encoding_for_model(model_name)
        return len(encoding.encode(text))
    except KeyError:
        # 兼容旧版模型名称
        encoding = tiktoken.get_encoding("cl100k_base")
        return len(encoding.encode(text))

from sentence_transformers import SentenceTransformer

MODEL_PATH = "/home/zp9080/models/all-mpnet-base-v2"

# 加载模型
model = SentenceTransformer(MODEL_PATH)

# 获取最大 token 长度
max_seq_length = model.get_max_seq_length()
print(f"模型最大支持 token 数量: {max_seq_length}")


# JSON_FOLDER_PATH = "/home/zp9080/Code/tx-anomaly-predict/hst/output_1"
# documents = JSONDocumentProcessor.load_json_data(JSON_FOLDER_PATH)

# # 为每个文档计算token数
# token_counts = []
# for idx, document in enumerate(documents, start=1):
#     if not hasattr(document, 'content'):
#         print(f"文档{idx}缺少content属性，已跳过")
#         continue
        
#     text_content = document.content
#     if not isinstance(text_content, str) or len(text_content.strip()) == 0:
#         print(f"文档{idx}的content为空或非字符串类型，已跳过")
#         continue

#     try:
#         token_count = count_tokens_with_tiktoken(text_content)
#         token_counts.append(token_count)
#         # print(f"文档{idx}的token数量: {token_count}")
#     except Exception as e:
#         print(f"文档{idx}处理失败: {str(e)}")

# # 在现有代码末尾添加最大token统计逻辑
# if token_counts:
#     max_tokens = max(token_counts)
#     print(f"最大token数量: {max_tokens}")
#     print(f"对应文档编号: {token_counts.index(max_tokens)+1}")  # 显示第一个出现最大值的文档序号
# else:
#     print("无有效token数据可计算最大值")
# # 打印统计结果
# print(f"\n总文档数: {len(documents)}")
# print(f"有效计算文档数: {len(token_counts)}")
# print(f"平均token数: {sum(token_counts)/len(token_counts):.1f}" if token_counts else "无有效数据")

# # 在现有统计代码后添加以下内容
# threshold = 30526
# over_limit_docs = []

# # 遍历所有文档和token计数
# for idx, (doc, token_count) in enumerate(zip(documents, token_counts), start=1):
#     if token_count > threshold:
#         # 获取来源文件名（从元数据中提取）
#         source_file = doc.meta.get("source_file", "未知文件") 
#         # 记录文档信息
#         over_limit_docs.append({
#             "文档编号": idx,
#             "token数量": token_count,
#             "来源文件": os.path.basename(source_file)[:30] + ("..." if len(source_file)>30 else "")
#         })

# # 输出统计结果
# if over_limit_docs:
#     print("\n=== 超限文档统计 ===")
#     print(f"阈值设定: {threshold} tokens")
#     print(f"超限文档总数: {len(over_limit_docs)}")
#     print(f"总计token数量: {sum(d['token数量'] for d in over_limit_docs)}")
    
#     # 打印详细信息（限制最多显示10条）
#     print("\n超限文档明细（前10条）:")
#     for doc in over_limit_docs[:10]:
#         print(f"文档{doc['文档编号']:04d} | Tokens: {doc['token数量']:6d} | 来源: {doc['来源文件']}")
# else:
#     print("\n没有超过30526 tokens的文档")


'''
最大token数量: 36223
对应文档编号: 44194

总文档数: 60286
有效计算文档数: 60286
平均token数: 1098.4

=== 超限文档统计 ===
阈值设定: 30526 tokens
超限文档总数: 2
总计token数量: 71945

超限文档明细（前10条）:
文档44194 | Tokens:  36223 | 来源: DeltaPrime_exp.sol.json...
文档44215 | Tokens:  35722 | 来源: DeltaPrime_exp.sol.json...
'''