import chromadb
import numpy as np
from sklearn.manifold import TSNE
import matplotlib.pyplot as plt
import random

# 初始化客户端
client = chromadb.PersistentClient(path="./vector_store_realtime_0")
collection = client.get_collection(name="langchain")

# 获取数据
data = collection.get(include=["embeddings", "documents", "metadatas"])
embeddings = data["embeddings"]
documents = data["documents"]
metadatas = data["metadatas"]
ids = data["ids"]

# 检查嵌入有效性
if embeddings is None or len(embeddings) == 0:
    print("❌ 没有嵌入数据")
    exit()

emb_array = np.array(embeddings)

if np.allclose(emb_array, emb_array[0]):
    print("⚠️ 所有嵌入向量完全相同，嵌入可能未生效")
    exit()

print(f"✅ 成功加载 {len(embeddings)} 个嵌入，维度为 {len(embeddings[0])}")

missing_ids = []
zero_vector_ids = []

for i, emb in enumerate(embeddings):
    if emb is None:
        missing_ids.append(ids[i])
    elif isinstance(emb, list) and all(v == 0 for v in emb):
        zero_vector_ids.append(ids[i])
    elif isinstance(emb, list) and len(emb) == 0:
        missing_ids.append(ids[i])

print(f"✅ 总嵌入数: {len(embeddings)}")
print(f"❌ 缺失嵌入数: {len(missing_ids)}")
print(f"⚠️ 全零嵌入数: {len(zero_vector_ids)}")

if missing_ids:
    print("\n❌ 以下 ID 没有嵌入:")
    for mid in missing_ids:
        print(f" - {mid}")

if zero_vector_ids:
    print("\n⚠️ 以下 ID 的嵌入为全零向量:")
    for zid in zero_vector_ids:
        print(f" - {zid}")

# 使用 t-SNE 降维
reducer = TSNE(n_components=2, perplexity=30, random_state=42)
reduced = reducer.fit_transform(emb_array)

# 提取标签（如果有元数据）
labels = [meta.get("type", "unknown") for meta in metadatas]

# 构建颜色映射
unique_labels = list(set(labels))
color_map = {label: plt.cm.tab10(i % 10) for i, label in enumerate(unique_labels)}
colors = [color_map[label] for label in labels]

# 绘图
plt.figure(figsize=(12, 10))
plt.scatter(reduced[:, 0], reduced[:, 1], c=colors, alpha=0.6, s=40)

# 只标注部分点（避免重叠）
for i in random.sample(range(len(ids)), min(20, len(ids))):
    plt.text(reduced[i, 0], reduced[i, 1], ids[i], fontsize=8)

plt.title("ChromaDB [langchain] 嵌入分布图（t-SNE 降维）")
plt.xlabel("维度 1")
plt.ylabel("维度 2")
plt.grid(True)
plt.tight_layout()
plt.show()
