import os
import json
import csv


def load_contract_mapping(csv_file):
    contract_mapping = {}
    with open(csv_file, mode='r', encoding='utf-8-sig') as file:
        reader = csv.DictReader(file)
        print("CSV Columns:", reader.fieldnames)  # Debug: 打印列名
        for row in reader:
            key = row['contract'].strip().lower()  # 处理大小写和空格
            contract_mapping[key] = row['contract_name']
    print("Loaded contract mapping:", contract_mapping)  # Debug 输出
    return contract_mapping


def replace_contract_names_in_json(json_file, contract_mapping):
    with open(json_file, 'r', encoding='utf-8') as file:
        data = json.load(file)

    print(f"Processing JSON file: {json_file}")  # Debug 输出

    def replace_contract(obj, path="root"):
        if isinstance(obj, dict):
            if 'contract' in obj:
                original_value = obj['contract']
                key = original_value.strip().lower()  # 处理大小写和空格
                if key in contract_mapping:
                    new_value = contract_mapping[key]
                    print(f"[{path}] Replacing contract: {original_value} -> {new_value}")  # Debug 输出
                    obj['contract'] = new_value
                #else:
                    #print(f"[{path}] No match found for: {original_value}")  # Debug 输出
            for key in obj:
                obj[key] = replace_contract(obj[key], path + f".{key}")
        elif isinstance(obj, list):
            for i, item in enumerate(obj):
                obj[i] = replace_contract(item, path + f"[{i}]")
        return obj

    data = replace_contract(data)

    with open(json_file, 'w', encoding='utf-8') as file:
        json.dump(data, file, indent=2, ensure_ascii=False)


def process_json_files_in_folder(folder_path, csv_file):
    contract_mapping = load_contract_mapping(csv_file)
    for root, _, files in os.walk(folder_path):
        for file in files:
            if file.endswith('.json'):
                json_path = os.path.join(root, file)
                replace_contract_names_in_json(json_path, contract_mapping)
                print(f'Processed {json_path}')


# 设置你的文件夹路径和CSV文件路径
json_folder_path = 'output_setup'  # 修改为你的JSON文件夹路径
csv_file_path = 'contract_mapping.csv'  # 修改为你的CSV文件路径

process_json_files_in_folder(json_folder_path, csv_file_path)
