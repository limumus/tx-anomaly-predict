import os
from datetime import datetime
import pandas as pd
import chardet
import requests
import json
import time
import re
from requests.adapters import HTTPAdapter, Retry
from typing import List, Dict, Any, Optional
from sentence_transformers import SentenceTransformer

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
from langchain.callbacks.base import BaseCallbackHandler

# 加载环境变量
load_dotenv()
# ⚠️ system_input 需要压缩: 373131 > 8000 字符
# 🔄 压缩参数: 比例=0.02, 深度=5, 阈值=5
# ✅ system_input 压缩完成: 373131 -> 5089 字符
# 🔄 压缩级别 1:
#   system_input: 5089 字符
#   reference_text: 33 字符
# ============== 系统配置 ==============
CONFIG = {
    "JSON_FOLDER_PATH": "output_de",
    "PERSIST_DIR": r"G:\safe\longchain_RAG\vector_store_realtime_0",
    "INTERMEDIATE_FOLDER": "intermediate_data",
    "CSV_PATH": "./extracted_data3.csv",
    "REASULT_FOLDER": "./batches_results_mix/728/second2",
    
    "HTTP_PROXY": "http://127.0.0.1:65151",
    "HTTPS_PROXY": "http://127.0.0.1:65151",

    #"JINA_API_KEY": "",#46,968
    "JINA_API_KEY": "",# 7,838,208


    "EMBEDDING_MODEL": "jina-embeddings-v3",

    "YI_API_KEY": "sk-",

    "DEEPSEEK_API_KEY": "",
    "TEST_API": "",
    "open_API": "sk-",

    "BAIDU_ACCESS_KEY": "",
    "BAIDU_SECRET_KEY": "",

    "OPENROUTER_API_KEY": "sk-or-v1-",
    "GEMINI_API_KEY": "",
    
    "SIMILARITY_THRESHOLD": 0.15,

    "GITEE_AI_API_URL": "https://api.moark.com/v1/chat/completions",
    "GITEE_AI_API_KEY": "",

    "MAX_RETRIES": 5,  # 最大重试次数
    "RETRY_DELAY": 10,  # 重试延迟（秒）
}

# ============== 调试工具函数 ==============
class SkipRAGManager:
    """统一管理 skip_rag 状态，避免全局变量混乱"""
    def __init__(self):
        self.skip_rag = False
    
    def set_skip_rag(self, value: bool):
        """设置 skip_rag 状态"""
        self.skip_rag = value
    
    def get_skip_rag(self):
        """获取当前 skip_rag 状态"""
        return self.skip_rag
    
    def reset(self):
        """重置状态"""
        self.skip_rag = False

# 创建全局管理器实例
skip_rag_manager = SkipRAGManager()

def debug_skip_rag(input_data: Any, function_name: str) -> Any:
    """调试函数：跟踪 skip_rag 标志的传递"""
    if isinstance(input_data, dict):
        skip_rag_value = input_data.get('skip_rag', '未设置')
        # print(f"🔍 [{function_name}] skip_rag = {skip_rag_value}")
        
        # 打印输入数据的键
        ## print(f"   📋 输入数据键: {list(input_data.keys())}")
        
        # 如果有上下文信息，打印文档数量
        if 'context' in input_data:
            context = input_data['context']
    #         if isinstance(context, list):
    #             # print(f"   📚 上下文文档数量: {len(context)}")
    #         else:
    #             # print(f"   📚 上下文类型: {type(context)}")
                
    # else:
    #     # print(f"🔍 [{function_name}] 输入数据类型: {type(input_data)}")
        
    return input_data


import pickle
import numpy as np
from typing import List, Dict, Any

# 常见函数签名映射
SIG_MAP = {
    "0x82be0b96": "collateralToken",
    "0x23b872dd": "transferFrom",
    "0xa9059cbb": "transfer",
    "0x095ea7b3": "approve",
    "0x40c10f19": "mint",
    "0x42966c68": "burn",
    "0x4e71d92d": "withdraw",
    "0x2e1a7d4d": "withdraw",
    "0x3ccfd60b": "flashLoan",
    "0x5cffe9de": "flashLoan",
    "0x1e2e5690": "swap",
    "0x38ed1739": "swap",
    "0x7c025200": "flashLoan",
    "0xcdc2e466": "withdraw",
    "0xd0e30db0": "deposit",
    "0x6a627842": "mint",
    "0x313ce567": "decimals",
    "0x06fdde03": "name",
    "0x95d89b41": "symbol",
    "0x18160ddd": "totalSupply",
}

def safe_parse_hex(hex_str):
    if not isinstance(hex_str, str):
        return str(hex_str)
    if hex_str.startswith("0x") and len(hex_str) >= 10:
        key = hex_str[:10].lower()
        return SIG_MAP.get(key, hex_str)
    return hex_str

def extract_features_from_json_v2(json_str):
    try:
        data = json.loads(json_str)
    except:
        data = {}

    calls = data.get("function_call", [])
    if not calls:
        for v in data.values():
            if isinstance(v, list):
                calls = v
                break
        if not calls:
            calls = []

    def traverse(clist, depth=0):
        info = {
            "call_count": 0,
            "event_count": 0,
            "max_depth": depth,
            "contracts": set(),
            "has_transfer": False,
            "has_approve": False,
            "has_flashloan": False,
            "has_delegatecall": False,
            "has_selfdestruct": False,
            "has_high_value": False,
            "value_list": [],
            "func_signatures": [],
            "total_value": 0.0,
        }
        if not isinstance(clist, list):
            return info

        for call in clist:
            if not isinstance(call, dict):
                continue

            info["call_count"] += 1
            func_raw = call.get("func", call.get("function", ""))
            func_name = safe_parse_hex(func_raw) if func_raw else ""
            info["func_signatures"].append(func_name)

            contract = call.get("contract", call.get("to", ""))
            if contract and isinstance(contract, str):
                info["contracts"].add(contract)

            ctype = call.get("type", "").upper()
            if ctype == "EVENT":
                info["event_count"] += 1

            if "transfer" in func_name.lower():
                info["has_transfer"] = True
            if "approve" in func_name.lower():
                info["has_approve"] = True
            if "flash" in func_name.lower():
                info["has_flashloan"] = True
            if "delegatecall" in ctype or func_name.lower() == "delegatecall":
                info["has_delegatecall"] = True
            if "selfdestruct" in func_name.lower():
                info["has_selfdestruct"] = True

            val_str = call.get("value", "0")
            try:
                if isinstance(val_str, str) and val_str.startswith("0x"):
                    val = float(int(val_str, 16))
                else:
                    val = float(val_str)
                if np.isfinite(val) and val <= 1e30:
                    info["value_list"].append(val)
                    info["total_value"] += val
                    if val > 1e18:
                        info["has_high_value"] = True
            except:
                pass

            sub_calls = call.get("internal_calls", [])
            if not sub_calls:
                sub_calls = call.get("calls", [])
            child = traverse(sub_calls, depth + 1)

            info["call_count"] += child["call_count"]
            info["event_count"] += child["event_count"]
            info["max_depth"] = max(info["max_depth"], child["max_depth"])
            info["contracts"].update(child["contracts"])
            info["has_transfer"] = info["has_transfer"] or child["has_transfer"]
            info["has_approve"] = info["has_approve"] or child["has_approve"]
            info["has_flashloan"] = info["has_flashloan"] or child["has_flashloan"]
            info["has_delegatecall"] = info["has_delegatecall"] or child["has_delegatecall"]
            info["has_selfdestruct"] = info["has_selfdestruct"] or child["has_selfdestruct"]
            info["has_high_value"] = info["has_high_value"] or child["has_high_value"]
            info["value_list"].extend(child["value_list"])
            info["total_value"] += child["total_value"]
            info["func_signatures"].extend(child["func_signatures"])

        return info

    stats = traverse(calls)

    call_count = stats["call_count"]
    event_count = stats["event_count"]
    max_depth = stats["max_depth"]
    unique_contracts = len(stats["contracts"])
    has_transfer = int(stats["has_transfer"])
    has_approve = int(stats["has_approve"])
    has_flashloan = int(stats["has_flashloan"])
    has_delegatecall = int(stats["has_delegatecall"])
    has_selfdestruct = int(stats["has_selfdestruct"])
    has_high_value = int(stats["has_high_value"])
    total_value = stats["total_value"]
    if total_value > 1e30:
        total_value = 1e30
    max_value = max(stats["value_list"]) if stats["value_list"] else 0.0
    if max_value > 1e30:
        max_value = 1e30
    unique_signatures = len(set(stats["func_signatures"]))
    unknown_sig_count = sum(1 for s in stats["func_signatures"] if isinstance(s, str) and s.startswith("0x") and len(s) >= 10)

    feat = [
        call_count,
        event_count,
        max_depth,
        unique_contracts,
        has_transfer,
        has_approve,
        has_flashloan,
        has_delegatecall,
        has_selfdestruct,
        has_high_value,
        total_value,
        max_value,
        unique_signatures,
        unknown_sig_count,
    ]
    feat = [0.0 if not np.isfinite(f) else f for f in feat]
    return feat

# ========== 特征提取部分结束 ==========

class XGBoostReranker:
    """基于XGBoost的二次筛选器：对当前交易打分，决定是否采纳RAG结果"""
    def __init__(self, model_path: str = r"G:\safe\longchain_RAG\xgb_filter_secondary2.pkl",
                 threshold_path: str = "best_threshold.txt"):
        with open(model_path, "rb") as f:
            self.model = pickle.load(f)
        # with open(threshold_path, "r") as f:
        #     self.threshold = float(f.read().strip())
        self.threshold = 0.55   # 固定阈值，简化逻辑
        # 特征顺序必须与训练时一致
        self.feature_names = [
            'call_count', 'event_count', 'max_depth', 'unique_contracts',
            'has_transfer', 'has_approve', 'has_flashloan', 'has_delegatecall',
            'has_selfdestruct', 'has_high_value', 'total_value_log', 'max_value_log',
            'unique_signatures', 'unknown_sig_count'
        ]

    def predict_proba(self, json_str: str) -> float:
        """
        输入交易JSON字符串，返回攻击概率（0~1）
        """
        feat = extract_features_from_json_v2(json_str)   # 14个原始特征
        # 对数变换（与训练代码一致）
        feat[10] = np.log1p(feat[10])   # total_value
        feat[11] = np.log1p(feat[11])   # max_value
        X = np.array(feat).reshape(1, -1)
        prob = self.model.predict_proba(X)[0, 1]
        return prob

    def should_use_rag(self, json_str: str) -> bool:
        """
        决定是否应该使用RAG检索的上下文
        若攻击概率 >= 阈值 => 使用RAG（返回True）
        否则 => 跳过RAG（返回False）
        """
        prob = self.predict_proba(json_str)
        return prob >= self.threshold


# 全局单例（避免重复加载）
_XGB_RERANKER = None

