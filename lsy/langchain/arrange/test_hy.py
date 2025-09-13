import os
import json
import time
from datetime import datetime
from typing import List, Dict, Any, Optional
import argparse
import glob
import requests
import re
from openai import OpenAI
from langchain_core.runnables import Runnable
from langchain_core.messages import AIMessage

# ============== 导入必要的函数 ==============
from contract_analyzer import load_system_input
from test_evaluator import ContractAnalyzerEvaluator

# ============== 混元专用配置 ==============
HUNYUAN_CONFIG = {
       "HUNYUAN_BASE_URL": "https://api.hunyuan.cloud.tencent.com/v1",
    "HUNYUAN_MODEL": "hunyuan-turbos-latest",
    
    # 测试相关配置
    "OUTPUT_FOLDER": r"G:\tx-anomaly-predict\lsy\invocation_flow\output",
    "RESULT_FOLDER": r".\test_result\hunyuan_test_results",
    "BATCH_SIZE": 20,
    "REQUEST_DELAY": 2,
}

# ============== 混元模型客户端 ==============
class HunyuanClient:
    """混元模型客户端"""
    
    def __init__(self):
        self.api_key = HUNYUAN_CONFIG["HUNYUAN_API_KEY"]
        self.base_url = HUNYUAN_CONFIG["HUNYUAN_BASE_URL"]
        self.model_name = HUNYUAN_CONFIG["HUNYUAN_MODEL"]
        
        # 初始化OpenAI客户端
        self.client = OpenAI(
            api_key=self.api_key,
            base_url=self.base_url
        )
    
    def generate_response(self, messages: List[Dict[str, str]]) -> str:
        """调用混元API生成响应"""
        try:
            completion = self.client.chat.completions.create(
                model=self.model_name,
                messages=messages,
                extra_body={
                    "enable_enhancement": True,  # 启用增强功能
                },
                timeout=60
            )
            
            return completion.choices[0].message.content
            
        except Exception as e:
            return f"API调用错误: {str(e)}"

# ============== 替换analyze_contract函数 ==============
def analyze_contract_hunyuan(query: str, system_input_path: str = None, system_input_text: str = None) -> Dict[str, Any]:
    """
    使用混元分析智能合约（替换原有的analyze_contract函数）
    """
    hunyuan_client = HunyuanClient()
    
    # 准备系统输入
    if system_input_path:
        try:
            with open(system_input_path, 'r', encoding='utf-8') as f:
                system_input = json.dumps(json.load(f), ensure_ascii=False)
        except Exception as e:
            print(f"错误: 无法读取 JSON 文件: {e}")
            system_input = ""
    elif system_input_text:
        system_input = system_input_text
    else:
        system_input = ""
    
    # 构建消息
    messages = [
        {
            "role": "system", 
            "content": """You are an expert in smart contract attack detection. Evaluate whether the current transaction is malicious.

Strict Answer Rules:
- You must begin your answer with one of: [Attack] or [Benign].
- Follow this structured format:

[Attack | Benign]

1. Behavior Summary:
- Describe the transaction's overall behavior, including contract interactions and fund movements.

2. Call Sequence Analysis:
- Analyze the function call sequence and highlight any abnormal or suspicious patterns.

3. Malicious Indicators:
- Identify specific behaviors that indicate an attack.

- Limit your answer to 200 words."""
        },
        {
            "role": "user",
            "content": f"""Please analyze this transaction:

System Input (Transaction Data):
{system_input[:3000]}

Question:
{query}"""
        }
    ]
    
    # 调用混元 API
    response = hunyuan_client.generate_response(messages)
    
    # 返回与原有analyze_contract相同的格式
    return {
        "answer": AIMessage(content=response),
        "context": []  # 混元版本没有上下文检索
    }

