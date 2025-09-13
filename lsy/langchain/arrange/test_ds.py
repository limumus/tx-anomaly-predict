import os
import json
import time
from datetime import datetime
from typing import List, Dict, Any, Optional
import argparse
import glob
import requests
import re

# ============== 导入必要的函数 ==============
from contract_analyzer import load_system_input, load_or_create_vector_store, create_conversational_chain
from test_evaluator import ContractAnalyzerEvaluator

# ============== DeepSeek专用配置 ==============
DEEPSEEK_CONFIG = {
    "DEEPSEEK_API_KEY": "",  # 替换为您的实际API密钥
    "DEEPSEEK_API_URL": "https://api.deepseek.com/v1/chat/completions",
    "DEEPSEEK_MODEL": "deepseek-chat",
    
    # 测试相关配置
    "OUTPUT_FOLDER": r"G:\tx-anomaly-predict\lsy\invocation_flow\output",
    "RESULT_FOLDER": "deepseek_test_results",
    "BATCH_SIZE": 20,
    "REQUEST_DELAY": 2,
    
    # 从contract_analyzer导入的配置（需要保持一致）
    "PERSIST_DIR": "vector_store_realtime_0",
    "CSV_PATH": "extracted_data2.csv"
}

# ============== DeepSeek模型封装 ==============
class DeepSeekAI:
    """DeepSeek模型封装"""
    
    def __init__(self):
        self.api_key = DEEPSEEK_CONFIG["DEEPSEEK_API_KEY"]
        self.api_url = DEEPSEEK_CONFIG["DEEPSEEK_API_URL"]
        self.model_name = DEEPSEEK_CONFIG["DEEPSEEK_MODEL"]
    
    def generate_response(self, messages: List[Dict[str, str]]) -> str:
        """调用DeepSeek API生成响应"""
        try:
            headers = {
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json"
            }
            
            payload = {
                "model": self.model_name,
                "messages": messages,
                "temperature": 0.1,
                "max_tokens": 1000,
                "stream": False
            }
            
            response = requests.post(self.api_url, headers=headers, json=payload, timeout=60)
            response.raise_for_status()
            response_data = response.json()
            
            return response_data["choices"][0]["message"]["content"]
            
        except requests.exceptions.Timeout:
            return "API请求超时"
        except requests.exceptions.RequestException as e:
            return f"API请求错误: {str(e)}"
        except Exception as e:
            return f"处理错误: {str(e)}"

# ============== DeepSeek LangChain包装器 ==============
class DeepSeekLLMWrapper:
    """DeepSeek模型的LangChain包装器"""
    
    def __init__(self, deepseek_ai: DeepSeekAI):
        self.deepseek_ai = deepseek_ai
    
    def invoke(self, input_data: Any, config: Optional[Dict] = None):
        """实现LangChain Runnable接口"""
        from langchain_core.messages import AIMessage, HumanMessage, SystemMessage
        
        try:
            # 处理不同类型的输入
            if isinstance(input_data, dict):
                query = input_data.get("input", "")
                reference = input_data.get("reference_text", "")
            elif hasattr(input_data, "messages"):
                messages = input_data.messages
                query = next((msg.content for msg in messages if isinstance(msg, HumanMessage)), "")
                reference = next((msg.content for msg in messages if isinstance(msg, SystemMessage)), "")
            else:
                return AIMessage(content="无效的输入格式")

            # 构建DeepSeek API需要的消息格式
            messages = []
            if reference:
                messages.append({"role": "user", "content": f"参考内容: {reference[:1000]}"})
            messages.append({"role": "user", "content": query})

            # 调用DeepSeek API
            response = self.deepseek_ai.generate_response(messages)
            return AIMessage(content=response)

        except Exception as e:
            return AIMessage(content=f"处理错误: {str(e)}")