def get_xgb_reranker() -> XGBoostReranker:
    global _XGB_RERANKER
    if _XGB_RERANKER is None:
        _XGB_RERANKER = XGBoostReranker()
    return _XGB_RERANKER

import json
from typing import Dict, Any

def summarize_call_tree(
    data: Any,
    max_depth: int = 7,
    current_depth: int = 0,
    summarize_threshold: int = 8
) -> Any:
    # 深度超过限制，直接返回摘要占位
    if current_depth >= max_depth:
        return {
            "summary": f"[Depth {current_depth} too deep, {type(data).__name__} structure omitted]",
            "truncated": True
        }

    if isinstance(data, dict):
        result: Dict[str, Any] = {}
        
        for key, value in data.items():
            if key == "internal_calls" and isinstance(value, list):
                calls = value
                
                # 情况1：数量过多 → 先生成自然语言摘要
                if len(calls) > summarize_threshold:
                    # 提取关键信息用于总结
                    key_info = []
                    contract_set = set()
                    func_set = set()
                    type_set = set()
                    
                    for call in calls:
                        c_type = call.get("type", "UNKNOWN")
                        contract = call.get("contract", "") or call.get("to", "") or "unknown"
                        func = call.get("function", "unknown")
                        
                        type_set.add(c_type)
                        contract_set.add(str(contract))
                        func_set.add(func)
                        
                        # 简单一行描述
                        desc = f"{c_type} → {contract[:40]} .{func[:50]}"
                        if desc not in key_info:  # 粗糙去重
                            key_info.append(desc)
                    
                    # 构建自然语言摘要
                    summary_lines = []
                    if type_set:
                        summary_lines.append(f"Call types: {', '.join(sorted(type_set))}")
                    if len(contract_set) <= 5:
                        summary_lines.append(f"Contracts involved: {', '.join(sorted(contract_set))}")
                    else:
                        summary_lines.append(f"Contracts involved: {len(contract_set)} unique contracts")
                    if len(func_set) <= 8:
                        summary_lines.append(f"Functions called: {', '.join(sorted(list(func_set)[:8]))}")
                    
                    # 保留前几个完整调用 + 摘要
                    preserved_calls = [
                        summarize_call_tree(call, max_depth, current_depth + 1)
                        for call in calls[:min(5, len(calls))]
                    ]
                    
                    result[key] = preserved_calls + [{
                        "summary": "\n".join([
                            f"[Summary of {len(calls)} internal calls]",
                            *summary_lines,
                            f"[Omitted {len(calls) - 5} similar/repetitive calls]"
                        ])
                    }]
                
                else:
                    # 正常去重 + 递归处理
                    seen = set()
                    unique = []
                    for call in calls[:30]:  # 最多保留30个
                        call_str = json.dumps(call, sort_keys=True)
                        if call_str not in seen:
                            seen.add(call_str)
                            unique.append(summarize_call_tree(call, max_depth, current_depth + 1))
                    
                    if len(calls) > 30:
                        unique.append({"summary": f"[Omitted {len(calls)-30} additional calls]"})
                    
                    result[key] = unique
            
            else:
                # 其他字段正常递归
                result[key] = summarize_call_tree(value, max_depth, current_depth + 1)
        
        return result
    
    elif isinstance(data, list):
        # 对列表也限制长度
        summarized_list = [
            summarize_call_tree(item, max_depth, current_depth)
            for item in data[:60]
        ]
        if len(data) > 60:
            summarized_list.append({"summary": f"[Omitted {len(data)-60} additional list items]"})
        return summarized_list
    
    else:
        # 标量值直接返回
        return data


class SimplePromptMonitor(BaseCallbackHandler):
    """简化的提示词监控"""
    
    # def on_llm_start(self, serialized: Dict[str, Any], prompts: List[str], **kwargs: Any) -> None:
    #     """当LLM开始时调用"""
    #     # print(f"\n🎯 发送给模型的完整Prompt:")
    #     # print("=" * 100)
    #     for i, prompt in enumerate(prompts):
    #         # print(f"【Prompt {i+1}】:")
    #         # print(prompt)
    #         # print("=" * 100)
    
    # def on_llm_end(self, response, **kwargs: Any) -> None:
    #     """当LLM结束时调用"""
    #     # print(f"\n🤖 模型响应:")
    #     # print("=" * 100)
    #     if hasattr(response, 'content'):
    #         # print(response.content)
    #     elif hasattr(response, 'generations'):
    #         for gen in response.generations:
    #             for g in gen:
    #                 # print(g.text)
    #     # print("=" * 100)