# ============== 主函数 - 使用batches.py的批量处理 ==============
def main():
    parser = argparse.ArgumentParser(description='混元模型批量测试工具')
    parser.add_argument('--max_files', type=int, default=0,
                       help='最大测试文件数量（0表示所有文件）')
    parser.add_argument('--batch_size', type=int, default=20,
                       help='每批处理的文件数量')
    parser.add_argument('--delay', type=int, default=2,
                       help='请求间隔时间（秒）')
    parser.add_argument('--output_folder', type=str, default=None,
                       help='测试文件文件夹路径')
    parser.add_argument('--check_only', action='store_true',
                       help='只检查配置，不运行测试')
    parser.add_argument('--combine_only', action='store_true',
                       help='仅合并现有结果，不进行新的测试')
    parser.add_argument('--stats_only', action='store_true',
                       help='仅显示统计信息，不进行测试或合并')
    
    args = parser.parse_args()
    
    # 更新配置
    if args.output_folder:
        HUNYUAN_CONFIG["OUTPUT_FOLDER"] = args.output_folder
    if args.batch_size:
        HUNYUAN_CONFIG["BATCH_SIZE"] = args.batch_size
    if args.delay:
        HUNYUAN_CONFIG["REQUEST_DELAY"] = args.delay
    
    # 检查API密钥配置
    if HUNYUAN_CONFIG["HUNYUAN_API_KEY"] != "您的混元API密钥":
        print("✅ 混元 API密钥已配置")
    else:
        print("⚠️  请先在 HUNYUAN_CONFIG 中配置您的混元 API密钥")
        return
    
    if args.check_only:
        print("配置检查完成，退出")
        return
    
    # 导入并运行batches.py的批量测试函数
    try:
        # 动态导入batches模块
        import importlib.util
        import sys
        
        batches_path = os.path.join(os.path.dirname(__file__), "batches.py")
        if not os.path.exists(batches_path):
            print("❌ 找不到batches.py文件")
            return
        
        spec = importlib.util.spec_from_file_location("batches_module", batches_path)
        batches_module = importlib.util.module_from_spec(spec)
        sys.modules["batches_module"] = batches_module
        spec.loader.exec_module(batches_module)
        
        print("✅ 成功导入batches模块")
        
        # 临时替换analyze_contract函数为混元版本
        original_analyze_contract = None
        if hasattr(batches_module, 'analyze_contract'):
            original_analyze_contract = batches_module.analyze_contract
            batches_module.analyze_contract = analyze_contract_hunyuan
            print("✅ 已替换analyze_contract函数为混元版本")
        
        # 根据参数选择操作
        if args.stats_only:
            # 显示统计信息
            if hasattr(batches_module, 'show_summary_stats'):
                batches_module.show_summary_stats(HUNYUAN_CONFIG["OUTPUT_FOLDER"])
            else:
                print("❌ batches模块中没有show_summary_stats函数")
                
        elif args.combine_only:
            # 仅合并结果
            if hasattr(batches_module, 'combine_batch_results'):
                summary = batches_module.combine_batch_results(HUNYUAN_CONFIG["OUTPUT_FOLDER"])
                if summary:
                    rename_results_for_hunyuan()
            else:
                print("❌ batches模块中没有combine_batch_results函数")
                
        else:
            # 运行批量测试
            print(f"\n{'='*60}")
            print("开始混元模型批量测试（使用batches.py）")
            print(f"{'='*60}")
            
            results = batches_module.run_batch_testing(
                output_folder=HUNYUAN_CONFIG["OUTPUT_FOLDER"],
                batch_size=HUNYUAN_CONFIG["BATCH_SIZE"],
                delay=HUNYUAN_CONFIG["REQUEST_DELAY"],
                resume_from=0,
                max_files=args.max_files
            )
            
            # 合并结果
            print(f"\n{'='*60}")
            print("正在合并测试结果...")
            print(f"{'='*60}")
            
            if hasattr(batches_module, 'combine_batch_results'):
                summary = batches_module.combine_batch_results(HUNYUAN_CONFIG["OUTPUT_FOLDER"])
                if summary:
                    rename_results_for_hunyuan()
        
        # 恢复原始函数（如果有）
        if original_analyze_contract:
            batches_module.analyze_contract = original_analyze_contract
            
    except Exception as e:
        print(f"运行批量测试时出错: {str(e)}")
        import traceback
        traceback.print_exc()

