import json
import os
import tempfile
import re
from typing import Dict, List, Set, Tuple, Optional

# ======================== CONFIGURATION ========================
FUNC_DEF_DIR = r"G:\tx-anomaly-predict\zp9080\Poc-Function-Final"
CALL_LOG_DIR = r"G:\safe\pythonProject\balanced_test_dataset"
DUPLICATES_FILE = r"G:\safe\longchain_RAG\functions\duplicates.json"
CALL_LIST_FILE = r"G:\safe\longchain_RAG\functions\call_list.json"

OUTPUT_JSON_DIR = r"G:\safe\pythonProject\balanced_test_dataset_preprocessed1"
PRUNING_OUTPUT_DIR = r"G:\safe\longchain_RAG\t\functions\processed_output"

ENABLE_PRUNING = True
ENABLE_PRUNING_FROM_LIST = False
ENABLE_CLEANING = True
TARGET_FUNCTION = "executeOperation"

PRUNING_CONFIG = {
    "remove_events": False,
    "remove_static_balance": True,     # 删除无价值的 STATICCALL（只删除 decimals/symbol/name）
    "max_depth": 12,
    "shorten_args": True,
    "max_arg_length": 200,
    "address_alias": True,
    "remove_duplicate_marked": True,   # 删除被标记为 _duplicate 的节点
    "force_keep_functions": [
        "flashLoan", "executeOperation",
        "withdraw", "transferFrom", "swap", "yoink"
    ]
}
# ================================================================

def ensure_dir(path: str) -> None:
    os.makedirs(path, exist_ok=True)

# 安全读取 JSON 文件（处理编码错误）
def safe_load_json(filepath: str) -> dict:
    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()
    # 如果仍有问题，尝试用 latin-1 解码（保证所有字节可读）
    if not content:
        with open(filepath, 'r', encoding='latin-1') as f:
            content = f.read()
    return json.loads(content)

# 安全写入 JSON 文件（确保输出为 UTF-8）
def safe_dump_json(filepath: str, data: dict) -> None:
    with open(filepath, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)

# ------------------------- 1. Cleaning Module for Function Definitions (based on duplicates.json) -------------------------
def clean_json_duplicates(func_file: str, duplicates_file: str) -> int:
    with open(func_file, 'r', encoding='utf-8') as f:
        data = json.load(f)
    with open(duplicates_file, 'r', encoding='utf-8') as f:
        duplicates = json.load(f)

    dup_set = set()
    for dup in duplicates:
        fname = dup.get("function_name")
        code = dup.get("original_code")
        if fname and code is not None:
            dup_set.add((fname, code))

    keep_set = set(PRUNING_CONFIG.get("force_keep_functions", []))

    filtered = []
    for item in data:
        fname = item.get("function_name")
        code = item.get("original_code")
        if fname in keep_set:
            filtered.append(item)
            continue
        if (fname, code) in dup_set:
            continue
        filtered.append(item)

    with open(func_file, 'w', encoding='utf-8') as f:
        json.dump(filtered, f, indent=2, ensure_ascii=False)
    return len(data) - len(filtered)

def run_cleaning_on_function_defs() -> Dict:
    stats = {}
    if not os.path.exists(DUPLICATES_FILE):
        print("Duplicates file not found. Function definition cleaning skipped.")
        return stats
    for filename in os.listdir(FUNC_DEF_DIR):
        if filename.endswith(".json") and not filename.endswith(".sol.json"):
            func_path = os.path.join(FUNC_DEF_DIR, filename)
            try:
                removed = clean_json_duplicates(func_path, DUPLICATES_FILE)
                if removed > 0:
                    print(f"Cleaned function definitions in {filename}: removed {removed} duplicate entries")
                stats[filename] = {"removed_duplicates": removed}
            except Exception as e:
                print(f"Error cleaning {filename}: {e}")
                stats[filename] = {"error": str(e)}
    return stats

# ------------------------- 2. Cleaning Module for Call Logs (internal duplicate marking) -------------------------
def mark_duplicate_calls_in_node(node: Dict, seen_signatures: Set[Tuple]) -> None:
    if not isinstance(node, dict):
        return
    signature = (
        node.get("type", ""),
        node.get("contract", ""),
        node.get("function", ""),
        node.get("args", ""),
        node.get("value", ""),
        node.get("return_value", ""),
    )
    if signature in seen_signatures:
        node["_duplicate"] = True
    else:
        seen_signatures.add(signature)
        node.pop("_duplicate", None)
    if "internal_calls" in node and isinstance(node["internal_calls"], list):
        for child in node["internal_calls"]:
            mark_duplicate_calls_in_node(child, seen_signatures)

