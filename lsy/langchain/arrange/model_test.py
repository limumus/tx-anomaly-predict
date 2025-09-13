import os
import json
import time
from datetime import datetime
from typing import List, Dict, Any, Callable, Optional
import argparse
import glob
import pandas as pd
from dataclasses import dataclass
import requests

from contract_analyzer import load_system_input, load_or_create_vector_store, create_conversational_chain

# ============== 模型专用配置 ==============
MODEL_CONFIG = {
    
    # 其他配置
    "PERSIST_DIR": "./vector_store_realtime_0",
    "CSV_PATH": "./extracted_data2.csv",
    "RESULT_FOLDER": "./model_comparison_results"
}

# ============== 模型相关类定义 ==============

@dataclass
class ModelConfig:
    """模型配置类"""
    name: str
    provider: str
    llm_creator: Callable
    description: str = ""
    config: Dict[str, Any] = None

class BaiduErnieAI:
    """百度文心ERNIE模型封装"""
    def __init__(self):
        self.access_key = MODEL_CONFIG["BAIDU_ACCESS_KEY"]
        self.secret_key = MODEL_CONFIG["BAIDU_SECRET_KEY"]
        self.api_url = MODEL_CONFIG["BAIDU_API_URL"]

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

class JinaEmbedding:
    """嵌入服务封装"""
    def __init__(self):
        self.api_url = "https://api.jina.ai/v1/embeddings"
        self.headers = {
            "Authorization": f"Bearer {MODEL_CONFIG['JINA_API_KEY']}",
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
                    "model": MODEL_CONFIG["EMBEDDING_MODEL"],
                    "input": [text[:8192]]
                },
                timeout=15
            )
            response.raise_for_status()
            return response.json()['data'][0]['embedding']
        except Exception as e:
            print(f"⚠️ 嵌入失败: {str(e)}")
            return []

class ErnieLLMWrapper:
    """ERNIE模型包装器"""
    def __init__(self, ernie_ai: BaiduErnieAI):
        self.ernie_ai = ernie_ai

    def invoke(self, input_data: Any, config: Optional[Dict] = None):
        from langchain_core.messages import AIMessage, HumanMessage, SystemMessage
        
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

class BaseModelWrapper:
    """基础模型包装器"""
    def __init__(self, model_config: ModelConfig):
        self.config = model_config
    
    def analyze_contract(self, query: str, system_input_path: str = None) -> Dict[str, Any]:
        """分析合约的抽象方法"""
        raise NotImplementedError("子类必须实现此方法")

class ErnieModelWrapper(BaseModelWrapper):
    """ERNIE模型包装器"""
    def __init__(self, model_config: ModelConfig):
        super().__init__(model_config)
        self.embedding = JinaEmbedding()
        self.vector_store = load_or_create_vector_store(MODEL_CONFIG["PERSIST_DIR"], self.embedding)
        self.ernie_ai = BaiduErnieAI()
        self.llm = ErnieLLMWrapper(self.ernie_ai)
    
    def analyze_contract(self, query: str, system_input_path: str = None) -> Dict[str, Any]:
        system_input = load_system_input(system_input_path) if system_input_path else ""
        
        conversational_chain = create_conversational_chain(
            self.vector_store,
            self.llm,
            csv_file_path=MODEL_CONFIG["CSV_PATH"]
        )
        
        return conversational_chain.invoke({
            "input": query,
            "system_input": system_input,
            "chat_history": [],
        })

class OpenAIModelWrapper(BaseModelWrapper):
    """OpenAI模型包装器"""
    def __init__(self, model_config: ModelConfig):
        super().__init__(model_config)
        self.api_key = MODEL_CONFIG["OPENAI_API_KEY"]
        self.api_url = MODEL_CONFIG["OPENAI_API_URL"]
        self.model_name = MODEL_CONFIG["OPENAI_MODEL"]
    
    def generate_response(self, messages: List[Dict[str, str]]) -> str:
        """调用OpenAI API"""
        try:
            headers = {
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json"
            }
            
            payload = {
                "model": self.model_name,
                "messages": messages,
                "temperature": 0.1,
                "max_tokens": 500
            }
            
            response = requests.post(self.api_url, headers=headers, json=payload, timeout=30)
            response.raise_for_status()
            response_data = response.json()
            
            return response_data["choices"][0]["message"]["content"]
            
        except Exception as e:
            return f"OpenAI API错误: {str(e)}"
    
    def analyze_contract(self, query: str, system_input_path: str = None) -> Dict[str, Any]:
        """简化版的OpenAI分析"""
        system_input = load_system_input(system_input_path) if system_input_path else ""
        
        messages = [
            {"role": "system", "content": "You are an expert in smart contract security analysis."},
            {"role": "user", "content": f"System Input: {system_input[:2000]}\n\nQuestion: {query}"}
        ]
        
        response = self.generate_response(messages)
        
        return {
            "answer": response,
            "context": []
        }

