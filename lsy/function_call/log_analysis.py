import re
import json
import os
import threading

import multiprocessing
import time

# 修改后的正则表达式
# CALL_PATTERN = re.compile(r"\[([0-9]+)\]([\w\s:]+)::(\w+)\{?(.*?)\}?\((.*?)\)\s*(?:\[([^\]]*)\])?")
CALL_PATTERN = re.compile(r"""
    \[([0-9]+)\]                           # 捕获调用编号，如 [123]
    \s*([\w\s\/-]+)::                      # 捕获类名，如 Pool、NFT、bxh/usdt Pair
    (\w+)                                  # 捕获函数名，如 unstakeNft、approve、token0
    (?:\{(.*?)\})?                         # 可选的花括号内参数，如 {value: 8000000000000000}
    \((.*?)\)                              # 小括号内的参数，如 ([13, 14])
    \s*(?:\[(.*?)\])?                      # 可选的方括号内容，如 [staticcall]
""", re.VERBOSE)
# 匹配合约创建调用（如 → new Attacker@0x...）
CREATE_CALL_PATTERN = re.compile(r"\[([0-9]+)\] → new (\S+)(?:\s*\[([^\]]*)\])?")
# 匹配返回值的正则表达式
RETURN_PATTERN = re.compile(r"← \[(Return|Stop)\]\s*(.*)")

class LogParser:
    def __init__(self):
        self.calls = []
        self.call_stack = []  # (depth, call)

    def parse_log(self, log_line):
        # 尝试匹配普通调用、创建调用和返回
        call_match = CALL_PATTERN.search(log_line)
        create_match = CREATE_CALL_PATTERN.search(log_line)
        return_match = RETURN_PATTERN.search(log_line)

        # 仅处理调用或返回行
        if call_match or create_match or return_match:
            depth = self._calculate_depth(log_line)
            # 调整调用栈层级
            while self.call_stack and self.call_stack[-1][0] >= depth:
                self.call_stack.pop()
            # 处理调用或返回
            if call_match:
                self._handle_call(call_match, depth)
            elif create_match:
                self._handle_create_call(create_match, depth)
            elif return_match:
                self._handle_return(return_match)
        else:
            # 非调用/返回行，完全跳过
            pass

    def _calculate_depth(self, log_line):
        """ 通过解析行首的├─、└─和│符号确定调用的深度 """
        depth = log_line.count('│') + log_line.count('├') + log_line.count('└')
        return depth

    def _handle_call(self, match, depth):
        call_id, contract, func, value, args, flags = match.groups()
        call_info = {
            "id": call_id,
            "contract": contract.strip(),
            "function": func,
            "value": value.strip() if value else None,
            "args": args,
            "return_value": None,
            "depth": depth,
            "internal_calls": []
        }
        self._add_to_parent(call_info, depth)
        self.call_stack.append((depth, call_info))
        print(f"Call parsed: {call_info}")

    def _handle_create_call(self, match, depth):
        call_id, contract, flags = match.groups()
        call_info = {
            "id": call_id,
            "contract": f"→ new {contract.strip()}",
            "function": "constructor",
            "args": "",
            "return_value": None,
            "depth": depth,
            "internal_calls": []
        }
        self._add_to_parent(call_info, depth)
        self.call_stack.append((depth, call_info))
        print(f"Create call parsed: {call_info}")

    def _handle_return(self, match):
        return_type = match.group(1)
        return_value = match.group(2).strip() if match.group(2) else None
        if self.call_stack:
            call_info = self.call_stack.pop()[1]
            call_info["return_value"] = return_value if return_value else "Returned"
            print(f"Return parsed: {call_info['id']}, Value: {call_info['return_value']}")

    def _add_to_parent(self, call_info, depth):
        if not self.call_stack:  # 根调用
            self.calls.append(call_info)
            print(f"Root call added: {call_info}")
        else:
            # 查找最近的父调用（depth更小）
            for parent_depth, parent_call in reversed(self.call_stack):
                if parent_depth < depth:
                    parent_call["internal_calls"].append(call_info)
                    print(f"Nested call added: {call_info} to parent {parent_call}")
                    break
            else:
                self.calls.append(call_info)  # 无父调用，作为根调用
                print(f"No parent found, added as root call: {call_info}")

    def get_logs(self):
        return {"calls": self.calls}