def clean_call_log_duplicates(call_log_path: str) -> int:
    data = safe_load_json(call_log_path)

    roots = None
    if "logs" in data and "calls" in data["logs"] and isinstance(data["logs"]["calls"], list):
        roots = data["logs"]["calls"]
    elif "calls" in data and isinstance(data["calls"], list):
        roots = data["calls"]
    elif "function_call" in data and isinstance(data["function_call"], list):
        roots = data["function_call"]
    else:
        print(f"Warning: {call_log_path} has no recognized call structure")
        return 0

    marked_count = 0
    for root in roots:
        seen = set()
        def mark_recursive(node):
            nonlocal marked_count
            if not isinstance(node, dict):
                return
            sig = (
                node.get("type", ""),
                node.get("contract", ""),
                node.get("function", ""),
                node.get("args", ""),
                node.get("value", ""),
                node.get("return_value", ""),
            )
            if sig in seen:
                if not node.get("_duplicate"):
                    node["_duplicate"] = True
                    marked_count += 1
            else:
                seen.add(sig)
                node.pop("_duplicate", None)
            if "internal_calls" in node and isinstance(node["internal_calls"], list):
                for child in node["internal_calls"]:
                    mark_recursive(child)
        mark_recursive(root)

    safe_dump_json(call_log_path, data)
    return marked_count

def run_cleaning_on_call_logs() -> Dict:
    stats = {}
    for filename in os.listdir(CALL_LOG_DIR):
        if filename.endswith(".json"):
            filepath = os.path.join(CALL_LOG_DIR, filename)
            try:
                marked = clean_call_log_duplicates(filepath)
                if marked > 0:
                    print(f"Marked {marked} duplicate calls in {filename}")
                stats[filename] = {"marked_duplicates": marked}
            except Exception as e:
                print(f"Error processing {filename}: {e}")
                stats[filename] = {"error": str(e)}
    return stats

# # ------------------------- 3. Injection Module -------------------------
# def build_function_map(func_def_file: str) -> Dict[str, Dict[str, str]]:
#     with open(func_def_file, 'r', encoding='utf-8') as f:
#         data = json.load(f)
#     mapping = {}
#     for entry in data:
#         fname = entry.get("function_name")
#         if fname:
#             mapping[fname] = {
#                 "original_code": entry.get("original_code", ""),
#                 "description": entry.get("description", "")
#             }
#     return mapping


# def process_calls_inject(calls: List[Dict], seen_functions: Set[str],
#                          func_map: Dict[str, Dict[str, str]]) -> None:
#     for call in calls:
#         fname = call.get("function")
#         if fname in func_map:
#             if fname not in seen_functions:
#                 seen_functions.add(fname)
#                 print(f"   [INJECT] First occurrence of '{fname}': injected original_code + description")
#                 updated = {
#                     "id": call.get("id"),
#                     "contract": call.get("contract"),
#                     "function": call.get("function"),
#                     "args": call.get("args"),
#                     "original_code": func_map[fname]["original_code"],
#                     "description": func_map[fname]["description"],
#                     "return_value": call.get("return_value"),
#                     "depth": call.get("depth"),
#                     "internal_calls": call.get("internal_calls", [])
#                 }
#             else:
#                 print(f"   [INJECT] Duplicate occurrence of '{fname}': added flag=1")
#                 updated = {
#                     "id": call.get("id"),
#                     "contract": call.get("contract"),
#                     "function": call.get("function"),
#                     "args": call.get("args"),
#                     "flag": 1,
#                     "return_value": call.get("return_value"),
#                     "depth": call.get("depth"),
#                     "internal_calls": call.get("internal_calls", [])
#                 }
#             call.clear()
#             call.update(updated)
#         if "internal_calls" in call:
#             process_calls_inject(call["internal_calls"], seen_functions, func_map)


# def inject_file_to_string(call_log_path: str, func_def_dir: str) -> str:
#     base_name = os.path.basename(call_log_path)
#     func_def_name = base_name
#     func_def_path = os.path.join(func_def_dir, func_def_name)

