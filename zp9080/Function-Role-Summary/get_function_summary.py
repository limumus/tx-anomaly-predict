from openai import OpenAI
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import os
import time
import random

api_key_list=[
    "sk_dlZ5XhnBttNciZyKy47tnJgGYKT8qZstXcHAJnZTxHE",
    "sk_aNmeJVQOcLbibYdTolrl9egzAYIcmbBSn2oH0mGa35c",
    "sk_nzOp1aHIzoesG-8Df5QKHrJK0lcwmnIYrQK3_NzFrCg",
    "sk_MCOsBJ7PVE-9EUQCMPcLtagpm6p-3qMWdURs2-fR-V8",
    "sk_KAc8coQzqdsBrceASawtFRETpwxcOzA3-99iCztczqk",
    "sk_rJU8pweCi5fH8-ajKQ47t4ba_wkYjJMr2QzrT2tLABE",
    "sk_vFX-KWlpBMxb8F04eL62xkhrJBgBl08v5xybfWzXGu0",
    "sk_TskXzNC1ehry9Sr9O2gKWyMp80tUzBOuJGzJbS-zEbs",
    "sk_up14w5-lfqh9Xqn8Th17Jq1He2e3Sd9hS6OKzpanXwE",
    "sk_fhqZbhL4sVtVMJMmX3AC7eErv2Dk7tiLq3qZuolD1uY"
]


def get_function_summary(code,client):
    """使用OpenAI API获取函数总结"""
    try:
        '''
            1. 核心功能：概括性说明code的作用
            2. 安全机制：列出关键修饰符和防御措施
            3. 参数作用：解释函数参数的作用
            4. 返回说明：描述输出值的计算逻辑
            你的回答要求：前面四个内容控制在1000字以内，不使用技术术语堆砌，按我的提示顺序给出回答
            你回答的格式
                1.核心功能 ...
                2.安全机制 ...
                3.参数作用 ...
                4.返回说明 ...
                In summary:...
        '''
        response = client.chat.completions.create(
            model="deepseek/deepseek-v3/community",
            
            messages=[
                {
                    "role": "system",
                    "content": 
                    '''
                    You are an expert in smart contract security analysis. Please summarize the following Solidity functions:
                    1. Core function: Summarize the role of code
                    2. Security mechanism: List key modifiers and defense measures
                    3. Parameter Function: Explain the role of function parameters
                    4. Return description: Describe the calculation logic of the output value
                    Your response requirement: The first four contents should be controlled within 1000 words, do not use technical jargon, and provide answers in my prompt order.
                    The format of your answer
                        1. Core functions:
                        2. Security mechanism:
                        3. Parameter Function:
                        4. Return description:
                        In summary,
                   '''
                },
                {
                    "role": "user",
                    "content": f"Solidity function code:\n{code}"
                }
            ],
            temperature=0.3,
            max_tokens=1000,
            
        )
        return response.choices[0].message.content.strip()
    except Exception as e:
        print(f"API调用失败: {str(e)}")
        return None

def process_json_file(input_file, output_file,api_key, delay_range=(0.2, 1.0)):
    # 创建线程专属的OpenAI客户端
    client = OpenAI(
        base_url="https://api.ppinfra.com/v3/openai",
        api_key=api_key,  # 使用传入的API Key
    )
    
    """处理JSON文件并生成描述"""
    with open(input_file, 'r') as f:
        data = json.load(f)
    flag=0
    for item in data:
        if "original_code" in item and item["original_code"].strip():
            print(f"处理函数：{item.get('function_name', '未知函数')}")
            item["description"] = get_function_summary(item["original_code"],client) or "描述生成失败"
            print(f"描述：{item['description']}")
            if "错误" in item["description"]:
                flag=1
            # input("pause\n")
            time.sleep(random.uniform(*delay_range))  # 控制处理速度

    if data!= [] and flag==0:
        with open(output_file, 'w') as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
        print(f"处理完成，结果已保存到：{output_file}")

if __name__ == "__main__":
    # 获取待处理文件列表
    list_dir = [f for f in os.listdir("/home/zp9080/Code/Poc-Function-NoDescription") 
               if f.endswith(".json") and f not in os.listdir("/home/zp9080/Code/Poc-Function-Final")]
    print(f"待处理文件列表：{list_dir}")
    #配置参数
    THREAD_CONFIG = {
        "max_workers": 10,          # 并发线程数（建议CPU核心数2倍）[8](@ref)
        "delay_range": (0.5, 1.5)  # 处理间隔随机延迟（秒）[6](@ref)
    }
    # 创建线程池
    with ThreadPoolExecutor(max_workers=THREAD_CONFIG["max_workers"]) as executor:
        futures = []
        for idx, file in enumerate(list_dir):  # 增加索引
            input_path = os.path.join("/home/zp9080/Code/Poc-Function-NoDescription/", file)
            output_path = os.path.join("/home/zp9080/Code/Poc-Function-Final/", file)
            
            # 轮询分配API Key
            selected_key = api_key_list[idx % len(api_key_list)]  # 循环使用密钥[7](@ref)
            
            futures.append(
                executor.submit(
                    process_json_file,
                    input_path,
                    output_path,
                    selected_key,  # 传入当前分配的API Key
                    THREAD_CONFIG["delay_range"]
                )
            )
        
        # 监控任务进度
        for future in as_completed(futures):
            try:
                future.result()
            except Exception as e:
                print(f"文件处理异常: {str(e)}")