def validate_call_hierarchy(calls):
    for call in calls:
        if "internal_calls" in call:
            for internal_call in call["internal_calls"]:
                # 检查内部调用的深度是否比父调用深一层
                if internal_call["depth"] != call["depth"] + 1:
                    return False, f"调用 {internal_call['id']} 的深度 ({internal_call['depth']}) 与父调用 {call['id']} 的深度 ({call['depth']}) 不匹配"
                # 递归检查内部调用的层级
                is_valid, error_message = validate_call_hierarchy(call["internal_calls"])
                if not is_valid:
                    return False, error_message
    return True, "所有调用层级均正确"


def validate_json_file(json_file_path):
    with open(json_file_path, 'r', encoding='utf-8') as file:
        data = json.load(file)
    calls = data['logs']['calls']
    is_valid, error_message = validate_call_hierarchy(calls)
    return is_valid, error_message


def process_log_file_worker(file_path, output_path, error_log, validation_error_log, result_queue):
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            logs = f.read()

        start_index = logs.find("Ran 1 test for src/test/")
        if start_index == -1:
            raise ValueError("Test log pattern not found")

        logs = logs[start_index:]

        log_parser = LogParser()
        for line in logs.strip().split('\n'):
            log_parser.parse_log(line.strip())

        output = {'logs': log_parser.get_logs()}

        with open(output_path, "w", encoding="utf-8") as f:
            json.dump(output, f, indent=2, ensure_ascii=False)

        print(f"Processed {file_path} -> {output_path}")

        is_valid, error_message = validate_json_file(output_path)
        if not is_valid:
            with open(validation_error_log, "a", encoding="utf-8") as err_file:
                err_file.write(f"Validation error in {output_path}: {error_message}\n")
            print(f"Validation error in {output_path}: {error_message}")
            result_queue.put(False)
            return

        print(f"Success in {output_path}: {error_message}")
        result_queue.put(True)

    except Exception as e:
        with open(error_log, "a", encoding="utf-8") as err_file:
            err_file.write(f"Error processing {file_path}: {str(e)}\n")
        print(f"Error processing {file_path}: {str(e)}")
        result_queue.put(False)


def process_log_file(file_path, output_path, error_log, validation_error_log, max_errors=20, timeout=20):
    result_queue = multiprocessing.Queue()
    process = multiprocessing.Process(target=process_log_file_worker, args=(file_path, output_path, error_log, validation_error_log, result_queue))

    process.start()
    process.join(timeout)  # 等待子进程执行完成，超时后继续执行

    if process.is_alive():
        print(f"Processing {file_path} timed out after {timeout} seconds.")
        process.terminate()  # 终止子进程
        process.join()  # 确保子进程完全退出
        with open(error_log, "a", encoding="utf-8") as err_file:
            err_file.write(f"Timeout error in {file_path}: Exceeded {timeout} seconds.\n")
        return False

    return result_queue.get() if not result_queue.empty() else False



def main():
    input_dir = "function_call/data/"
    output_dir = "function_call/output"
    error_log = "error.txt"
    validation_error_log = "validation_errors.txt"

    if not os.path.exists(output_dir):
        os.makedirs(output_dir)

    for root, _, files in os.walk(input_dir):
        for file in files:
            if file.endswith(".sol.txt"):
                file_path = os.path.join(root, file)

                relative_path = os.path.relpath(file_path, input_dir)
                output_path = os.path.join(output_dir, relative_path.replace(".txt", ".json"))

                output_dir_path = os.path.dirname(output_path)
                if not os.path.exists(output_dir_path):
                    os.makedirs(output_dir_path)

                result = process_log_file(file_path, output_path, error_log, validation_error_log)


if __name__ == "__main__":
    main()