#     if not os.path.exists(func_def_path):
#         print(f"⚠️ No function definition for {base_name}, skipping injection")
#         with open(call_log_path, 'r', encoding='utf-8') as f:
#             return f.read()

#     func_map = build_function_map(func_def_path)
#     with open(call_log_path, 'r', encoding='utf-8') as f:
#         data = json.load(f)

#     if "logs" in data and "calls" in data["logs"]:
#         calls = data["logs"]["calls"]
#     elif "calls" in data:
#         calls = data["calls"]
#     else:
#         return json.dumps(data, ensure_ascii=False)

#     seen = set()
#     process_calls_inject(calls, seen, func_map)
#     return json.dumps(data, ensure_ascii=False, indent=2)

# ------------------------- 4. Pruning Module -------------------------
def apply_general_rules(node: Dict, current_depth: int = 0) -> Optional[Dict]:
    if not isinstance(node, dict):
        return node

    # 删除被标记为重复的节点（如果启用）
    if PRUNING_CONFIG.get("remove_duplicate_marked", False) and node.get("_duplicate") == True:
        return None

    max_depth = PRUNING_CONFIG.get("max_depth")
    if max_depth and current_depth > max_depth:
        return {"_truncated": f"depth {current_depth} exceeds limit"}

    node_type = node.get("type", "")
    func_name = node.get("function", "")

    # EVENT 节点：不再删除（保留所有事件）
    # if PRUNING_CONFIG.get("remove_events", False) and node_type == "EVENT":
    #     return None

    # STATICCALL 只删除无价值的元数据查询
    if PRUNING_CONFIG.get("remove_static_balance", False) and node_type == "STATICCALL":
        if any(key in func_name.lower() for key in ["decimals", "symbol", "name"]):
            return None
        # balanceOf 和 getReserves 等保留

    if "internal_calls" in node and isinstance(node["internal_calls"], list):
        new_calls = []
        for child in node["internal_calls"]:
            processed_child = apply_general_rules(child, current_depth + 1)
            if processed_child is not None:
                new_calls.append(processed_child)
        node["internal_calls"] = new_calls

    if PRUNING_CONFIG.get("shorten_args", False) and "args" in node and isinstance(node["args"], str):
        max_len = PRUNING_CONFIG.get("max_arg_length", 200)
        if len(node["args"]) > max_len:
            node["args"] = node["args"][:max_len] + "...<truncated>"

    if PRUNING_CONFIG.get("address_alias", False) and "contract" in node:
        addr = node["contract"]
        if isinstance(addr, str):
            hex_match = re.search(r'0x[a-fA-F0-9]{8,}', addr)
            if hex_match and len(hex_match.group(0)) > 10:
                hex_addr = hex_match.group(0)
                short_addr = hex_addr[:6] + "..." + hex_addr[-4:]
                node["contract"] = addr.replace(hex_addr, short_addr)

    return node

def extract_deepest_chain(root: Dict, target_func: str) -> Tuple[List[Dict], Optional[int]]:
    deepest_chain = []
    first_depth = None

    def dfs(node: Dict, depth: int, path: List[Dict]) -> int:
        nonlocal deepest_chain, first_depth
        path.append(node)
        max_depth = depth

        if node.get('function') == target_func:
            if first_depth is None:
                first_depth = node.get('depth')
            if depth > len(deepest_chain) - 1:
                deepest_chain = path.copy()
            for child in node.get('internal_calls', []):
                child_max = dfs(child, depth + 1, path.copy())
                max_depth = max(max_depth, child_max)
        elif 'internal_calls' in node:
            for child in node['internal_calls']:
                child_max = dfs(child, depth + 1, path.copy())
                max_depth = max(max_depth, child_max)
        return max_depth

    dfs(root, root.get('depth', 0), [])
    return deepest_chain, first_depth

def prune_same_level_non_target(node: Dict, target_depth: int, target_func: str) -> None:
    if 'internal_calls' not in node:
        return
    new_calls = []
    for child in node['internal_calls']:
        child_func = child.get('function')
        child_depth = child.get('depth')
        if child_func == target_func or child_depth != target_depth:
            new_calls.append(child)
            prune_same_level_non_target(child, target_depth, target_func)
    node['internal_calls'] = new_calls

