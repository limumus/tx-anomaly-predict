from flask import Flask, request, jsonify
import sys

sys.path.append(r"G:\tx-anomaly-predict\zqj")
import QA_2
from flask_cors import CORS  # 确保正确导入 CORS

app = Flask(__name__)  # 先定义 Flask 实例
CORS(app, resources={r"/*": {"origins": "*"}})  # 现在可以安全调用 CORS


def convert_to_html_paragraphs(text):
    """将文本转换为 HTML 段落格式"""
    text = text.replace('\\n\\n', '\n')
    text = text.replace('\\n', '\n')
    paragraphs = text.strip().split('\n')
    html_paragraphs = [f'<div style="text-indent: 2em;">{para.strip()}</div>' for para in paragraphs if para.strip()]
    return '<br>'.join(html_paragraphs)


def extract_content(text):
    """提取文本中的核心内容"""
    start_keyword = "答案: content='"
    end_keyword = "' additional_kwargs"

    start_idx = text.find(start_keyword) + len(start_keyword)
    end_idx = text.find(end_keyword)

    if start_idx != -1 and end_idx != -1:
        return text[start_idx:end_idx]
    else:
        return "无法提取该部分"


@app.route("/analyze", methods=["POST"])
def analyze():
    """处理用户查询并调用 QA_2 进行分析"""
    data = request.json
    query_text = data.get("query", "")

    if not query_text.strip():
        return jsonify({"error": "输入为空，请提供有效查询"})

    try:
        output = QA_2.run(query_text)  # 运行分析逻辑
        processed_output = extract_content(output)  # 提取核心内容
        formatted_output = convert_to_html_paragraphs(processed_output)  # 转换为 HTML 结构

        return jsonify({"result": formatted_output})  # 以 JSON 返回结果

    except Exception as e:
        return jsonify({"error": f"处理出错: {str(e)}"})


if __name__ == "__main__":
    app.run(debug=True, host="0.0.0.0", port=5000)  # 监听所有 IP，确保 React 端可访问
