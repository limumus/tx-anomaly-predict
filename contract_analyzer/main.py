import os
import traceback
from typing import Dict, Any, Optional, List
from dataclasses import dataclass

from config.settings import CONFIG
from core.embeddings import JinaEmbedding
from core.vector_store import load_or_create_vector_store
from models.ernie_model import BaiduErnieAI, ErnieLLMWrapper
from core.middleware import IntelligentExclusionSystem
from utils.debug_utils import StateManager, get_state_manager
from core.reranker import get_xgb_reranker
from core.message_manager import MessageManager
from utils.file_utils import load_system_input


@dataclass
class AnalysisConfig:
    """分析管道配置"""
    persist_dir: str = CONFIG.get("persist_dir", "./vector_storage")
    csv_path: str = CONFIG.get("csv_path", "./semantic_mappings.csv")
    similarity_threshold: float = CONFIG.get("similarity_threshold", 0.25)
    enable_monitoring: bool = True


class ContractAnalyzer:
    """
    智能合约攻击检测主分析器（唯一核心入口）
    集成：向量检索 + 排除过滤 + XGBoost二次验证 + RAG/直出提示 + LLM推理
    """
    
    SIMILARITY_SEARCH_K = 5
    MIN_DOCS_FOR_RAG = 1
    
    def __init__(self, config: AnalysisConfig = None):
        self.config = config or AnalysisConfig()
        
        # 1. 初始化全局状态管理器（控制 RAG 开关）
        self.skip_rag_manager: StateManager = get_state_manager()
        self.skip_rag_manager.reset_state()
        
        # 2. 初始化嵌入模型与向量库
        self.embedding = JinaEmbedding()
        self.vector_store = load_or_create_vector_store(
            self.config.persist_dir, 
            self.embedding
        )
        print(f"✅ 向量库加载成功，共 {self.vector_store._collection.count()} 个向量")
        
        # 3. 初始化 ERNIE 大模型
        self.ernie_ai = BaiduErnieAI()
        self.llm = ErnieLLMWrapper(self.ernie_ai)
        print("✅ ERNIE 大模型包装器初始化完成")
        
        # 4. 初始化 XGBoost 二次验证器（若模型路径不存在会降级）
        try:
            self.reranker = get_xgb_reranker()
            print(f"✅ XGBoost 验证器加载成功，阈值: {self.reranker.threshold}")
        except Exception as e:
            print(f"⚠️ XGBoost 加载失败，将跳过二次验证: {e}")
            self.reranker = None
        
        # 5. 初始化排除中间件（防止检索到同文件名噪音）
        try:
            self.exclusion_middleware = IntelligentExclusionSystem("exclusion_middleware_fixed")
            print("✅ 排除中间件加载成功")
        except Exception as e:
            print(f"⚠️ 排除中间件加载失败，将跳过文件过滤: {e}")
            self.exclusion_middleware = None

    def analyze(
        self, 
        query: str, 
        system_input_path: Optional[str] = None,
        system_input_text: Optional[str] = None,
        verbose: bool = False
    ) -> Dict[str, Any]:
        """
        主分析接口
        
        Args:
            query: 分析问句（如 "请分析该交易是否为攻击"）
            system_input_path: 待分析交易 JSON 文件路径
            system_input_text: 直接传入的交易 JSON 字符串（二选一）
            verbose: 是否打印详细日志
            
        Returns:
            包含 answer, used_rag, xgb_prob, similarity_info 等的字典
        """
        try:
            if verbose:
                self._print_start_log(query, system_input_path)
            
            # 第一步：准备输入数据
            system_input = self._prepare_system_input(system_input_path, system_input_text)
            if not system_input:
                return {"error": "无法读取系统输入（system_input 为空）", "status": "failed"}
            
            # 第二步：语义检索 + 过滤（显式传递路径）
            retrieved_docs, similarity_scores = self._retrieve_and_filter(
                query_text=system_input,
                file_path=system_input_path   # ✅ 显式传递路径
            )
            
            # 第三步：XGBoost 二次验证（决定是否真正使用 RAG）
            use_rag, xgb_prob = self._decide_rag_strategy(system_input, retrieved_docs)
            
            # 第四步：构建提示词并调用 LLM
            answer = self._call_llm(
                query=query,
                system_input=system_input,
                retrieved_docs=retrieved_docs if use_rag else [],
                use_rag=use_rag,
                xgb_prob=xgb_prob
            )
            
            # 第五步：打包返回结果
            result = {
                "answer": answer,
                "used_rag": use_rag,
                "xgb_prob": xgb_prob,
                "retrieved_docs_count": len(retrieved_docs) if use_rag else 0,
                "similarity_scores": similarity_scores,
                "analysis_strategy": "rag" if use_rag else "direct",
                "status": "success"
            }
            
            if verbose:
                self._print_end_log(result)
            
            return result
            
        except Exception as e:
            print(f"❌ 分析管道致命错误: {str(e)}")
            if verbose:
                traceback.print_exc()
            return {
                "error": f"分析失败: {str(e)}",
                "status": "failed",
                "used_rag": False,
                "xgb_prob": None
            }

    # ==================== 私有方法（各步骤实现） ====================
    
    def _prepare_system_input(self, path: Optional[str], text: Optional[str]) -> str:
        """加载并序列化交易 JSON"""
        if path:
            return load_system_input(path)
        elif text:
            return text
        return ""

    def _retrieve_and_filter(self, query_text: str, file_path: Optional[str]) -> (List[Any], List[float]):
        """
        执行语义检索，并应用排除规则 + 相似度阈值过滤
        参数:
            query_text: 用于检索的文本（通常是 system_input）
            file_path: 当前分析的文件路径（用于排除中间件过滤）
        返回:
            (过滤后的文档列表, 对应的相似度分数列表)
        """
        # 1. 执行向量检索（默认取 Top-K）
        docs_with_scores = self.vector_store.similarity_search_with_score(
            query_text,
            k=self.SIMILARITY_SEARCH_K
        )
        all_docs = [doc for doc, _ in docs_with_scores]
        all_scores = [score for _, score in docs_with_scores]
        
        print(f"🔍 初始检索到 {len(all_docs)} 个候选文档")
        
        # 2. 应用排除中间件（如果可用且传入了文件路径）
        filtered_docs = all_docs
        if self.exclusion_middleware and file_path:
            filtered_docs = self.exclusion_middleware.filter_documents_by_pattern(
                filtered_docs, 
                file_path
            )
            print(f"🚫 排除中间件过滤后剩余 {len(filtered_docs)} 个文档")
        elif self.exclusion_middleware and not file_path:
            print("⚠️ 未提供文件路径，跳过排除中间件过滤")
        
        # 3. 应用相似度阈值过滤（距离越小越相似）
        threshold = self.config.similarity_threshold
        final_docs = []
        final_scores = []
        doc_score_map = {id(doc): score for doc, score in zip(all_docs, all_scores)}
        for doc in filtered_docs:
            score = doc_score_map.get(id(doc), 1.0)  # 若找不到则给大值
            if score <= threshold:
                final_docs.append(doc)
                final_scores.append(score)
                # 增强元数据
                if hasattr(doc, 'metadata'):
                    doc.metadata['similarity_score'] = float(score)
        
        print(f"📊 相似度阈值 ({threshold}) 过滤后剩余 {len(final_docs)} 个文档")
        return final_docs, final_scores

    def _decide_rag_strategy(self, system_input: str, retrieved_docs: List) -> (bool, Optional[float]):
        """
        利用 XGBoost 对当前交易进行二次验证，决定是否使用 RAG。
        返回: (是否使用 RAG, XGBoost 概率值)
        """
        # 如果文档数不足，直接放弃 RAG
        if len(retrieved_docs) < self.MIN_DOCS_FOR_RAG:
            print("⚠️ 检索文档不足，放弃 RAG，采用直出模式")
            self.skip_rag_manager.set_skip_rag(True)
            return False, None
        
        # 如果 XGBoost 不可用，默认使用 RAG（但保留警告）
        if self.reranker is None:
            print("⚠️ XGBoost 不可用，默认启用 RAG")
            self.skip_rag_manager.set_skip_rag(False)
            return True, None
        
        # 执行 XGBoost 预测
        try:
            prob = self.reranker.predict_proba(system_input)
            print(f"🎯 XGBoost 攻击概率: {prob:.4f} (阈值: {self.reranker.threshold})")
            
            if prob < self.reranker.threshold:
                print("🚫 XGBoost 验证失败（概率过低），放弃 RAG，强制直出模式")
                self.skip_rag_manager.set_skip_rag(True)
                return False, prob
            else:
                print("✅ XGBoost 验证通过，保留 RAG 上下文")
                self.skip_rag_manager.set_skip_rag(False)
                return True, prob
        except Exception as e:
            print(f"⚠️ XGBoost 推理异常: {e}，降级为默认启用 RAG")
            self.skip_rag_manager.set_skip_rag(False)
            return True, None

    def _call_llm(
        self, 
        query: str, 
        system_input: str, 
        retrieved_docs: List, 
        use_rag: bool,
        xgb_prob: Optional[float]
    ) -> str:
        """
        构建最终提示词并调用 ERNIE 大模型。
        使用 MessageManager 统一管理提示模板、压缩和 XGBoost 提示注入。
        """
        # 1. 若使用 RAG，构建参考文本（截断长文本）
        reference_text = ""
        if use_rag and retrieved_docs:
            segments = []
            for i, doc in enumerate(retrieved_docs[:3]):  # 最多取前 3 个
                content = doc.page_content[:500]  # 截断至 500 字符
                source = doc.metadata.get('source_file', 'Unknown') if hasattr(doc, 'metadata') else 'Unknown'
                segments.append(f"[文档 {i+1}] 来源: {source}\n内容: {content}...")
            reference_text = "\n\n".join(segments)
        
        # 2. 通过 MessageManager 构建最终消息（含压缩、XGBoost 提示）
        messages = MessageManager.construct_analysis_messages(
            query=query,
            system_input=system_input,
            reference_text=reference_text,
            skip_rag=not use_rag,      # MessageManager 中的 skip_rag 是“是否跳过”
            prompt_type="rag" if use_rag else "direct",
            xgb_prob=xgb_prob
        )
        
        # 3. 提取用户消息内容并调用 ERNIE
        user_message = messages[0]["content"]
        print(f"📝 提示词长度: {len(user_message)} 字符")
        
        # 4. 通过 ErnieLLMWrapper 调用（自带重试和错误处理）
        llm_input = {
            "query": query,
            "system_input": system_input,
            "reference_text": reference_text,
            "skip_rag": not use_rag,
            "prompt_type": "rag" if use_rag else "direct",
            "xgb_prob": xgb_prob
        }
        response = self.llm.invoke(llm_input)
        return response.content if hasattr(response, 'content') else str(response)

    # ==================== 日志辅助方法 ====================
    
    def _print_start_log(self, query: str, path: Optional[str]):
        print("\n" + "=" * 60)
        print("🚀 智能合约攻击检测管道启动")
        print(f"📌 查询: {query[:50]}...")
        print(f"📂 输入源: {path or '直接文本'}")
        print("=" * 60 + "\n")
    
    def _print_end_log(self, result: Dict):
        print("\n" + "=" * 60)
        print("✅ 分析完成")
        print(f"📊 策略: {result['analysis_strategy']}")
        print(f"📄 检索文档数: {result['retrieved_docs_count']}")
        if result.get('xgb_prob') is not None:
            print(f"🤖 XGBoost 概率: {result['xgb_prob']:.4f}")
        print(f"💬 回答预览: {result['answer'][:100]}...")
        print("=" * 60 + "\n")


