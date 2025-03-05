import os
import re
import json


def extract_contract_info(file_path, parent_folder):
    """提取Solidity合约中的交易链接、合约名称和相关地址"""
    with open(file_path, "r", encoding="utf-8") as f:
        content = f.read()

    # 交易链接
    tx_pattern = re.compile(
        r'https?://[a-zA-Z0-9.-]+/explorer/tx/[a-zA-Z0-9]+/0x[a-fA-F0-9]{64}|https?://[a-zA-Z0-9.-]+/tx/0x[a-fA-F0-9]{64}')
    links = tx_pattern.findall(content)

    # Attack Tx 多行格式
    tx_hash_pattern = re.compile(r'Attack Tx\s*:\s*(?:0x[a-fA-F0-9]{64}(?:\s*//.*)?\s*)+')
    tx_hashes = re.findall(r'0x[a-fA-F0-9]{64}', content)

    # 合约地址链接
    address_pattern = re.compile(r'https?://[a-zA-Z0-9.-]+/address/0x[a-fA-F0-9]{40}')
    address_links = address_pattern.findall(content)

    contract_name = os.path.splitext(os.path.basename(file_path))[0]

    return {
        "name": contract_name,
        "date": parent_folder,
        "links": list(set(links)),  # 去重
        "tx_hashes": list(set(tx_hashes)),  # 存储Tx哈希
        "address_links": list(set(address_links))
    }


def parse_contracts_from_folder(base_folder):
    contract_data = []

    for root, _, files in os.walk(base_folder):
        for file in files:
            if file.endswith(".sol"):
                parent_folder = os.path.basename(root)  # 获取次级目录作为时间
                file_path = os.path.join(root, file)
                contract_info = extract_contract_info(file_path, parent_folder)
                contract_data.append(contract_info)

    return contract_data



def main():
    base_folder = "test"
    output_file="contracts.json"
    contract_data = parse_contracts_from_folder(base_folder)
    with open(output_file, "w", encoding="utf-8") as f:
        json.dump(contract_data, f, indent=4, ensure_ascii=False)
    print(f"已保存 {len(contract_data)} 个合约信息到 contracts.json")


if __name__ == "__main__":
    main()