class DeepSeekModelWrapper(BaseModelWrapper):
    """DeepSeek模型包装器"""
    def __init__(self, model_config: ModelConfig):
        super().__init__(model_config)
        self.api_key = MODEL_CONFIG["DEEPSEEK_API_KEY"]
        self.api_url = MODEL_CONFIG["DEEPSEEK_API_URL"]
        self.model_name = MODEL_CONFIG["DEEPSEEK_MODEL"]
    
    def generate_response(self, messages: List[Dict[str, str]]) -> str:
        """调用DeepSeek API"""
        try:
            headers = {
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json"
            }
            
            payload = {
                "model": self.model_name,
                "messages": messages,
                "temperature": 0.1,
                "max_tokens": 500
            }
            
            response = requests.post(self.api_url, headers=headers, json=payload, timeout=30)
            response.raise_for_status()
            response_data = response.json()
            
            return response_data["choices"][0]["message"]["content"]
            
        except Exception as e:
            return f"DeepSeek API错误: {str(e)}"
    
    def analyze_contract(self, query: str, system_input_path: str = None) -> Dict[str, Any]:
        """简化版的DeepSeek分析"""
        system_input = load_system_input(system_input_path) if system_input_path else ""
        
        messages = [
            {"role": "system", "content": "You are an expert in smart contract security analysis."},
            {"role": "user", "content": f"System Input: {system_input[:2000]}\n\nQuestion: {query}"}
        ]
        
        response = self.generate_response(messages)
        
        return {
            "answer": response,
            "context": []
        }

# ============== 模型注册表 ==============

MODEL_REGISTRY = {
    "ernie-speed-128k": ModelConfig(
        name="ernie-speed-128k",
        provider="Baidu",
        llm_creator=lambda config: ErnieModelWrapper(config),
        description="百度文心ERNIE Speed 128K模型"
    ),
    "gpt-4o": ModelConfig(
        name="gpt-4o",
        provider="OpenAI",
        llm_creator=lambda config: OpenAIModelWrapper(config),
        description="OpenAI GPT-4o模型"
    ),
    "deepseek-chat": ModelConfig(
        name="deepseek-chat",
        provider="DeepSeek",
        llm_creator=lambda config: DeepSeekModelWrapper(config),
        description="DeepSeek Chat模型"
    )
}

# ============== 多模型测试器 ==============

