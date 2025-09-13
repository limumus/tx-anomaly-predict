import os
import json
import glob
import time
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
from typing import List, Dict, Any, Tuple
from datetime import datetime
from collections import defaultdict

# 导入主分析器
from contract_analyzer import analyze_contract, CONFIG

class SimilarityAnalyzer:
    """相似度分析工具，用于确定最佳相似度阈值"""
    
    def __init__(self, test_files_dir: str, output_dir: str = "./similarity_analysis"):
        self.test_files_dir = test_files_dir
        self.output_dir = output_dir
        os.makedirs(output_dir, exist_ok=True)
        
    def discover_test_files(self, pattern: str = "**/*.json") -> List[str]:
        """发现测试文件"""
        search_pattern = os.path.join(self.test_files_dir, pattern)
        return glob.glob(search_pattern, recursive=True)
    
    def analyze_similarity_distribution(self, files: List[str], sample_size: int = 100) -> Dict[str, Any]:
        """
        分析相似度分布
        Args:
            files: 测试文件列表
            sample_size: 采样数量
        """
        if sample_size > 0 and len(files) > sample_size:
            files = np.random.choice(files, sample_size, replace=False).tolist()
        
        similarity_scores = []
        file_results = []
        
        print(f"开始分析 {len(files)} 个文件的相似度分布...")
        
        for i, file_path in enumerate(files):
            try:
                print(f"[{i+1}/{len(files)}] 分析: {os.path.basename(file_path)}")
                
                result = analyze_contract(
                    query="Analyze this transaction for potential attacks",
                    system_input_path=file_path
                )
                
                # 添加调试输出
                print(f"  结果类型: {type(result)}")
                print(f"  结果键: {list(result.keys())}")
                
                if "error" in result:
                    print(f"  ❌ 错误信息: {result['error']}")
                    continue
                    
                if "similarity_info" in result:
                    sim_info = result["similarity_info"]
                    print(f"  相似度信息: {sim_info}")
                    file_result = {
                        "file_path": file_path,
                        "file_name": os.path.basename(file_path),
                        "min_score": sim_info["min_score"],
                        "max_score": sim_info["max_score"],
                        "avg_score": sim_info["avg_score"],
                        "doc_count": sim_info["doc_count"]
                    }
                    file_results.append(file_result)
                    similarity_scores.append(sim_info["avg_score"])
                    print(f"  平均相似度: {sim_info['avg_score']:.3f}")
                else:
                    print(f"  ❌ 没有 similarity_info")
                    # 检查是否有 context
                    if "context" in result:
                        print(f"  上下文文档数量: {len(result['context'])}")
                        for j, doc in enumerate(result["context"]):
                            if hasattr(doc, 'metadata'):
                                print(f"    文档 {j+1} 元数据键: {list(doc.metadata.keys())}")
                
                # 避免API限制
                if i < len(files) - 1:
                    time.sleep(1)
                    
            except Exception as e:
                print(f"分析文件 {os.path.basename(file_path)} 时出错: {str(e)}")
                import traceback
                traceback.print_exc()
                continue
        
        # 添加调试信息
        print(f"\n调试信息:")
        print(f"处理文件总数: {len(files)}")
        print(f"成功获取相似度的文件: {len(similarity_scores)}")
        print(f"相似度分数列表: {similarity_scores}")
        
        # 计算统计信息
        if similarity_scores:
            scores_array = np.array(similarity_scores)
            stats = {
                "total_files": len(similarity_scores),
                "mean": float(np.mean(scores_array)),
                "median": float(np.median(scores_array)),
                "std": float(np.std(scores_array)),
                "min": float(np.min(scores_array)),
                "max": float(np.max(scores_array)),
                "q1": float(np.percentile(scores_array, 25)),
                "q3": float(np.percentile(scores_array, 75)),
                "percentile_90": float(np.percentile(scores_array, 90)),
                "percentile_95": float(np.percentile(scores_array, 95)),
            }
            
            # 生成阈值建议
            threshold_suggestions = self._generate_threshold_suggestions(stats, scores_array)
            
            return {
                "statistics": stats,
                "threshold_suggestions": threshold_suggestions,
                "file_results": file_results,
                "similarity_scores": similarity_scores,
                "analysis_date": datetime.now().isoformat()
            }
        else:
            print("❌ 没有获取到任何有效的相似度数据")
            # 尝试分析前几个文件的原始结果来诊断问题
            if files and len(files) > 0:
                sample_file = files[0]
                print(f"\n诊断样本文件: {sample_file}")
                try:
                    sample_result = analyze_contract(
                        query="Analyze this transaction for potential attacks",
                        system_input_path=sample_file
                    )
                    print(f"样本文件结果类型: {type(sample_result)}")
                    print(f"样本文件结果键: {list(sample_result.keys()) if isinstance(sample_result, dict) else 'N/A'}")
                    print(f"样本文件结果内容: {json.dumps(sample_result, ensure_ascii=False)[:500] if isinstance(sample_result, dict) else sample_result}")
                except Exception as e:
                    print(f"诊断样本文件时出错: {e}")
            
            return {"error": "没有获取到有效的相似度数据", "processed_files": len(files), "successful_files": 0}
        
    def _generate_threshold_suggestions(self, stats: Dict, scores: List[float]) -> Dict[str, Any]:
        """生成阈值建议"""
        scores_array = np.array(scores)
        
        # 不同阈值下的覆盖率
        thresholds = np.arange(0.1, 1.0, 0.05)
        coverage = []
        
        for threshold in thresholds:
            coverage_rate = np.mean(scores_array >= threshold)
            coverage.append({
                "threshold": float(threshold),
                "coverage_rate": float(coverage_rate),
                "files_above": int(np.sum(scores_array >= threshold))
            })
        
        # 推荐阈值
        recommended_thresholds = {
            "conservative": {
                "threshold": float(stats["q3"]),
                "description": "保守阈值（上四分位数），确保高质量匹配",
                "coverage": float(np.mean(scores_array >= stats["q3"]))
            },
            "balanced": {
                "threshold": float(stats["median"]),
                "description": "平衡阈值（中位数），兼顾质量和数量",
                "coverage": float(np.mean(scores_array >= stats["median"]))
            },
            "aggressive": {
                "threshold": float(stats["q1"]),
                "description": "激进阈值（下四分位数），最大化召回率",
                "coverage": float(np.mean(scores_array >= stats["q1"]))
            }
        }
        
        return {
            "coverage_analysis": coverage,
            "recommended_thresholds": recommended_thresholds,
            "optimal_threshold": self._find_optimal_threshold(coverage)
        }
    
    def _find_optimal_threshold(self, coverage: List[Dict]) -> Dict[str, Any]:
        """找到最优阈值（覆盖率下降最快的点）"""
        thresholds = [item["threshold"] for item in coverage]
        coverage_rates = [item["coverage_rate"] for item in coverage]
        
        # 计算覆盖率变化率
        coverage_changes = []
        for i in range(1, len(coverage_rates)):
            change = coverage_rates[i-1] - coverage_rates[i]
            coverage_changes.append(change)
        
        # 找到变化率最大的点
        if coverage_changes:
            max_change_index = np.argmax(coverage_changes)
            optimal_threshold = thresholds[max_change_index + 1]
            
            return {
                "threshold": optimal_threshold,
                "coverage_rate": coverage_rates[max_change_index + 1],
                "change_rate": coverage_changes[max_change_index],
                "description": f"最优阈值（覆盖率下降最快的点）"
            }
        else:
            return {"threshold": 0.7, "description": "默认阈值"}
    
    def create_visualizations(self, analysis_results: Dict, save_plots: bool = True):
        """创建可视化图表"""
        scores = analysis_results.get("similarity_scores", [])
        if not scores:
            return
        
        # 创建图表
        fig, ((ax1, ax2), (ax3, ax4)) = plt.subplots(2, 2, figsize=(15, 12))
        
        # 1. 相似度分布直方图
        ax1.hist(scores, bins=20, alpha=0.7, color='skyblue', edgecolor='black')
        ax1.set_xlabel('相似度分数')
        ax1.set_ylabel('文件数量')
        ax1.set_title('相似度分布直方图')
        ax1.grid(True, alpha=0.3)
        
        # 2. 箱线图
        ax2.boxplot(scores, vert=False)
        ax2.set_xlabel('相似度分数')
        ax2.set_title('相似度箱线图')
        ax2.grid(True, alpha=0.3)
        
        # 3. 覆盖率曲线
        coverage_data = analysis_results["threshold_suggestions"]["coverage_analysis"]
        thresholds = [item["threshold"] for item in coverage_data]
        coverage_rates = [item["coverage_rate"] for item in coverage_data]
        
        ax3.plot(thresholds, coverage_rates, 'b-', marker='o', linewidth=2)
        ax3.set_xlabel('阈值')
        ax3.set_ylabel('覆盖率')
        ax3.set_title('阈值 vs 覆盖率')
        ax3.grid(True, alpha=0.3)
        ax3.set_ylim(0, 1)
        
        # 4. 累积分布函数
        sorted_scores = np.sort(scores)
        cdf = np.arange(1, len(sorted_scores) + 1) / len(sorted_scores)
        ax4.plot(sorted_scores, cdf, 'r-', linewidth=2)
        ax4.set_xlabel('相似度分数')
        ax4.set_ylabel('累积概率')
        ax4.set_title('相似度累积分布函数')
        ax4.grid(True, alpha=0.3)
        
        plt.tight_layout()
        
        if save_plots:
            plot_path = os.path.join(self.output_dir, "similarity_analysis_plots.png")
            plt.savefig(plot_path, dpi=300, bbox_inches='tight')
            print(f"图表已保存至: {plot_path}")
        
        plt.show()
    
    def generate_report(self, analysis_results: Dict):
        """生成详细报告"""
        report = {
            "analysis_summary": {
                "total_files_analyzed": len(analysis_results.get("similarity_scores", [])),
                "analysis_date": analysis_results.get("analysis_date", ""),
                "overall_statistics": analysis_results.get("statistics", {})
            },
            "threshold_recommendations": analysis_results.get("threshold_suggestions", {}),
            "detailed_analysis": analysis_results
        }
        
        # 保存报告
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        report_path = os.path.join(self.output_dir, f"similarity_analysis_report_{timestamp}.json")
        
        with open(report_path, 'w', encoding='utf-8') as f:
            json.dump(report, f, ensure_ascii=False, indent=2)
        
        print(f"分析报告已保存至: {report_path}")
        
        # 打印关键信息
        stats = analysis_results["statistics"]
        recommendations = analysis_results["threshold_suggestions"]["recommended_thresholds"]
        
        print("\n" + "="*60)
        print("相似度分析结果摘要")
        print("="*60)
        print(f"分析文件数量: {stats['total_files']}")
        print(f"平均相似度: {stats['mean']:.3f}")
        print(f"中位数相似度: {stats['median']:.3f}")
        print(f"标准差: {stats['std']:.3f}")
        print(f"范围: [{stats['min']:.3f}, {stats['max']:.3f}]")
        
        print("\n推荐阈值:")
        for name, rec in recommendations.items():
            print(f"  {name}: {rec['threshold']:.3f} (覆盖率: {rec['coverage']:.1%}) - {rec['description']}")
        
        optimal = analysis_results["threshold_suggestions"]["optimal_threshold"]
        print(f"最优阈值: {optimal['threshold']:.3f} (覆盖率: {optimal['coverage_rate']:.1%})")
        
        return report_path

