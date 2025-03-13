import os
import json
import re
import time
import multiprocessing

# 正则匹配模式
sender_pattern = r"\[Sender\](0x[0-9a-fA-F]{40})"
return_pattern = r"^\((true|false|\d+(?:,\d{3})*|NULL|[_a-zA-Z]+=[\d+(?:,\d{3})*]+|Null Address|runtime code=\(long param\)|(?:[_a-zA-Z]+=[^,()]+,?\s*)+)\)$"

call_pattern = r"(?P<type>CALL|EVENT|STATICCALL|DELEGATECALL)\s*(?P<contract>\[?(?:Sender|Receiver)?\]?\s*[\w\s\-:\.\[\]\(\)\$,\/\|&]+(?:&#\d+;|[\u0000-\uFFFF])*)\s*\.\s*(?P<function>[a-zA-Z0-9_]+)\((?P<params>.*)\)"
callvalue_pattern = r"(?P<type>CALLvalue)\s*:\s*(?P<value>\d+\.\d+|\d+)\s*(?P<contract>\[?(?:Sender|Receiver)?\]?\s*[\w\s\-:\.\[\]\(\)\$,\/\|&]+)\.(?P<function>[a-zA-Z0-9_]+)\((?P<params>.*?)\)"
create_pattern = r"(?P<type>CREATE2?|CREATE)\s*(?P<contract>0x[a-fA-F0-9]{40}|[\w\s:\-(),|&]+)(?:\.(?P<function>\w+)\((?P<params>.*?)\))?"

# 处理参数括号嵌套
def extract_params(s):
    stack = []
    result = []
    i = 0
    while i < len(s):
        if s[i] == '(':
            stack.append(s[i])
            if len(stack) > 1:
                result.append(s[i])
        elif s[i] == ')':
            stack.pop()
            if len(stack) > 0:
                result.append(s[i])
        else:
            if len(stack) > 0:
                result.append(s[i])
        i += 1
    return ''.join(result)

# 解析合约调用
def extract_function_calls(line):
    function_calls = []

    # 解析 CREATE 操作
    match_create = re.search(create_pattern, line)
    if match_create:
        function_calls.append({
            "type": match_create.group("type"),  # CREATE
            "contract": match_create.group("contract"),  # 目标合约地址
            "function": match_create.group("function") if match_create.group("function") else "CREATE",
            "args": extract_params(f"({match_create.group('params')})") if match_create.group("params") else "NULL",
            "return_value": None,
            "internal_calls": []
        })

    # 解析 CALLvalue 语句
    match_callvalue = re.search(callvalue_pattern, line)
    if match_callvalue:
        function_calls.append({
            "type": match_callvalue.group("type"),
            "value": match_callvalue.group("value"),
            "contract": match_callvalue.group("contract"),
            "function": match_callvalue.group("function"),
            "args": extract_params(f"({match_callvalue.group('params')})") if match_callvalue.group("params") else "NULL",
            "return_value": None,
            "internal_calls": []
        })
    else:
        # 解析 CALL / EVENT / STATICCALL 语句
        for match in re.finditer(call_pattern, line):
            function_calls.append({
                "type": match.group("type"),
                "contract": match.group("contract"),
                "function": match.group("function"),
                "args": extract_params(f"({match.group('params')})") if match.group("params") else "NULL",
                "return_value": None,
                "internal_calls": []
            })

    return function_calls

def extract_sender(line):
    sender_match = re.search(sender_pattern, line)
    return sender_match.group(1) if sender_match else None

def extract_return_value(line):
    return_match = re.search(return_pattern, line)
    return return_match.group(1) if return_match else None

