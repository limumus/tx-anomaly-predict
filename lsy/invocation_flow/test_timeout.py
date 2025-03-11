import os
import json
import multiprocessing

def validate_call_hierarchy(calls):
    """ 递归验证调用层次结构（忽略 sender ）"""
    for call in calls:
        if "internal_calls" in call:
            for internal_call in call["internal_calls"]:
                # 确保子调用的深度比父调用深一层
                if internal_call["depth"] != call["depth"] + 1:
                    return False, f"Call {internal_call['contract']} function {internal_call['function']} depth ({internal_call['depth']}) does not match parent call {call['contract']} function {call['function']} depth ({call['depth']})"
                # 递归检查子调用
                is_valid, error_message = validate_call_hierarchy(call["internal_calls"])
                if not is_valid:
                    return False, error_message
    return True, "All call hierarchies are correct"


def validate_json_file_worker(address, result_queue):
    """ 在子进程中执行 JSON 文件验证（忽略 sender） """
    json_file_path = os.path.normpath(os.path.join("output1", address.replace("test\\", "") + ".json"))

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


def validate_json_file(address, timeout=10):
    """ 启动子进程执行 JSON 验证，限制超时时间 """
    result_queue = multiprocessing.Queue()
    process = multiprocessing.Process(target=validate_json_file_worker, args=(address, result_queue))

    process.start()
    process.join(timeout)  # 等待 timeout 秒

    if process.is_alive():
        print(f"Validation timeout for {address} (exceeded {timeout}s)")
        process.terminate()
        process.join()
        return False, "Validation timeout"

    return result_queue.get() if not result_queue.empty() else (False, "Unknown error")


def validate_all_json_files(timeout_file, error_file):
    with open(timeout_file, "r", encoding="utf-8") as timeout_log, open(error_file, "w", encoding="utf-8") as error_file:
        timeout_lines = timeout_log.readlines()
        for line in timeout_lines:
            address = line.strip()  # 从timeout_file读取的地址
            print(f"正在验证文件: {address}")

            result, error_message = validate_json_file(address, timeout=600)
            if result:
                print(f"文件验证通过: {address}")
            else:
                error_file.write(f"{address}: {error_message}\n")
                print(f"错误: {address}, 错误信息: {error_message}")

    print("验证完成！")


if __name__ == "__main__":
    timeout_file = "output/timeout_files.txt"  # 存储地址的文件
    error_file = "output/verification_errors.txt"  # 验证错误日志文件
    validate_all_json_files(timeout_file, error_file)