class MultiModelTester:
    """多模型性能对比测试器"""
    
    def __init__(self, output_folder: str):
        self.output_folder = output_folder
        self.test_cases = []
        self.results = []
    
    def discover_test_files(self, max_files: int = 0) -> List[str]:
        """发现测试文件"""
        pattern = os.path.join(self.output_folder, "**", "*_exp.sol", "*.txt.json")
        discovered_files = glob.glob(pattern, recursive=True)
        
        if max_files > 0:
            discovered_files = discovered_files[:max_files]
        
        return discovered_files
    
    def create_test_cases(self, max_files: int = 10) -> List[Dict[str, Any]]:
        """创建测试用例"""
        test_files = self.discover_test_files(max_files)
        
        test_cases = []
        for i, file_path in enumerate(test_files):
            test_cases.append({
                "test_id": f"test_{i+1:04d}",
                "query": "Please analyze this transaction to determine if it's an attack or benign contract behavior.",
                "system_input_file": file_path,
                "expected_label": "Attack",
                "folder_name": os.path.basename(os.path.dirname(file_path)),
                "file_name": os.path.basename(file_path)
            })
        
        return test_cases
    
    def extract_label(self, response: Any) -> str:
        """从响应中提取标签"""
        import re
        
        if isinstance(response, dict) and "answer" in response:
            answer = response["answer"]
            if hasattr(answer, 'content'):
                content = answer.content
            else:
                content = str(answer)
        else:
            content = str(response)
        
        match = re.search(r'^\[(Attack|Benign)\]', content, re.IGNORECASE)
        if match:
            return match.group(1).capitalize()
        
        if re.search(r'\bAttack\b', content, re.IGNORECASE):
            return "Attack"
        elif re.search(r'\bBenign\b', content, re.IGNORECASE):
            return "Benign"
        
        return "Unknown"
    
    def evaluate_response(self, test_case: Dict[str, Any], response: Any, 
                         processing_time: float, model_name: str) -> Dict[str, Any]:
        """评估单个响应"""
        predicted_label = self.extract_label(response)
        is_correct = predicted_label.lower() == test_case["expected_label"].lower()
        
        response_content = str(response.get("answer", "")) if isinstance(response, dict) else str(response)
        
        return {
            "test_id": test_case["test_id"],
            "model": model_name,
            "query": test_case["query"],
            "system_input_file": test_case["system_input_file"],
            "folder_name": test_case["folder_name"],
            "file_name": test_case["file_name"],
            "response": response_content[:500] + "..." if len(response_content) > 500 else response_content,
            "predicted_label": predicted_label,
            "expected_label": test_case["expected_label"],
            "is_correct": is_correct,
            "processing_time_seconds": round(processing_time, 2),
            "test_time": datetime.now().isoformat()
        }
    
    def test_single_model(self, model_config: ModelConfig, test_cases: List[Dict[str, Any]], 
                         delay: int = 2) -> List[Dict[str, Any]]:
        """测试单个模型"""
        print(f"\n{'='*60}")
        print(f"开始测试模型: {model_config.name} ({model_config.description})")
        print(f"{'='*60}")
        
        model_wrapper = model_config.llm_creator(model_config)
        results = []
        
        for i, test_case in enumerate(test_cases):
            try:
                print(f"[{i+1}/{len(test_cases)}] {model_config.name}: {test_case['file_name']}")
                
                start_time = time.time()
                response = model_wrapper.analyze_contract(
                    query=test_case["query"],
                    system_input_path=test_case["system_input_file"]
                )
                processing_time = time.time() - start_time
                
                evaluation = self.evaluate_response(test_case, response, processing_time, model_config.name)
                results.append(evaluation)
                
                print(f"  预测: {evaluation['predicted_label']}, 时间: {processing_time:.2f}s, 正确: {evaluation['is_correct']}")
                
                if i < len(test_cases) - 1:
                    time.sleep(delay)
                    
            except Exception as e:
                print(f"处理出错: {str(e)}")
                error_result = {
                    "test_id": test_case["test_id"],
                    "model": model_config.name,
                    "query": test_case["query"],
                    "system_input_file": test_case["system_input_file"],
                    "folder_name": test_case["folder_name"],
                    "file_name": test_case["file_name"],
                    "response": f"错误: {str(e)}",
                    "predicted_label": "Error",
                    "expected_label": test_case["expected_label"],
                    "is_correct": False,
                    "processing_time_seconds": 0,
                    "test_time": datetime.now().isoformat(),
                    "error": str(e)
                }
                results.append(error_result)
                time.sleep(delay * 2)
        
        return results
    
    def run_comparison_test(self, model_names: List[str], max_files: int = 10, 
                           delay: int = 2) -> Dict[str, Any]:
        """运行多模型对比测试"""
        test_cases = self.create_test_cases(max_files)
        print(f"创建了 {len(test_cases)} 个测试用例")
        
        all_results = {}
        
        for model_name in model_names:
            if model_name not in MODEL_REGISTRY:
                print(f"警告: 模型 {model_name} 未在注册表中找到")
                continue
            
            model_config = MODEL_REGISTRY[model_name]
            results = self.test_single_model(model_config, test_cases, delay)
            all_results[model_name] = results
            
            # 保存当前模型结果
            self.save_model_results(model_name, results)
            
            # 模型间等待
            if model_name != model_names[-1]:
                print(f"\n等待30秒后测试下一个模型...")
                time.sleep(30)
        
        # 生成对比报告
        comparison_report = self.generate_comparison_report(all_results)
        self.save_comparison_report(comparison_report)
        
        return comparison_report
    
    def save_model_results(self, model_name: str, results: List[Dict[str, Any]]):
        """保存单个模型的结果"""
        os.makedirs(MODEL_CONFIG["RESULT_FOLDER"], exist_ok=True)
        
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f"{model_name}_results_{timestamp}.json"
        filepath = os.path.join(MODEL_CONFIG["RESULT_FOLDER"], filename)
        
        with open(filepath, 'w', encoding='utf-8') as f:
            json.dump({
                "model": model_name,
                "test_date": timestamp,
                "total_tests": len(results),
                "results": results
            }, f, ensure_ascii=False, indent=2)
        
        print(f"{model_name} 结果已保存到: {filepath}")
    
    def generate_comparison_report(self, all_results: Dict[str, List[Dict[str, Any]]]) -> Dict[str, Any]:
        """生成对比报告"""
        report = {
            "comparison_date": datetime.now().isoformat(),
            "models": {},
            "summary": {}
        }
        
        for model_name, results in all_results.items():
            total_tests = len(results)
            correct_predictions = sum(1 for r in results if r.get("is_correct", False))
            error_count = sum(1 for r in results if r.get("predicted_label") == "Error")
            avg_time = sum(r.get("processing_time_seconds", 0) for r in results) / total_tests if total_tests > 0 else 0
            
            report["models"][model_name] = {
                "total_tests": total_tests,
                "correct_predictions": correct_predictions,
                "accuracy": correct_predictions / total_tests if total_tests > 0 else 0,
                "error_count": error_count,
                "average_processing_time": round(avg_time, 2),
                "total_processing_time": sum(r.get("processing_time_seconds", 0) for r in results)
            }
        
        return report
    
    def save_comparison_report(self, report: Dict[str, Any]):
        """保存对比报告"""
        os.makedirs(MODEL_CONFIG["RESULT_FOLDER"], exist_ok=True)
        
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f"model_comparison_report_{timestamp}.json"
        filepath = os.path.join(MODEL_CONFIG["RESULT_FOLDER"], filename)
        
        with open(filepath, 'w', encoding='utf-8') as f:
            json.dump(report, f, ensure_ascii=False, indent=2)
        
        print(f"\n对比报告已保存到: {filepath}")
        
        # 打印简要报告
        print(f"\n{'='*60}")
        print("模型性能对比报告")
        print(f"{'='*60}")
        for model_name, stats in report["models"].items():
            print(f"{model_name}:")
            print(f"  准确率: {stats['accuracy']:.2%}")
            print(f"  平均处理时间: {stats['average_processing_time']:.2f}s")
            print(f"  错误数量: {stats['error_count']}")
            print()

