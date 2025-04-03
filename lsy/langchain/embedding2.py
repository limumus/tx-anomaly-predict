import os
import json
from typing import List
import requests
from tqdm import tqdm
from langchain.embeddings.base import Embeddings
from langchain_chroma import Chroma
from langchain.schema import Document
from collections import deque

CONFIG = {
    "JSON_FOLDER_PATH": "output_de",
    "PERSIST_DIR": "vector_store_realtime_0",
    "INTERMEDIATE_FOLDER": "intermediate_data",  # 新增保存中间数据的文件夹
    # "JINA_API_KEY": "jina_2788715e24ec409ab14302244c6f339cjoAe0RecO8q8PHxT2_N50r_Ejo07",
    # "JINA_API_KEY": "jina_1c8147b1e3944c83afa2cf111515f7dchVtlSwkYb8mv-Y2suRmJxuo_YeMR",
    "JINA_API_KEY": "jina_23283d82eae7486a884ece2bcbaf3ecbrOg1kDYNc7qCkqbkofZ81kDjikie",
    "EMBEDDING_MODEL": "jina-embeddings-v3",
}


class RealtimeVectorStore:
    """支持实时保存的向量数据库管理类"""

    def __init__(self, persist_dir: str, embedding: Embeddings, progress_file="vector_store_progress.json"):
        # 初始化空数据库（如果不存在则创建）
        self.store = Chroma(
            persist_directory=persist_dir,
            embedding_function=embedding,
            collection_metadata={"hnsw:space": "cosine"}
        )
        self.batch_size = 5
        self.current_batch = []
        self.progress_file = progress_file
        self.processed_documents = self.load_progress()

    def load_progress(self):
        if os.path.exists(self.progress_file):
            with open(self.progress_file, "r", encoding="utf-8") as f:
                return json.load(f)
        return []

    def save_progress(self):
        with open(self.progress_file, "w", encoding="utf-8") as f:
            json.dump(self.processed_documents, f, ensure_ascii=False, indent=2)

    def add_document(self, document: Document, embedding: List[float]):
        if document.metadata.get("source_file") in self.processed_documents:
            return  # 跳过已处理的文档

        """添加单个文档并实时保存"""
        try:
            # 使用关键字传递参数
            self.store.add_documents(documents=[document], embeddings=[embedding])
            self.processed_documents.append(document.metadata.get("source_file"))
            self.save_progress()  # 保存进度
        except Exception as e:
            print(f"⚠️ 添加文档失败: {str(e)}")

    def finalize(self):
        """处理剩余未保存的文档"""
        if self.current_batch:
            self._save_batch()

    def _save_batch(self):
        """批量保存文档到数据库"""
        try:
            docs, embs = zip(*self.current_batch)
            # 使用关键字传递参数
            self.store.add_documents(
                documents=list(docs),
                embeddings=list(embs)
            )
            self.current_batch = []
        except Exception as e:
            print(f"⚠️ 批量保存失败: {str(e)}")


class JinaEmbedding(Embeddings):
    """实时嵌入服务"""

    def __init__(self):
        self.api_url = "https://api.jina.ai/v1/embeddings"
        self.headers = {
            "Authorization": f"Bearer {CONFIG['JINA_API_KEY']}",
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
                    "model": CONFIG["EMBEDDING_MODEL"],
                    "input": [text[:8192]]  # 截断超长文本
                },
                timeout=15
            )
            response.raise_for_status()
            return response.json()['data'][0]['embedding']
        except Exception as e:
            print(f"⚠️ 嵌入失败: {str(e)}")
            return []


class JSONDocumentProcessor:

    @staticmethod
    def process_calls(calls: List[dict]) -> List[dict]:
        queue = deque(calls)  # 使用双端队列处理嵌套结构
        all_slices, temp_slice = [], []

        while queue:
            node = queue.popleft()
            temp_slice.append({
                "id": node.get("id"),
                "contract": node.get("contract"),
                "function": node.get("function"),
                "depth": node.get("depth")
            })
            # 当临时切片达到100条时保存
            if len(temp_slice) >= 100:
                all_slices.append(temp_slice)
                temp_slice = []
            # 处理嵌套的内部调用
            queue.extend(node.get("internal_calls", []))
        # 处理剩余不足100条的切片
        if temp_slice:
            all_slices.append(temp_slice)
        return all_slices

    @staticmethod
    def load_json_data(folder_path: str, intermediate_folder: str, progress_file="processing_progress.json") -> List[
        Document]:
        file_paths = [
            os.path.join(root, file)
            for root, _, files in os.walk(folder_path)
            for file in files if file.endswith(".json")
        ]
        documents = []

        # 读取进度文件
        if os.path.exists(progress_file):
            with open(progress_file, "r", encoding="utf-8") as f:
                processed_files = json.load(f)
        else:
            processed_files = []
        print(f"📁 发现 {len(file_paths)} 个JSON文件，开始处理...")

        for index, file_path in enumerate(tqdm(file_paths, desc="📁 文件处理进度", unit="文件")):
            # 跳过已经处理过的文件
            if file_path in processed_files:
                continue
            try:
                with open(file_path, "r", encoding="utf-8") as f:
                    data = json.load(f)

                if not data.get("calls"):  # 如果没有交易调用数据，跳过
                    continue

                calls = data.get("calls", [])
                all_slices = JSONDocumentProcessor.process_calls(calls)

                # 保存每个文件的切片数据到中间文件夹
                slice_file = os.path.join(intermediate_folder, f"{os.path.basename(file_path)}_slices.json")
                with open(slice_file, "w", encoding="utf-8") as f:
                    json.dump(all_slices, f, ensure_ascii=False, indent=2)

                # 将每个切片转换为 LangChain 文档
                for item in all_slices:
                    documents.append(Document(
                        page_content=json.dumps(item, ensure_ascii=False, indent=2),
                        metadata={"source_file": file_path}
                    ))
                    if all_slices:  # 只有当文件确实有切片时才标记为已处理
                        processed_files.append(file_path)

                        # 保存进度到文件
                        with open(progress_file, "w", encoding="utf-8") as f:
                            json.dump(processed_files, f, ensure_ascii=False, indent=2)


            except Exception as e:
                print(f"⚠️ 文件处理失败 {file_path}: {str(e)}")

        print(f"✅ 成功处理 {len(documents)} 个文档")
        return documents


def main():
    # 初始化服务组件
    embedding = JinaEmbedding()
    processor = JSONDocumentProcessor()
    vector_db = RealtimeVectorStore(CONFIG["PERSIST_DIR"], embedding)

    if not os.path.exists(CONFIG["INTERMEDIATE_FOLDER"]):
        os.makedirs(CONFIG["INTERMEDIATE_FOLDER"])
    # 处理文档并将中间结果保存到文件夹
    documents = processor.load_json_data(CONFIG["JSON_FOLDER_PATH"], CONFIG["INTERMEDIATE_FOLDER"])

    # 实时处理文档流并生成嵌入
    for doc in tqdm(documents, desc="生成嵌入"):
        try:
            # 确保 doc.page_content 是一个字符串
            if isinstance(doc.page_content, str):
                embedding_vector = embedding.embed_documents([doc.page_content])[0]
                vector_db.add_document(doc, embedding_vector)
            else:
                print(f"⚠️ 跳过无效文档: {doc.metadata.get('source_file', 'Unknown')}, 内容非字符串")
                continue
        except Exception as e:
            print(f"文档处理失败: {str(e)}")
            continue

    # 确保最后一批数据保存
    vector_db.finalize()
    print(f"✅ 处理完成! 总文档数: {len(documents)}")


if __name__ == "__main__":
    main()
