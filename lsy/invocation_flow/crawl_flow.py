import os
import json
import time
from playwright.sync_api import sync_playwright


def scrape_invocation_flow(url, retries=1, delay=5):
    attempt = 0
    while attempt < retries:
        try:
            with sync_playwright() as p:
                browser = p.chromium.launch(headless=False)
                page = browser.new_page()
                print(f"访问页面: {url}")
                page.goto(url, timeout=60000)
                time.sleep(5)

                # 选择 Default 选项
                default_selector = '#invocationFlowPanel .ant-select-selection-item'
                page.wait_for_selector(default_selector, timeout=10000)
                page.click(default_selector)
                time.sleep(2)

                # 选择 All 选项
                page.click(".ant-select-item[title='All']", force=True)
                time.sleep(2)

                selected_value = page.inner_text(default_selector)
                print(f"当前选中的值: {selected_value}")

                if "ALL" in selected_value:
                    print("成功选择 `ALL`。")

                page.wait_for_selector("#tree-container-0 > div > div.ant-tree-list > div > div > div", timeout=20000)
                time.sleep(3)

                content = page.evaluate('''() => {
                    let element = document.querySelector("#tree-container-0 > div > div.ant-tree-list > div > div > div");
                    return element ? element.innerText : null;
                }''')

                browser.close()
                return content if content else None
        except Exception as e:
            print(f"错误: {e}")
            attempt += 1
            if attempt < retries:
                print(f"等待 {delay} 秒后重试...")
                time.sleep(delay)
    return None


# 遍历 link 文件夹下所有 txt 文件
input_dir = 'link'
output_dir = 'output'
error_file = 'error_link.txt'
error_paths = []

for file_name in os.listdir(input_dir):
    if file_name.endswith('.txt'):
        chain_name = file_name.replace('.txt', '')  # 获取链名称
        input_file = os.path.join(input_dir, file_name)

        with open(input_file, 'r') as f:
            lines = f.readlines()

        for line in lines:
            parts = line.strip().split(" - ")
            if len(parts) != 2:
                print(f"跳过无效行: {line.strip()}")
                continue

            contract_path, hash_value = parts
            relative_path = contract_path.replace('/home/zp9080/Code/DeFiHackLabs/src/test/', '')

            tx_url = f"https://app.blocksec.com/explorer/tx/{chain_name}/{hash_value}"
            print(f"正在爬取哈希: {hash_value} ({chain_name})...")
            data = scrape_invocation_flow(tx_url)

            if data:
                output_path = os.path.join(output_dir, relative_path, f"{hash_value}.txt")
                os.makedirs(os.path.dirname(output_path), exist_ok=True)
                with open(output_path, 'w', encoding='utf-8') as f:
                    json.dump(data, f, ensure_ascii=False, indent=4)
                print(f"数据已保存到 {output_path}")
            else:
                print(f"爬取失败: {contract_path} - {hash_value}")
                error_paths.append(f"{contract_path} - {hash_value}")

# 保存错误路径
if error_paths:
    with open(error_file, 'w', encoding='utf-8') as f:
        for path in error_paths:
            f.write(path + "\n")
    print(f"爬取失败的路径已保存到 {error_file}")