import os
import matplotlib.pyplot as plt
from collections import defaultdict

def count_lines_optimized(file_path):
    """优化大文件行数统计方法（内存安全版）[1,6](@ref)"""
    with open(file_path, 'rb') as f:
        count = 0
        buf_size = 1024 * 1024  # 1MB缓冲区
        last_char = b'\n'
        
        while True:
            chunk = f.read(buf_size)
            if not chunk:
                break
            count += chunk.count(b'\n')
            last_char = chunk[-1:] if chunk else last_char
        
        # 处理最后一行无换行符的情况[8](@ref)
        if last_char != b'\n':
            count += 1
    return count

def find_extreme_files(directory):
    """查找目录下行数最多和最少的文件[2,3](@ref)"""
    file_stats = defaultdict(int)
    
    # 递归遍历目录（排除隐藏文件）[5](@ref)
    for root, dirs, files in os.walk(directory):
        dirs[:] = [d for d in dirs if not d.startswith('.')]  # 过滤隐藏目录
        
        for filename in files:
            # 过滤隐藏文件和非文本文件[2](@ref)
            if filename.startswith('.') or not is_text_file(filename):
                continue
                
            filepath = os.path.join(root, filename)
            try:
                lines = count_lines_optimized(filepath)
                file_stats[filepath] = lines
            except (IOError, UnicodeDecodeError) as e:
                print(f"警告：无法处理文件 {filepath}（{str(e)}）")
    
    if not file_stats:
        return None, None, 0, 0
        
    # 查找极值文件[7](@ref)
    max_file = max(file_stats, key=file_stats.get)
    min_file = min(file_stats, key=file_stats.get)
    return max_file, min_file, file_stats[max_file], file_stats[min_file]

def is_text_file(filename):
    """智能判断文本文件类型（扩展名过滤）[2](@ref)"""
    text_extensions = {'.txt', '.csv', '.py', '.js', '.json', '.md', '.log'}
    ext = os.path.splitext(filename)[1].lower()
    return ext in text_extensions

import os
import matplotlib.pyplot as plt
from collections import defaultdict

# 原有行数统计函数保持不变...

def generate_pie_chart(file_stats):
    """生成行数占比饼图（新增功能）[1,5,7](@ref)"""
    # 数据分组统计
    line_ranges = {
        '0-100': 0,
        '101-500': 0,
        '501-1000': 0,
        '1000+': 0
    }
    
    for lines in file_stats.values():
        if lines <= 100:
            line_ranges['0-100'] += 1
        elif 101 <= lines <= 500:
            line_ranges['101-500'] += 1
        elif 501 <= lines <= 1000:
            line_ranges['501-1000'] += 1
        else:
            line_ranges['1000+'] += 1

    # 过滤空数据组
    labels = [k for k, v in line_ranges.items() if v > 0]
    sizes = [v for v in line_ranges.values() if v > 0]
    
    # 可视化配置
    colors = ['#ff9999', '#66b3ff', '#99ff99', '#ffcc99']
    explode = (0.1, 0, 0, 0)[:len(labels)]  # 突出显示最大占比组
    
    plt.figure(figsize=(10, 6))
    plt.pie(sizes, 
            labels=labels, 
            colors=colors[:len(labels)],
            autopct='%1.1f%%',
            startangle=90,
            explode=explode,
            shadow=True,
            textprops={'fontsize': 12})
    
    plt.title(f'文件行数分布分析（总计 {len(file_stats)} 个文件）\n', fontsize=14)
    plt.axis('equal')  # 保证圆形
    plt.tight_layout()
    plt.show()

if __name__ == "__main__":
    target_dir = "/home/zp9080/Code/tx-anomaly-predict/hst/output_1"
    
    if not os.path.isdir(target_dir):
        print("错误：目录路径无效")
    else:
        max_file, min_file, max_lines, min_lines = find_extreme_files(target_dir)
        if max_file:
            # 输出极值文件统计
            print(f"\n【统计结果】\n"
                  f"行数最多的文件：{max_file}\n"
                  f"行数：{max_lines:,} 行\n"
                  f"行数最少的文件：{min_file}\n"
                  f"行数：{min_lines:,} 行")
            
            # 新增饼图生成
            file_stats = defaultdict(int)
            for root, _, files in os.walk(target_dir):
                for f in files:
                    filepath = os.path.join(root, f)
                    if filepath in [max_file, min_file]:
                        continue  # 跳过已统计的极值文件
                    file_stats[filepath] = count_lines_optimized(filepath)
            
            generate_pie_chart(file_stats)
        else:
            print("目录中没有可分析的文本文件")