# ============== 消息管理器类 ==============
class MessageManager:
    """统一管理消息的构建和压缩 - 只负责数据压缩，不负责prompt构建"""
    def build_messages_with_prompt_template(
        query: str,
        system_input: str,
        reference_text: str = "",
        skip_rag: bool = False,
        prompt_type: str = "rag",
        xgb_prob: Optional[float] = None   # 新增 XGBoost 概率
    ) -> List[Dict[str, str]]:
        """
        根据prompt模板构建完整消息
        """
        messages = []
        
        # 构建 XGBoost 提示
        xgb_hint = ""
        if xgb_prob is not None:
            xgb_hint = f"\n[ML Preliminary Assessment] XGBoost model outputs attack probability {xgb_prob:.3f} (threshold 0.5). This is a corrective hint to avoid false positives (over-classifying as attacks), not a final decision.\n"

        if prompt_type == "rag":
            if not skip_rag and reference_text.strip():
                context_content = f"Historical attack examples (context):\n{reference_text}\n\nCurrent transaction (system_input):\n{system_input}"
            else:
                context_content = f"Current transaction (system_input):\n{system_input}"
            
            prompt_content = f"""You are an expert in smart contract transaction analysis. Your task is to analyze the `Current transaction` against `Historical attack examples` provided in the context to determine malicious intent.
{context_content}
Key Analysis Focus:
- Bias: Start with the assumption that this is an Attack executing a known pattern.
- Comparison: Directly compare the execution flow and fund transfers in `system_input` with the logic of the historical examples.
- Logic: Ignore function names (e.g., `testExploit`); focus on the operational sequence, state changes, and security implications.
- Focus Points: Inter-contract calls, abnormal fund movements, and state manipulation patterns.
Core Directive: The historical examples were retrieved due to high behavioral similarity to the current transaction. Therefore, you must assume malicious intent initially and focus on validating the attack pattern.
Question:{query}
Strict Answer Rules:{xgb_hint}
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
"""
        else:
            prompt_content = f"""You are an expert in smart contract transaction analysis. Evaluate the current transaction based only on the provided transaction data.
Current transaction (system_input):\n{system_input}
Question: {query}


Strict Answer Rules:{xgb_hint}
- You must begin your answer with one of: `Attack` or `Benign`.
- Follow this structured format:

[Attack || Benign]

1. Behavior Summary:
- Describe the transaction's overall behavior, including contract interactions and fund movements.

2. Call Sequence Analysis:
- Analyze the function call sequence. Highlight any unusual order of operations or patterns that violate established smart contract security practices.

3. Malicious Indicators:
- Identify specific behaviors that directly indicate an attack OR explicitly state why the transaction is logically sound.

- Limit your answer to 200 words."""
        
        messages.append({
            "role": "user",
            "content": prompt_content,
            "type": "prompt",
            "original_length": len(prompt_content)
        })
        return messages

    @staticmethod
    def compress_system_input(system_input: str, max_chars: int = 8000) -> str:
        if not system_input or len(system_input) <= max_chars:
            return system_input
        
        # print(f"⚠️ system_input 需要压缩: {len(system_input)} > {max_chars} 字符")
        
        try:
            # 尝试解析为 JSON
            data = json.loads(system_input)
            
            # 计算需要压缩的比例
            compression_ratio = max_chars / len(system_input)
            
            # 根据压缩比例调整压缩深度
            if compression_ratio < 0.5:
                max_depth = 5  # 高压缩率，深度较小
                summarize_threshold = 5
            elif compression_ratio < 0.7:
                max_depth = 6  # 中等压缩率
                summarize_threshold = 8
            else:
                max_depth = 7  # 低压缩率
                summarize_threshold = 10
            
            # print(f"🔄 压缩参数: 比例={compression_ratio:.2f}, 深度={max_depth}, 阈值={summarize_threshold}")
            
            # 使用现有的总结函数压缩 JSON
            compressed_data = summarize_call_tree(
                data, 
                max_depth=max_depth,
                summarize_threshold=summarize_threshold
            )
            
            # 转换回 JSON 字符串
            compressed_json = json.dumps(compressed_data, ensure_ascii=False)
            
            # 如果还是太长，进行截断
            if len(compressed_json) > max_chars:
                # print(f"⚠️ 压缩后仍然过长 ({len(compressed_json)} > {max_chars})，进行智能截断")
                
                # 尝试保留关键结构
                if "{" in compressed_json and "}" in compressed_json:
                    # 保留JSON的开头和结尾
                    half_chars = max_chars // 2
                    start_part = compressed_json[:half_chars]
                    end_part = compressed_json[-half_chars:]
                    
                    # 找到合适的截断点
                    last_brace = start_part.rfind("}")
                    if last_brace != -1 and last_brace > half_chars - 100:
                        start_part = start_part[:last_brace + 1]
                    
                    first_brace = end_part.find("{")
                    if first_brace != -1 and first_brace < 100:
                        end_part = end_part[first_brace:]
                    
                    compressed_json = f"{start_part}\n... [中间内容已省略] ...\n{end_part}"
                    
                    # 最终截断
                    if len(compressed_json) > max_chars:
                        compressed_json = compressed_json[:max_chars]
                else:
                    # 如果不是标准JSON，直接截断
                    compressed_json = compressed_json[:max_chars]
            
            # print(f"✅ system_input 压缩完成: {len(system_input)} -> {len(compressed_json)} 字符")
            return compressed_json
            
        except json.JSONDecodeError:
            # 如果不是 JSON，直接智能截断
            # print(f"⚠️ system_input 不是有效 JSON，进行智能截断")
            
            # 保留开头和结尾的重要信息
            keep_start = int(max_chars * 0.6)  # 保留前60%
            keep_end = max_chars - keep_start - 50  # 保留结尾部分
            
            compressed = (
                system_input[:keep_start] + 
                "\n\n... [中间内容已省略] ...\n\n" + 
                system_input[-keep_end:] if len(system_input) > keep_end else system_input
            )
            
            if len(compressed) > max_chars:
                compressed = compressed[:max_chars]
            
            return compressed + "\n[内容已截断]"
        except Exception as e:
            # print(f"❌ system_input 压缩失败: {e}")
            # 失败时返回原始内容，但进行截断
            return system_input[:max_chars] + "\n[压缩失败，内容已截断]"
    
    @staticmethod
    def compress_reference_text(reference_text: str, max_chars: int = 4000) -> str:
        if not reference_text or len(reference_text) <= max_chars:
            return reference_text
        
        # print(f"⚠️ reference_text 需要压缩: {len(reference_text)} > {max_chars} 字符")
        
        try:
            # 将参考文本按段落分割
            paragraphs = reference_text.split("\n\n")
            
            if len(paragraphs) <= 3:
                # 段落较少，直接截断
                return reference_text[:max_chars] + "\n[内容已截断]"
            
            # 计算每个段落的大致长度
            paragraph_lengths = [len(p) for p in paragraphs]
            total_length = sum(paragraph_lengths)
            
            # 确定要保留的段落数
            avg_length = total_length / len(paragraphs)
            paragraphs_to_keep = max(2, int(max_chars / avg_length))  # 至少保留2段
            
            if paragraphs_to_keep >= len(paragraphs):
                # 如果段落不多，直接截断
                return reference_text[:max_chars] + "\n[内容已截断]"
            
            # 选择保留的段落：开头几段 + 结尾几段
            keep_start = max(1, paragraphs_to_keep // 2)  # 保留开头的段落数
            keep_end = paragraphs_to_keep - keep_start    # 保留结尾的段落数
            
            # 构建压缩后的文本
            compressed_paragraphs = paragraphs[:keep_start] + [f"[省略了 {len(paragraphs) - paragraphs_to_keep} 个相似案例...]"] + paragraphs[-keep_end:]
            compressed_text = "\n\n".join(compressed_paragraphs)
            
            # 确保不超过长度限制
            if len(compressed_text) > max_chars:
                compressed_text = compressed_text[:max_chars]
            
            # print(f"✅ reference_text 压缩完成: {len(reference_text)} -> {len(compressed_text)} 字符")
            # print(f"   原始段落数: {len(paragraphs)}，保留段落数: {len(compressed_paragraphs)}")
            
            return compressed_text
            
        except Exception as e:
            # print(f"❌ reference_text 压缩失败: {e}")
            # 失败时返回截断的原始文本
            return reference_text[:max_chars] + "\n[压缩失败，内容已截断]"
    
    @staticmethod
    def create_compression_plan(
        system_input: str,
        reference_text: str = "",
        max_total_chars: int = 15000,
        system_input_weight: float = 0.7,
        reference_text_weight: float = 0.3
    ) -> Dict[str, Any]:
        """
        创建压缩计划，智能分配字符预算
        
        参数:
            system_input: 系统输入
            reference_text: 参考文本
            max_total_chars: 总字符数限制
            system_input_weight: system_input的权重
            reference_text_weight: reference_text的权重
            
        返回:
            压缩计划字典
        """
        # 计算各部分当前长度
        system_input_len = len(system_input)
        reference_text_len = len(reference_text)
        total_len = system_input_len + reference_text_len
        
        if total_len <= max_total_chars:
            # 不需要压缩
            return {
                "needs_compression": False,
                "system_input_target": system_input_len,
                "reference_text_target": reference_text_len,
                "total_length": total_len,
                "max_total_chars": max_total_chars
            }
        
        # print(f"📊 压缩计划分析:")
        # print(f"  system_input: {system_input_len} 字符")
        # print(f"  reference_text: {reference_text_len} 字符")
        # print(f"  总计: {total_len} 字符，限制: {max_total_chars} 字符")
        # print(f"  超出: {total_len - max_total_chars} 字符")
        
        # 根据权重分配字符预算
        system_input_budget = int(max_total_chars * system_input_weight)
        reference_text_budget = int(max_total_chars * reference_text_weight)
        
        # 调整预算（如果某部分已经小于预算）
        if system_input_len < system_input_budget:
            # system_input 有富余，将预算分配给 reference_text
            surplus = system_input_budget - system_input_len
            reference_text_budget += surplus
            system_input_budget = system_input_len
        
        if reference_text_len < reference_text_budget:
            # reference_text 有富余，将预算分配给 system_input
            surplus = reference_text_budget - reference_text_len
            system_input_budget += surplus
            reference_text_budget = reference_text_len
        
        # print(f"📋 压缩计划:")
        # print(f"  system_input 目标: {system_input_budget} 字符 (当前: {system_input_len})")
        # print(f"  reference_text 目标: {reference_text_budget} 字符 (当前: {reference_text_len})")
        
        return {
            "needs_compression": True,
            "system_input_target": system_input_budget,
            "reference_text_target": reference_text_budget,
            "total_length": total_len,
            "max_total_chars": max_total_chars,
            "compression_needed": {
                "system_input": max(0, system_input_len - system_input_budget),
                "reference_text": max(0, reference_text_len - reference_text_budget)
            }
        }
    
    @staticmethod
    def apply_compression_plan(
        system_input: str,
        reference_text: str,
        plan: Dict[str, Any]
    ) -> Dict[str, str]:
        """
        应用压缩计划
        
        返回:
            包含压缩后数据的字典
        """
        if not plan["needs_compression"]:
            return {
                "system_input": system_input,
                "reference_text": reference_text,
                "compression_applied": False
            }
        
        # print(f"🔄 应用压缩计划...")
        
        # 压缩 system_input
        compressed_system_input = MessageManager.compress_system_input(
            system_input,
            max_chars=plan["system_input_target"]
        )
        
        # 压缩 reference_text
        # compressed_reference_text = MessageManager.compress_reference_text(
        #     reference_text,
        #     max_chars=plan["reference_text_target"]
        # )
        compressed_reference_text = reference_text  # 目前不压缩 reference_text
        
        total_after = len(compressed_system_input) + len(compressed_reference_text)
        
        # print(f"✅ 压缩应用完成:")
        # print(f"  system_input: {len(system_input)} -> {len(compressed_system_input)}")
        # print(f"  reference_text: {len(reference_text)} -> {len(compressed_reference_text)}")
        # print(f"  总计: {plan['total_length']} -> {total_after} 字符")
        
        return {
            "system_input": compressed_system_input,
            "reference_text": compressed_reference_text,
            "compression_applied": True,
            "original_lengths": {
                "system_input": len(system_input),
                "reference_text": len(reference_text)
            },
            "compressed_lengths": {
                "system_input": len(compressed_system_input),
                "reference_text": len(compressed_reference_text)
            }
        }
# ============== 百度文心ERNIE模型封装（重试 + 输入长度错误） ==============
class BaiduErnieAI:
    def __init__(self):
        self.access_key = CONFIG["BAIDU_ACCESS_KEY"]
        self.secret_key = CONFIG["BAIDU_SECRET_KEY"]
        self.api_url = "https://aip.baidubce.com/rpc/2.0/ai_custom/v1/wenxinworkshop/chat/ernie-speed-128k"
        self.max_retries = CONFIG["MAX_RETRIES"]  # 5
        self.retry_delay = CONFIG["RETRY_DELAY"]  # 5秒

    def get_access_token(self):
        url = f"https://aip.baidubce.com/oauth/2.0/token?grant_type=client_credentials&client_id={self.access_key}&client_secret={self.secret_key}"
        try:
            response = requests.post(url, headers={'Content-Type': 'application/json'}, timeout=10)
            response.raise_for_status()
            return response.json().get("access_token")
        except Exception as e:
            # print(f"获取访问令牌失败: {str(e)}")
            return None

    def generate_response(self, messages: List[Dict[str, str]]) -> str:
        """
        改进的重试逻辑，处理长度错误
        """
        last_error = None
        
        for attempt in range(self.max_retries + 1):
            try:
                # print(f"🔄 BaiduErnieAI 调用第 {attempt + 1}/{self.max_retries + 1} 次")
                access_token = self.get_access_token()
                if not access_token:
                    if attempt < self.max_retries:
                        time.sleep(self.retry_delay)
                        continue
                    return "无法获取访问令牌"

                url = f"{self.api_url}?access_token={access_token}"
                payload = json.dumps({"messages": messages}, ensure_ascii=False)

                response = requests.post(url,
                                        headers={'Content-Type': 'application/json'},
                                        data=payload,
                                        timeout=60)
                response.raise_for_status()
                data = response.json()

                if "error_code" in data:
                    error_msg = data.get("error_msg", "")
                    full_error = f"API错误: {error_msg}"

                    # 检查是否是长度错误
                    if any(keyword in error_msg.lower() for keyword in [
                        "max input characters",
                        "prompt tokens too long",
                        "input too long",
                        "tokens too long",
                        "content too long"
                    ]):
                        # print(f"⚠️ 输入过长错误: {error_msg}")
                        
                        if attempt < self.max_retries:
                            # 返回特定错误让上层处理
                            return f"INPUT_TOO_LONG_ERROR: {error_msg}"
                        else:
                            return full_error
                    
                    # 其他可重试错误
                    if attempt < self.max_retries:
                        # print(f"⚠️ API错误，{self.retry_delay}秒后重试...")
                        time.sleep(self.retry_delay)
                        continue
                    
                    return full_error

                return data.get("result", "未能获取回答")

            except requests.exceptions.Timeout:
                last_error = "API请求超时"
                # print(f"⏰ 超时，{self.retry_delay}秒后重试...")
                if attempt < self.max_retries:
                    time.sleep(self.retry_delay)
                else:
                    break
                    
            except requests.exceptions.RequestException as e:
                last_error = f"网络错误: {e}"
                # print(f"🔌 网络错误: {e}")
                if attempt < self.max_retries:
                    time.sleep(self.retry_delay)
                else:
                    break
                    
            except Exception as e:
                last_error = f"未知错误: {e}"
                # print(f"💥 未知错误: {e}")
                break

        return f"API调用失败: {last_error}"


class Llama3InstructAI:
    def __init__(self):
        self.api_url = "https://api.apiyi.com/v1/chat/completions"
        self.api_key = CONFIG["YI_API_KEY"]
        self.max_retries = CONFIG["MAX_RETRIES"]  # 5
        self.retry_delay = CONFIG["RETRY_DELAY"]  # 5秒

    def _make_api_call(self, messages: List[Dict], access_token: str = None, **kwargs) -> Dict:
        """
        执行实际的API调用
        """
        #"model": "gpt-3.5-turbo",
        payload = {
            "model": "gpt-4.1-mini",
            "messages": messages,
            "stream": False,
            "max_tokens": 1024,
            "temperature": 0.7,
            "top_p": 1,
            "n": 1,
        }
        payload.update(kwargs)

        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
        }

        print(f"🔗 调用Llama3 API: {self.api_url}")
        response = requests.post(
            self.api_url,
            headers=headers,
            data=json.dumps(payload),
            timeout=60
        )
        response.raise_for_status()
        return response.json()

    def _extract_content(self, response_data: Dict) -> str:
        """
        从API响应中提取内容
        """
        if "choices" in response_data and len(response_data["choices"]) > 0:
            message = response_data["choices"][0].get("message", {})
            content = message.get("content", "").strip()
            return content if content else "API返回空内容"
        return "API响应格式异常"

    def generate_response(self, messages: List[Dict[str, str]], **kwargs) -> str:
        """
        改进的重试逻辑，处理特定错误
        """
        last_error = None
        
        for attempt in range(self.max_retries + 1):
            try:
                print(f"🔄 gpt-4.1-mini 调用第 {attempt + 1}/{self.max_retries + 1} 次")
                
                # 检查API密钥
                if not self.api_key:
                    if attempt < self.max_retries:
                        time.sleep(self.retry_delay)
                        continue
                    return "无法获取API密钥"

                # 执行API调用
                response_data = self._make_api_call(messages, **kwargs)
                
                # 检查API返回的错误
                if "error" in response_data:
                    error_msg = response_data["error"].get("message", "")
                    error_type = response_data["error"].get("type", "")
                    full_error = f"API错误[{error_type}]: {error_msg}"

                    # 检查是否是输入过长错误
                    input_too_long_keywords = [
                        "max_tokens", "token_limit", "too_long",
                        "length", "exceed", "limit"
                    ]
                    
                    if any(keyword in error_msg.lower() for keyword in input_too_long_keywords):
                        # print(f"⚠️ 输入过长错误: {error_msg}")
                        
                        if attempt < self.max_retries:
                            # 返回特定错误让上层处理
                            return f"INPUT_TOO_LONG_ERROR: {error_msg}"
                        else:
                            return full_error
                    
                    # 其他可重试错误
                    if attempt < self.max_retries:
                        # print(f"⚠️ API错误，{self.retry_delay}秒后重试...")
                        time.sleep(self.retry_delay)
                        continue
                    
                    return full_error

                # 提取并返回内容
                content = self._extract_content(response_data)
                if content in ["API返回空内容", "API响应格式异常"]:
                    if attempt < self.max_retries:
                        # print(f"⚠️ {content}，{self.retry_delay}秒后重试...")
                        time.sleep(self.retry_delay)
                        continue
                
                # print(f"✅ API调用成功")
                return content

            except requests.exceptions.Timeout:
                last_error = "API请求超时"
                # print(f"⏰ 超时，{self.retry_delay}秒后重试...")
                if attempt < self.max_retries:
                    time.sleep(self.retry_delay)
                else:
                    break
                    
            except requests.exceptions.RequestException as e:
                last_error = f"网络错误: {e}"
                # print(f"🔌 网络错误: {e}")
                if attempt < self.max_retries:
                    time.sleep(self.retry_delay)
                else:
                    break
                    
            except Exception as e:
                last_error = f"未知错误: {e}"
                # print(f"💥 未知错误: {e}")
                # 对于未知错误，不重试
                break

        return f"API调用失败: {last_error}" if last_error else "API调用失败: 未知错误"