def rename_results_for_hunyuan():
    """重命名结果文件以标识混元测试"""
    result_dir = "batch_results"  # 默认结果目录
    
    try:
        # 重命名汇总文件
        combined_files = glob.glob(os.path.join(result_dir, "combined_results_*.json"))
        if combined_files:
            latest_file = max(combined_files, key=os.path.getctime)
            new_name = latest_file.replace("combined_results_", "hunyuan_combined_")
            os.rename(latest_file, new_name)
            print(f"重命名汇总文件: {new_name}")
        
        # 重命名详细结果文件
        detailed_files = glob.glob(os.path.join(result_dir, "detailed_results_*.json"))
        if detailed_files:
            latest_detailed = max(detailed_files, key=os.path.getctime)
            new_detailed_name = latest_detailed.replace("detailed_results_", "hunyuan_detailed_")
            os.rename(latest_detailed, new_detailed_name)
            print(f"重命名详细结果文件: {new_detailed_name}")
            
        # 重命名批次文件夹
        batch_dir = os.path.join(result_dir, "batches")
        if os.path.exists(batch_dir):
            new_batch_dir = os.path.join(result_dir, "hunyuan_batches")
            os.rename(batch_dir, new_batch_dir)
            print(f"重命名批次文件夹: {new_batch_dir}")
            
    except Exception as e:
        print(f"重命名结果文件时出错: {e}")

# ============== 环境检查函数 ==============
def check_environment():
    """检查环境配置"""
    try:
        # 检查openai包是否安装
        import openai
        print("✅ openai包已安装")
        
        # 检查API密钥
        if HUNYUAN_CONFIG["HUNYUAN_API_KEY"] != "您的混元API密钥":
            print("✅ 混元API密钥已配置")
            
            # 测试连接
            client = HunyuanClient()
            test_response = client.generate_response([
                {"role": "user", "content": "Hello"}
            ])
            
            if "API调用错误" not in test_response:
                print("✅ 混元API连接成功")
                return True
            else:
                print("❌ 混元API连接失败")
                return False
        else:
            print("❌ 请配置混元API密钥")
            return False
            
    except ImportError:
        print("❌ 请安装openai包: pip install openai")
        return False
    except Exception as e:
        print(f"❌ 环境检查失败: {str(e)}")
        return False

# ============== 独立运行函数（备选方案） ==============
def run_standalone_test():
    """独立运行测试（如果batches.py不可用）"""
    print("使用独立测试实现...")
    
    evaluator = ContractAnalyzerEvaluator(HUNYUAN_CONFIG["OUTPUT_FOLDER"])
    test_cases = evaluator.create_test_cases(HUNYUAN_CONFIG["MAX_FILES"] or 0)
    
    print(f"开始混元模型测试")
    print(f"总测试文件: {len(test_cases)}")
    print(f"{'='*60}")
    
    results = []
    
    for i, test_case in enumerate(test_cases):
        try:
            print(f"[{i+1}/{len(test_cases)}] 处理: {test_case['file_name']}")
            
            start_time = time.time()
            result = analyze_contract_hunyuan(
                query=test_case["query"],
                system_input_path=test_case["system_input_file"]
            )
            processing_time = time.time() - start_time
            
            evaluation = evaluator.evaluate_single_response(test_case, result)
            evaluation["processing_time_seconds"] = round(processing_time, 2)
            results.append(evaluation)
            
            print(f"  预测: {evaluation['predicted_label']}, 时间: {processing_time:.2f}s, 正确: {evaluation['is_correct']}")
            
            if i < len(test_cases) - 1:
                time.sleep(HUNYUAN_CONFIG["REQUEST_DELAY"])
                
        except Exception as e:
            print(f"处理文件时出错: {str(e)}")
            time.sleep(HUNYUAN_CONFIG["REQUEST_DELAY"] * 2)
    
    # 保存结果
    save_standalone_results(results)

def save_standalone_results(results: List[Dict[str, Any]]):
    """保存独立测试结果"""
    os.makedirs(HUNYUAN_CONFIG["RESULT_FOLDER"], exist_ok=True)
    
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    filename = f"hunyuan_standalone_results_{timestamp}.json"
    filepath = os.path.join(HUNYUAN_CONFIG["RESULT_FOLDER"], filename)
    
    # 计算统计信息
    total_tests = len(results)
    correct_predictions = sum(1 for r in results if r.get("is_correct", False))
    accuracy = correct_predictions / total_tests if total_tests > 0 else 0
    
    summary = {
        "model": "hunyuan-turbos-latest",
        "test_date": timestamp,
        "total_tests": total_tests,
        "correct_predictions": correct_predictions,
        "accuracy": accuracy,
        "results": results
    }
    
    with open(filepath, 'w', encoding='utf-8') as f:
        json.dump(summary, f, ensure_ascii=False, indent=2)
    
    print(f"\n测试完成! 结果保存到: {filepath}")
    print(f"准确率: {accuracy:.2%}")

if __name__ == "__main__":
    # 首先检查环境
    if not check_environment():
        print("环境检查失败，请先配置好环境")
    else:
        main()