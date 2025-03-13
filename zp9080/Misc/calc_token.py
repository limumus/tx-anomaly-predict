import tiktoken

def openai_token_counter(file_path, encoding_name="cl100k_base"):
    encoding = tiktoken.get_encoding(encoding_name)
    with open(file_path, 'r', encoding='utf-8') as f:
        text = f.read()
    tokens = encoding.encode(text)
    return len(tokens)

# 计算原始token数量
raw_tokens = openai_token_counter("/home/zp9080/Code/tx-anomaly-predict/hst/output_1/Moonhacker_exp.sol.json")

# 转换为千单位（两种格式可选）
# 格式1：精确到小数点后一位（如 15.3k）
k_tokens = raw_tokens / 1000
print(f"GPT-4接口Token数：{k_tokens:.1f}k")  # 示例输出：15.3k

# 格式2：自动整数/小数转换（如 15k 或 15.5k）
formatted_tokens = f"{int(k_tokens)}k" if k_tokens.is_integer() else f"{k_tokens:.1f}k"
print(f"GPT-4接口Token数：{formatted_tokens}")


