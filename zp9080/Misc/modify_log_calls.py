import os
import json

def check_calls_length(folder_path: str):
    """遍历文件夹中的JSON文件，检测calls数组长度大于1的文件路径"""
    for root, dirs, files in os.walk(folder_path):  # 递归遍历所有子文件夹[2,3](@ref)
        for file in files:
            if file.endswith(".json"):  # 筛选JSON文件[1,2](@ref)
                file_path = os.path.join(root, file)
                try:
                    with open(file_path, "r", encoding="utf-8") as f:
                        data = json.load(f)
                    calls = data.get("logs", {}).get("calls", [])  # 安全获取嵌套字段
                    if len(calls) > 1:
                        print(f"满足条件的文件路径: {file_path}")
                except json.JSONDecodeError:
                    print(f"错误：{file_path} 不是有效的JSON文件")
                except Exception as e:
                    print(f"读取 {file_path} 时发生异常: {str(e)}")


def modify_calls_elements(folder_path: str):
    """修改后版本：所有文件均写入Final-Data目录，仅当calls长度>1时修改内容"""
    output_folder = "/home/zp9080/Code/tx-anomaly-predict/zp9080/Final-Data"
    os.makedirs(output_folder, exist_ok=True)  # 确保目标目录存在[4,5](@ref)

    for root, _, files in os.walk(folder_path):  # 递归遍历目录[2,3](@ref)
        for file in files:
            if file.endswith(".json"):
                source_path = os.path.join(root, file)
                target_path = os.path.join(output_folder, file)  # 保持同名[2](@ref)
                
                try:
                    with open(source_path, "r", encoding="utf-8") as f:
                        data = json.load(f)
                        calls = data.get("logs", {}).get("calls", [])
                        
                        modified = False
                        # 仅当长度>1时修改元素
                        if len(calls) > 1:  # [7](@ref)
                            calls[0] = calls[1]
                            data["logs"]["calls"] = calls
                            modified = True
                        
                        # 无论是否修改都写入目标路径
                        with open(target_path, "w", encoding="utf-8") as new_f:
                            json.dump(data, new_f, indent=2, ensure_ascii=False)  # 格式化写入[4,6](@ref)
                        
                        print(f"已{'修改并' if modified else ''}生成文件: {target_path}")
                            
                except json.JSONDecodeError:
                    print(f"错误：{source_path} 不是有效的JSON文件")
                except PermissionError:
                    print(f"权限不足：无法写入 {target_path}")
                except Exception as e:
                    print(f"处理 {source_path} 时发生异常: {str(e)}")


if __name__=="__main__":
    folder_path="/home/zp9080/Code/tx-anomaly-predict/zp9080/Final-Data"
    check_calls_length(folder_path)
    # modify_calls_elements(folder_path)