import os
import json
import pandas as pd
import numpy as np
from typing import List, Dict, Any, Optional
from datetime import datetime
from dataclasses import dataclass, asdict
from pathlib import Path
import matplotlib.pyplot as plt
import seaborn as sns


@dataclass
class VisualizationConfig:
    output_dir: str = "./metrics_output"
    enable_visualizations: bool = True
    sample_limit: int = 100
    confidence_level: float = 0.95


class MetricsVisualizer:
    
    def __init__(self, config: Optional[VisualizationConfig] = None):
        self.config = config or VisualizationConfig()
        self._initialize_output_directory()
        
    def _initialize_output_directory(self):
        Path(self.config.output_dir).mkdir(parents=True, exist_ok=True)
        
        # Create subdirectories for different output types
        subdirs = ["json_exports", "visualizations", "tables", "executive_summaries"]
        for subdir in subdirs:
            Path(os.path.join(self.config.output_dir, subdir)).mkdir(exist_ok=True)
    
    def generate_metrics_export(self,
                              results: List[Dict[str, Any]],
                              metrics: Dict[str, float],
                              export_title: str = "ModelEvaluation") -> Dict[str, str]:

        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        base_filename = f"{export_title}_{timestamp}"
        
        export_structure = self._create_export_structure(results, metrics, export_title)
        
        file_paths = {
            "json_export": self._export_to_json(export_structure, base_filename),
            "markdown_summary": self._generate_markdown_summary(export_structure, base_filename),
            "csv_export": self._export_to_csv(results, base_filename)
        }
        
        if self.config.enable_visualizations:
            viz_paths = self._generate_visualizations(results, metrics, base_filename)
            file_paths.update(viz_paths)
        
        executive_summary = self._generate_executive_summary(export_structure)
        summary_path = self._save_executive_summary(executive_summary, base_filename)
        file_paths["executive_summary"] = summary_path
        
        print(f"Metrics export completed:")
        for export_type, path in file_paths.items():
            print(f"  {export_type}: {path}")
        
        return file_paths
    
    def _create_export_structure(self,
                               results: List[Dict[str, Any]],
                               metrics: Dict[str, float],
                               title: str) -> Dict[str, Any]:

        confidence_intervals = self._calculate_confidence_intervals(results, metrics)
        
        stratified_samples = self._create_stratified_samples(results)
        
        return {
            "metadata": {
                "export_title": title,
                "generation_timestamp": datetime.now().isoformat(),
                "version": "1.0",
                "total_samples": len(results)
            },
            "performance_summary": {
                "core_metrics": self._extract_core_metrics(metrics),
                "confidence_intervals": confidence_intervals,
                "statistical_significance": self._calculate_statistical_significance(results)
            },
            "detailed_analysis": {
                "stratified_samples": stratified_samples,
                "error_analysis": self._analyze_errors(results),
                "performance_distribution": self._analyze_performance_distribution(results)
            },
            "raw_data_reference": {
                "sample_count": min(self.config.sample_limit, len(results)),
                "data_schema": self._infer_data_schema(results[0]) if results else {}
            }
        }
    
    def _calculate_confidence_intervals(self,
                                      results: List[Dict[str, Any]],
                                      metrics: Dict[str, float],
                                      n_bootstrap: int = 1000) -> Dict[str, Any]:

        if len(results) < 30:
            return {"insufficient_samples": True}
        
        outcomes = []
        for result in results:
            if result.get("predicted_label") == result.get("expected_label"):
                outcomes.append(1)
            else:
                outcomes.append(0)
        
        outcomes_array = np.array(outcomes)
        bootstrap_metrics = []
        
        for _ in range(n_bootstrap):
            sample = np.random.choice(outcomes_array, size=len(outcomes_array), replace=True)
            bootstrap_metrics.append(np.mean(sample))
        
        alpha = 1 - self.config.confidence_level
        lower = np.percentile(bootstrap_metrics, 100 * alpha / 2)
        upper = np.percentile(bootstrap_metrics, 100 * (1 - alpha / 2))
        
        return {
            "accuracy_ci_lower": float(lower),
            "accuracy_ci_upper": float(upper),
            "ci_width": float(upper - lower),
            "confidence_level": self.config.confidence_level,
            "bootstrap_samples": n_bootstrap
        }
    
    def _create_stratified_samples(self,
                                 results: List[Dict[str, Any]]) -> Dict[str, List[Dict[str, Any]]]:

        if not results:
            return {}
        
        df = pd.DataFrame(results)
        stratified = {}
        
        if "is_correct" in df.columns:
            correct_samples = df[df["is_correct"] == True].head(5).to_dict('records')
            incorrect_samples = df[df["is_correct"] == False].head(5).to_dict('records')
            stratified["correct_predictions"] = correct_samples
            stratified["incorrect_predictions"] = incorrect_samples
        
        if "predicted_label" in df.columns:
            for label in df["predicted_label"].unique():
                label_samples = df[df["predicted_label"] == label].head(3).to_dict('records')
                stratified[f"predicted_{label}"] = label_samples
        
        return stratified
    
    def _analyze_errors(self, results: List[Dict[str, Any]]) -> Dict[str, Any]:

        if not results:
            return {}
        
        df = pd.DataFrame(results)
        error_analysis = {}
        
        if all(col in df.columns for col in ["predicted_label", "expected_label"]):
            error_patterns = df[df["predicted_label"] != df["expected_label"]]
            error_analysis["error_count"] = len(error_patterns)
            error_analysis["error_rate"] = len(error_patterns) / len(df)
            
            confusion_counts = error_patterns.groupby(["expected_label", "predicted_label"]).size().unstack(fill_value=0)
            error_analysis["confusion_patterns"] = confusion_counts.to_dict()
        
        return error_analysis
    
    def _extract_core_metrics(self, metrics: Dict[str, float]) -> Dict[str, float]:

        core_categories = {
            "classification": ["accuracy", "precision", "recall", "f1_score", "mcc"],
            "performance": ["avg_processing_time", "p95_processing_time"],
            "similarity": ["mean_similarity", "median_similarity"]
        }
        
        extracted = {}
        for category, keys in core_categories.items():
            category_metrics = {}
            for key in keys:
                if key in metrics:
                    category_metrics[key] = metrics[key]
            if category_metrics:
                extracted[category] = category_metrics
        
        return extracted
    
    def _export_to_json(self, export_structure: Dict[str, Any], base_filename: str) -> str:
        export_path = os.path.join(
            self.config.output_dir, 
            "json_exports", 
            f"{base_filename}.json"
        )
        
        with open(export_path, 'w', encoding='utf-8') as f:
            json.dump(export_structure, f, ensure_ascii=False, indent=2)
        
        return export_path
    
    def _generate_markdown_summary(self, export_structure: Dict[str, Any], base_filename: str) -> str:
        md_path = os.path.join(
            self.config.output_dir,
            "executive_summaries",
            f"{base_filename}.md"
        )
        
        summary = self._create_markdown_content(export_structure)
        
        with open(md_path, 'w', encoding='utf-8') as f:
            f.write(summary)
        
        return md_path
    
    def _create_markdown_content(self, export_structure: Dict[str, Any]) -> str:
        metadata = export_structure["metadata"]
        performance = export_structure["performance_summary"]
        
        content = f"""# {metadata['export_title']}

## Executive Summary

**Generation Time**: {metadata['generation_timestamp']}
**Total Samples**: {metadata['total_samples']:,}

## Performance Metrics

### Classification Performance
"""
        
        if "classification" in performance["core_metrics"]:
            class_metrics = performance["core_metrics"]["classification"]
            for metric_name, value in class_metrics.items():
                if isinstance(value, float):
                    content += f"- **{metric_name.replace('_', ' ').title()}**: {value:.4f}\n"
                else:
                    content += f"- **{metric_name.replace('_', ' ').title()}**: {value}\n"
        
        if "confidence_intervals" in performance:
            ci = performance["confidence_intervals"]
            if "accuracy_ci_lower" in ci:
                content += f"\n### Statistical Confidence\n"
                content += f"- **{self.config.confidence_level:.0%} CI for Accuracy**: [{ci['accuracy_ci_lower']:.4f}, {ci['accuracy_ci_upper']:.4f}]\n"
                content += f"- **Confidence Interval Width**: {ci['ci_width']:.4f}\n"
        
        details = export_structure["detailed_analysis"]
        if "error_analysis" in details:
            error_info = details["error_analysis"]
            content += f"\n### Error Analysis\n"
            content += f"- **Total Errors**: {error_info.get('error_count', 0)}\n"
            content += f"- **Error Rate**: {error_info.get('error_rate', 0):.2%}\n"
        
        return content
    
    def _export_to_csv(self, results: List[Dict[str, Any]], base_filename: str) -> str:
        if not results:
            return ""
        
        csv_path = os.path.join(
            self.config.output_dir,
            "tables",
            f"{base_filename}.csv"
        )
        
        df = pd.DataFrame(results)
        df.to_csv(csv_path, index=False, encoding='utf-8')
        
        return csv_path
    
    def _generate_visualizations(self,
                               results: List[Dict[str, Any]],
                               metrics: Dict[str, float],
                               base_filename: str) -> Dict[str, str]:

        viz_paths = {}
        

        if len(results) > 0:
            cm_path = self._plot_confusion_matrix(results, base_filename)
            viz_paths["confusion_matrix"] = cm_path
        
        if "processing_time" in str(results):
            perf_path = self._plot_performance_distribution(results, base_filename)
            viz_paths["performance_distribution"] = perf_path
        
        return viz_paths
    
    def _plot_confusion_matrix(self, results: List[Dict[str, Any]], base_filename: str) -> str:

        plot_path = os.path.join(
            self.config.output_dir,
            "visualizations",
            f"{base_filename}_confusion_matrix.png"
        )
        
        plt.figure(figsize=(10, 8))
        plt.title("Confusion Matrix Analysis")
        plt.savefig(plot_path, dpi=300, bbox_inches='tight')
        plt.close()
        
        return plot_path
    
    def _plot_performance_distribution(self, results: List[Dict[str, Any]], base_filename: str) -> str:
        plot_path = os.path.join(
            self.config.output_dir,
            "visualizations",
            f"{base_filename}_performance_distribution.png"
        )
        
        plt.figure(figsize=(10, 6))
        plt.title("Processing Time Distribution")
        plt.savefig(plot_path, dpi=300, bbox_inches='tight')
        plt.close()
        
        return plot_path
    
    def _generate_executive_summary(self, export_structure: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "key_metrics": export_structure["performance_summary"]["core_metrics"],
            "sample_statistics": {
                "total": export_structure["metadata"]["total_samples"],
                "error_rate": export_structure["detailed_analysis"].get("error_analysis", {}).get("error_rate", 0)
            },
            "export_timestamp": export_structure["metadata"]["generation_timestamp"]
        }
    
    def _save_executive_summary(self, summary: Dict[str, Any], base_filename: str) -> str:
        summary_path = os.path.join(
            self.config.output_dir,
            "executive_summaries",
            f"{base_filename}_executive.json"
        )
        
        with open(summary_path, 'w', encoding='utf-8') as f:
            json.dump(summary, f, ensure_ascii=False, indent=2)
        
        return summary_path
    
    def _calculate_statistical_significance(self, results: List[Dict[str, Any]]) -> Dict[str, Any]:
        if len(results) < 20:
            return {"insufficient_data": True}
        
        return {
            "sample_size_adequate": len(results) >= 30,
            "recommended_actions": [
                "Increase sample size for stronger conclusions",
                "Consider cross-validation for stability assessment"
            ]
        }
    
    def _infer_data_schema(self, sample_result: Dict[str, Any]) -> Dict[str, str]:
        schema = {}
        for key, value in sample_result.items():
            schema[key] = type(value).__name__
        return schema
    
    def _analyze_performance_distribution(self, results: List[Dict[str, Any]]) -> Dict[str, Any]:
        if not results:
            return {}
        
        # Extract processing times
        times = []
        for result in results:
            if isinstance(result, dict) and "processing_time" in result:
                time_val = result["processing_time"]
                if isinstance(time_val, (int, float)) and time_val > 0:
                    times.append(time_val)
        
        if not times:
            return {}
        
        times_array = np.array(times)
        
        return {
            "time_statistics": {
                "mean": float(np.mean(times_array)),
                "median": float(np.median(times_array)),
                "std": float(np.std(times_array)),
                "p95": float(np.percentile(times_array, 95))
            },
            "sample_count": len(times)
        }