def process_text(text):
    if text.startswith('"') and text.endswith('"'):
        text = text[1:-1]

    lines = text.strip().split("\\n")
    result = {"sender": {}, "function_call": []}
    call_stack = []
    last_depth = -1
    depth = -1
    sender_found = False

    for line in lines:
        line = line.strip()
        if not sender_found:
            sender = extract_sender(line)
            if sender:
                result['sender'] = {"type": "SENDER", "content": sender}
                sender_found = True
                continue
        if line.isdigit():
            depth = int(line)
            continue
        function_calls = extract_function_calls(line)
        for function_call in function_calls:
            function_call["depth"] = depth
            if depth > last_depth:
                if call_stack:
                    call_stack[-1]["internal_calls"].append(function_call)
                else:
                    result["function_call"].append(function_call)
                call_stack.append(function_call)
            elif depth <= last_depth:
                while call_stack and call_stack[-1]["depth"] >= depth:
                    call_stack.pop()
                if call_stack:
                    call_stack[-1]["internal_calls"].append(function_call)
                else:
                    result["function_call"].append(function_call)
                call_stack.append(function_call)
        return_value = extract_return_value(line)
        if return_value is not None and call_stack:
            call_stack[-1]["return_value"] = return_value
        last_depth = depth
    return result


def validate_call_hierarchy(calls):
    for call in calls:
        if "internal_calls" in call:
            for internal_call in call["internal_calls"]:
                if internal_call["depth"] != call["depth"] + 1:
                    return False, f"Call {internal_call['contract']} function {internal_call['function']} depth ({internal_call['depth']}) does not match parent call {call['contract']} function {call['function']} depth ({call['depth']})"                
                is_valid, error_message = validate_call_hierarchy(call["internal_calls"])
                if not is_valid:
                    return False, error_message
    return True, "All call hierarchies are correct"


def validate_json_file_worker(json_file_path, result_queue):
    try:
        with open(json_file_path, 'r', encoding='utf-8') as file:
            data = json.load(file)

        # 检查 data 是否为字典类型
        if not isinstance(data, dict):
            result_queue.put((False, f"Invalid JSON structure in {json_file_path}: Expected a dictionary"))
            return

        function_calls = data.get('function_call', [])
        if not function_calls:
            result_queue.put((False, f"No function calls found in {json_file_path}"))
            return

        is_valid, error_message = validate_call_hierarchy(function_calls)
        result_queue.put((is_valid, error_message))
    except Exception as e:
        result_queue.put((False, f"Exception occurred: {str(e)}"))


def validate_json_file(json_file_path, timeout=10):
    result_queue = multiprocessing.Queue()
    process = multiprocessing.Process(target=validate_json_file_worker, args=(json_file_path, result_queue))

    process.start()
    process.join(timeout)  # 等待 timeout 秒

    if process.is_alive():
        print(f"Validation timeout for {json_file_path} (exceeded {timeout}s)")
        process.terminate()
        process.join()
        return False, "Validation timeout"

    return result_queue.get() if not result_queue.empty() else (False, "Unknown error")


def process_all_txt_files(root_folder, output_folder, error_file, timeout_file):
    if not os.path.exists(output_folder):
        os.makedirs(output_folder)

    with open(error_file, "w", encoding="utf-8") as error_log, open(timeout_file, "w", encoding="utf-8") as timeout_log:
        for root, dirs, files in os.walk(root_folder):
            for file in files:
                if file.endswith(".txt"):
                    input_file_path = os.path.join(root, file)
                    output_file_path = os.path.join(output_folder, os.path.relpath(input_file_path, root_folder) + ".json")
                    output_dir = os.path.dirname(output_file_path)
                    if not os.path.exists(output_dir):
                        os.makedirs(output_dir)

                    print(f"正在处理文件: {input_file_path}")

                    with open(input_file_path, 'r', encoding='utf-8') as file:
                        text_data = file.read()

                    parsed_result = process_text(text_data)
                    with open(output_file_path, 'w', encoding='utf-8') as json_file:
                        json.dump(parsed_result, json_file, indent=4)

                    result, error_message = validate_json_file(output_file_path, timeout=20)
                    if result:
                        print(f"文件验证通过: {input_file_path}")
                    else:
                        timeout_log.write(input_file_path + "\n")
                        print(f"超时跳过: {input_file_path}")
                        error_log.write(f"{input_file_path}: {error_message}\n")
                        print(f"错误: {input_file_path}, 错误信息: {error_message}")

    print("处理完成！")


def main():
    root_folder = "log"
    output_folder = "output"
    error_file = "output/error_files.txt"
    timeout_file = "output/timeout_files.txt"
    process_all_txt_files(root_folder, output_folder, error_file, timeout_file)


if __name__ == "__main__":
    main()
