import json
import os

def clean_json(input_file1, input_file2):
    """清理 JSON 文件中不在第二个 JSON 文件中的函数"""
    with open(input_file1, 'r', encoding='utf-8') as file:
        data1 = json.load(file)

    with open(input_file2, 'r', encoding='utf-8') as file:
        data2 = json.load(file)

    function_names = {item.get("function") for item in data2.get("logs", {}).get("calls", [])}

    filtered_data = [
        item for item in data1
        if not (
            item.get("original_code") == "" and
            item.get("description") == "" and
            item.get("source_type") == "attacker_contract" and
            item.get("function_name") not in function_names
        )
    ]

    with open(input_file1, 'w', encoding='utf-8') as file:
        json.dump(filtered_data, file, indent=2, ensure_ascii=False)

def clean_json_with_duplicates(input_file1, duplicates_file):
    """基于给定的 duplicates.json 文件进行去重"""
    with open(input_file1, 'r', encoding='utf-8') as file:
        data1 = json.load(file)

    with open(duplicates_file, 'r', encoding='utf-8') as file:
        duplicates = json.load(file)

    filtered_data = [
        item for item in data1
        if not any(
            item.get("function_name") == dup.get("function_name") and
            item.get("original_code") == dup.get("original_code")
            for dup in duplicates
        )
    ]

    with open(input_file1, 'w', encoding='utf-8') as file:
        json.dump(filtered_data, file, indent=2, ensure_ascii=False)

def process_json_files(folder1, folder2, duplicates_file):
    """遍历 JSON 文件，先清理不在第二个 JSON 文件中的数据，再进行去重"""
    for filename in os.listdir(folder1):
        if filename.endswith(".json") and not filename.endswith(".sol.json"):
            input_file1 = os.path.join(folder1, filename)
            input_file2 = os.path.join(folder2, filename.replace(".json", ".sol.json"))

            if os.path.exists(input_file2):
                clean_json(input_file1, input_file2)
                clean_json_with_duplicates(input_file1, duplicates_file)

# 文件夹路径
folder1 = r"C:\\Users\\86153\\Desktop\\functions\\Poc-Function-Final"
folder2 = r"C:\\Users\\86153\\Desktop\\functions\\output_final\\output_1"
duplicates_file = r"C:\\Users\\86153\\Desktop\\functions\\duplicates.json"

process_json_files(folder1, folder2, duplicates_file)
