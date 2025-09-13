import os
import json
import pandas as pd
from datetime import datetime
from typing import List, Dict, Any
import time
import re
import glob
from langchain_core.messages import AIMessage

from contract_analyzer import analyze_contract, CONFIG, load_system_input

class ContractAnalyzerEvaluator:
    """智能合约分析器评估类"""
    
    def __init__(self, output_folder: str = r"G:\safe\pythonProject\benign_output"):
        self.output_folder = output_folder
        self.test_results = []
        self.metrics = {
            "total_tests": 0,
            "correct_predictions": 0,
            "accuracy": 0,
            "precision_attack": 0,
            "recall_attack": 0,
            "f1_score_attack": 0,
            "precision_benign": 0,
            "recall_benign": 0,
            "f1_score_benign": 0
        }
    
    def extract_label(self, response: Any) -> str:
        # 处理AIMessage对象
        if isinstance(response, AIMessage):
            response_content = response.content
        elif isinstance(response, dict) and "answer" in response:
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
        
        # 从内容中提取标签
        match = re.search(r'^\[(Attack|Benign)\]', response_content, re.IGNORECASE)
        if match:
            return match.group(1).capitalize()
        
        if re.search(r'\bAttack\b', response_content, re.IGNORECASE):
            return "Attack"
        elif re.search(r'\bBenign\b', response_content, re.IGNORECASE):
            return "Benign"
        
        return "Unknown"
    
    def get_response_content(self, response: Any) -> str:
        """从响应中提取内容字符串"""
        if isinstance(response, AIMessage):
            return response.content
        elif isinstance(response, dict) and "answer" in response:
            answer = response["answer"]
            if isinstance(answer, AIMessage):
                return answer.content
            else:
                return str(answer)
        elif isinstance(response, str):
            return response
        else:
            return str(response)
    
    def check_response_structure(self, response: Any) -> bool:
        """检查响应结构完整性"""
        response_content = self.get_response_content(response)
        
        required_sections = [
            "1. Behavior Summary:",
            "2. Call Sequence Analysis:", 
            "3. Malicious Indicators:"
        ]
        return all(section in response_content for section in required_sections)
    
    def discover_test_files(self) -> List[str]:
        """自动发现output文件夹中的所有测试文件"""
        test_files = []
        
        # 遍历所有_exp.sol文件夹中的.json文件
        #pattern = os.path.join(self.output_folder, "**", "*_exp.sol", "*.txt.json")
        pattern = os.path.join(self.output_folder, "*.json")
        discovered_files = glob.glob(pattern, recursive=True)
        
        print(f"发现 {len(discovered_files)} 个测试文件")
        return discovered_files
    
    def get_expected_label(self, file_path: str) -> str:
        """根据文件路径确定预期标签"""
        # 如果文件在 *_exp.sol 文件夹中，则预期为Attack
        if "_exp.sol" in file_path:
            return "Attack"
        return "Attack"  # 默认假设为Attack
    
    def create_test_cases(self, max_files: int = 10) -> List[Dict[str, Any]]:
        """创建测试用例"""
        test_files = self.discover_test_files()
        
        if not test_files:
            print("警告: 未发现任何测试文件")
            return []
        
        # 限制测试文件数量
        if max_files > 0:
            test_files = test_files[:max_files]
        
        test_cases = []
        for i, file_path in enumerate(test_files):
            test_cases.append({
                "test_id": f"test_{i+1:03d}",
                "query": "Please analyze the current input in the context of the preceding and following text to determine whether it pertains to attack contracts?",
                "system_input_file": file_path,
                "expected_label": self.get_expected_label(file_path),
                "test_type": "attack" if self.get_expected_label(file_path) == "Attack" else "benign",
                "folder_name": os.path.basename(os.path.dirname(file_path)),
                "file_name": os.path.basename(file_path)
            })
        
        return test_cases
    
    def evaluate_single_response(self, test_case: Dict[str, Any], response: Any) -> Dict[str, Any]:
        """评估单个响应"""
        predicted_label = self.extract_label(response)
        is_correct = predicted_label.lower() == test_case["expected_label"].lower()
        
        # 获取响应内容用于显示
        response_content = self.get_response_content(response)
        
        evaluation = {
            "test_id": test_case["test_id"],
            "query": test_case["query"],
            "system_input_file": test_case["system_input_file"],
            "folder_name": test_case["folder_name"],
            "file_name": test_case["file_name"],
            "response": response_content[:500] + "..." if len(response_content) > 500 else response_content,
            "predicted_label": predicted_label,
            "expected_label": test_case["expected_label"],
            "is_correct": is_correct,
            "has_required_structure": self.check_response_structure(response),
            "word_count": len(response_content.split()),
            "test_type": test_case["test_type"]
        }
        
        return evaluation
    
    def calculate_detailed_metrics(self, results: List[Dict[str, Any]]):
        """计算详细的评估指标"""
        # 初始化计数器
        tp_attack = 0  # 真正例：预测为Attack且确实为Attack
        fp_attack = 0  # 假正例：预测为Attack但实际为Benign  
        fn_attack = 0  # 假反例：预测为Benign但实际为Attack
        tn_benign = 0  # 真反例：预测为Benign且确实为Benign
        
        for result in results:
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
            self.metrics["precision_attack"] = tp_attack / (tp_attack + fp_attack)
        if tp_attack + fn_attack > 0:
            self.metrics["recall_attack"] = tp_attack / (tp_attack + fn_attack)
        if self.metrics["precision_attack"] > 0 and self.metrics["recall_attack"] > 0:
            self.metrics["f1_score_attack"] = (2 * self.metrics["precision_attack"] * self.metrics["recall_attack"] / 
                                            (self.metrics["precision_attack"] + self.metrics["recall_attack"]))
        
        # 计算Benign类的指标（如果有benign样本）
        if tn_benign + fp_attack > 0:
            self.metrics["precision_benign"] = tn_benign / (tn_benign + fp_attack)
        if tn_benign + fn_attack > 0:
            self.metrics["recall_benign"] = tn_benign / (tn_benign + fn_attack)
        if self.metrics["precision_benign"] > 0 and self.metrics["recall_benign"] > 0:
            self.metrics["f1_score_benign"] = (2 * self.metrics["precision_benign"] * self.metrics["recall_benign"] / 
                                            (self.metrics["precision_benign"] + self.metrics["recall_benign"]))
    
    def run_comprehensive_test(self, max_files: int = 5, delay: int = 2):
        """运行综合测试"""
        print("=== 开始智能合约分析器性能测试 ===")
        print(f"扫描文件夹: {self.output_folder}")
        
        # 创建测试用例
        test_cases = self.create_test_cases(max_files)
        
        if not test_cases:
            print("错误: 没有有效的测试用例")
            return []
        
        print(f"准备测试 {len(test_cases)} 个文件")
        results = []
        
        for i, test_case in enumerate(test_cases):
            print(f"\n[{i+1}/{len(test_cases)}] 处理测试用例: {test_case['test_id']}")
            print(f"文件: {test_case['folder_name']}/{test_case['file_name']}")
            print(f"预期标签: {test_case['expected_label']}")
            
            try:
                # 检查文件是否存在
                if not os.path.exists(test_case["system_input_file"]):
                    print(f"警告: 文件不存在: {test_case['system_input_file']}")
                    continue
                
                # 调用核心分析函数
                start_time = time.time()
                result = analyze_contract(
                    query=test_case["query"],
                    system_input_path=test_case["system_input_file"]
                )
                response_time = time.time() - start_time
                
                # 调试信息：打印结果的类型和结构
                print(f"结果类型: {type(result)}")
                if isinstance(result, dict):
                    print(f"结果键: {list(result.keys())}")
                    if "answer" in result:
                        print(f"answer类型: {type(result['answer'])}")
                
                # 评估响应 - 传递整个结果对象，让extract_label处理
                evaluation = self.evaluate_single_response(test_case, result)
                evaluation["processing_time_seconds"] = round(response_time, 2)
                
                results.append(evaluation)
                
                # 更新指标
                self.metrics["total_tests"] += 1
                if evaluation["is_correct"]:
                    self.metrics["correct_predictions"] += 1
                
                print(f"预测标签: {evaluation['predicted_label']}")
                print(f"是否正确: {'✓' if evaluation['is_correct'] else '✗'}")
                print(f"处理时间: {response_time:.2f}秒")
                print(f"响应摘要: {evaluation['response'][:100]}...")
                
                # 避免API限制
                if i < len(test_cases) - 1:  # 不是最后一个测试
                    print(f"等待 {delay} 秒...")
                    time.sleep(delay)
                
            except Exception as e:
                print(f"处理测试用例时出错: {str(e)}")
                import traceback
                error_traceback = traceback.format_exc()
                print(f"错误详情: {error_traceback}")
                
                error_result = {
                    "test_id": test_case["test_id"],
                    "query": test_case["query"],
                    "system_input_file": test_case["system_input_file"],
                    "folder_name": test_case["folder_name"],
                    "file_name": test_case["file_name"],
                    "response": f"错误: {str(e)}",
                    "predicted_label": "Error",
                    "expected_label": test_case["expected_label"],
                    "is_correct": False,
                    "has_required_structure": False,
                    "word_count": 0,
                    "error": str(e),
                    "error_traceback": error_traceback,
                    "test_type": test_case["test_type"]
                }
                results.append(error_result)
                self.metrics["total_tests"] += 1
        
        # 计算指标
        if self.metrics["total_tests"] > 0:
            self.metrics["accuracy"] = self.metrics["correct_predictions"] / self.metrics["total_tests"]
        
        # 计算详细指标
        self.calculate_detailed_metrics(results)
        
        # 保存结果
        self.save_test_results(results)
        
        return results
    
    def save_test_results(self, results: List[Dict[str, Any]]):
        """保存测试结果"""
        os.makedirs(CONFIG["REASULT_FOLDER"], exist_ok=True)
        
        summary = {
            "metrics": self.metrics,
            "test_configuration": {
                "output_folder": self.output_folder,
                "total_test_cases": len(results),
                "total_files_found": len(self.discover_test_files())
            },
            "detailed_results": results
        }
        
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f"evaluation_summary_{timestamp}.json"
        filepath = os.path.join(CONFIG["REASULT_FOLDER"], filename)
        
        with open(filepath, 'w', encoding='utf-8') as f:
            json.dump(summary, f, ensure_ascii=False, indent=2)
        
        print(f"\n{'='*50}")
        print(f"测试完成!")
        print(f"测试结果已保存到: {filepath}")
        print(f"{'='*50}")
        print(f"总测试用例: {self.metrics['total_tests']}")
        print(f"正确预测: {self.metrics['correct_predictions']}")
        print(f"准确率: {self.metrics['accuracy']:.2%}")
        
        if self.metrics['total_tests'] > 0:
            print(f"\n=== 详细指标 ===")
            print(f"Attack精确率: {self.metrics['precision_attack']:.2%}")
            print(f"Attack召回率: {self.metrics['recall_attack']:.2%}")
            print(f"Attack F1分数: {self.metrics['f1_score_attack']:.2%}")
            
            # 只有当有benign样本时才显示benign指标
            if any(result["test_type"] == "benign" for result in results):
                print(f"Benign精确率: {self.metrics['precision_benign']:.2%}")
                print(f"Benign召回率: {self.metrics['recall_benign']:.2%}")
                print(f"Benign F1分数: {self.metrics['f1_score_benign']:.2%}")
        
        # 打印详细结果摘要
        print(f"\n=== 测试结果摘要 ===")
        attack_results = [r for r in results if r["test_type"] == "attack"]
        benign_results = [r for r in results if r["test_type"] == "benign"]
        
        if attack_results:
            correct_attack = sum(1 for r in attack_results if r.get("is_correct", False))
            print(f"攻击样本: {correct_attack}/{len(attack_results)} 正确")
        
        if benign_results:
            correct_benign = sum(1 for r in benign_results if r.get("is_correct", False))
            print(f"正常样本: {correct_benign}/{len(benign_results)} 正确")
        
        # 打印前几个结果的详细信息
        print(f"\n=== 前5个详细结果 ===")
        for i, result in enumerate(results[:5]):
            status = "✓" if result.get("is_correct", False) else "✗"
            error_msg = f", 错误: {result['error']}" if "error" in result else ""
            print(f"{i+1}. {status} {result['folder_name']}/{result['file_name']}:")
            print(f"   预测={result['predicted_label']}, 预期={result['expected_label']}{error_msg}")
            if "response" in result and len(result["response"]) > 0:
                print(f"   响应: {result['response'][:100]}...")

# 主测试函数
def main():
    import argparse
    
    parser = argparse.ArgumentParser(description='智能合约分析器测试工具')
    parser.add_argument('--output_folder', type=str, default=r"G:\tx-anomaly-predict\lsy\invocation_flow\output",
                       help='输出文件夹路径')
    parser.add_argument('--max_files', type=int, default=3,
                       help='最大测试文件数量')
    parser.add_argument('--delay', type=int, default=3,
                       help='请求间隔时间（秒）')
    
    args = parser.parse_args()
    
    evaluator = ContractAnalyzerEvaluator(args.output_folder)
    
    # 运行综合测试
    results = evaluator.run_comprehensive_test(max_files=args.max_files, delay=args.delay)
    
    return results

if __name__ == "__main__":
    main()