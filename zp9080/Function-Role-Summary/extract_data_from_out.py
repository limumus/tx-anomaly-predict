import os
import json

def extract_and_combine_json_data(root_dir):
    # 遍历 root_dir 下的所有子文件夹
    for subdir, _, files in os.walk(root_dir):
        json_data = []
        # 遍历子文件夹中的所有文件
        for file in files:
            if file.endswith('.json'):
                file_path = os.path.join(subdir, file)
                try:
                    with open(file_path, 'r') as f:
                        data = json.load(f)
                        # 提取 'abi' 和 'methodIdentifiers' 字段
                        abi = data.get('abi', [])
                        method_identifiers = data.get('methodIdentifiers', {})
                        json_data.append({
                            'file': file,
                            'abi': abi,
                            'methodIdentifiers': method_identifiers
                        })
                except (json.JSONDecodeError, IOError) as e:
                    print(f"Error reading {file_path}: {e}")
        
        if json_data:
            # 获取当前子文件夹的名称
            folder_name = os.path.basename(subdir).replace('.sol', '') 
            # 构建输出文件路径
            output_file = os.path.join("Poc-Function-Set/" f"{folder_name}.json")
            print(output_file)
            try:
                with open(output_file, 'w') as f:
                    json.dump(json_data, f, indent=2)
                print(f"Extracted data saved to {output_file}")
            except IOError as e:
                print(f"Error writing to {output_file}: {e}")

if __name__ == "__main__":
    root_directory = "/home/zp9080/Code/out"
    extract_and_combine_json_data(root_directory)
