import os
import re
import json
import uuid
import requests
from typing import List, Dict, Any, Optional
from neo4j import GraphDatabase
from dotenv import load_dotenv
from langchain_core.runnables import Runnable

# ============== 配置部分 ==============
load_dotenv()

CONFIG = {
    "BAIDU_ACCESS_KEY": "hoxYjdAGl1u5ijV9WmuSa5Ld",
    "BAIDU_SECRET_KEY": "GImapGj06l7YK13nQgYN7Fsc6p1jm1Si",
    "NEO4J_URI": "bolt://localhost:7687",
    "NEO4J_USER": "neo4j",
    "NEO4J_PASSWORD": ""  # 请使用自己的neo4j用户密码
}


# ============== Neo4j 数据加载器 ==============
class Neo4jLoader:
    def __init__(self, clear_existing=False):
        self.driver = GraphDatabase.driver(
            CONFIG["NEO4J_URI"],
            auth=(CONFIG["NEO4J_USER"], CONFIG["NEO4J_PASSWORD"])
        )
        if clear_existing:
            self.clear_database()

    def clear_database(self):
        """清除现有数据"""
        with self.driver.session() as session:
            session.run("MATCH (n) DETACH DELETE n")
            print("已清除Neo4j数据库中的现有数据")

    def load_data(self, json_path: str):
        """加载JSON数据到Neo4j"""
        with open(json_path) as f:
            data = json.load(f)

        with self.driver.session() as session:
            for root_call in data["logs"]["calls"]:
                session.execute_write(self._process_call, root_call, None)

    def _process_call(self, tx, call: Dict, parent_uuid: Optional[str]):
        """递归处理调用层级"""
        node_uuid = str(uuid.uuid4())

        tx.run("""
        CREATE (c:Call)
        SET c.uuid = $uuid,
            c.original_id = $id,
            c.contract = $contract,
            c.function = $function,
            c.depth = $depth,
            c.args = $args
        """, {
            "uuid": node_uuid,
            "id": call["id"],
            "contract": call["contract"],
            "function": call["function"],
            "depth": call["depth"],
            "args": call.get("args", "")
        })

        if parent_uuid:
            tx.run("""
            MATCH (parent:Call {uuid: $p_uuid}), (child:Call {uuid: $c_uuid})
            CREATE (parent)-[:HAS_INTERNAL_CALL]->(child)
            """, {"p_uuid": parent_uuid, "c_uuid": node_uuid})

        for child in call.get("internal_calls", []):
            self._process_call(tx, child, node_uuid)

    def get_schema(self) -> Dict:
        """获取当前数据库的schema信息"""
        with self.driver.session() as session:
            # 获取节点标签
            labels = session.run("CALL db.labels()").value()
            # 获取关系类型
            relationship_types = session.run("CALL db.relationshipTypes()").value()
            # 获取属性
            properties = {}
            for label in labels:
                result = session.run(f"""
                MATCH (n:`{label}`)
                WITH keys(n) AS keys
                RETURN apoc.coll.toSet(apoc.coll.flatten(collect(keys))) AS properties
                """)
                properties[label] = result.single()["properties"]

            return {
                "labels": labels,
                "relationship_types": relationship_types,
                "properties": properties
            }


