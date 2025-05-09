from flask import Flask, request, render_template
import QA_2  # 假设这是你处理分析逻辑的模块
import os

def convert_to_html_paragraphs(text):
    text = text.replace('\\n\\n', '\n')  # 若输入中为字面量
    text = text.replace('\\n', '\n')  # 若输入中为字面量
    paragraphs = text.strip().split('\n')
    html_paragraphs = [f'<div style="text-indent: 2em;">{para.strip()}</div>' for para in paragraphs if para.strip()]
    return '<br>'.join(html_paragraphs)


def extract_content(text):
    # 找到你需要的内容的开始和结束标志（不包括标志本身）
    start_keyword = "答案: content='"
    end_keyword = "' additional_kwargs"

    # 提取内容的部分
    start_idx = text.find(start_keyword) + len(start_keyword)  # 跳过 start_keyword
    end_idx = text.find(end_keyword)  # 不加 len(end_keyword)，这样就不包含 end_keyword

    # 检查索引是否有效
    if start_idx != -1 and end_idx != -1:
        return text[start_idx:end_idx]
    else:
        return "无法提取该部分"

app = Flask(__name__)


@app.route('/')
def index():
    # 返回主页面，用户输入文件路径
    return render_template('index.html')


@app.route('/run', methods=['POST'])
def run_code():
    # 获取用户提交的文件路径
    system_input_path = request.form['input_path']

    try:
        # 调用 QA_2 模块中的 run 函数，传递系统输入路径并返回分析结果
        output = QA_2.run(system_input_path)
        output = extract_content(output)
        output = convert_to_html_paragraphs(output)
        print(output)

        # ✅ 指定图片路径列表，注意是 static/ 下的相对路径
        image_paths = [
            "images/1.png",
            "images/2.png" #按需要增减图片，对应名字写好
        ]

    except Exception as e:
        # 如果运行出错，返回错误信息
        output = f"运行出错：{e}"
        image_paths = []

    # 返回分析结果页面
    return render_template(
        'result.html',
        output=output,
        input_path=system_input_path,
        image_paths=image_paths  # ✅ 添加这行
    )




# 预测准确度功能（预留）
@app.route('/predict_accuracy')
def predict_accuracy():
    return render_template('predict_accuracy.html')


# 历史查询功能（预留）
@app.route('/history_query')
def history_query():
    return render_template('history_query.html')


if __name__ == '__main__':
    app.run(debug=True)
