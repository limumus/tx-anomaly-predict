import os
import json
import time
from datetime import datetime
from typing import List, Dict, Any
import argparse
import glob

from contract_analyzer import analyze_contract, CONFIG

def run_batch_testing(output_folder: str, batch_size: int = 50, delay: int = 2, 
                     resume_from: int = 0, max_files: int = 0) -> List[Dict[str, Any]]:
    """分批处理大量测试文件"""
    
    # 导入测试评估器
    from test_evaluator import ContractAnalyzerEvaluator
    
    evaluator = ContractAnalyzerEvaluator(output_folder)
    
    # 发现所有文件
    all_files = evaluator.discover_test_files()
    total_files = len(all_files)
    
    if max_files > 0:
        all_files = all_files[:max_files]
        total_files = len(all_files)
    
    print(f"发现 {total_files} 个文件，将分批次处理")
    print(f"从第 {resume_from} 个文件开始，每批 {batch_size} 个文件")
    
    all_results = []
    processed_count = resume_from
    
    for batch_start in range(resume_from, total_files, batch_size):
        batch_end = min(batch_start + batch_size, total_files)
        batch_files = all_files[batch_start:batch_end]
        
        print(f"\n{'='*60}")
        print(f"处理批次 {(batch_start//batch_size) + 1}: 文件 {batch_start}-{batch_end-1}")
        print(f"进度: {processed_count}/{total_files} ({processed_count/total_files*100:.1f}%)")
        print(f"{'='*60}")
        
        batch_results = []
        
        for i, file_path in enumerate(batch_files):
            file_index = batch_start + i
            try:
                print(f"[{file_index+1}/{total_files}] 处理文件: {os.path.basename(file_path)}")
                
                # 直接使用 analyze_contract 函数
                start_time = time.time()
                result = analyze_contract(
                    query="Please analyze this transaction to determine if it's an attack or benign contract behavior.",
                    system_input_path=file_path
                )
                response_time = time.time() - start_time
                
                # 创建测试用例用于评估
                test_case = {
                    "test_id": f"test_{file_index+1:04d}",
                    "query": "Please analyze this transaction to determine if it's an attack or benign contract behavior.",
                    "system_input_file": file_path,
                    "expected_label": "Benign",
                    "test_type": "benign",
                    "folder_name": os.path.basename(os.path.dirname(file_path)),
                    "file_name": os.path.basename(file_path)
                }
                
                # 评估响应
                evaluation = evaluator.evaluate_single_response(test_case, result)
                evaluation["processing_time_seconds"] = round(response_time, 2)
                evaluation["file_index"] = file_index
                
                batch_results.append(evaluation)
                processed_count += 1
                
                print(f"  预测: {evaluation['predicted_label']}, 时间: {response_time:.2f}s")
                
                # 避免API限制
                if i < len(batch_files) - 1:
                    time.sleep(delay)
                    
            except Exception as e:
                print(f"处理文件 {os.path.basename(file_path)} 时出错: {str(e)}")
                error_result = {
                    "test_id": f"test_{file_index+1:04d}",
                    "query": "Please analyze this transaction to determine if it's an attack or benign contract behavior.",
                    "system_input_file": file_path,
                    "folder_name": os.path.basename(os.path.dirname(file_path)),
                    "file_name": os.path.basename(file_path),
                    "response": f"错误: {str(e)}",
                    "predicted_label": "Error",
                    "expected_label": "Bengin",
                    "is_correct": False,
                    "has_required_structure": False,
                    "word_count": 0,
                    "error": str(e),
                    "file_index": file_index,
                    "test_type": "benign"
                }
                batch_results.append(error_result)
                processed_count += 1
                
                # 错误后等待更长时间
                time.sleep(delay * 2)
        
        # 保存当前批次结果
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        batch_filename = f"batch_{batch_start:04d}_{batch_end-1:04d}_{timestamp}.json"
        
        # 创建批次结果文件夹
        batch_dir = os.path.join(CONFIG.get("REASULT_FOLDER", "batch_results"), "batches")
        os.makedirs(batch_dir, exist_ok=True)
        
        batch_filepath = os.path.join(batch_dir, batch_filename)
        
        with open(batch_filepath, 'w', encoding='utf-8') as f:
            json.dump({
                "batch_info": {
                    "batch_number": (batch_start // batch_size) + 1,
                    "start_index": batch_start,
                    "end_index": batch_end - 1,
                    "total_files": len(batch_results),
                    "processing_date": timestamp
                },
                "results": batch_results
            }, f, ensure_ascii=False, indent=2)
        
        all_results.extend(batch_results)
        
        # 每完成一个批次后等待一段时间，避免过热
        if batch_end < total_files:
            wait_time = 30  # 批次间等待30秒
            print(f"批次完成，等待{wait_time}秒后继续...")
            time.sleep(wait_time)
    
    return all_results

def get_next_index(folder, prefix="combined_results_", suffix=".json"):
    """获取下一个可用的文件索引"""
    existing_files = glob.glob(os.path.join(folder, f"{prefix}*{suffix}"))
    indices = []
    for f in existing_files:
        try:
            # 从文件名中提取数字部分
            filename = os.path.basename(f)
            num_str = filename.replace(prefix, "").replace(suffix, "")
            if num_str.isdigit():
                indices.append(int(num_str))
        except ValueError:
            continue
    next_index = max(indices, default=0) + 1
    return next_index

def combine_batch_results(output_folder: str):
    """合并所有批次结果"""
    batch_dir = os.path.join(CONFIG.get("REASULT_FOLDER", "batch_results"), "batches")
    
    if not os.path.exists(batch_dir):
        print("没有找到批次结果文件夹")
        return
    
    all_results = []
    batch_files = [f for f in os.listdir(batch_dir) if f.startswith("batch_") and f.endswith(".json")]
    
    print(f"找到 {len(batch_files)} 个批次文件")
    
    for batch_file in sorted(batch_files):
        batch_path = os.path.join(batch_dir, batch_file)
        try:
            with open(batch_path, 'r', encoding='utf-8') as f:
                batch_data = json.load(f)
                results = batch_data.get("results", [])
                all_results.extend(results)
                print(f"已加载批次: {batch_file} ({len(results)} 个结果)")
        except Exception as e:
            print(f"加载批次 {batch_file} 时出错: {e}")
    
    if not all_results:
        print("没有找到任何结果数据")
        return
    
    # 计算总体指标
    from test_evaluator import ContractAnalyzerEvaluator
    evaluator = ContractAnalyzerEvaluator(output_folder)
    
    # 计算指标
    total_tests = len(all_results)
    correct_predictions = sum(1 for r in all_results if r.get("is_correct", False))
    accuracy = correct_predictions / total_tests if total_tests > 0 else 0
    
    # 获取当前时间戳
    current_timestamp = datetime.now().isoformat()
    
    # 获取下一个文件索引
    combined_dir = CONFIG.get("REASULT_FOLDER", "batch_results")
    os.makedirs(combined_dir, exist_ok=True)
    next_index = get_next_index(combined_dir)
    combined_filename = f"combined_results_{next_index:03d}.json"
    combined_filepath = os.path.join(combined_dir, combined_filename)
    
    # 创建汇总数据
    summary = {
        "metrics": {
            "total_tests": total_tests,
            "correct_predictions": correct_predictions,
            "accuracy": accuracy,
            "error_count": sum(1 for r in all_results if r.get("predicted_label") == "Error")
        },
        "test_date": current_timestamp,
        "total_batches": len(batch_files),
        "batch_files": batch_files,
        "detailed_results_count": len(all_results),
        # 不包含详细结果以避免文件过大，如果需要可以取消注释下一行
        # "detailed_results": all_results
    }
    
    # 保存汇总文件
    with open(combined_filepath, 'w', encoding='utf-8') as f:
        json.dump(summary, f, ensure_ascii=False, indent=2)
    
    # 另外保存详细结果到单独文件（避免主文件过大）
    detailed_filename = f"detailed_results_{next_index:03d}.json"
    detailed_filepath = os.path.join(combined_dir, detailed_filename)
    with open(detailed_filepath, 'w', encoding='utf-8') as f:
        json.dump({
            "summary": summary,
            "detailed_results": all_results
        }, f, ensure_ascii=False, indent=2)
    
    print(f"\n{'='*60}")
    print("合并完成!")
    print(f"总测试用例: {total_tests}")
    print(f"正确预测: {correct_predictions}")
    print(f"准确率: {accuracy:.2%}")
    print(f"错误数量: {summary['metrics']['error_count']}")
    print(f"汇总文件: {combined_filepath}")
    print(f"详细结果: {detailed_filepath}")
    print(f"{'='*60}")
    
    return summary

def show_summary_stats(output_folder: str):
    """显示统计摘要"""
    combined_dir = CONFIG.get("REASULT_FOLDER", "batch_results")
    combined_files = [f for f in os.listdir(combined_dir) if f.startswith("combined_results_") and f.endswith(".json")]
    
    if not combined_files:
        print("没有找到汇总文件")
        return
    
    # 按修改时间排序，获取最新的文件
    combined_files.sort(key=lambda x: os.path.getmtime(os.path.join(combined_dir, x)), reverse=True)
    latest_file = combined_files[0]
    latest_path = os.path.join(combined_dir, latest_file)
    
    try:
        with open(latest_path, 'r', encoding='utf-8') as f:
            summary = json.load(f)
        
        print(f"\n最新汇总文件: {latest_file}")
        print(f"{'='*50}")
        print(f"测试日期: {summary.get('test_date', '未知')}")
        print(f"总测试用例: {summary['metrics']['total_tests']}")
        print(f"正确预测: {summary['metrics']['correct_predictions']}")
        print(f"准确率: {summary['metrics']['accuracy']:.2%}")
        print(f"错误数量: {summary['metrics']['error_count']}")
        print(f"批次数量: {summary['total_batches']}")
        
    except Exception as e:
        print(f"读取汇总文件时出错: {e}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='批量测试智能合约分析器')
    parser.add_argument('--output_folder', type=str, 
                       default=r"G:\safe\pythonProject\benign_output",
                       help='输出文件夹路径')
    parser.add_argument('--batch_size', type=int, default=20,
                       help='每批处理的文件数量')
    parser.add_argument('--delay', type=int, default=2,
                       help='文件间延迟时间（秒）')
    parser.add_argument('--resume_from', type=int, default=0,
                       help='从第几个文件开始处理')
    parser.add_argument('--max_files', type=int, default=0,
                       help='最大处理文件数量（0表示所有文件）')
    parser.add_argument('--combine_only', action='store_true',
                       help='仅合并现有结果，不进行新的测试')
    parser.add_argument('--stats_only', action='store_true',
                       help='仅显示统计信息，不进行测试或合并')
    
    args = parser.parse_args()
    
    if args.stats_only:
        show_summary_stats(args.output_folder)
    elif args.combine_only:
        combine_batch_results(args.output_folder)
    else:
        # 运行批量测试
        results = run_batch_testing(
            output_folder=args.output_folder,
            batch_size=args.batch_size,
            delay=args.delay,
            resume_from=args.resume_from,
            max_files=args.max_files
        )
        
        print(f"\n批量测试完成! 共处理 {len(results)} 个文件")
        
        # 合并结果
        combine_batch_results(args.output_folder)