import os
import json
import time
from datetime import datetime
from typing import List, Dict, Any, Optional
import argparse
import glob
import requests
from langchain_core.messages import AIMessage
import re

# ============== 导入评估类 ==============
# 假设 test_evaluate.py 在同一目录下，或者您需要调整导入路径
try:
    from test_evaluate import ContractAnalyzerEvaluator
except ImportError:
    # 如果无法导入，我们将内联定义关键函数
    print("警告: 无法导入 test_evaluate.py，使用内联评估函数")

# ============== 百度文心ERNIE配置 ==============
ERNIE_CONFIG = {

    # 测试配置
    "OUTPUT_FOLDER": r"G:\tx-anomaly-predict\lsy\invocation_flow\output",
    "RESULT_FOLDER": "./test_result/rag",
    "BATCH_SIZE": 20,
    "REQUEST_DELAY": 2,
}

# ============== 百度文心ERNIE模型封装 ==============
class BaiduErnieAI:
    def __init__(self):
        self.access_key = ERNIE_CONFIG["BAIDU_ACCESS_KEY"]
        self.secret_key = ERNIE_CONFIG["BAIDU_SECRET_KEY"]
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

# ============== 直接模型调用类 ==============
class DirectErnieClient:
    
    def __init__(self):
        self.ernie_ai = BaiduErnieAI()
    
    def analyze_transaction(self, transaction_data: str, query: str) -> str:
        """直接分析交易数据"""
        try:
            messages = [
                {
                    "role": "user",
                    "content": f"""You are an expert in smart contract attack detection. Evaluate whether the current transaction is malicious, using the following inputs:

Question: {query}

Current transaction data:
{transaction_data[:3000]}

Key Analysis Focus:
- Your task is to critically evaluate the transaction data
- Focus on:
  - Logical function call flow
  - Inter-contract calls
  - Abnormal fund transfers
- Ignore function names like `testExploit`; focus solely on execution logic.

Strict Answer Rules:
- You must begin your answer with one of: `Attack` or `Benign`.
- Follow this structured format:

[Attack | Benign]

1. Behavior Summary:
- Describe the transaction's overall behavior, including contract interactions and fund movements.

2. Call Sequence Analysis:
- Analyze the function call sequence and highlight any abnormal or suspicious patterns.

3. Malicious Indicators:
- Identify specific behaviors that indicate an attack.

- Limit your answer to 200 words.
"""
                }
            ]
            
            response = self.ernie_ai.generate_response(messages)
            return response
            
        except Exception as e:
            return f"ERNIE API Error: {str(e)}"

# ============== 文件处理函数 ==============
def discover_test_files(output_folder: str) -> List[str]:
    """发现测试文件"""
    pattern = os.path.join(output_folder, "**", "*_exp.sol", "*.txt.json")
    return glob.glob(pattern, recursive=True)

def load_transaction_data(file_path: str) -> str:
    """加载交易数据"""
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            data = json.load(f)
            return json.dumps(data, ensure_ascii=False)
    except Exception as e:
        print(f"Error loading file {file_path}: {e}")
        return ""

# ============== 评估函数 - 使用 test_evaluate.py 中的逻辑 ==============
def extract_label(response: str) -> str:
    """从响应中提取标签 - 使用 test_evaluate.py 中的逻辑"""
    # 处理AIMessage对象（如果需要）
    if isinstance(response, AIMessage):
        response_content = response.content
    elif isinstance(response, dict) and "answer" in response:
        # 从字典中提取answer字段，它可能是AIMessage对象
        answer = response["answer"]
        if isinstance(answer, AIMessage):
            response_content = answer.content
        else:
            response_content = str(answer)
    elif isinstance(response, str):
        response_content = response
    else:
        print(f"警告: 未知的响应类型: {type(response)}")
        response_content = str(response)
    
    # 从内容中提取标签 - 改进的正则表达式
    match = re.search(r'^\[?(Attack|Benign)\]?', response_content, re.IGNORECASE)
    if match:
        return match.group(1).capitalize()
    
    # 如果没有明确的标签标记，尝试在内容中查找
    if re.search(r'\bAttack\b', response_content, re.IGNORECASE):
        return "Attack"
    elif re.search(r'\bBenign\b', response_content, re.IGNORECASE):
        return "Benign"
    
    return "Unknown"

