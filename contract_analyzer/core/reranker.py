import pickle
import numpy as np
from .feature_extractor import extract_features_from_json_v2

class XGBoostReranker:
    def __init__(self, model_path: str = r"G:\safe\longchain_RAG\xgb_filter_secondary2.pkl",
                 threshold_path: str = "best_threshold.txt"):
        with open(model_path, "rb") as f:
            self.model = pickle.load(f)
        # 如果存在阈值文件可以读取，否则使用固定值
        self.threshold = 0.55
        self.feature_names = [
            'call_count', 'event_count', 'max_depth', 'unique_contracts',
            'has_transfer', 'has_approve', 'has_flashloan', 'has_delegatecall',
            'has_selfdestruct', 'has_high_value', 'total_value_log', 'max_value_log',
            'unique_signatures', 'unknown_sig_count'
        ]

    def predict_proba(self, json_str: str) -> float:
        feat = extract_features_from_json_v2(json_str)
        feat[10] = np.log1p(feat[10])   # total_value
        feat[11] = np.log1p(feat[11])   # max_value
        X = np.array(feat).reshape(1, -1)
        prob = self.model.predict_proba(X)[0, 1]
        return prob

    def should_use_rag(self, json_str: str) -> bool:
        prob = self.predict_proba(json_str)
        return prob >= self.threshold

_XGB_RERANKER = None

def get_xgb_reranker(model_path: str = r"G:\safe\longchain_RAG\xgb_filter_secondary2.pkl") -> XGBoostReranker:
    global _XGB_RERANKER
    if _XGB_RERANKER is None:
        _XGB_RERANKER = XGBoostReranker(model_path)
    return _XGB_RERANKER