# ============== 嵌入服务封装 ==============
class JinaEmbedding(Embeddings):
    def __init__(self):
        self.api_url = "https://api.jina.ai/v1/embeddings"
        self.headers = {
            "Authorization": f"Bearer {CONFIG['JINA_API_KEY']}",
            "Content-Type": "application/json"
        }
        self.session = requests.Session()
        proxies = {}
        if CONFIG.get("HTTP_PROXY"):
            proxies["http"] = CONFIG["HTTP_PROXY"]
        if CONFIG.get("HTTPS_PROXY"):
            proxies["https"] = CONFIG["HTTPS_PROXY"]
        if proxies:
            self.session.proxies.update(proxies)
            print(f"🔌 已设置代理: {proxies}")

        # 配置重试策略：最多重试3次，遇到超时/连接错误/5xx都会重试
        retries = Retry(
            total=3,                # 总重试次数
            backoff_factor=2,       # 重试间隔递增：2s, 4s, 8s...
            status_forcelist=[429, 500, 502, 503, 504],
            allowed_methods=["POST"]
        )

        self.session.mount("https://", HTTPAdapter(max_retries=retries))

    def embed_documents(self, texts: List[str]) -> List[List[float]]:
        return [self._get_embedding(text) for text in texts]

    def embed_query(self, text: str) -> List[float]:
        return self._get_embedding(text)

    def _get_embedding(self, text: str) -> List[float]:
        try:
            response = self.session.post(
                self.api_url,  # <--- 修正：使用 self.api_url
                headers=self.headers,
                json={
                    "model": CONFIG.get("EMBEDDING_MODEL", "jina-embeddings-v3"),
                    "input": [text[:8192]]
                },
                timeout=15
            )
            response.raise_for_status()
            data = response.json()
            if not data.get('data') or len(data['data']) == 0:
                raise ValueError("API returned empty embedding data")
            return data['data'][0]['embedding']
        except Exception as e:
            raise RuntimeError(f"Embedding API failed: {e}") from e

# class JinaEmbedding:
#     def __init__(self, model_path: str = "G:/huggingface/jina-embeddings-v3"):
#         # 自动检测设备
#         try:
#             import torch
#             device = "cuda" if torch.cuda.is_available() else "cpu"
#         except ImportError:
#             device = "cpu"

#         # 使用 SentenceTransformer 加载本地模型
#         self.model = SentenceTransformer(
#             model_path,
#             device=device,
#             trust_remote_code=True
#         )
#         self.embedding_dim = self.model.get_sentence_embedding_dimension()

#     def embed_documents(self, texts: List[str]) -> List[List[float]]:
#         # SentenceTransformer 原生支持批量处理，效率更高
#         embeddings = self.model.encode(
#             texts,
#             normalize_embeddings=False,   # 根据需求决定是否归一化
#             show_progress_bar=False
#         )
#         return embeddings.tolist()

#     def embed_query(self, text: str) -> List[float]:
#         # 单条查询
#         embedding = self.model.encode(
#             text,
#             normalize_embeddings=False
#         )
#         return embedding.tolist()


# ============== ERNIE模型包装器 ==============
class ErnieLLMWrapper(Runnable):
    def __init__(self, ernie_ai: BaiduErnieAI):
        super().__init__()
        self.ernie_ai = ernie_ai
    
    def invoke(self, input_data: Any, config: Optional[Dict] = None) -> AIMessage:
        print(f"\n{'🔍'*30}")
        print(f"ErnieLLMWrapper 收到输入:")
        print(f"  类型: {type(input_data)}")
        
        try:
            if not isinstance(input_data, dict):
                return AIMessage(content="错误：LLM Wrapper 接收到非字典输入")
            
            # 提取必需字段
            query = input_data.get("query", "Please analyze whether this transaction constitutes a malicious attack.")
            system_input = input_data.get("system_input", "")
            reference_text = input_data.get("reference_text", "")
            skip_rag = input_data.get("skip_rag", False)
            prompt_type = input_data.get("prompt_type", "rag")
            xgb_prob = input_data.get("xgb_prob", None)   # 获取 XGBoost 概率
            
            # 创建初始数据备份（只包含数据部分）
            current_backup = {
                "query": query,
                "system_input": system_input,
                "reference_text": reference_text,
                "skip_rag": skip_rag,
                "prompt_type": prompt_type,
                "compression_level": 0,  # 压缩级别，0表示未压缩
                "original_system_input_length": len(system_input),
                "original_reference_text_length": len(reference_text)
            }
            
            # 最大压缩级别
            max_compression_level = 3
            
            for compression_level in range(max_compression_level + 1):
                try:
                    # print(f"\n🔄 尝试压缩级别 {compression_level}/{max_compression_level}")
                    
                    # 如果是第0级（未压缩），使用原始数据
                    # 如果是第1级及以上，压缩数据
                    if compression_level > 0:
                        # 根据压缩级别调整目标长度
                        if compression_level == 1:
                            # 第一级压缩：中等压缩
                            target_system_chars = 8000
                            #target_reference_chars = 3000
                        elif compression_level == 2:
                            # 第二级压缩：较强压缩
                            target_system_chars = 5000
                            #target_reference_chars = 1500
                        else:
                            # 第三级压缩：最强压缩
                            target_system_chars = 3000
                            #target_reference_chars = 800
                        
                        # 压缩 system_input
                        compressed_system_input = MessageManager.compress_system_input(
                            current_backup["system_input"], 
                            max_chars=target_system_chars
                        )
                        
                        # 压缩 reference_text
                        # compressed_reference_text = MessageManager.compress_reference_text(
                        #     current_backup["reference_text"],
                        #     max_chars=target_reference_chars
                        # )
                        compressed_reference_text = current_backup["reference_text"]  # 目前不压缩 reference_text
                        
                        # 更新备份数据
                        current_backup["system_input"] = compressed_system_input
                        current_backup["reference_text"] = compressed_reference_text
                        current_backup["compression_level"] = compression_level
                        
                        # print(f"🔄 压缩级别 {compression_level}:")
                        # print(f"  system_input: {len(current_backup['system_input'])} 字符")
                        # print(f"  reference_text: {len(current_backup['reference_text'])} 字符")
                    
                    # 使用当前数据构建完整prompt（每次都重新构建）
                    prompt_content = self._build_prompt_content(
                        query=current_backup["query"],
                        system_input=current_backup["system_input"],
                        reference_text=current_backup["reference_text"],
                        skip_rag=current_backup["skip_rag"],
                        prompt_type=current_backup["prompt_type"],
                        xgb_prob=xgb_prob
                    )
                    
                    # 构建API消息（单条用户消息）
                    api_messages = [{"role": "user", "content": prompt_content}]

                    if isinstance(input_data, dict):
                        input_data["_full_prompt_content"] = prompt_content  # 保存完整的prompt内容
                        input_data["_api_messages"] = api_messages  # 保存API消息
                    

                    # 🔴 新增：直接将prompt内容写入txt文件（最简单版本）
                    # try:
                    #     import hashlib
                    #     import os
                        
                    #     # 生成当前prompt的hash作为文件名
                    #     prompt_hash = hashlib.md5(prompt_content.encode('utf-8')).hexdigest()
                    #     # if system_input_path:
                    #     #     # 使用文件名的hash（去掉路径和扩展名）
                    #     #     file_name = os.path.basename(system_input_path)  # 如：bsc-0xe968e648b2353cea06fc3da39714fb964b9354a1ee05750a3c5cc118da23444b.json
                    #     #     file_hash = file_name.replace('.json', '')  # 去掉.json后缀
                    #     #     prompt_hash = file_hash  # 直接使用文件名hash
                    #     # else:
                    #     #     prompt_hash = hashlib.md5(prompt_content.encode('utf-8')).hexdigest()
                        
                    #     # 指定固定文件夹
                    #     save_dir = r"G:\safe\longchain_RAG\batches_results_mix\api_messages_logs\batch"  # 修改行：修改为你的路径
                    #     os.makedirs(save_dir, exist_ok=True)
                        
                    #     # 创建文件路径
                    #     file_path = os.path.join(save_dir, f"{prompt_hash}.txt")
                        
                    #     # 只写入prompt内容
                    #     with open(file_path, 'w', encoding='utf-8') as f:
                    #         f.write(prompt_content)
                        
                    #     print(f"📝 Prompt内容已保存到: {file_path} (hash: {prompt_hash})")
                        
                    # except Exception as e:
                    #     print(f"⚠️ 保存Prompt到文件失败: {e}")
                    print(f"📊 完整prompt字符数: {len(prompt_content)}")
                    #print(f"完整的prompt内容预览:\n{prompt_content}...\n")
                    
                    # 为每个压缩级别设置重试次数
                    max_retries = 3
                    retry_count = 0
                    
                    while retry_count < max_retries:
                        try:
                            response = self.ernie_ai.generate_response(api_messages)
                            
                            # 检查是否是长度错误
                            if "INPUT_TOO_LONG_ERROR" in response:
                                # print(f"⚠️ API返回长度错误，将在下一级别进行压缩")
                                if compression_level < max_compression_level:
                                    break  # 跳出重试循环，进入下一压缩级别
                                else:
                                    # 达到最大压缩级别仍然失败
                                    # print("❌ 所有压缩级别都失败")
                                    return AIMessage(content="[Unknown]\n\nAnalysis function fault: Unable to process due to excessive input length after multiple compression attempts.")
                            
                            # 检查其他API错误
                            if any(keyword in response for keyword in ["API错误", "API调用失败", "网络错误"]):
                                retry_count += 1
                                if retry_count < max_retries:
                                    # print(f"⚠️ API错误，第 {retry_count} 次重试（压缩级别 {compression_level}）")
                                    continue  # 继续重试当前压缩级别
                                else:
                                    # print(f"⚠️ API错误达到最大重试次数，尝试下一压缩级别")
                                    break
                            
                            # 成功返回
                            # print(f"✅ API调用成功，压缩级别: {compression_level}")
                            return AIMessage(
                                content=response,
                                additional_kwargs={
                                    "_full_prompt_content": prompt_content if 'prompt_content' in locals() else "",
                                    "_api_messages": api_messages if 'api_messages' in locals() else []
                                }
                            )
                                                        
                        except Exception as e:
                            retry_count += 1
                            if retry_count < max_retries:
                                # print(f"⚠️ API调用异常，第 {retry_count} 次重试（压缩级别 {compression_level}）: {e}")
                                continue
                            else:
                                # print(f"⚠️ API调用异常达到最大重试次数，尝试下一压缩级别: {e}")
                                break
                    
                    if compression_level < max_compression_level:
                        continue
                    else:
                        break
                        
                except Exception as e:
                    # print(f"❌ 压缩级别 {compression_level} 失败: {e}")
                    if compression_level < max_compression_level:
                        continue
                    else:
                        break
            
            # 所有尝试都失败
            # print(f"❌ 所有压缩尝试都失败")
            return AIMessage(content="[Unknown]\n\nAnalysis function fault: Unable to process the transaction after multiple attempts.")
            
        except Exception as e:
            import traceback
            traceback.print_exc()
            return AIMessage(content=f"[Unknown]\n\nAnalysis function fault: {str(e)}")
    
    def _build_prompt_content(
        self,
        query: str,
        system_input: str,
        reference_text: str = "",
        skip_rag: bool = False,
        prompt_type: str = "rag",
        xgb_prob: Optional[float] = None
    ) -> str:
        # 直接调用 MessageManager 的构建方法
        messages = MessageManager.build_messages_with_prompt_template(
            query=query,
            system_input=system_input,
            reference_text=reference_text,
            skip_rag=skip_rag,
            prompt_type=prompt_type,
            xgb_prob=xgb_prob
        )
        return messages[0]["content"]
    
