import numpy as np
from typing import List, Dict, Any, Tuple
from dataclasses import dataclass
from enum import Enum
from scipy import stats


class LabelType(Enum):
    ATTACK = "attack"
    BENIGN = "benign"


@dataclass
class ConfusionMatrix:
    true_positives: int = 0
    true_negatives: int = 0
    false_positives: int = 0
    false_negatives: int = 0
    
    @property
    def total_samples(self) -> int:
        return self.true_positives + self.true_negatives + self.false_positives + self.false_negatives
    
    def to_dict(self) -> Dict[str, int]:
        return {
            "tp": self.true_positives,
            "tn": self.true_negatives,
            "fp": self.false_positives,
            "fn": self.false_negatives
        }


class StatisticalMetrics:
    
    @staticmethod
    def compute_classification_metrics(
        results: List[Dict[str, Any]], 
        beta: float = 1.0
    ) -> Dict[str, float]:
        
        confusion_matrix = StatisticalMetrics._compute_confusion_matrix(results)
        
        if confusion_matrix.total_samples == 0:
            return {"error": "No valid samples for classification analysis"}
        
        # Core binary classification metrics
        primary_metrics = StatisticalMetrics._compute_primary_metrics(confusion_matrix, beta)
        
        # Class-specific metrics
        class_metrics = StatisticalMetrics._compute_class_specific_metrics(confusion_matrix, beta)
        
        # Statistical significance testing
        significance_metrics = StatisticalMetrics._compute_statistical_significance(confusion_matrix)
        
        return {
            **primary_metrics,
            **class_metrics,
            **significance_metrics,
            **confusion_matrix.to_dict(),
            "total_samples": confusion_matrix.total_samples,
            "prevalence": confusion_matrix.true_positives / confusion_matrix.total_samples
        }
    
    @staticmethod
    def _compute_confusion_matrix(results: List[Dict[str, Any]]) -> ConfusionMatrix:
        matrix = ConfusionMatrix()
        
        for result in results:
            predicted = result.get("predicted_label", "").strip().lower()
            expected = result.get("expected_label", "").strip().lower()
            
            if expected == LabelType.ATTACK.value:
                if predicted == LabelType.ATTACK.value:
                    matrix.true_positives += 1
                elif predicted == LabelType.BENIGN.value:
                    matrix.false_negatives += 1
            elif expected == LabelType.BENIGN.value:
                if predicted == LabelType.BENIGN.value:
                    matrix.true_negatives += 1
                elif predicted == LabelType.ATTACK.value:
                    matrix.false_positives += 1
        
        return matrix
    
    @staticmethod
    def _compute_primary_metrics(matrix: ConfusionMatrix, beta: float) -> Dict[str, float]:
        eps = 1e-10  # Numerical stability constant
        
        # Accuracy with Laplace smoothing
        accuracy = (matrix.true_positives + matrix.true_negatives + 1) / (matrix.total_samples + 2)
        
        # Precision, Recall with stability
        precision = (matrix.true_positives + eps) / (matrix.true_positives + matrix.false_positives + eps)
        recall = (matrix.true_positives + eps) / (matrix.true_positives + matrix.false_negatives + eps)
        
        # F-beta score with harmonic mean
        beta_squared = beta ** 2
        f_beta = (1 + beta_squared) * (precision * recall) / (beta_squared * precision + recall + eps)
        
        # Matthews Correlation Coefficient (MCC)
        numerator = (matrix.true_positives * matrix.true_negatives - 
                    matrix.false_positives * matrix.false_negatives)
        denominator = np.sqrt(
            (matrix.true_positives + matrix.false_positives) *
            (matrix.true_positives + matrix.false_negatives) *
            (matrix.true_negatives + matrix.false_positives) *
            (matrix.true_negatives + matrix.false_negatives) + eps
        )
        mcc = numerator / denominator
        
        return {
            "accuracy": float(accuracy),
            "precision": float(precision),
            "recall": float(recall),
            f"f{beta}_score": float(f_beta),
            "mcc": float(mcc)
        }
    
    @staticmethod
    def _compute_class_specific_metrics(matrix: ConfusionMatrix, beta: float) -> Dict[str, float]:
        eps = 1e-10
        
        # Attack class metrics (positive class)
        attack_precision = (matrix.true_positives + eps) / (matrix.true_positives + matrix.false_positives + eps)
        attack_recall = (matrix.true_positives + eps) / (matrix.true_positives + matrix.false_negatives + eps)
        beta_squared = beta ** 2
        attack_f_beta = (1 + beta_squared) * (attack_precision * attack_recall) / (beta_squared * attack_precision + attack_recall + eps)
        
        # Benign class metrics (negative class)
        benign_precision = (matrix.true_negatives + eps) / (matrix.true_negatives + matrix.false_negatives + eps)
        benign_recall = (matrix.true_negatives + eps) / (matrix.true_negatives + matrix.false_positives + eps)
        benign_f_beta = (1 + beta_squared) * (benign_precision * benign_recall) / (beta_squared * benign_precision + benign_recall + eps)
        
        return {
            "attack_precision": float(attack_precision),
            "attack_recall": float(attack_recall),
            f"attack_f{beta}_score": float(attack_f_beta),
            "benign_precision": float(benign_precision),
            "benign_recall": float(benign_recall),
            f"benign_f{beta}_score": float(benign_f_beta)
        }
    
    @staticmethod
    def _compute_statistical_significance(matrix: ConfusionMatrix) -> Dict[str, float]:
        if matrix.total_samples < 30:
            return {"statistical_power": 0.0, "confidence_interval_width": 1.0}
        
        # Compute confidence intervals using Wilson score
        p = matrix.true_positives / matrix.total_samples
        n = matrix.total_samples
        z = 1.96  # 95% confidence
        
        wilson_center = (p + z*z/(2*n)) / (1 + z*z/n)
        wilson_margin = z * np.sqrt(p*(1-p)/n + z*z/(4*n*n)) / (1 + z*z/n)
        
        lower_bound = wilson_center - wilson_margin
        upper_bound = wilson_center + wilson_margin
        
        return {
            "confidence_interval_95_lower": max(0.0, float(lower_bound)),
            "confidence_interval_95_upper": min(1.0, float(upper_bound)),
            "confidence_interval_width": float(upper_bound - lower_bound)
        }
    
    @staticmethod
    def compute_performance_distribution(
        processing_times: List[float]
    ) -> Dict[str, float]:
        if not processing_times:
            return {}
        
        times_array = np.array(processing_times)
        
        trim_proportion = 0.1
        trimmed_mean = stats.trim_mean(times_array, trim_proportion)
        
        percentiles = [25, 50, 75, 90, 95, 99]
        percentile_values = np.percentile(times_array, percentiles)
        
        skewness = float(stats.skew(times_array))
        kurtosis = float(stats.kurtosis(times_array))
        
        cv = float(np.std(times_array) / np.mean(times_array)) if np.mean(times_array) > 0 else 0
        
        metrics = {
            "trimmed_mean": float(trimmed_mean),
            "median": float(np.median(times_array)),
            "std_dev": float(np.std(times_array)),
            "coeff_variation": float(cv),
            "skewness": skewness,
            "kurtosis": kurtosis,
            "total_time": float(np.sum(times_array)),
            "sample_count": len(times_array)
        }
        
        # Add percentile metrics
        for p, val in zip(percentiles, percentile_values):
            metrics[f"p{p}_time"] = float(val)
        
        return metrics
    
    @staticmethod
    def compute_similarity_distribution(
        similarity_scores: List[float]
    ) -> Dict[str, float]:
        if not similarity_scores:
            return {}
        
        scores_array = np.array(similarity_scores)
        
        moments = {
            "mean": float(np.mean(scores_array)),
            "median": float(np.median(scores_array)),
            "variance": float(np.var(scores_array)),
            "std_dev": float(np.std(scores_array)),
            "range": float(np.max(scores_array) - np.min(scores_array))
        }
        
        q1, q3 = np.percentile(scores_array, [25, 75])
        iqr = q3 - q1
        
        lower_bound = q1 - 1.5 * iqr
        upper_bound = q3 + 1.5 * iqr
        
        outliers = np.sum((scores_array < lower_bound) | (scores_array > upper_bound))
        
        moments.update({
            "interquartile_range": float(iqr),
            "outlier_count": int(outliers),
            "outlier_proportion": float(outliers / len(scores_array)),
            "normalized_range": moments["range"] / (moments["mean"] + 1e-10)
        })
        
        return moments