# ============== 修改analyze_contract函数以使用DeepSeek ==============
def analyze_contract_with_deepseek(query: str, system_input_path: str = None, system_input_text: str = None) -> Dict[str, Any]:
    """
    使用DeepSeek分析智能合约的主要函数
    Args:
        query: 查询文本
        system_input_path: 系统输入文件路径
        system_input_text: 系统输入文本（二选一）
    Returns:
        分析结果字典
    """
    # 初始化DeepSeek组件
    deepseek_ai = DeepSeekAI()
    deepseek_llm = DeepSeekLLMWrapper(deepseek_ai)
    
    # 使用contract_analyzer中的函数初始化向量数据库
    from contract_analyzer import JinaEmbedding
    embedding = JinaEmbedding()
    vector_store = load_or_create_vector_store(DEEPSEEK_CONFIG["PERSIST_DIR"], embedding)
    
    # 创建对话链
    conversational_chain = create_conversational_chain(
        vector_store,
        deepseek_llm,
        csv_file_path=DEEPSEEK_CONFIG["CSV_PATH"]
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

# ============== 主函数 - 使用batches.py的批量处理 ==============
def main():
    # 首先检查并配置环境
    parser = argparse.ArgumentParser(description='DeepSeek模型测试工具')
    parser.add_argument('--max_files', type=int, default=0,
                       help='最大测试文件数量（0表示所有文件）')
    parser.add_argument('--batch_size', type=int, default=None,
                       help='每批处理的文件数量')
    parser.add_argument('--delay', type=int, default=None,
                       help='请求间隔时间（秒）')
    parser.add_argument('--output_folder', type=str, default=None,
                       help='测试文件文件夹路径')
    parser.add_argument('--check_only', action='store_true',
                       help='只检查配置，不运行测试')
    
    args = parser.parse_args()
    
    # 更新配置（如果提供了命令行参数）
    if args.output_folder:
        DEEPSEEK_CONFIG["OUTPUT_FOLDER"] = args.output_folder
    if args.batch_size:
        DEEPSEEK_CONFIG["BATCH_SIZE"] = args.batch_size
    if args.delay:
        DEEPSEEK_CONFIG["REQUEST_DELAY"] = args.delay
    
    # 检查API密钥配置
    if DEEPSEEK_CONFIG["DEEPSEEK_API_KEY"].startswith("sk_"):
        print("✅ DeepSeek API密钥已配置")
    else:
        print("⚠️  请先在 DEEPSEEK_CONFIG 中配置您的DeepSeek API密钥")
        return
    
    if args.check_only:
        print("配置检查完成，退出")
        return
    
    # 导入并运行batches.py的批量测试函数
    try:
        # 动态导入batches模块
        import importlib.util
        import sys
        
        # 假设batches.py在同一目录下
        batches_path = os.path.join(os.path.dirname(__file__), "batches.py")
        if not os.path.exists(batches_path):
            print("❌ 找不到batches.py文件，请确保它与本文件在同一目录下")
            return
        
        # 动态导入batches模块
        spec = importlib.util.spec_from_file_location("batches_module", batches_path)
        batches_module = importlib.util.module_from_spec(spec)
        sys.modules["batches_module"] = batches_module
        spec.loader.exec_module(batches_module)
        
        print("✅ 成功导入batches模块")
        
        # 临时替换analyze_contract函数为DeepSeek版本
        original_analyze_contract = None
        if hasattr(batches_module, 'analyze_contract'):
            original_analyze_contract = batches_module.analyze_contract
            batches_module.analyze_contract = analyze_contract_with_deepseek
            print("✅ 已替换analyze_contract函数为DeepSeek版本")
        
        # 运行批量测试
        print(f"\n{'='*60}")
        print("开始DeepSeek模型批量测试（使用batches.py）")
        print(f"{'='*60}")
        
        # 调用batches.py的run_batch_testing函数
        results = batches_module.run_batch_testing(
            output_folder=DEEPSEEK_CONFIG["OUTPUT_FOLDER"],
            batch_size=DEEPSEEK_CONFIG["BATCH_SIZE"],
            delay=DEEPSEEK_CONFIG["REQUEST_DELAY"],
            resume_from=0,
            max_files=args.max_files
        )
        
        # 恢复原始函数（如果有）
        if original_analyze_contract:
            batches_module.analyze_contract = original_analyze_contract
        
        # 合并结果
        print(f"\n{'='*60}")
        print("正在合并测试结果...")
        print(f"{'='*60}")
        
        summary = batches_module.combine_batch_results(DEEPSEEK_CONFIG["OUTPUT_FOLDER"])
        
        # 重命名结果文件以标识DeepSeek测试
        if summary:
            self.rename_results_for_deepseek()
        
        return results
        
    except Exception as e:
        print(f"运行批量测试时出错: {str(e)}")
        import traceback
        traceback.print_exc()
        return None

def rename_results_for_deepseek():
    """重命名结果文件以标识DeepSeek测试"""
    result_dir = "batch_results"  # 默认结果目录
    
    try:
        # 重命名汇总文件
        combined_files = glob.glob(os.path.join(result_dir, "combined_results_*.json"))
        if combined_files:
            latest_file = max(combined_files, key=os.path.getctime)
            new_name = latest_file.replace("combined_results_", "deepseek_combined_")
            os.rename(latest_file, new_name)
            print(f"重命名汇总文件: {new_name}")
        
        # 重命名详细结果文件
        detailed_files = glob.glob(os.path.join(result_dir, "detailed_results_*.json"))
        if detailed_files:
            latest_detailed = max(detailed_files, key=os.path.getctime)
            new_detailed_name = latest_detailed.replace("detailed_results_", "deepseek_detailed_")
            os.rename(latest_detailed, new_detailed_name)
            print(f"重命名详细结果文件: {new_detailed_name}")
            
    except Exception as e:
        print(f"重命名结果文件时出错: {e}")

# ============== 替代方案：如果无法导入batches.py，使用本地实现 ==============
def run_local_batch_testing():
    """本地批量测试实现（备选方案）"""
    print("使用本地批量测试实现...")
    
    evaluator = ContractAnalyzerEvaluator(DEEPSEEK_CONFIG["OUTPUT_FOLDER"])
    
    # 发现所有文件
    test_files = evaluator.discover_test_files()
    if DEEPSEEK_CONFIG["MAX_FILES"] > 0:
        test_files = test_files[:DEEPSEEK_CONFIG["MAX_FILES"]]
    
    print(f"发现 {len(test_files)} 个测试文件")
    
    all_results = []
    for i, file_path in enumerate(test_files):
        try:
            print(f"[{i+1}/{len(test_files)}] 处理: {os.path.basename(file_path)}")
            
            start_time = time.time()
            result = analyze_contract_with_deepseek(
                query="Please analyze this transaction to determine if it's an attack or benign contract behavior.",
                system_input_path=file_path
            )
            processing_time = time.time() - start_time
            
            # 创建测试用例
            test_case = {
                "test_id": f"test_{i+1:04d}",
                "query": "Please analyze this transaction to determine if it's an attack or benign contract behavior.",
                "system_input_file": file_path,
                "expected_label": "Attack",
                "test_type": "attack",
                "folder_name": os.path.basename(os.path.dirname(file_path)),
                "file_name": os.path.basename(file_path)
            }
            
            # 评估结果
            evaluation = evaluator.evaluate_single_response(test_case, result)
            evaluation["processing_time_seconds"] = round(processing_time, 2)
            all_results.append(evaluation)
            
            print(f"  预测: {evaluation['predicted_label']}, 时间: {processing_time:.2f}s")
            
            # 延迟
            if i < len(test_files) - 1:
                time.sleep(DEEPSEEK_CONFIG["REQUEST_DELAY"])
                
        except Exception as e:
            print(f"处理文件时出错: {str(e)}")
            # 添加错误结果...
            time.sleep(DEEPSEEK_CONFIG["REQUEST_DELAY"] * 2)
    
    return all_results

if __name__ == "__main__":
    main()