# ============== 环境检查函数 ==============

def check_model_environment():
    """检查模型环境配置"""
    print("检查模型环境配置...")
    
    # 检查必要的API密钥
    required_keys = {
        "BAIDU_ACCESS_KEY": "百度文心ERNIE",
        "BAIDU_SECRET_KEY": "百度文心ERNIE",
        "JINA_API_KEY": "Jina Embedding",
    }
    
    missing_keys = []
    for key, service in required_keys.items():
        if MODEL_CONFIG.get(key) == "your_{}_here".format(key.lower()):
            missing_keys.append(f"{service} ({key})")
    
    if missing_keys:
        print("⚠️  警告: 以下API密钥需要配置:")
        for missing in missing_keys:
            print(f"  - {missing}")
        print("\n请在 MODEL_CONFIG 中更新您的API密钥")
        return False
    
    print("✅ 环境配置检查通过")
    return True

def setup_environment_from_env():
    """从环境变量设置配置"""
    import os
    # 尝试从环境变量获取配置
    for key in MODEL_CONFIG.keys():
        env_value = os.getenv(key)
        if env_value and MODEL_CONFIG[key].startswith("your_"):
            MODEL_CONFIG[key] = env_value
            print(f"从环境变量设置 {key}")

# ============== 主函数 ==============

def main():
    # 首先尝试从环境变量设置配置
    setup_environment_from_env()
    
    parser = argparse.ArgumentParser(description='多模型性能对比测试工具')
    parser.add_argument('--output_folder', type=str, 
                       default=r"G:\tx-anomaly-predict\lsy\invocation_flow\output",
                       help='测试文件文件夹路径')
    parser.add_argument('--models', type=str, nargs='+',
                       default=["ernie-speed-128k"],
                       help='要测试的模型名称列表')
    parser.add_argument('--max_files', type=int, default=5,
                       help='最大测试文件数量')
    parser.add_argument('--delay', type=int, default=2,
                       help='请求间隔时间（秒）')
    parser.add_argument('--list_models', action='store_true',
                       help='列出所有可用的模型')
    parser.add_argument('--check_env', action='store_true',
                       help='只检查环境配置，不运行测试')
    
    args = parser.parse_args()
    
    if not check_model_environment() and not args.check_env:
        print("环境配置不完整，请先配置API密钥")
        return
    
    if args.check_env:
        return
    
    if args.list_models:
        print("可用的模型:")
        for model_name, config in MODEL_REGISTRY.items():
            print(f"  {model_name}: {config.description}")
        
        print("\n当前配置的模型:")
        for model_name in args.models:
            if model_name in MODEL_REGISTRY:
                print(f"  ✅ {model_name}")
            else:
                print(f"  ❌ {model_name} (未找到)")
        return
    
    tester = MultiModelTester(args.output_folder)
    
    # 运行对比测试
    report = tester.run_comparison_test(
        model_names=args.models,
        max_files=args.max_files,
        delay=args.delay
    )
    
    return report

if __name__ == "__main__":
    main()
