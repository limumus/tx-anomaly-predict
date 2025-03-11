import json


# 定义递归函数，提取最深的 executeOperation 的完整链条，并剪枝非直系父节点的分支
def extract_execute_operations(data):
    flag = 0
    first_depth = None  # 用于保存第一个 executeOperation 的 depth

    def find_deepest_execute_operation(node, max_depth=0, path=[], keep_chain=[], parent_path=[], is_root=True):
        nonlocal flag, first_depth  # 引入外部作用域的 first_depth 变量

        path.append(node)
        current_parent_path = parent_path + [node]

        # 仅保留从根节点到第一个 `executeOperation` 的直系父节点路径
        if is_root:
            if node['depth'] == 0:
                if 'internal_calls' in node:
                    node['internal_calls'] = [child for child in node['internal_calls'] if child in current_parent_path]

        # 如果是 `executeOperation`，进行处理
        if node['function'] == 'executeOperation':
            if flag == 0:
                first_depth = node['depth']
                flag = 1
                print(f"First executeOperation depth: {first_depth}")  # 打印第一个 executeOperation 的 depth

            if node['depth'] > max_depth:
                max_depth = node['depth']
                keep_chain.clear()  # 清空之前的路径
                keep_chain.extend(path)  # 保留当前路径

            if 'internal_calls' in node:
                if is_root:
                    node['internal_calls'] = [child for child in node['internal_calls'] if
                                              child['function'] == 'executeOperation']
                for child in node['internal_calls']:
                    find_deepest_execute_operation(child, max_depth, path.copy(), keep_chain, current_parent_path,
                                                   is_root=False)

        elif 'internal_calls' in node:
            for child in node['internal_calls']:
                find_deepest_execute_operation(child, max_depth, path.copy(), keep_chain, current_parent_path, is_root)

        return max_depth, first_depth

    keep_chain = []
    max_depth, first_depth = find_deepest_execute_operation(data, 0, [], keep_chain, [], True)

    # 返回处理后的链条和第一个 executeOperation 的 depth
    return keep_chain, first_depth

def prune_same_level_non_execute_operations(node, execute_depth):
    """遍历树结构，删除同级的非 executeOperation 节点及其子节点"""
    if 'internal_calls' in node:
        # 过滤掉与 executeOperation 同级且函数名不是 executeOperation 的节点
        new_internal_calls = []
        for child in node['internal_calls']:
            if child['function'] == 'executeOperation' or child['depth'] != execute_depth:
                new_internal_calls.append(child)
            #else:
                # 打印信息，删除同级非 executeOperation 的节点
                #print(f"删除节点: ID = {child['id']}, Contract = {child['contract']}, Function = {child['function']}, Depth = {child['depth']}")

        node['internal_calls'] = new_internal_calls

        # 对内部调用继续递归
        for child in node['internal_calls']:
            prune_same_level_non_execute_operations(child, execute_depth)



# 从 call_list.json 读取数据
with open('call_list.json', 'r') as f:
    call_data = json.load(f)



# 提取每个根节点的最深 executeOperation 铯条，并进行剪枝
processed_data = []
for item in call_data:
    # 提取最深的 executeOperation 链条
    deepest_chain, first_depth = extract_execute_operations(item)
    if deepest_chain:
        # 获取第一个 executeOperation 节点
        first_execute_operation = deepest_chain[0]
        execute_depth = first_depth
        print(first_depth)
        # 剪枝同级非 executeOperation 的节点
        prune_same_level_non_execute_operations(first_execute_operation, execute_depth)

        # 只保留最深的 executeOperation 链条的根节点
        processed_data.append(deepest_chain[0])

# 将处理后的数据写入 list6.json
with open('list6.json', 'w') as f:
    json.dump(processed_data, f, indent=2)

print("处理完成，结果已写入 list6.json")
