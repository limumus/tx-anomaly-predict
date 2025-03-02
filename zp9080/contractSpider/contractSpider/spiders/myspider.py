import scrapy
import re
import os
import random
from scrapy.crawler import CrawlerProcess
import time

# 定义要扫描的目录路径
directory_path = "/home/zp9080/Code/DeFiHackLabs/src/test/2025-01"  # 替换为你的目标目录

# 提取合约地址的正则表达式
address_pattern = r'\b0x[a-fA-F0-9]{40}\b'

# 读取文件内容并提取合约地址及其变量名
def extract_addresses_and_names_from_file(file_path):
    address_map = {}
    with open(file_path, 'r', encoding='utf-8') as f:
        for line_number, line in enumerate(f, 1):
            # 匹配 0x 开头的地址
            match = re.search(r'0x[a-fA-F0-9]{40}', line)
            if match:
                # 查找该行中的 = 号
                equal_index = line.find('=')
                if equal_index != -1:
                    # 提取变量名
                    var_name = line[:equal_index].strip().split()[-1]
                    # 提取合约地址
                    address = match.group()
                    address_map[var_name] = address
    return address_map

def extract_contract_code_from_file(file_path):
    """
    从文件中提取合约代码
    :param file_path: 文件路径
    :return: 合约代码
    """
    code_start = False
    contract_code = []
    with open(file_path, 'r', encoding='utf-8') as file:
        lines = file.readlines()
        for line in lines:
            # 检查合约是否开始
            if 'pragma solidity' in line:
                code_start = True
                contract_code.append(line)
                continue  # 跳过当前行，直接进入下一行
            
            if code_start :
                # 检查合约是否结束
                if '</pre>' in line:
                    # 处理合约结束行
                    # 取出 </pre> 和 < 之间的部分
                    parts = line.split('</pre>')
                    if len(parts) > 1:
                        # 取出 </pre> 后面的内容
                        rest_line = parts[1]
                        # 找到第一个 < 的位置
                        first_lt = rest_line.find('<')
                        if first_lt != -1:
                            # 截取到第一个 <
                            code_line = rest_line[:first_lt]
                        else:
                            # 没有 <，直接取全部内容
                            code_line = rest_line
                        # 添加 }（假设这里总有一个 }）
                        code_line += '}'
                        contract_code.append(code_line)
                        contract_code.append('\n')
                        code_start=False
                else:
                    # 添加合约代码行
                    contract_code.append(line)

     # 如果找到合约代码，则保存到文件
    if contract_code:
        # 生成输出文件路径（假设保存到与输入文件同名的 .sol 文件）
        output_file_path = os.path.splitext(file_path)[0] + '.sol'
        # 写入合约代码到文件
        with open(output_file_path, 'w', encoding='utf-8') as output_file:
            output_file.write(''.join(contract_code))
        print(f"合约代码已保存到 {output_file_path}")
    else:
        print("未找到合约代码")
    
def clean_contract_code_from_file(input_file_path, output_file_path=None):
    """
    从文件中逐行清理合约代码中的HTML标签和特殊符号,并保留原始格式
    :param input_file_path: 输入文件路径
    :param output_file_path: 输出文件路径（可选）
    :return: 清理后的合约代码
    """
    try:
        # 检查输入文件是否存在
        if not os.path.exists(input_file_path):
            raise FileNotFoundError(f"输入文件 {input_file_path} 不存在")
        
        # 初始化清理后的代码列表
        cleaned_lines = []
        
        # 逐行读取文件内容
        with open(input_file_path, 'r', encoding='utf-8') as file:
            lines = file.readlines()
            for line in lines:
                # 移除HTML标签
                line_without_tags = re.sub(r'<[^>]*>', '', line)
                
                # 替换HTML实体编码为对应的字符
                html_entities = {
                    '&#39;': "'",
                    '&lt;': '<',
                    '&gt;': '>',
                    '&amp;': '&',
                    "&quot;": '"'
                }
                for entity, char in html_entities.items():
                    line_without_tags = line_without_tags.replace(entity, char)
                
                cleaned_line = line_without_tags
                if cleaned_line:
                    cleaned_lines.append(cleaned_line)
        
        # 如果提供了输出文件路径，则保存清理后的代码
        output_file_path=input_file_path
        if output_file_path:
            with open(output_file_path, 'w', encoding='utf-8') as output_file:
                output_file.write(''.join(cleaned_lines))
            print(f"已清理的合约代码已保存到 {output_file_path}")
        
    except Exception as e:
        print(f"清理合约代码时发生错误: {e}")
        return None