def prune_single_file_to_string(call_log_path: str, target_func: str,
                                apply_general: bool = True) -> str:
    data = safe_load_json(call_log_path)

    root = None
    if "logs" in data and "calls" in data["logs"] and data["logs"]["calls"]:
        root = data["logs"]["calls"][0] if isinstance(data["logs"]["calls"], list) else data["logs"]["calls"]
    elif "calls" in data and data["calls"]:
        root = data["calls"][0] if isinstance(data["calls"], list) else data["calls"]
    elif "function_call" in data and data["function_call"]:
        root = data["function_call"][0] if isinstance(data["function_call"], list) else data["function_call"]
    else:
        return json.dumps(data, ensure_ascii=False)

    if apply_general:
        root = apply_general_rules(root)
        if root is None:
            root = {"_pruned": "all nodes removed"}

    deepest_chain, first_depth = extract_deepest_chain(root, target_func)
    if deepest_chain and first_depth is not None:
        first_node = deepest_chain[0]
        prune_same_level_non_target(first_node, first_depth, target_func)
        new_root = first_node
    else:
        new_root = root

    if "logs" in data and "calls" in data["logs"]:
        data["logs"]["calls"] = [new_root]
    elif "calls" in data:
        data["calls"] = [new_root]
    elif "function_call" in data:
        data["function_call"] = [new_root]
    else:
        data = new_root

    return json.dumps(data, ensure_ascii=False, indent=2)

def run_pruning_from_list(call_list_file: str, output_dir: str, target_func: str) -> Optional[str]:
    if not os.path.exists(call_list_file):
        print(f"Error: Call list file not found: {call_list_file}")
        return None
    with open(call_list_file, 'r', encoding='utf-8') as f:
        call_data = json.load(f)

    processed_roots = []
    for root in call_data:
        root = apply_general_rules(root)
        if root is None:
            continue
        deepest_chain, first_depth = extract_deepest_chain(root, target_func)
        if deepest_chain and first_depth is not None:
            first_node = deepest_chain[0]
            prune_same_level_non_target(first_node, first_depth, target_func)
            processed_roots.append(first_node)
        else:
            processed_roots.append(root)

    ensure_dir(output_dir)
    output_file = os.path.join(output_dir, "list6.json")
    with open(output_file, 'w', encoding='utf-8') as f:
        json.dump(processed_roots, f, indent=2)
    return output_file

# ------------------------- 5. Main Pipeline -------------------------
def process_all_call_logs():
    ensure_dir(OUTPUT_JSON_DIR)
    stats = {"processed": 0, "failed": 0}

    if ENABLE_CLEANING:
        print("=== Step 0: Cleaning function definitions (based on duplicates.json) ===")
        func_clean_stats = run_cleaning_on_function_defs()
        total_removed = sum(v.get("removed_duplicates", 0) for v in func_clean_stats.values())
        print(f"Function definition cleaning completed. Total removed entries: {total_removed}")

        print("=== Step 1: Marking internal duplicate calls in call logs ===")
        call_clean_stats = run_cleaning_on_call_logs()
        total_marked = sum(v.get("marked_duplicates", 0) for v in call_clean_stats.values())
        print(f"Call log marking completed. Total marked duplicate nodes: {total_marked}")

    for filename in os.listdir(CALL_LOG_DIR):
        src_path = os.path.join(CALL_LOG_DIR, filename)
        out_path = os.path.join(OUTPUT_JSON_DIR, filename)

        try:
            # 安全读取文件（处理编码错误）
            with open(src_path, 'r', encoding='utf-8', errors='gbk') as f:
                json_str = f.read()

            if ENABLE_PRUNING:
                with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as tmp:
                    tmp.write(json_str)
                    tmp_path = tmp.name
                try:
                    json_str = prune_single_file_to_string(tmp_path, TARGET_FUNCTION, apply_general=True)
                finally:
                    os.unlink(tmp_path)

            with open(out_path, 'w', encoding='utf-8') as f:
                f.write(json_str)
            stats["processed"] += 1
        except Exception as e:
            print(f"Failed: {filename} - {e}")
            stats["failed"] += 1

    return stats

def main():
    print("=== TxShield Preprocessing ===")
    if not ENABLE_PRUNING_FROM_LIST:
        stats = process_all_call_logs()
        print(f"Processed: {stats['processed']}, Failed: {stats['failed']}")
    else:
        output_path = run_pruning_from_list(CALL_LIST_FILE, PRUNING_OUTPUT_DIR, TARGET_FUNCTION)
        print(f"Pruning output: {output_path}")
    print("=== Preprocessing Complete ===")

if __name__ == "__main__":
    main()