# ============== 百度千帆大模型集成 ==============
class QianfanLLM(Runnable):
    """支持知识图谱问答的千帆大模型包装器"""

    def __init__(self):
        self.access_token = self._get_access_token()
        self.api_url = "https://aip.baidubce.com/rpc/2.0/ai_custom/v1/wenxinworkshop/chat/ernie-speed-128k"
        self.driver = None  # 不再保持长连接，每次查询时新建连接
        self.last_schema = None
        self.last_schema_update = 0

    def _get_driver(self):
        """获取新的数据库连接"""
        return GraphDatabase.driver(
            CONFIG["NEO4J_URI"],
            auth=(CONFIG["NEO4J_USER"], CONFIG["NEO4J_PASSWORD"])
        )

    def _get_access_token(self) -> str:
        """获取访问令牌"""
        url = f"https://aip.baidubce.com/oauth/2.0/token?grant_type=client_credentials&client_id={CONFIG['BAIDU_ACCESS_KEY']}&client_secret={CONFIG['BAIDU_SECRET_KEY']}"
        return requests.post(url).json().get("access_token")

    def _get_current_schema(self) -> Dict:
        """获取当前数据库schema"""
        with self._get_driver().session() as session:
            # 获取节点标签
            labels = session.run("CALL db.labels()").value()
            # 获取关系类型
            relationship_types = session.run("CALL db.relationshipTypes()").value()
            # 获取属性
            properties = {}
            for label in labels:
                result = session.run(f"""
                MATCH (n:`{label}`)
                WITH keys(n) AS keys
                RETURN apoc.coll.toSet(apoc.coll.flatten(collect(keys))) AS properties
                """)
                properties[label] = result.single()["properties"]

            return {
                "labels": labels,
                "relationship_types": relationship_types,
                "properties": properties
            }

    def _generate_cypher(self, question: str) -> str:
        """生成Cypher查询语句"""
        # 获取当前数据库schema
        current_schema = self._get_current_schema()

        # 构建schema描述
        schema_desc = "当前图谱结构:\n"
        for label in current_schema["labels"]:
            schema_desc += f"- 节点类型: {label} {{"
            schema_desc += ", ".join(current_schema["properties"].get(label, []))
            schema_desc += "}\n"

        schema_desc += "关系类型: " + ", ".join(current_schema["relationship_types"]) + "\n"

        # 先尝试匹配简单查询
        if "depth为" in question and "有几个" in question:
            depth = re.search(r"depth为(\d+)", question)
            if depth:
                return f"MATCH (n:Call) WHERE n.depth = {depth.group(1)} RETURN count(n) AS count"

        if "depth为" in question:
            depth = re.search(r"depth为(\d+)", question)
            if depth:
                return f"MATCH (n:Call) WHERE n.depth = {depth.group(1)} RETURN n"

        if "合约" in question and "调用" in question and "几次" in question:
            contract = re.search(r"0x[0-9a-fA-F]+", question)
            if contract:
                return f"MATCH (n:Call) WHERE n.contract = '{contract.group()}' RETURN count(n) AS call_count"

        if ("函数" in question or "transferFrom" in question) and "有几个" in question:
            func = re.search(r"函数(\w+)", question) or "transferFrom"
            func_name = func if isinstance(func, str) else func.group(1)
            return f"MATCH (n:Call) WHERE n.function CONTAINS '{func_name}' RETURN count(n) AS count"

        if "函数" in question or "transferFrom" in question:
            func = re.search(r"函数(\w+)", question) or "transferFrom"
            func_name = func if isinstance(func, str) else func.group(1)
            return f"MATCH (n:Call) WHERE n.function CONTAINS '{func_name}' RETURN n"

        # 复杂查询使用大模型生成
        prompt = f"""{schema_desc}

        你是一个Neo4j专家，请根据以上图谱结构生成Cypher查询。以下是一些示例查询:
        - 查询depth为1的节点: MATCH (n:Call) WHERE n.depth = 1 RETURN n
        - 查询depth为1的节点数量: MATCH (n:Call) WHERE n.depth = 1 RETURN count(n) AS count
        - 查询特定合约: MATCH (n:Call) WHERE n.contract = '0x...' RETURN n
        - 查询函数调用: MATCH (n:Call) WHERE n.function CONTAINS 'transfer' RETURN n

        要求：
        1. 只输出Cypher代码
        2. 使用英文关键字
        3. 包含RETURN语句
        4. 确保查询与当前图谱结构匹配

        问题：{question}"""

        response = requests.post(
            f"{self.api_url}?access_token={self.access_token}",
            json={"messages": [{"role": "user", "content": prompt}]}
        ).json()

        return self._clean_cypher(response.get("result", ""))

    def _clean_cypher(self, raw: str) -> str:
        """清洗Cypher语句"""
        if "```cypher" in raw:
            raw = raw.split("```cypher")[1].split("```")[0]
        return re.sub(r"[^a-zA-Z0-9_{}:()\-\"=<>.*, ]", "", raw).strip()

    def _execute_query(self, cypher: str) -> List[Dict]:
        """执行Cypher查询"""
        driver = self._get_driver()
        try:
            with driver.session() as session:
                result = session.run(cypher)
                return [dict(record) for record in result]
        except Exception as e:
            return [{"error": str(e), "cypher": cypher}]
        finally:
            driver.close()

    def _format_result(self, result: List[Dict]) -> str:
        """格式化查询结果"""
        if not result:
            return "没有查询到结果"

        if "error" in result[0]:
            return f"查询错误: {result[0]['error']}\n使用的查询语句: {result[0].get('cypher', '')}"

        formatted = []
        for item in result:
            formatted_item = {}
            for k, v in item.items():
                if isinstance(v, dict) and "function" in v:
                    formatted_item.update({
                        "合约": v.get("contract", ""),
                        "函数": v.get("function", ""),
                        "深度": v.get("depth", "")
                    })
                else:
                    formatted_item[str(k)] = str(v)
            formatted.append(formatted_item)

        return json.dumps(formatted, ensure_ascii=False, indent=2)

    def invoke(self, input_data: Dict) -> Dict:
        """处理问答请求"""
        question = input_data.get("query", "")

        # 生成并执行Cypher
        cypher = self._generate_cypher(question)
        query_result = self._execute_query(cypher)
        formatted_result = self._format_result(query_result)

        # 生成自然语言回答
        response = requests.post(
            f"{self.api_url}?access_token={self.access_token}",
            json={
                "messages": [{
                    "role": "user",
                    "content": f"""根据以下查询结果回答问题：
                    问题：{question}
                    查询结果：{formatted_result}

                    要求：
                    1. 用中文回答
                    2. 结构化总结查询结果
                    3. 如果结果中有错误，请分析可能的原因"""
                }]
            }
        ).json()

        return {
            "result": response.get("result", "请求失败"),
            "cypher": cypher,
            "raw_result": query_result
        }


# ============== 主程序 ==============
if __name__ == "__main__":
    # 步骤1：导入数据到Neo4j（可选清除旧数据）
    clear_existing = input("是否清除现有数据？(y/n): ").lower() == 'y'
    loader = Neo4jLoader(clear_existing=clear_existing)

    try:
        json_file = input("请输入要导入的JSON文件路径（如：FortressLoans_exp.sol.json）: ")
        loader.load_data(json_file)
        print("Neo4j 数据导入成功")

        # 显示当前schema
        schema = loader.get_schema()
        print("\n当前数据库结构:")
        print(f"节点标签: {', '.join(schema['labels'])}")
        print(f"关系类型: {', '.join(schema['relationship_types'])}")
        print("节点属性:")
        for label, props in schema["properties"].items():
            print(f"- {label}: {', '.join(props)}")
    except Exception as e:
        print(f"数据导入失败: {str(e)}")
    finally:
        loader.driver.close()

    # 步骤2：初始化问答系统
    qa_system = QianfanLLM()

    # 交互式问答
    while True:
        print("\n" + "=" * 50)
        q = input("请输入问题（输入'quit'退出）: ")
        if q.lower() == 'quit':
            break

        result = qa_system.invoke({"query": q})
        print(f"\n回答：{result['result']}")
        print(f"使用的Cypher查询: {result['cypher']}")