def get_expected_label(file_path: str) -> str:
    """根据文件路径确定预期标签 - 使用 test_evaluate.py 中的逻辑"""
    # 如果文件在 *_exp.sol 文件夹中，则预期为Attack
    if "_exp.sol" in file_path:
        return "Attack"
    return "Attack"  # 默认假设为Attack

def evaluate_response(response: str, file_path: str) -> Dict[str, Any]:
    """评估模型响应 - 使用 test_evaluate.py 中的逻辑"""
    predicted_label = extract_label(response)
    expected_label = get_expected_label(file_path)
    is_correct = predicted_label.lower() == expected_label.lower()
    
    return {
        "predicted_label": predicted_label,
        "expected_label": expected_label,
        "is_correct": is_correct,
        "response": response[:500] + "..." if len(response) > 500 else response,
        "has_required_format": bool(re.search(r'^\[?(Attack|Benign)\]?', response, re.IGNORECASE))
    }

# ============== 批处理核心函数 ==============
def process_batch(files: List[str], batch_number: int, client: DirectErnieClient) -> List[Dict[str, Any]]:
    """处理一个批次的文件"""
    batch_results = []
    
    for i, file_path in enumerate(files):
        try:
            print(f"  [{i+1}/{len(files)}] Processing: {os.path.basename(file_path)}")
            
            # 加载交易数据
            transaction_data = load_transaction_data(file_path)
            if not transaction_data:
                continue
            
            # 准备查询
            query = "Please analyze this transaction to determine if it's an attack or benign contract behavior."
    
            # 调用模型
            start_time = time.time()
            response = client.analyze_transaction(transaction_data, query)
            processing_time = time.time() - start_time
            
            # 评估结果 - 使用改进的评估函数
            evaluation = evaluate_response(response, file_path)
            evaluation.update({
                "file_path": file_path,
                "file_name": os.path.basename(file_path),
                "folder_name": os.path.basename(os.path.dirname(file_path)),
                "processing_time": round(processing_time, 2),
                "batch_number": batch_number,
                "timestamp": datetime.now().isoformat(),
                "test_type": "attack"  # 所有文件都是攻击样本
            })
            
            batch_results.append(evaluation)
            
            print(f"    → Prediction: {evaluation['predicted_label']}, Expected: {evaluation['expected_label']}, Time: {processing_time:.2f}s, Correct: {evaluation['is_correct']}")
            
            # 请求间隔
            if i < len(files) - 1:
                time.sleep(ERNIE_CONFIG["REQUEST_DELAY"])
                
        except Exception as e:
            print(f"    → Error: {str(e)}")
            error_result = {
                "file_path": file_path,
                "file_name": os.path.basename(file_path),
                "error": str(e),
                "batch_number": batch_number,
                "timestamp": datetime.now().isoformat()
            }
            batch_results.append(error_result)
            time.sleep(ERNIE_CONFIG["REQUEST_DELAY"] * 2)
    
    return batch_results

