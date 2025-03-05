import os
import json
import multiprocessing


def validate_call_hierarchy(calls):
    for call in calls:
        if "internal_calls" in call:
            for internal_call in call["internal_calls"]:
                # 确保子调用的深度比父调用深一层
                if internal_call["depth"] != call["depth"] + 1:
                    return False, f"Call {internal_call['id']} depth ({internal_call['depth']}) does not match parent call {call['id']} depth ({call['depth']})"
                # 递归检查子调用
                is_valid, error_message = validate_call_hierarchy(call["internal_calls"])
                if not is_valid:
                    return False, error_message
    return True, "All call hierarchies are correct"


def validate_json_file_worker(json_file_path, result_queue):
    try:
        with open(json_file_path, 'r', encoding='utf-8') as file:
            data = json.load(file)

        calls = data.get('logs', {}).get('calls', [])
        if not calls:
            result_queue.put((False, "No calls found in JSON"))
            return

        is_valid, error_message = validate_call_hierarchy(calls)
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


def validate_json_files_in_directory(directory_path, timeout=10):
    error_files = []

    for root, _, files in os.walk(directory_path):
        for file_name in files:
            if file_name.endswith(".json"):
                json_file_path = os.path.join(root, file_name)
                is_valid, error_message = validate_json_file(json_file_path, timeout)

                if is_valid:
                    print(f"{file_name}: All call hierarchies are correct")
                else:
                    print(f"{file_name}: Error: {error_message}")
                    error_files.append(json_file_path)
    
    if error_files:
        error_file_path = r"error_files.txt"
        os.makedirs(os.path.dirname(error_file_path), exist_ok=True)
        with open(error_file_path, "w", encoding="utf-8") as error_file:
            for error_file_path in error_files:
                error_file.write(f"{error_file_path}\n")
        print(f"Error file paths have been saved to {error_file_path}")


if __name__ == "__main__":
    directory_path = r"output"
    validate_json_files_in_directory(directory_path, timeout=20)
