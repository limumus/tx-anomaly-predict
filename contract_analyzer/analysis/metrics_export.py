import os
import json
import pandas as pd
import numpy as np
from typing import List, Dict, Any, Optional
from datetime import datetime
from dataclasses import dataclass, asdict
from pathlib import Path
from enum import Enum


class ExportFormat(Enum):
    JSON = "json"
    MARKDOWN = "markdown"
    CSV = "csv"
    EXECUTIVE = "executive"


class ConfidenceLevel(Enum):
    """Statistical confidence levels"""
    CONFIDENCE_95 = 0.95
    CONFIDENCE_99 = 0.99
    CONFIDENCE_90 = 0.90


@dataclass
class ExportConfiguration:
    output_directory: str = "./metrics_exports"
    enable_visualizations: bool = True
    sample_retention_limit: int = 100
    confidence_level: ConfidenceLevel = ConfidenceLevel.CONFIDENCE_95
    bootstrap_iterations: int = 1000
    enable_error_analysis: bool = True
    generate_executive_summary: bool = True


class MetricsExporter:
    DEFAULT_OUTPUT_DIR = "./metrics_exports"
    VISUALIZATION_ENABLED = True
    SAMPLE_RETENTION_LIMIT = 100
    BOOTSTRAP_ITERATIONS = 1000
    
    def __init__(self, config: Optional[ExportConfiguration] = None):

        self.config = config or ExportConfiguration()
        self._initialize_export_infrastructure()
    
    def _initialize_export_infrastructure(self):

        base_dir = Path(self.config.output_directory)
        base_dir.mkdir(parents=True, exist_ok=True)
        
        self.directories = {
            "json_exports": base_dir / "json_exports",
            "visualizations": base_dir / "visualizations",
            "tabular_data": base_dir / "tabular_data",
            "executive_summaries": base_dir / "executive_summaries",
            "statistical_analysis": base_dir / "statistical_analysis"
        }
        
        for directory in self.directories.values():
            directory.mkdir(exist_ok=True)
    
    def export_comprehensive_analysis(
        self,
        evaluation_results: List[Dict[str, Any]],
        computed_metrics: Dict[str, float],
        analysis_title: str = "ModelEvaluation"
    ) -> Dict[ExportFormat, str]:

        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        export_identifier = f"{analysis_title}_{timestamp}"
        
        analysis_structure = self._construct_analysis_hierarchy(
            evaluation_results, 
            computed_metrics, 
            analysis_title
        )
        
        export_paths = {
            ExportFormat.JSON: self._export_json_analysis(
                analysis_structure, 
                export_identifier
            ),
            ExportFormat.MARKDOWN: self._generate_markdown_summary(
                analysis_structure, 
                export_identifier
            ),
            ExportFormat.CSV: self._export_tabular_data(
                evaluation_results, 
                export_identifier
            )
        }
        
        if self.config.enable_error_analysis:
            statistical_report = self._perform_statistical_analysis(
                evaluation_results, 
                computed_metrics
            )
            export_paths[ExportFormat.EXECUTIVE] = self._export_statistical_report(
                statistical_report, 
                export_identifier
            )
        
        if self.config.enable_visualizations:
            visualization_paths = self._generate_analysis_visualizations(
                evaluation_results, 
                computed_metrics, 
                export_identifier
            )
            export_paths.update(visualization_paths)
        
        self._log_export_completion(export_paths)
        return export_paths
    
    def _construct_analysis_hierarchy(
        self,
        results: List[Dict[str, Any]],
        metrics: Dict[str, float],
        title: str
    ) -> Dict[str, Any]:

        confidence_metrics = self._calculate_statistical_confidence(
            results, 
            metrics
        )
        

        stratified_samples = self._perform_stratified_sampling(results)
        error_patterns = self._analyze_error_patterns(results)
        
        return {
            "metadata": {
                "analysis_title": title,
                "export_timestamp": datetime.now().isoformat(),
                "total_samples": len(results),
                "analysis_version": "2.0",
                "configuration": asdict(self.config)
            },
            "performance_metrics": {
                "core_indicators": self._categorize_metrics(metrics),
                "statistical_confidence": confidence_metrics,
                "performance_distribution": self._analyze_performance_distribution(results)
            },
            "detailed_analysis": {
                "stratified_samples": stratified_samples,
                "error_analysis": error_patterns,
                "data_characteristics": self._analyze_data_characteristics(results)
            }
        }
    
    def _calculate_statistical_confidence(
        self,
        results: List[Dict[str, Any]],
        metrics: Dict[str, float]
    ) -> Dict[str, Any]:

        if len(results) < self.MINIMUM_SAMPLES_FOR_CONFIDENCE:
            return {"insufficient_samples": True}
        
        outcomes = self._extract_classification_outcomes(results)
        
        bootstrap_estimates = self._perform_bootstrap_analysis(
            outcomes, 
            self.config.bootstrap_iterations
        )
        
        alpha = 1 - self.config.confidence_level.value
        lower_percentile = 100 * alpha / 2
        upper_percentile = 100 * (1 - alpha / 2)
        
        lower_bound = np.percentile(bootstrap_estimates, lower_percentile)
        upper_bound = np.percentile(bootstrap_estimates, upper_percentile)
        
        return {
            "confidence_level": self.config.confidence_level.value,
            "accuracy_ci": [float(lower_bound), float(upper_bound)],
            "interval_width": float(upper_bound - lower_bound),
            "bootstrap_samples": self.config.bootstrap_iterations
        }
    
    def _perform_stratified_sampling(
        self, 
        results: List[Dict[str, Any]]
    ) -> Dict[str, List[Dict[str, Any]]]:

        if not results:
            return {}
        
        df = pd.DataFrame(results)
        stratified = {}
        
        if "is_correct" in df.columns:
            correct_mask = df["is_correct"] == True
            stratified["correct_predictions"] = df[correct_mask].head(
                self.config.sample_retention_limit // 2
            ).to_dict('records')
            
            incorrect_mask = df["is_correct"] == False
            stratified["incorrect_predictions"] = df[incorrect_mask].head(
                self.config.sample_retention_limit // 2
            ).to_dict('records')
        
        if "predicted_label" in df.columns:
            for label in df["predicted_label"].unique():
                label_samples = df[df["predicted_label"] == label].head(5).to_dict('records')
                stratified[f"predicted_{label}"] = label_samples
        
        return stratified
    
    def _analyze_error_patterns(
        self, 
        results: List[Dict[str, Any]]
    ) -> Dict[str, Any]:

        if not results:
            return {}
        
        df = pd.DataFrame(results)
        
        if all(col in df.columns for col in ["predicted_label", "expected_label"]):
            misclassified = df[df["predicted_label"] != df["expected_label"]]
            
            confusion_matrix = pd.crosstab(
                df["expected_label"], 
                df["predicted_label"]
            ).to_dict()
            
            return {
                "misclassification_count": len(misclassified),
                "error_rate": len(misclassified) / len(df),
                "confusion_matrix": confusion_matrix,
                "common_error_patterns": self._identify_common_errors(misclassified)
            }
        
        return {}
    
    def _categorize_metrics(
        self, 
        metrics: Dict[str, float]
    ) -> Dict[str, Dict[str, float]]:
 
        categories = {
            "classification": ["accuracy", "precision", "recall", "f1_score", "mcc"],
            "performance": ["avg_processing_time", "median_processing_time", "p95_processing_time"],
            "similarity": ["mean_similarity", "median_similarity", "std_similarity"]
        }
        
        categorized = {}
        for category, metric_keys in categories.items():
            category_metrics = {
                key: metrics[key] 
                for key in metric_keys 
                if key in metrics
            }
            if category_metrics:
                categorized[category] = category_metrics
        
        return categorized
    
    def _export_json_analysis(
        self, 
        analysis: Dict[str, Any], 
        identifier: str
    ) -> str:

        export_path = self.directories["json_exports"] / f"{identifier}.json"
        
        with open(export_path, 'w', encoding='utf-8') as f:
            json.dump(analysis, f, ensure_ascii=False, indent=2)
        
        return str(export_path)
    
    def _generate_markdown_summary(
        self, 
        analysis: Dict[str, Any], 
        identifier: str
    ) -> str:

        markdown_path = self.directories["executive_summaries"] / f"{identifier}.md"
        
        summary = self._create_markdown_content(analysis)
        
        with open(markdown_path, 'w', encoding='utf-8') as f:
            f.write(summary)
        
        return str(markdown_path)
    
    def _create_markdown_content(self, analysis: Dict[str, Any]) -> str:

        metadata = analysis["metadata"]
        metrics = analysis["performance_metrics"]
        
        content = [
            f"# {metadata['analysis_title']}",
            "",
            f"**Analysis Timestamp**: {metadata['export_timestamp']}",
            f"**Total Samples**: {metadata['total_samples']:,}",
            "",
            "## Performance Summary"
        ]
        
        if "core_indicators" in metrics:
            for category, category_metrics in metrics["core_indicators"].items():
                content.append(f"\n### {category.title()} Metrics")
                for metric_name, value in category_metrics.items():
                    if isinstance(value, float):
                        content.append(f"- **{metric_name.replace('_', ' ').title()}**: {value:.4f}")
                    else:
                        content.append(f"- **{metric_name.replace('_', ' ').title()}**: {value}")
        
        if "statistical_confidence" in metrics:
            ci = metrics["statistical_confidence"]
            if "accuracy_ci" in ci:
                lower, upper = ci["accuracy_ci"]
                content.append(f"\n### Statistical Analysis")
                content.append(f"- **{ci['confidence_level']*100:.0f}% Confidence Interval**: [{lower:.4f}, {upper:.4f}]")
                content.append(f"- **Interval Width**: {ci['interval_width']:.4f}")
        
        return "\n".join(content)
    
    def _export_tabular_data(
        self, 
        results: List[Dict[str, Any]], 
        identifier: str
    ) -> str:

        if not results:
            return ""
        
        csv_path = self.directories["tabular_data"] / f"{identifier}.csv"
        
        df = pd.DataFrame(results)
        df.to_csv(csv_path, index=False, encoding='utf-8')
        
        return str(csv_path)
    
    def _perform_statistical_analysis(
        self,
        results: List[Dict[str, Any]],
        metrics: Dict[str, float]
    ) -> Dict[str, Any]:

        return {
            "analysis_timestamp": datetime.now().isoformat(),
            "sample_characteristics": {
                "total_samples": len(results),
                "recommended_minimum": self.MINIMUM_SAMPLES_FOR_CONFIDENCE,
                "sufficient_for_analysis": len(results) >= self.MINIMUM_SAMPLES_FOR_CONFIDENCE
            },
            "statistical_recommendations": self._generate_statistical_recommendations(results)
        }
    
    def _export_statistical_report(
        self, 
        report: Dict[str, Any], 
        identifier: str
    ) -> str:

        report_path = self.directories["statistical_analysis"] / f"{identifier}_statistics.json"
        
        with open(report_path, 'w', encoding='utf-8') as f:
            json.dump(report, f, ensure_ascii=False, indent=2)
        
        return str(report_path)
    
    def _generate_analysis_visualizations(
        self,
        results: List[Dict[str, Any]],
        metrics: Dict[str, float],
        identifier: str
    ) -> Dict[str, str]:
        
        return {}
    
    def _log_export_completion(self, export_paths: Dict):

        print("Metrics export completed successfully:")
        for export_type, path in export_paths.items():
            if path:  # Only log non-empty paths
                print(f"  {export_type.value if isinstance(export_type, ExportFormat) else export_type}: {path}")
    
    # Utility methods
    MINIMUM_SAMPLES_FOR_CONFIDENCE = 30
    
    def _extract_classification_outcomes(
        self, 
        results: List[Dict[str, Any]]
    ) -> np.ndarray:

        outcomes = []
        for result in results:
            if result.get("predicted_label") == result.get("expected_label"):
                outcomes.append(1)
            else:
                outcomes.append(0)
        return np.array(outcomes)
    
    def _perform_bootstrap_analysis(
        self, 
        outcomes: np.ndarray, 
        iterations: int
    ) -> np.ndarray:

        bootstrap_estimates = []
        n = len(outcomes)
        
        for _ in range(iterations):
            sample = np.random.choice(outcomes, size=n, replace=True)
            bootstrap_estimates.append(np.mean(sample))
        
        return np.array(bootstrap_estimates)
    
    def _identify_common_errors(
        self, 
        misclassified: pd.DataFrame
    ) -> List[Dict[str, Any]]:

        if len(misclassified) == 0:
            return []
        
        error_counts = misclassified.groupby(["expected_label", "predicted_label"]).size()
        top_errors = error_counts.nlargest(5).to_dict()
        
        return [
            {"expected": expected, "predicted": predicted, "count": count}
            for (expected, predicted), count in top_errors.items()
        ]
    
    def _analyze_performance_distribution(
        self, 
        results: List[Dict[str, Any]]
    ) -> Dict[str, Any]:

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
            "statistics": {
                "mean": float(np.mean(times_array)),
                "median": float(np.median(times_array)),
                "std": float(np.std(times_array)),
                "p95": float(np.percentile(times_array, 95))
            },
            "sample_count": len(times)
        }
    
    def _analyze_data_characteristics(
        self, 
        results: List[Dict[str, Any]]
    ) -> Dict[str, Any]:

        if not results:
            return {}
        
        df = pd.DataFrame(results)
        
        characteristics = {
            "column_count": len(df.columns),
            "row_count": len(df),
            "missing_values": df.isnull().sum().to_dict(),
            "data_types": {col: str(dtype) for col, dtype in df.dtypes.items()}
        }
        
        return characteristics
    
    def _generate_statistical_recommendations(
        self, 
        results: List[Dict[str, Any]]
    ) -> List[str]:

        recommendations = []
        
        if len(results) < self.MINIMUM_SAMPLES_FOR_CONFIDENCE:
            recommendations.append(
                f"Increase sample size to at least {self.MINIMUM_SAMPLES_FOR_CONFIDENCE} for reliable statistical analysis"
            )
        
        if len(results) >= 100:
            recommendations.append(
                "Consider implementing cross-validation for more robust performance estimation"
            )
        
        return recommendations