def main():
    """主函数"""
    import argparse
    
    parser = argparse.ArgumentParser(description='相似度分析工具')
    parser.add_argument('--test_dir', type=str, default=r"G:\safe\pythonProject\output",
                       help='测试文件目录路径')
    parser.add_argument('--output_dir', type=str, default="./similarity_analysis",
                       help='输出目录路径')
    parser.add_argument('--sample_size', type=int, default=50,
                       help='采样文件数量（0表示所有文件）')
    parser.add_argument('--create_plots', action='store_true',
                       help='创建可视化图表')
    
    args = parser.parse_args()
    
    # 创建分析器
    analyzer = SimilarityAnalyzer(args.test_dir, args.output_dir)
    
    # 发现测试文件
    test_files = analyzer.discover_test_files()
    print(f"发现 {len(test_files)} 个测试文件")
    
    if not test_files:
        print("没有找到测试文件")
        return
    
    # 分析相似度分布
    results = analyzer.analyze_similarity_distribution(test_files, args.sample_size)
    
    if "error" in results:
        print(f"分析失败: {results['error']}")
        return
    
    # 生成报告
    report_path = analyzer.generate_report(results)
    
    # 创建图表
    if args.create_plots:
        analyzer.create_visualizations(results)
    
    print(f"\n分析完成！报告已保存至: {report_path}")
    
    # 建议下一步操作
    optimal_threshold = results["threshold_suggestions"]["optimal_threshold"]["threshold"]
    print(f"\n建议: 将 CONFIG.SIMILARITY_THRESHOLD 设置为 {optimal_threshold:.3f}")

if __name__ == "__main__":
    main()