# ============== 向量数据库管理 ==============
def load_or_create_vector_store(persist_dir: str, embedding: Embeddings) -> Chroma:
    if os.path.exists(persist_dir):
        return Chroma(persist_directory=persist_dir, embedding_function=embedding)
    else:
        return Chroma(persist_directory=persist_dir, embedding_function=embedding)

# ============== Gitee AI Qwen3模型封装（带重试机制） ==============
class GiteeQwenAI:
    def __init__(self):
        self.api_url = CONFIG["GITEE_AI_API_URL"]
        self.api_key = CONFIG["GITEE_AI_API_KEY"]
        self.max_retries = CONFIG["MAX_RETRIES"]
        self.retry_delay = CONFIG["RETRY_DELAY"]

    def generate_response_with_retry(self, messages: List[Dict[str, str]], query_id: str = "unknown", **kwargs) -> str:
        """
        带重试机制的API调用
        """
        last_error = None
        
        for attempt in range(self.max_retries + 1):  # 初始尝试 + 重试次数
            try:
                print(f"🔄 尝试调用API (第 {attempt + 1}/{self.max_retries + 1} 次)...")
                
                result = self._make_api_call(messages, **kwargs)
                
                # 检查是否是需要重试的错误
                if self._should_retry(result):
                    if attempt < self.max_retries:
                        print(f"⚠️ API返回可重试错误，{self.retry_delay}秒后重试...")
                        time.sleep(self.retry_delay)
                        continue
                    else:
                        print("❌ 达到最大重试次数，放弃重试")
                        return result
                else:
                    # 成功或不可重试的错误
                    return result
                    
            except requests.exceptions.Timeout as e:
                last_error = f"API请求超时: {str(e)}"
                print(f"⏰ {last_error}")
                if attempt < self.max_retries:
                    print(f"⏰ 超时，{self.retry_delay}秒后重试...")
                    time.sleep(self.retry_delay)
                else:
                    break
                    
            except requests.exceptions.RequestException as e:
                last_error = f"API请求异常: {str(e)}"
                print(f"🔌 {last_error}")
                if attempt < self.max_retries:
                    print(f"🔌 网络异常，{self.retry_delay}秒后重试...")
                    time.sleep(self.retry_delay)
                else:
                    break
                    
            except Exception as e:
                last_error = f"API调用异常: {str(e)}"
                print(f"💥 {last_error}")
                # 对于其他异常，不重试
                break
        
        # 所有重试都失败，记录错误
        error_data = {
            "query_id": query_id,
            "error_type": "API_CALL_FAILED",
            "error_message": last_error,
            "attempts": attempt + 1,
            "messages_preview": str(messages)[:500] if messages else "No messages"
        }
        
        return f"API调用失败 after {attempt + 1} 次尝试: {last_error}"

    def _make_api_call(self, messages: List[Dict[str, str]], **kwargs) -> str:
        """执行单次API调用"""
        # 构建请求数据
        payload = {
            "model": "Qwen3-8B",
            "messages": messages,
            "stream": False,
            "max_tokens": 1024,
            "frequency_penalty": 0,
            "presence_penalty": 0,
            "temperature": 0.7,
            "top_p": 1,
            "top_logprobs": 0,
            "n": 1,
        }
        
        # 更新自定义参数
        payload.update(kwargs)
        payload = clean_payload(payload)
        
        headers = {
            'Content-Type': 'application/json',
            'Authorization': f'Bearer {self.api_key}'
        }

        print(f"🔗 调用Gitee AI API: {self.api_url}")
        response = requests.post(
            self.api_url,
            headers=headers,
            data=json.dumps(payload),
            timeout=60
        )
        response.raise_for_status()
        
        response_data = response.json()
        print(f"✅ API响应状态: {response.status_code}")
        
        # 解析响应
        if "choices" in response_data and len(response_data["choices"]) > 0:
            message = response_data["choices"][0].get("message", {})
            content = message.get("content", "未能获取回答")
            
            # 检查内容是否有效
            if not content or content.strip() == "":
                return "API返回空内容"
            return content
        else:
            error_msg = f"API响应格式异常: {response_data}"
            print(f"❌ {error_msg}")
            return error_msg

    def _should_retry(self, result: str) -> bool:
        """判断是否需要重试"""
        retry_conditions = [
            "API请求超时",
            "API请求异常",
            "API调用异常",
            "API返回空内容",
            "API响应格式异常",
            "无法获取访问令牌",
        ]
        
        return any(condition in result for condition in retry_conditions)

    def generate_response(self, messages: List[Dict[str, str]], **kwargs) -> str:
        """向后兼容的接口"""
        return self.generate_response_with_retry(messages, "unknown", **kwargs)

def clean_payload(payload: Dict[str, Any]) -> Dict[str, Any]:
    return {
        k: v for k, v in payload.items()
        if v is not None and v != "" and v != [None]
    }

# ============== DeepSeek V3模型封装（带重试机制） ==============
class DeepSeekV3API:
    def __init__(self):
        self.api_url = "https://api.deepseek.com/v1/chat/completions"
        self.api_key = CONFIG["DEEPSEEK_API_KEY"]
        self.max_retries = CONFIG["MAX_RETRIES"]
        self.retry_delay = CONFIG["RETRY_DELAY"]

    def generate_response_with_retry(self, messages: List[Dict], query_id: str = "unknown", **kwargs) -> str:
        last_error = None

        for attempt in range(self.max_retries + 1):
            try:
                # print(f"🔄 尝试调用DeepSeek API (第 {attempt + 1}/{self.max_retries + 1} 次)...")
                result = self._make_api_call(messages, **kwargs)

                if self._should_retry(result):
                    if attempt < self.max_retries:
                        # print(f"⚠️ API返回可重试错误，{self.retry_delay}秒后重试...")
                        time.sleep(self.retry_delay)
                        continue
                    else:
                        # print("❌ 达到最大重试次数，放弃重试")
                        return result
                else:
                    return result

            except requests.exceptions.Timeout as e:
                last_error = f"API请求超时: {str(e)}"
                # print(f"⏰ {last_error}")
                if attempt < self.max_retries:
                    time.sleep(self.retry_delay)
                else:
                    break

            except requests.exceptions.RequestException as e:
                last_error = f"API请求异常: {str(e)}"
                # print(f"🔌 {last_error}")
                if attempt < self.max_retries:
                    time.sleep(self.retry_delay)
                else:
                    break

            except Exception as e:
                last_error = f"API调用异常: {str(e)}"
                # print(f"💥 {last_error}")
                break

        error_data = {
            "query_id": query_id,
            "error_type": "API_CALL_FAILED",
            "error_message": last_error,
            "attempts": attempt + 1,
            "messages_preview": str(messages)[:500] if messages else "No messages"
        }

        return f"API调用失败 after {attempt + 1} 次尝试: {last_error}"

    def _make_api_call(self, messages: List[Dict], **kwargs) -> str:
        payload = {
            "model": "deepseek-v3.2-exp",
            "messages": messages,
            "stream": False,
            "max_tokens": 1024,
            "temperature": 0.7,
            "top_p": 1,
            "n": 1,
            "enable_thinking": True  # 开启思考模式，适合论文推理
        }

        payload.update(kwargs)

        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json"
        }

        # print(f"🔗 调用DeepSeek API: {self.api_url}")
        response = requests.post(
            self.api_url,
            headers=headers,
            data=json.dumps(payload),
            timeout=60
        )
        response.raise_for_status()

        response_data = response.json()
        # print(f"✅ API响应状态: {response.status_code}")

        if "choices" in response_data and len(response_data["choices"]) > 0:
            message = response_data["choices"][0].get("message", {})
            content = message.get("content", "未能获取回答")
            return content if content.strip() else "API返回空内容"
        else:
            error_msg = f"API响应格式异常: {response_data}"
            # print(f"❌ {error_msg}")
            return error_msg

    def _should_retry(self, result: str) -> bool:
        retry_conditions = [
            "API请求超时",
            "API请求异常",
            "API调用异常",
            "API返回空内容",
            "API响应格式异常",
            "无法获取访问令牌",
        ]
        return any(condition in result for condition in retry_conditions)

    def generate_response(self, messages: List[Dict], **kwargs) -> str:
        return self.generate_response_with_retry(messages, "unknown", **kwargs)

