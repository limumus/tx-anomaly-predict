import os
import json
import re



def find_directories(name,root_dir):
    """
    遍历 root_dir 下的所有文件夹，返回名称为 xxx 的文件夹路径列表。

    参数:
        root_dir (str): 起始目录路径。

    返回:
        list: 包含所有名称为 xxx 的文件夹路径的列表。
    """
    directories = []

    # 遍历 root_dir 及其子目录
    for root, dirs, files in os.walk(root_dir):
        # 检查当前目录中的子目录是否有名为 xyz 的文件夹
        if  name in dirs:
            # 构造完整路径并添加到列表中
            path = os.path.join(root, name)
            directories.append(path)

    return directories

def find_file(name,root_dir):
    """
    遍历 root_dir 下的所有文件夹，返回名称为 xxx 的文件路径。
    参数:
        root_dir (str): 起始目录路径。
    """
    # 遍历 root_dir 及其子目录
    for root, dirs, files in os.walk(root_dir):
        for file in files:
            if  name in file and file.endswith('.sol'):
                return os.path.join(root,file)

def get_attacker_contract_set():
    file_list = []
    target_directory = "/home/zp9080/Code/DeFiHackLabs/src/test/"

    # 遍历文件夹
    for root, dirs, files in os.walk(target_directory):
        # 将当前目录下的所有文件名添加到文件列表中
        for file in files:
            file_list.append(os.path.join(root, file))  # 保留完整路径

    attacker_contract_set={""}
    for each in file_list:
        with open(each,'r') as f:
            lines=f.readlines()
            for line in lines:
                if(('contract' in line and 'Test' in line and '{' in line) or ('Exploit' in line and '{' in line)):
                    attacker_contract_set.add(line.split(" ")[1])
    return attacker_contract_set


def get_function_definition(file_path, func_name,flag,lib_list):
    """
    从 Solidity 文件中提取指定函数的定义。

    参数:
        file_path (str): Solidity 文件的路径。
        function_name (str): 需要提取的函数名。

    返回:
        str: 如果找到函数定义，返回函数定义的字符串；否则返回 None。
    """
    function_definition=""
    if(flag==0):
        current_function = []

        with open(file_path, 'r') as f:
            lines = f.readlines()
        start=0
        for line in lines:
            # find start of function
            if(func_name in line and 'function' in line and ';' not in line and '(' in line and (line.index('function') < line.index(func_name)) ):
                 #仍然有一点不足，就是比如function xxx ，如果函数名为xxxyyy,那么包含了xxx,函数original_code就会受影响，
                 #因此应该先利用split提取出函数名，然后再进行处理比较合理
                if(line.strip().split(' ')[1].split('(')[0]==func_name):
                    start=start+2
            elif( (func_name not in line and 'function' in line and start==2 ) or ('/**' in line and start==2) or ('LICENSE' in line and start==2) or ('pragma solidity' in line and start==2)):
                start=start-1
            
            if(start==2):
                current_function.append(line)
            if(start==1):
                break
        
        function_definition=''.join(current_function)

    else:
        current_function = []
        with open(file_path, 'r') as f:
            lines = f.readlines()
        start=0
        flag=0
        for line in lines:
            #遇到} }也是一个函数定义的结束
            if('}'in line):flag+=1
            elif('}' not in line and flag>0):flag-=1
            # find start of function
            if(func_name in line and 'function' in line and ';' not in line and '(' in line and (line.index('function') < line.index(func_name)) ):
                if(line.strip().split(' ')[1].split('(')[0]==func_name):
                    start=start+2
            elif( (func_name not in line and 'function' in line and start==2 ) or ('fallback' in line and start==2) or ('receive' in line and start==2) or (flag==2 and start==2) ):
                start=start-1
            if(start==2):
                current_function.append(line)
            if(start==1):
                break
        function_definition=''.join(current_function)

        if(function_definition!=""):
           pass
        else:
            for file in lib_list:
                current_function = []
                with open(file, 'r') as f:
                    lines = f.readlines()
                start=0
                flag=0
                for line in lines:
                    #遇到} }也是一个函数定义的结束
                    if('}'in line):flag+=1
                    elif('}' not in line and flag>0):flag-=1
                    # find start of function
                    if(func_name in line and 'function' in line and ';' not in line and '(' in line and (line.index('function') < line.index(func_name)) ):
                        if(line.strip().split(' ')[1].split('(')[0]==func_name):
                            start=start+2
                    elif( (func_name not in line and 'function' in line and start==2 ) or ('fallback' in line and start==2) or ('receive' in line and start==2) or (flag==2 and start==2) ):
                        start=start-1
                    if(start==2):
                        current_function.append(line)
                    if(start==1):
                        break

                function_definition=''.join(current_function)
                if(function_definition!=""):break
                else:continue
    
    return function_definition 


