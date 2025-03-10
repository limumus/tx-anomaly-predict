import os
import json

folder1 = r"C:\Users\86153\Desktop\functions\Poc-Function-Final"
folder2 = r"C:\Users\86153\Desktop\functions\output_final\output_1"

# 递归处理 calls 及其 internal_calls，并处理 args 之后插入的数据
def process_calls(calls, seen_functions, function_data):
    for call in calls:
        function = call.get("function")
        if function in function_data:
            if function not in seen_functions:
                seen_functions.add(function)
                # 重新构造字典，在 args 之后插入 original_code 和 description
                updated_call = {
                    "id": call.get("id"),
                    "contract": call.get("contract"),
                    "function": call.get("function"),
                    "args": call.get("args"),
                    "original_code": function_data[function]["original_code"],
                    "description": function_data[function]["description"],
                    "return_value": call.get("return_value"),
                    "depth": call.get("depth"),
                    "internal_calls": call.get("internal_calls", [])
                }
            else:
                # 仅插入 flag，设置 flag 为 1，表示重复
                updated_call = {
                    "id": call.get("id"),
                    "contract": call.get("contract"),
                    "function": call.get("function"),
                    "args": call.get("args"),
                    "flag": 1,  # 1表示重复
                    "return_value": call.get("return_value"),
                    "depth": call.get("depth"),
                    "internal_calls": call.get("internal_calls", [])
                }

            call.clear()
            call.update(updated_call)

        if "internal_calls" in call:
            process_calls(call["internal_calls"], seen_functions, function_data)

# 处理 folder2 目录的 .sol.json 文件
for filename in os.listdir(folder2):
    if filename.endswith(".sol.json"):
        original_filename = filename.replace(".sol.json", ".json")

        # 确保在 folder1 中找到对应的文件
        if os.path.exists(os.path.join(folder1, original_filename)):
            filepath2 = os.path.join(folder2, filename)

            # 读取对应的 folder1 中的 .json 文件并构建 function_data 字典
            function_data = {}
            folder1_filepath = os.path.join(folder1, original_filename)
            try:
                with open(folder1_filepath, "r", encoding="utf-8") as f:
                    data = json.load(f)
                    for entry in data:
                        function_name = entry.get("function_name")
                        if function_name:
                            function_data[function_name] = {
                                "original_code": entry.get("original_code"),
                                "description": entry.get("description"),
                            }
            except (json.JSONDecodeError, FileNotFoundError) as e:
                print(f"解析错误: {folder1_filepath} - {e}")
                continue

            # 处理 folder2 目录中的 .sol.json 文件
            try:
                with open(filepath2, "r", encoding="utf-8") as f:
                    data = json.load(f)

                calls = data.get("logs", {}).get("calls", [])
                seen_functions = set()
                process_calls(calls, seen_functions, function_data)

                # 更新处理后的 .sol.json 文件
                with open(filepath2, "w", encoding="utf-8") as f:
                    json.dump(data, f, indent=2, ensure_ascii=False)

            except (json.JSONDecodeError, FileNotFoundError) as e:
                print(f"解析错误: {filepath2} - {e}")