# ============== 创建对话链 ==============
def create_conversational_chain(vector_store: Chroma, llm: Runnable, csv_file_path: str,
                                original_input: Dict, xgb_reranker: XGBoostReranker = None) -> Runnable:
    """
    创建对话链，新增 xgb_reranker 用于二次筛选
    """
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
        ("human", """You are an expert in smart contract attack detection. Your task is to analyze the `Current transaction` against `Historical attack examples` provided in the context to determine malicious intent.
    Core Directive: The historical examples were retrieved due to high behavioral similarity to the current transaction. Therefore, you must assume malicious intent initially and focus on validating the attack pattern.

    1. Current transaction (system_input):{system_input}
    2. Historical attack examples (context):{context}

    Key Analysis Focus:
    - Bias: Start with the assumption that this is an Attack executing a known pattern.
    - Comparison: Directly compare the execution flow and fund transfers in `system_input` with the logic of the historical examples.
    - Logic: Ignore function names (e.g., `testExploit`); focus on the operational sequence, state changes, and security implications.
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
    """)
    ])

    direct_qa_prompt = ChatPromptTemplate.from_messages([
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
    """)
    ])


    retriever = vector_store.as_retriever(search_kwargs={"k": 1})

    def enhanced_retriever(input_data: Dict) -> List[Document]:
        """增强的检索器，带 skip_rag 调试"""
        #global global_skip_rag
        
        try:
            # 检查是否已经设置了 skip_rag
            if input_data.get("skip_rag", False):
                print("🚫 enhanced_retriever: 检测到 skip_rag=True，直接返回空列表")
                skip_rag_manager.set_skip_rag(True)
                return []
            
            # 统一提取查询文本
            query_text = ""
            if "system_input" in input_data and input_data["system_input"]:
                query_text = input_data["system_input"]
            elif "input" in input_data and input_data["input"]:
                query_text = input_data["input"]
            elif "original_query" in input_data and input_data["original_query"]:
                query_text = input_data["original_query"]
            else:
                # 如果都没有，尝试从其他字段获取
                for key, value in input_data.items():
                    if isinstance(value, str) and value.strip():
                        query_text = value
                        break
            
            if not query_text:
                query_text = str(input_data)
            
            print(f"🔍 enhanced_retriever: 使用文本进行检索: {query_text[:200]}...")
            
            # 使用 similarity_search_with_score 获取带分数的文档
            docs_with_scores = vector_store.similarity_search_with_score(
                query_text,
                k=3
            )
            
            # 分离文档和分数
            docs = [doc for doc, score in docs_with_scores]
            similarity_scores = [score for doc, score in docs_with_scores]
            
            print(f"📊 enhanced_retriever: 检索到 {len(docs)} 个文档，相似度分数: {[f'{score:.4f}' for score in similarity_scores]}")
            
            # 应用距离阈值过滤
            threshold = CONFIG.get("SIMILARITY_THRESHOLD", 0.12)
            filtered_docs = []
            filtered_scores = []
            
            for doc, score in docs_with_scores:
                if score <= threshold:
                    filtered_docs.append(doc)
                    filtered_scores.append(score)
                    
                    if not hasattr(doc, 'metadata') or doc.metadata is None:
                        doc.metadata = {}
                    elif not isinstance(doc.metadata, dict):
                        doc.metadata = dict(doc.metadata)
                    
                    doc.metadata['similarity_score'] = float(score)
                    doc.metadata['score'] = float(score)
                    print(f"✅ 文档分数: {score:.4f} (通过阈值 {threshold})")
                else:
                    print(f"❌ 文档分数: {score:.4f} (未通过阈值 {threshold})")
            
            docs = filtered_docs
            similarity_scores = filtered_scores
            
            # 如果没有通过阈值的文档，设置跳过RAG标志
            if not docs:
                print("🚫 enhanced_retriever: 没有找到足够相似的文档，设置 skip_rag=True")
                input_data["skip_rag"] = True
                skip_rag_manager.set_skip_rag(True)
                input_data["_similarity_scores"] = similarity_scores
                input_data["_docs_with_scores"] = list(zip(docs, similarity_scores))
                
                # 关键修复：如果存在原始输入引用，也同步设置 skip_rag
                if "_original_input_ref" in input_data and isinstance(input_data["_original_input_ref"], dict):
                    input_data["_original_input_ref"]["skip_rag"] = True
                    skip_rag_manager.set_skip_rag(True)
                    print("🔄 enhanced_retriever: 已同步 skip_rag 到原始输入引用")
            
                return []
            
            # 将分数添加到文档元数据中
            for i, (doc, score) in enumerate(zip(docs, similarity_scores)):
                print(f"📄 文档 {i+1} 分数: {score:.4f}")
            
            # 存储相似度信息供后续使用
            input_data["_similarity_scores"] = similarity_scores
            input_data["_docs_with_scores"] = list(zip(docs, similarity_scores))
            input_data["skip_rag"] = False
            ######change########
            input_data["_retrieved_documents"] = docs  # 新增：保存检索到的文档

            skip_rag_manager.set_skip_rag(False)
            
            return docs
            
        except Exception as e:
            # print(f"❌ enhanced_retriever: 检索失败: {e}")
            input_data["skip_rag"] = True
            skip_rag_manager.set_skip_rag(True)
            
            if "_original_input_ref" in input_data and isinstance(input_data["_original_input_ref"], dict):
                input_data["_original_input_ref"]["skip_rag"] = True
                skip_rag_manager.set_skip_rag(True)
                print("🔄 enhanced_retriever: 出错时已同步 skip_rag 到原始输入引用")
            
            return []
    
    # ============== 修复 create_retriever_input 函数 ==============
    def create_retriever_input(x):
        """修复：确保正确传递 skip_rag 参数"""
        if isinstance(x, dict):
            input_dict = {
                "input": x.get("input", ""),
                "skip_rag": x.get("skip_rag", False)  # 关键修复：传递 skip_rag
            }
        else:
            input_dict = {"input": str(x), "skip_rag": False}
        
        return input_dict

    def enhanced_retriever_with_context(input_data: Dict) -> List[Document]:
        """带上下文的检索器"""
        
        # 创建完整数据，但保留对原始 input_data 的引用
        full_data = {
            "processd_query": input_data,
            "system_input": original_input.get("system_input", ""),
            "original_query": original_input.get("input", ""),
            "_original_input_ref": input_data  # 添加对原始输入的引用
        }
        
        # 传递 skip_rag 标志
        if isinstance(input_data, dict):
        # 传递 skip_rag 标志
            if "skip_rag" in input_data:
                full_data["skip_rag"] = input_data["skip_rag"]
                skip_rag_manager.set_skip_rag(input_data["skip_rag"])
                print(f"🔄 enhanced_retriever_with_context: 传递 skip_rag = {input_data['skip_rag']}")
            
            # 传递其他可能需要的参数
            for key in ["system_input", "chat_history"]:
                if key in input_data:
                    full_data[key] = input_data[key]
        
        # print(f"📦 enhanced_retriever_with_context: 完整数据键: {list(full_data.keys())}")
        
        # 调用检索器
        docs = enhanced_retriever(full_data)
        
        if "skip_rag" in full_data:
            input_data["skip_rag"] = full_data["skip_rag"]
            input_data["_retrieved_documents"] = full_data.get("_retrieved_documents", [])  # 新增：同步文档
            print(f"🔄 enhanced_retriever_with_context: 同步 skip_rag = {full_data['skip_rag']} 回原始输入")
        
        return docs

    # ============== route_based_on_rag 函数 ==============
    def route_based_on_rag(inputs: Dict) -> Dict:
        """根据是否使用RAG路由到不同的处理链"""
        query = inputs.get("input", "")
        system_input = inputs.get("system_input", "")
        current_skip_rag = skip_rag_manager.get_skip_rag()
        print(current_skip_rag)
        if current_skip_rag:
            print("🔄 route_based_on_rag: 使用直接查询路径（跳过RAG）")
            return {
                "query": query,
                "system_input": system_input,
                "skip_rag": True
            }
        else:
            print("🔄 route_based_on_rag: 使用RAG增强查询路径")

            def replace_ids_with_descriptions_FINAL(data, id_to_description, current_doc_ids_set):
                """
                递归处理数据结构：
                1. 如果 ID 匹配到 description，则用 description_Security 替换 id。
                2. 如果 ID 没有匹配到 description，则直接删除 id。
                """
                if isinstance(data, list):
                    # 如果是列表，递归处理列表中的每个元素
                    return [replace_ids_with_descriptions_FINAL(item, id_to_description, current_doc_ids_set) 
                            for item in data]
                
                elif isinstance(data, dict):
                    new_data = {}
                    
                    # 遍历字典中的所有键值对
                    for key, value in data.items():
                        
                        if key == 'id':
                            doc_id = str(value)
                            
                            # 记录该文档中出现的 ID
                            current_doc_ids_set.add(doc_id)
                            
                            if doc_id in id_to_description:
                                # 规则 1: ID 匹配成功，用 description_Security 替换 id
                                new_data['description_Security'] = id_to_description[doc_id]
                                # print(f"🔄 匹配成功：ID {doc_id} 已替换为 description_Security")
                            #else:
                                # 规则 2: ID 匹配失败，直接跳过，达到删除 id 的目的
                                # print(f"➖ 匹配失败：ID {doc_id} 已删除")
                            
                        else:
                            # 规则 3: 处理其他键，进行递归
                            new_data[key] = replace_ids_with_descriptions_FINAL(value, id_to_description, current_doc_ids_set)
                            
                    return new_data
                    
                else:
                    # 如果不是列表也不是字典，返回原值
                    return data

            # --- 主处理函数 (包含修正后的逻辑) ---
            def process_documents_with_description_replacement(inputs: Dict[str, Any], CONFIG: Dict[str, Any]):
                docs: List[Document] = inputs.get("context", [])
                
                # 1. 读取CSV数据并创建 ID 到 description 的映射
                try:
                    csv_data = pd.read_csv(
                        CONFIG["CSV_PATH"], 
                        usecols=['id', 'description_Security'], 
                        encoding="MacRoman"
                    )
                    csv_data["id"] = csv_data["id"].astype(str)
                    id_to_description = dict(zip(csv_data["id"], csv_data["description_Security"]))
                    # print(f"📊 加载了 {len(id_to_description)} 个ID-description映射")
                except Exception as e:
                    # print(f"❌ CSV 文件加载或处理失败: {e}")
                    return {
                        "query": inputs.get("input", ""),
                        "system_input": inputs.get("system_input", ""),
                        "context": docs,
                        "reference_text": "Error loading CSV data for description replacement.",
                        "skip_rag": False
                    }

                processed_docs = []
                global_reference_texts = []
                
                for doc in docs:
                    current_doc_ids_set = set() # 记录当前文档中出现的 ID
                    
                    try:
                        json_data = json.loads(doc.page_content)
                        
                        # ⭐ 核心：使用修正后的递归函数进行替换/删除
                        processed_json = replace_ids_with_descriptions_FINAL(json_data, id_to_description, current_doc_ids_set)
                        
                        # 创建新的文档内容
                        # ensure_ascii=False 确保中文等字符正确编码
                        new_page_content = json.dumps(processed_json, ensure_ascii=False)
                        
                        # 创建新文档对象，保留原metadata
                        new_doc = Document(
                            page_content=new_page_content,
                            metadata=doc.metadata.copy() if doc.metadata else {}
                        )
                        processed_docs.append(new_doc)
                        
                        # print(f"✅ 文档处理完毕。文档中 ID 数量: {len(current_doc_ids_set)}")
                        
                        # 2. 构建当前文档中匹配到的 reference_text 摘要
                        for doc_id in current_doc_ids_set:
                            if doc_id in id_to_description:
                                description = id_to_description[doc_id]
                                ref_text = (
                                    f"ID: {doc_id}\n"
                                    f"Description: {description}\n"
                                    "------"
                                )
                                # 避免重复添加到最终的 reference_text
                                if ref_text not in global_reference_texts:
                                    global_reference_texts.append(ref_text)
                        
                    except json.JSONDecodeError as e:
                        # print(f"❌ 文档JSON解析失败: {e}，保留原始内容。")
                        processed_docs.append(doc)
                        continue
                
                # 3. 构建最终的 reference_text
                reference_text = "\n\n".join(global_reference_texts) if global_reference_texts else "No matching ID found in CSV data."

                result = {
                    "query": inputs.get("input", ""),
                    "system_input": inputs.get("system_input", ""),
                    "context": processed_docs,
                    "reference_text": reference_text,
                    "skip_rag": False
                }
                
                # print(f"✅ 最终处理完成。")
                return result
            
            # 调用文档处理函数
            result = process_documents_with_description_replacement(inputs, CONFIG)
            
            # 返回处理结果
            return {
                "query": result["query"],
                "system_input": result["system_input"],
                "reference_text": result["reference_text"],
                "skip_rag": False
            }

    # ============== 修复：route_to_appropriate_prompt 函数 ==============
    def route_to_appropriate_prompt(inputs: Dict) -> Dict:
        """路由到适当的提示词模板，返回LLM调用所需的参数"""
        # print(f"\n{'🔍'*30}")
        # print(f"route_to_appropriate_prompt 收到输入:")
        # print(f"  类型: {type(inputs)}")
        # if isinstance(inputs, dict):
        #     # print(f"  键: {list(inputs.keys())}")
        #     for key, value in inputs.items():
        #         if isinstance(value, str):
        #             # print(f"  {key}: {value[:100]}...")
        #         elif isinstance(value, list):
        #             # print(f"  {key}: [{len(value)} 个元素]")
        #         else:
        #             # print(f"  {key}: {type(value)}")
        # # print(f"{'🔍'*30}\n")
        
        # if not isinstance(inputs, dict):
        #     # print(f"❌ route_to_appropriate_prompt: 输入不是字典，类型: {type(inputs)}")
        #     return {"error": "输入格式错误"}
        
        # 确定prompt类型
        current_skip_rag = skip_rag_manager.get_skip_rag()
        if current_skip_rag:
            print("📝 route_to_appropriate_prompt: 选择直接查询提示词")
            prompt_type = "direct"
        else:
            print("📝 route_to_appropriate_prompt: 选择RAG增强提示词")
            prompt_type = "rag"
        
        try:
            # 提取关键信息
            query = inputs.get("query", "")
            system_input = inputs.get("system_input", "")
            reference_text = inputs.get("reference_text", "")
            xgb_prob = inputs.get("xgb_prob", None)   # 获取概率
            
            # 构建LLM调用参数
            llm_input = {
                "query": query,
                "system_input": system_input,
                "reference_text": reference_text,
                "skip_rag": current_skip_rag,
                "prompt_type": prompt_type,  # 添加prompt类型
                "xgb_prob": xgb_prob
            }
            
            # print(f"🔍 构建的LLM输入参数:")
            # print(f"   query: {query[:100]}...")
            # print(f"   system_input 长度: {len(system_input)}")
            # print(f"   reference_text 长度: {len(reference_text)}")
            print(f"   skip_rag: {current_skip_rag}")
            # print(f"   prompt_type: {prompt_type}")
            
            # 构建完整消息用于显示
            messages = MessageManager.build_messages_with_prompt_template(
                query=query,
                system_input=system_input,
                reference_text=reference_text,
                skip_rag=current_skip_rag,
                prompt_type=prompt_type,
                xgb_prob= xgb_prob
            )
            
            if messages:
                content = messages[0]["content"]
                # print(f"\n🎯 构建的完整Prompt:")
                # print(f"长度: {len(content)} 字符")
                # print(f"预览: {content[:500]}...")
            
            # print(f"\n{'✅' * 20}")
            
            # 返回LLM调用参数
            return llm_input
            
        except Exception as e:
            # print(f"❌ route_to_appropriate_prompt 出错: {e}")
            import traceback
            traceback.print_exc()
            return {"error": f"提示词处理失败: {str(e)}"}


    history_aware_retriever = create_history_aware_retriever(
        llm,
        RunnableLambda(create_retriever_input) | enhanced_retriever_with_context,
        contextualize_q_prompt
    )
    
    def full_processing_chain(input_data: Dict) -> Dict:
        """完整的处理链"""
        # 步骤1: 检索上下文（RAG 粗筛）
        context = enhanced_retriever_with_context(input_data)
        
        xgb_prob = None
        current_skip_rag = skip_rag_manager.get_skip_rag()
        
        # 条件：XGBoost 可用 + RAG 未跳过
        if xgb_reranker is not None and not current_skip_rag:
            system_input_json = input_data.get("system_input", "")
            if system_input_json:
                prob = xgb_reranker.predict_proba(system_input_json)
                xgb_prob = prob
                print(f"🎯 XGBoost二次验证: 攻击概率={prob:.4f}, 阈值={xgb_reranker.threshold}")
                if prob < xgb_reranker.threshold:
                    # XGBoost 认为低概率（可能误召回），放弃 RAG 结果，改为直接模式
                    print("🚫 XGBoost 验证失败，放弃 RAG 上下文，改为直接模式")
                    input_data["skip_rag"] = True
                    skip_rag_manager.set_skip_rag(True)
                    context = []   # 清空检索结果
                    current_skip_rag = True
                    # 同步到原始输入引用（如果存在）
                    if "_original_input_ref" in input_data and isinstance(input_data["_original_input_ref"], dict):
                        input_data["_original_input_ref"]["skip_rag"] = True
                else:
                    print("✅ XGBoost 验证通过，保留 RAG 上下文")
                    # 确保 skip_rag 为 False（可能之前被设为 True，但这里覆盖为 False）
                    input_data["skip_rag"] = False
                    skip_rag_manager.set_skip_rag(False)
                    current_skip_rag = False
        
        # 步骤2: 构建 reference_text（使用重命名后的函数）
        routed_data = route_based_on_rag({
            **input_data,
            "context": context
        })
        
        # 关键修改：将 xgb_prob 传递给 prompt 构建函数
        if xgb_prob is not None:
            routed_data["xgb_prob"] = xgb_prob
        
        # 步骤3: 选择提示词模板并构建 prompt
        llm_input = route_to_appropriate_prompt(routed_data)
        current_skip_rag = skip_rag_manager.get_skip_rag()
        
        if "error" in llm_input:
            return {
                "answer": f"错误: {llm_input['error']}",
                "context": context,
                "used_rag": not current_skip_rag
            }
        
        # 步骤4: 调用 LLM
        llm_response = llm.invoke(llm_input)
        
        # 构建结果
        result = {
            "answer": llm_response.content if hasattr(llm_response, 'content') else str(llm_response),
            "context": context,
            "used_rag": not current_skip_rag
        }
        
        if isinstance(input_data, dict):
            if "_full_prompt_content" in input_data:
                result["_full_prompt_content"] = input_data["_full_prompt_content"]
            if "_api_messages" in input_data:
                result["_api_messages"] = input_data["_api_messages"]
            if "_retrieved_documents" in input_data:
                result["_retrieved_documents"] = input_data["_retrieved_documents"]
        
        # 提取相似度信息
        similarity_info = None
        if hasattr(context, '__iter__'):
            scores = []
            for doc in context:
                if hasattr(doc, 'metadata') and doc.metadata:
                    score = doc.metadata.get('similarity_score')
                    if score is not None:
                        scores.append(float(score))
            if scores:
                similarity_info = {
                    "min_score": min(scores),
                    "max_score": max(scores),
                    "avg_score": sum(scores) / len(scores),
                    "doc_count": len(scores),
                    "all_scores": scores
                }
                result["similarity_info"] = similarity_info
        
        # 在结果中附带 XGBoost 概率
        if xgb_prob is not None:
            result["xgb_prob"] = xgb_prob
        
        return result
    
    return RunnableLambda(full_processing_chain)




# ============== 核心推理函数 ==============
def analyze_contract(query: str, system_input_path: str = None, system_input_text: str = None) -> Dict[str, Any]:
    try:
        # 初始化组件
        skip_rag_manager.reset()
        embedding = JinaEmbedding()
        vector_store = load_or_create_vector_store(CONFIG["PERSIST_DIR"], embedding)
        # print(f"📊 向量数据库中有 {vector_store._collection.count()} 条向量数据")
        #ernie_ai = BaiduErnieAI()
        # ernie_ai = GiteeQwenAI()  # 使用Gitee Qwen3模型
        #ernie_ai = Llama4MaverickAI()  # 使用Llama4 Maverick模型
        #ernie_ai = DeepSeekV3API()  # 使用DeepSeek V3模型
        #ernie_ai = Gemma3InstructAPI()  # 使用Gemma3 Instruct模型
        ernie_ai = Llama3InstructAI()  # 使用Llama3 Instruct模型
        llm = ErnieLLMWrapper(ernie_ai)
        
        # 准备系统输入
        if system_input_path:
            system_input = load_system_input(system_input_path)
        elif system_input_text:
            system_input = system_input_text
        else:
            system_input = ""
        
        reranker = get_xgb_reranker()

        # 创建输入数据字典
        input_data = {
            "input": query,
            "system_input": system_input,
            "chat_history": [],
            "skip_rag": False
        }

        
        print(f"\n{'🚀'*30}")
        print(f"开始分析合约:")
        print(f"  查询: {query[:100]}...")
        print(f"  系统输入长度: {len(system_input)}")
        print(f"{'🚀'*30}\n")
                
        # 创建对话链
        conversational_chain = create_conversational_chain(
            vector_store,
            llm,
            csv_file_path=CONFIG["CSV_PATH"],
            original_input=input_data,
            xgb_reranker=reranker
        )

        # 执行推理
        print("🚀 开始执行推理...")
        callbacks = [SimplePromptMonitor()]
        llm_response = conversational_chain.invoke(input_data, config={"callbacks": callbacks})

        # 🔴 修复：直接从LLM响应中提取API消息
        if hasattr(llm_response, 'additional_kwargs'):
            result = {
                "answer": llm_response.content,
                "used_rag": not skip_rag_manager.get_skip_rag(),
                "similarity_info": None,
                "xgb_prob": llm_response.get("xgb_prob", None)
            }
            # 复制additional_kwargs中的调试信息
            for key in ["_full_prompt_content", "_api_messages"]:
                if key in llm_response.additional_kwargs:
                    result[key] = llm_response.additional_kwargs[key]
        else:
            # 原有逻辑
            result = conversational_chain.invoke(input_data, config={"callbacks": callbacks})
            final_skip_rag = skip_rag_manager.get_skip_rag()
            
            # 确保所有必要字段都存在
            if "used_rag" not in result:
                result["used_rag"] = not final_skip_rag
            if "similarity_info" not in result:
                result["similarity_info"] = None

        # 可选：在返回中添加XGBoost概率信息
        try:
            prob = reranker.predict_proba(system_input)
            result["xgb_attack_probability"] = prob
            result["xgb_threshold"] = reranker.threshold
            result["xgb_decision"] = "use_rag" if reranker.should_use_rag(system_input) else "skip_rag"
        except Exception as e:
            print(f"XGBoost评分失败: {e}")
        

        print(f"🔍 最终是否使用RAG: {result['used_rag']}")

        return result
        
    except Exception as e:
        # print(f"❌ 分析过程中出错: {str(e)}")
        import traceback
        traceback.print_exc()
        return {
            "error": f"分析过程中出错: {str(e)}", 
            "status": "failed",
            "similarity_info": None,
            "used_rag": False,
            "xgb_prob": llm_response.get("xgb_prob", None)
        }

def _extract_similarity_info(result: Dict, input_data: Dict = None) -> Optional[Dict]:
    """从结果中提取相似度信息"""
    similarity_scores = []
    
    # 方法1: 首先检查输入数据中是否有存储的相似度信息
    if input_data and "_similarity_scores" in input_data:
        scores = input_data["_similarity_scores"]
        if scores and len(scores) > 0:
            #try:
            similarity_scores = [float(score) for score in scores]
                # print(f"📊 从输入数据中获取相似度分数: {similarity_scores}")
            #except (ValueError, TypeError) as e:
                # print(f"❌ 输入数据中的分数格式错误: {e}")
    
    # 方法2: 从文档元数据中获取相似度分数
    if not similarity_scores and isinstance(result, dict) and "context" in result and result["context"]:
        for i, doc in enumerate(result["context"]):
            score = None
            
            metadata = None
            if hasattr(doc, 'metadata'):
                metadata = doc.metadata
            elif isinstance(doc, dict) and 'metadata' in doc:
                metadata = doc['metadata']
            
            if metadata:
                for score_key in ['similarity_score', 'score', 'similarity', 'distance']:
                    if score_key in metadata:
                        score_value = metadata[score_key]
                        try:
                            score = float(score_value)
                            # print(f"📊 从文档 {i} 元数据中获取分数 ({score_key}): {score}")
                            break
                        except (ValueError, TypeError) as e:
                            continue
            
            if score is not None:
                similarity_scores.append(score)
    
    # 方法3: 检查结果字典中是否有直接存储的分数
    if not similarity_scores and isinstance(result, dict):
        for key in result.keys():
            if any(term in key.lower() for term in ['score', 'similarity', 'distance']):
                value = result[key]
                if isinstance(value, (int, float)):
                    try:
                        similarity_scores.append(float(value))
                        # print(f"📊 从结果键 {key} 获取分数: {value}")
                    except (ValueError, TypeError) as e:
                        pass
                elif isinstance(value, list) and value:
                    for j, item in enumerate(value):
                        try:
                            score = float(item)
                            similarity_scores.append(score)
                        except (ValueError, TypeError):
                            pass
    
    if similarity_scores:
        return {
            "min_score": min(similarity_scores),
            "max_score": max(similarity_scores),
            "avg_score": sum(similarity_scores) / len(similarity_scores),
            "doc_count": len(similarity_scores),
            "all_scores": similarity_scores
        }
    
    # print("⚠️ 无法获取任何有效的相似度信息")
    return None

def load_system_input(file_path: str) -> str:
    """加载系统输入文件"""
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            return json.dumps(json.load(f), ensure_ascii=False)
    except Exception as e:
        # print(f"❌ 错误: 无法读取 JSON 文件: {e}")
        return ""

# ============== 简单测试函数 ==============
def simple_test():
    """简单的测试函数"""
    query = "Please analyze this transaction to determine if it's an attack or benign contract behavior."
    global system_input_path
    #system_input_path = r"G:\\safe\\pythonProject\\D1\\D5_extract_log1\\bsc-0xe968e648b2353cea06fc3da39714fb964b9354a1ee05750a3c5cc118da23444b.json"
    #system_input_path = r"G:\\safe\\pythonProject\\D1\\D5_extract_log1\\bsc-0xf2a0c957fef493af44f55b201fbc6d82db2e4a045c5c856bfe3d8cb80fa30c12.json"
    #system_input_path = r"G:\\safe\\pythonProject\\D1\\D5_extract_log1\\bsc-0x31fdf621f60684579de00f30b33fa051c19f1fd45d891c817e2a3888a9b75726.json" 0
    # system_input_path = r"G:\\safe\\pythonProject\\D1\\D5_extract_log1\\bsc-0x50b0c05dd326022cae774623e5db17d8edbc41b4f064a3bcae105f69492ceadc.json"
    #system_input_path = r"G:\\safe\\pythonProject\\D1\\D5_extract_log1\\bsc-0xf598e092ab82ce08798f9dab7ea6ade64f152aa91db897f3449b23ab591baa1d.json"
    # system_input_path = r"G:\\safe\\pythonProject\\D1\\D5_extract_log1\\eth-0x44aad3b853866468161735496a5d9cc961ce5aa872924c5d78673076b1cd95aa.json"
    # system_input_path = r"G:\\safe\\pythonProject\\balanced_test_dataset\\1194e1d6085885ce054a7ff8cd3cd0c3fa308ec87e4ccde8dd0549842fef4f1b_benign.json"# 1，1，0 Attack 0
    #system_input_path = "G:\\safe\\pythonProject\\balanced_test_dataset\\12fe79f1de8aed0ba947cec4dce5d33368d649903cb45a5d3e915cc459e751fc_benign.json" # 1，1，1 Attack
    # system_input_path = "G:\\safe\\pythonProject\\balanced_test_dataset\\13c40ae677419fe0031d1e719169e59b8865eb36d37637884eb6086244c767b7_benign.json" # 1, 1, 1 Attack 0.1370
    # system_input_path = "G:\\safe\\pythonProject\\balanced_test_dataset\\171072422efb5cd461546bfe986017d9b5aa427ff1c07ebe8acc064b13a7b7be_benign.json" # 1，1，1 Attack 0.1465
    # system_input_path = "G:\\safe\\pythonProject\\balanced_test_dataset\\1711e8674da7ef1383cf18421e3280a06578d2aad815b4db85b04e46248bc1e4_benign.json" # 1，1，1 Attack 0.14
    # system_input_path = "G:\\safe\\pythonProject\\balanced_test_dataset\\1c024753da9cf244902600ea2283b9e99f0dd43fdaeee21747e9d22aa24c66a7_benign.json" # 1，1，1 Attack 0.149
    # system_input_path = "G:\\safe\\pythonProject\\balanced_test_dataset\\24093121db8496d0396445efe9bf69168be7896bf11de9c09e19460c94673648_benign.json" # 1，1，0 Attack 0.1530，0.1364
    # system_input_path = "G:\\safe\\pythonProject\\balanced_test_dataset\\24c64648ab24db3304f8f0927b7e2254f5eb6091edd767c5e8c7d27a2a42bc38_benign.json" #1，1，1 Attack 0.1419
    system_input_path = "G:\\safe\\pythonProject\\balanced_test_dataset\\24dd395529d4b9e89fa5b8a7a7b0d5f8501657d31f4f4c0689141081beabb3d_benign.json" #1，1，1 Attack 0.1324
    # system_input_path = "G:\\safe\\pythonProject\\balanced_test_dataset\\2881e839d4d562fad5356183e4f6a9d427ba6f475614ce8ef64dbfe557a4a2cc_benign.json" #1，1，1 Attack 0.1388
    # system_input_path = "G:\\safe\\pythonProject\\balanced_test_dataset\\2b4a5a91ccb7775da1545c5c0c2459c123d2c8062c8f1a9b8ddd3a0eaca65de3_benign.json" #1，1，1 Attack 0.1422
    # system_input_path = "G:\\safe\\pythonProject\\balanced_test_dataset\\2db9a6a51604e2be8b2c3469773afb201f0b48a318fb7e5f5e49175e818df5ba_benign.json" # 1，1，1 Attack 0.1375
    # system_input_path = "G:\\safe\\pythonProject\\balanced_test_dataset\\2e7dc8b2fb7e25fd00ed9565dcc0ad4546363171d5e00f196d48103983ae477c_benign.json" # 1，1，1 Attack 0.1464

    print("=== 开始简单测试 ===")
    result = analyze_contract(query, system_input_path=system_input_path)
    
    print("\n=== 查询结果 ===")
    if isinstance(result, dict) and "answer" in result:
        print(f"✅ 答案: {result['answer']}")
        print(f"🔍 使用RAG: {result.get('used_rag', '未知')}")
        if "similarity_info" in result:
            print(f"📊 相似度信息: {result['similarity_info']}")
        if "context" in result:
            print("\n📚 参考文档:")
            for i, doc in enumerate(result["context"]):
                source = "未知来源"
                if hasattr(doc, 'metadata') and doc.metadata:
                    source = doc.metadata.get('source_file', '未知来源')
                elif isinstance(doc, dict) and 'metadata' in doc:
                    source = doc['metadata'].get('source_file', '未知来源')
                print(f"  {i+1}. {source}")
    else:
        print(0)
        print(f"📋 原始结果: {result}")
    
    return result

if __name__ == "__main__":
    simple_test()