if __name__ == '__main__':
    # 目录路径
    root_dir = '/home/zp9080/Code/src/test'
    json_files_dir = '/home/zp9080/Code/Poc-Function-Set'  # 假设JSON文件都在这个目录下
    attacker_contract_set=get_attacker_contract_set()
    # 批量处理多个JSON文件,每个json文件为一个单位,每个json文件对应一个POC
    for json_file in os.listdir(json_files_dir):
        if json_file.endswith('.json'):
            json_data_list=[]
            filename=json_file.replace('.json','')
            json_file_path = os.path.join(json_files_dir, json_file)
            output_root_dir='/home/zp9080/Code/Poc-Function-NoDescription/'
            lib_path="/home/zp9080/Code/DeFiHackLabs/lib/forge-std/src/"
            lib_list=[]
            for root, dirs, files in os.walk(lib_path):
               for file in files:
                   lib_list.append(os.path.join(root, file))  # 保留完整路径

            # 读取JSON文件
            with open(json_file_path, 'r') as f:
                data = json.load(f)
            
            # 遍历 JSON 中的每个合约，查找其中的 methodIdentifiers
            #data是个列表，each是个字典,每个each其实就是对应的一个contract或者interface,针对每个each
            #判断其是attacker还是vicitim,然后进行original_code的寻找
            for each in data:
                victim_contract_functions=[]
                attacker_contract_functions=[]
                file=each['file'].replace('.json','')
                type=0
                if(file in attacker_contract_set):
                    type=1
                methods=each['methodIdentifiers']
                for key,value in methods.items():
                    if(type==1):
                        attacker_contract_functions.append(key)
                    else:
                        victim_contract_functions.append(key)
                
                if(type==0):
                    # 寻找victim_contract_functions的original_code
                    contract_folder = find_directories(filename,root_dir)
                    if(contract_folder==[]):continue
                    else :contract_folder=contract_folder[0]

                    for func_name in victim_contract_functions:
                        func_definition=''
                        func_name=func_name.split('(')[0].strip()
                        for sol_file in os.listdir(contract_folder):
                            if sol_file.endswith('.sol'):
                                sol_file_path = os.path.join(contract_folder, sol_file)
                                # print(func_name,sol_file,sol_file_path)
                                func_definition = get_function_definition(sol_file_path, func_name,0,lib_list)
                                if func_definition!='':
                                    break

                        # 检查 func_name 是否已存在
                        found = False
                        for item in json_data_list:
                            if item["function_name"] == func_name:
                                found = True
                                break

                        # 如果未找到，则添加到列表
                        if not found:
                            if func_definition != '':
                                json_data_list.append({"contract/interface":file,"source_type":"victim_contract","function_name": func_name, "original_code": func_definition, "description": ""})
                            else:
                                json_data_list.append({"contract/interface":file,"source_type":"victim_contract","function_name": func_name, "original_code": "", "description": ""})

                else:
                    #寻找attacker_contract_functions的original_code
                    contract_file_path= find_file(filename,root_dir)
                    for func_name in attacker_contract_functions:
                        func_definition=''
                        func_name=func_name.split('(')[0].strip()
                        func_definition = get_function_definition(contract_file_path, func_name,1,lib_list)

                        # 检查 func_name 是否已存在
                        found = False
                        for item in json_data_list:
                            if item["function_name"] == func_name:
                                found = True
                                break

                        # 如果未找到，则添加到列表
                        if not found:
                            if func_definition != '':
                                json_data_list.append({"contract/interface":file,"source_type":"attacker_contract","function_name": func_name, "original_code": func_definition, "description": ""})
                            else:
                                json_data_list.append({"contract/interface":file,"source_type":"attacker_contract","function_name": func_name, "original_code": "", "description": ""})

            # 将修改后的数据保存回 JSON 文件
            output_filename=os.path.join(output_root_dir,json_file)
            with open(output_filename, 'w') as f:
                json.dump(json_data_list, f, indent=2)

            print(f"Updated {json_file_path} with function definitions.")