def run_direct_analysis(max_files: int = 0) -> Dict[str, Any]:
    """运行直接模型分析"""
    # 发现文件
    all_files = discover_test_files(ERNIE_CONFIG["OUTPUT_FOLDER"])
    if max_files > 0:
        all_files = all_files[:max_files]
    
    print(f"Found {len(all_files)} files for analysis")
    print(f"Batch size: {ERNIE_CONFIG['BATCH_SIZE']}")
    print("=" * 60)
    
    client = DirectErnieClient()
    all_results = []
    total_batches = (len(all_files) + ERNIE_CONFIG["BATCH_SIZE"] - 1) // ERNIE_CONFIG["BATCH_SIZE"]
    
    for batch_idx in range(total_batches):
        batch_start = batch_idx * ERNIE_CONFIG["BATCH_SIZE"]
        batch_end = min(batch_start + ERNIE_CONFIG["BATCH_SIZE"], len(all_files))
        batch_files = all_files[batch_start:batch_end]
        
        print(f"\n📦 Batch {batch_idx + 1}/{total_batches}: Files {batch_start}-{batch_end-1}")
        print("-" * 50)
        
        # 处理当前批次
        batch_results = process_batch(batch_files, batch_idx + 1, client)
        all_results.extend(batch_results)
        
        # 保存批次结果
        save_batch_results(batch_results, batch_idx + 1)
        
        # 批次间延迟
        if batch_idx < total_batches - 1:
            delay = 30
            print(f"\n⏰ Waiting {delay}s before next batch...")
            time.sleep(delay)
    
    # 生成最终报告
    return generate_final_report(all_results)

# ============== 结果保存函数 ==============
def save_batch_results(results: List[Dict[str, Any]], batch_number: int):
    """保存批次结果"""
    os.makedirs(ERNIE_CONFIG["RESULT_FOLDER"], exist_ok=True)
    
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    filename = f"batch_{batch_number:03d}_{timestamp}.json"
    filepath = os.path.join(ERNIE_CONFIG["RESULT_FOLDER"], filename)
    
    with open(filepath, 'w', encoding='utf-8') as f:
        json.dump({
            "batch_info": {
                "batch_number": batch_number,
                "total_files": len(results),
                "processing_date": timestamp,
                "model": "ernie-speed-128k"
            },
            "results": results
        }, f, ensure_ascii=False, indent=2)
    
    print(f"💾 Batch results saved to: {filename}")

def calculate_detailed_metrics(results: List[Dict[str, Any]]) -> Dict[str, float]:
    """计算详细的评估指标 - 使用 test_evaluate.py 中的逻辑"""
    # 初始化计数器
    tp_attack = 0  # 真正例：预测为Attack且确实为Attack
    fp_attack = 0  # 假正例：预测为Attack但实际为Benign  
    fn_attack = 0  # 假反例：预测为Benign但实际为Attack
    tn_benign = 0  # 真反例：预测为Benign且确实为Benign
    
    metrics = {
        "precision_attack": 0,
        "recall_attack": 0,
        "f1_score_attack": 0,
        "precision_benign": 0,
        "recall_benign": 0,
        "f1_score_benign": 0
    }
    
    for result in results:
        if "error" in result:
            continue
            
        if result["test_type"] == "attack":
            if result["predicted_label"].lower() == "attack":
                tp_attack += 1
            else:
                fn_attack += 1
        else:  # benign
            if result["predicted_label"].lower() == "benign":
                tn_benign += 1
            else:
                fp_attack += 1
    
    # 计算Attack类的指标
    if tp_attack + fp_attack > 0:
        metrics["precision_attack"] = tp_attack / (tp_attack + fp_attack)
    if tp_attack + fn_attack > 0:
        metrics["recall_attack"] = tp_attack / (tp_attack + fn_attack)
    if metrics["precision_attack"] > 0 and metrics["recall_attack"] > 0:
        metrics["f1_score_attack"] = (2 * metrics["precision_attack"] * metrics["recall_attack"] / 
                                    (metrics["precision_attack"] + metrics["recall_attack"]))
    
    return metrics