# ==================== 全局便捷函数 ====================
def analyze_contract(
    query: str,
    system_input_path: Optional[str] = None,
    system_input_text: Optional[str] = None,
    verbose: bool = True
) -> Dict[str, Any]:
    """
    对外暴露的便捷分析函数（与旧 API 保持一致）
    """
    analyzer = ContractAnalyzer()
    return analyzer.analyze(query, system_input_path, system_input_text, verbose)


# ==================== 命令行入口 ====================
if __name__ == "__main__":
    # 演示用法（请替换为实际路径）
    TEST_QUERY = "请分析该交易是否存在攻击行为"
    TEST_PATH = "path/to/your/test_transaction.json"  # 请替换为实际 JSON 文件路径
    
    print("⚠️ 请确保 TEST_PATH 指向一个有效的交易 JSON 文件")
    
    # 若文件存在则执行
    if os.path.exists(TEST_PATH):
        result = analyze_contract(
            query=TEST_QUERY,
            system_input_path=TEST_PATH,
            verbose=True
        )
        print("\n📦 完整返回结果:")
        print(f"状态: {result.get('status')}")
        print(f"最终答案: {result.get('answer')}")
    else:
        print(f"❌ 测试文件不存在: {TEST_PATH}")
        print("请修改 TEST_PATH 变量后重试")