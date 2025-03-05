import os
import json

def remove_setup_calls(calls):
    """递归删除所有 function 为 'setUp' 的调用及其子调用"""
    filtered_calls = []
    setup_count = 0  # 用于计数 'setUp' 调用的次数
    for call in calls:
        function_name = call.get("function")
        print(f"Processing function: {function_name}")  # 输出当前处理的函数
        if function_name == "setUp":
            setup_count += 1
            print(f"Skipping 'setUp' function.")  # 输出跳过 setUp 的信息
            continue  # 跳过 'setUp' 及其所有子调用
        # 递归清理 internal_calls
        if "internal_calls" in call:
            nested_setup_count, internal_filtered_calls = remove_setup_calls(call["internal_calls"])
            setup_count += nested_setup_count
            call["internal_calls"] = internal_filtered_calls
        filtered_calls.append(call)
    return setup_count, filtered_calls

def clean_json_file(file_path):
    """读取 JSON 文件，删除 'setUp' 相关的日志及其子调用，并保存修改后的 JSON。"""
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            try:
                data = json.load(f)
                print(f"Successfully loaded JSON from {file_path}")  # 成功加载 JSON 的输出
            except json.JSONDecodeError as e:
                print(f"Error decoding JSON in {file_path}: {e}")
                return  # 如果文件不是有效的 JSON，直接跳过
        if "logs" in data and "calls" in data["logs"]:
            print(f"Found 'logs' and 'calls' in {file_path}")  # 输出检查到 "logs" 和 "calls"
            setup_count, cleaned_calls = remove_setup_calls(data["logs"]["calls"])
            if setup_count > 2:  # 如果出现超过一个 'setUp' 调用，保存文件路径
                error_files.append(file_path)
            data["logs"]["calls"] = cleaned_calls

        # 将修改后的 JSON 写回文件
        with open(file_path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=4, ensure_ascii=False)

        print(f"Processed: {file_path}")

    except Exception as e:
        print(f"Error processing {file_path}: {e}")

def process_folder(directory):
    """遍历指定目录，处理所有 .sol.json 文件。"""
    for root, _, files in os.walk(directory):
        for file in files:
            if file.endswith(".sol.json"):  # 修改文件扩展名匹配条件
                file_path = os.path.join(root, file)
                print(f"Processing file: {file_path}")  # 输出正在处理的文件路径
                clean_json_file(file_path)

if __name__ == "__main__":
    error_files = []  # 存储识别到多个 'setUp' 调用的文件路径
    folder_path = "output_setup"  # 目标文件夹路径
    process_folder(folder_path)

    # 输出所有错误的文件路径
    if error_files:
        print("Files with multiple 'setUp' calls:")
        for file in error_files:
            print(file)
    else:
        print("No errors found.")