def generate_final_report(all_results: List[Dict[str, Any]]) -> Dict[str, Any]:
    """生成最终报告"""
    # 过滤出有效结果（非错误结果）
    valid_results = [r for r in all_results if "error" not in r]
    error_results = [r for r in all_results if "error" in r]
    
    # 计算指标
    total_tests = len(valid_results)
    correct_predictions = sum(1 for r in valid_results if r.get("is_correct", False))
    accuracy = correct_predictions / total_tests if total_tests > 0 else 0
    
    # 计算详细指标
    detailed_metrics = calculate_detailed_metrics(valid_results)
    
    # 标签分布
    label_counts = {}
    for result in valid_results:
        label = result.get("predicted_label", "Unknown")
        label_counts[label] = label_counts.get(label, 0) + 1
    
    report = {
        "model": "ernie-speed-128k",
        "test_date": datetime.now().isoformat(),
        "metrics": {
            "total_files_processed": len(all_results),
            "valid_results": total_tests,
            "error_results": len(error_results),
            "correct_predictions": correct_predictions,
            "accuracy": accuracy,
            "average_processing_time": sum(r.get("processing_time", 0) for r in valid_results) / total_tests if total_tests > 0 else 0,
            **detailed_metrics
        },
        "label_distribution": label_counts,
        "summary": f"ERNIE direct analysis completed with {accuracy:.2%} accuracy"
    }
    
    # 保存最终报告
    os.makedirs(ERNIE_CONFIG["RESULT_FOLDER"], exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    report_file = os.path.join(ERNIE_CONFIG["RESULT_FOLDER"], f"final_report_{timestamp}.json")
    
    with open(report_file, 'w', encoding='utf-8') as f:
        json.dump(report, f, ensure_ascii=False, indent=2)
    
    return report

def print_summary(report: Dict[str, Any]):
    """打印统计摘要"""
    print(f"\n{'='*60}")
    print("🎯 ERNIE DIRECT ANALYSIS SUMMARY")
    print(f"{'='*60}")
    print(f"Model: {report['model']}")
    print(f"Date: {report['test_date']}")
    print(f"Total files processed: {report['metrics']['total_files_processed']}")
    print(f"Valid results: {report['metrics']['valid_results']}")
    print(f"Error results: {report['metrics']['error_results']}")
    print(f"Correct predictions: {report['metrics']['correct_predictions']}")
    print(f"Accuracy: {report['metrics']['accuracy']:.2%}")
    print(f"Avg processing time: {report['metrics']['average_processing_time']:.2f}s")
    
    # 打印详细指标
    print(f"\n📊 Detailed Metrics:")
    print(f"Attack Precision: {report['metrics']['precision_attack']:.2%}")
    print(f"Attack Recall: {report['metrics']['recall_attack']:.2%}")
    print(f"Attack F1 Score: {report['metrics']['f1_score_attack']:.2%}")
    
    print(f"\n📊 Label distribution:")
    for label, count in report['label_distribution'].items():
        print(f"  {label}: {count}")

# ============== 环境检查函数 ==============
def check_environment():
    """检查环境配置"""
    if ERNIE_CONFIG["BAIDU_ACCESS_KEY"] != "您的百度Access Key" and ERNIE_CONFIG["BAIDU_SECRET_KEY"] != "您的百度Secret Key":
        print("✅ 百度文心ERNIE API密钥已配置")
        return True
    else:
        print("❌ 请配置百度文心ERNIE API密钥")
        return False

# ============== 主函数 ==============
def main():
    parser = argparse.ArgumentParser(description='百度文心ERNIE直接测试工具')
    parser.add_argument('--max_files', type=int, default=0,
                       help='最大处理文件数量（0表示所有文件）')
    parser.add_argument('--batch_size', type=int, default=None,
                       help='每批处理的文件数量')
    parser.add_argument('--delay', type=int, default=None,
                       help='请求间隔时间（秒）')
    
    args = parser.parse_args()
    
    # 更新配置
    if args.batch_size:
        ERNIE_CONFIG["BATCH_SIZE"] = args.batch_size
    if args.delay:
        ERNIE_CONFIG["REQUEST_DELAY"] = args.delay
    
    # 检查配置
    if not check_environment():
        return
    
    print("🚀 开始百度文心ERNIE直接分析")
    print("📝 无RAG - 直接模型查询")
    print("=" * 60)
    
    # 运行分析
    report = run_direct_analysis(args.max_files)
    
    # 打印摘要
    print_summary(report)
    
    print(f"\n✅ 分析完成! 结果保存在: {ERNIE_CONFIG['RESULT_FOLDER']}")

if __name__ == "__main__":
    main()