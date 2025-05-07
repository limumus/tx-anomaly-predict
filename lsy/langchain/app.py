from flask import Flask, request, render_template
import QA_2  # 假设这是你处理分析逻辑的模块
import os
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
    except Exception as e:
        # 如果运行出错，返回错误信息
        output = f"运行出错：{e}"

    # 返回分析结果页面，将分析输出和文件路径传递给模板
    return render_template('result.html', output=output, input_path=system_input_path)



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
