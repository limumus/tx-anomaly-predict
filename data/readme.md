 `history_knowledge.csv` ： RAG 组件使用的历史攻击知识库。包含过往 DeFi 攻击事件的攻击类型。 

 `defiattack_original_multimodel_728.csv` ： 在完整 DeFiAttackBench 数据集（728 条样本）上的原始多模型评估结果。**未加入** XGBoost 后处理器。 

 `defiattack_with_xgboost_728.csv` ： 在相同 728 条 DeFiAttackBench 数据集上，加入 XGBoost 分类器后的更新评估结果。这是论文主结果对比（Table 1）所使用的数据，包含 Kimi_k3、Deepseek-v4-pro、GPT-5.6-luna、Qwen3_8B 等模型。 其中Qwen3_8B属于测试模型仅供参考。

 `ablation_study_kimi_k3.csv` ： 以 **Kimi_k3** 为完整 TxHunt 系统的消融实验结果。报告了完整系统(参考defiattack_with_xgboost_728.csv中的kimi)、去除 XGBoost、去除两阶段检索、去除 RAG 等不同配置下的性能。 