# 定义 Scrapy 爬虫
class mySpider(scrapy.Spider):
    name = "myspider"
    allowed_domains = ["bscscan.com", "etherscan.io", "optimistic.etherscan.io"]
    
    def start_requests(self):
        # 随机 User-Agent 列表
        user_agents = [
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/118.0.0.0 Safari/537.36',
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:120.0) Gecko/20100101 Firefox/120.0',
            'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Safari/605.1.15'
        ]
        # 随机选择 User-Agent 和代理
        headers = {
            'User-Agent': random.choice(user_agents),
            'Accept-Language': 'en-US,en;q=0.9',
        }
        proxies = {
            'http': 'http://127.0.0.1:7890',
            'https': 'http://127.0.0.1:7890'
        }
        # 递归遍历目录下的所有文件
        for dirpath, dirnames, filenames in os.walk(directory_path):
            for filename in filenames:
                file_path = os.path.join(dirpath, filename)
                print(f"Processing file: {file_path}")  # 显示正在处理的文件
                address_map = extract_addresses_and_names_from_file(file_path)
                
                if not address_map:
                    print(f"No contract addresses found in file: {file_path}")
                    continue  # 跳过没有地址的文件
                
                print(f'Address map for file: {file_path}', address_map)
                
                # 对当前文件的 address_map 生成请求
                for var_name, address in address_map.items():
                    for domain in self.allowed_domains:
                        url = f"https://{domain}/address/{address}#code"
                        proxy = proxies.get('https', proxies.get('http'))
                        # 生成 0 到 2 秒之间的随机延迟
                        delay = random.uniform(0, 1.5)  
                        print(f"Sleeping for {delay} seconds")
                        time.sleep(delay)
                        yield scrapy.Request(
                            url,
                            headers=headers,
                            meta={"file_path":file_path,"var_name": var_name, "proxy": proxy},
                            callback=self.parse
                        )
    
    def parse(self, response):
        if(b'pragma solidity' in response.body):
            pass
        else:
            return
        var_name = response.meta.get("var_name")
        file_name = f"{var_name}.sol"
        # print(response.body)
        # 提取合约代码
        contract_code = response.body  
        print(type(contract_code))
        # input("Press Enter to continue...")
        if contract_code:
            # 根据每个文件名创建一个文件夹，创建文件夹用于存储以变量命名的合约代码
            file_path = response.meta.get("file_path")
            # 使用 os.path.splitext() 去掉文件名的后缀
            file_name_without_extension, _ = os.path.splitext(file_path)
            output_dir = file_name_without_extension
            os.makedirs(output_dir, exist_ok=True)
            file_path = os.path.join(output_dir, file_name)
            
            # 将代码保存到文件
            with open(file_path, "wb") as f:
                f.write(contract_code)
            
            extract_contract_code_from_file(file_path)
            clean_contract_code_from_file(file_path)

            self.logger.info(f"Contract code saved to {file_path}")


        else:
            self.logger.warning(f"No contract code found for variable: {var_name}")
        


if __name__ == "__main__":
    # 配置并启动 Scrapy 爬虫
    process = CrawlerProcess()
    process.crawl(mySpider)
    process.start()