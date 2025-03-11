import os
import shutil


def move_and_clean_json(base_dir):
    moved_files = {}
    for root, dirs, files in os.walk(base_dir, topdown=False):
        if root == base_dir:
            continue  # 跳过根目录

        for file in files:
            if file.endswith(".sol.json"):
                src_path = os.path.join(root, file)
                dest_path = os.path.join(base_dir, file)

                if os.path.exists(dest_path):
                    base_name, ext = os.path.splitext(file)
                    counter = 1
                    new_dest_path = f"{os.path.join(base_dir, base_name)}_{counter}{ext}"
                    while os.path.exists(new_dest_path):
                        counter += 1
                        new_dest_path = f"{os.path.join(base_dir, base_name)}_{counter}{ext}"
                    dest_path = new_dest_path
                    moved_files[file] = dest_path

                shutil.move(src_path, dest_path)
                print(f"Moved: {src_path} -> {dest_path}")

        # 移动完成后删除空目录
        if not os.listdir(root):
            os.rmdir(root)
            print(f"Deleted empty directory: {root}")

    if moved_files:
        print("Duplicate files detected and renamed:")
        for original, new_name in moved_files.items():
            print(f"{original} -> {new_name}")


if __name__ == "__main__":
    base_directory = r"C:\Users\86153\Desktop\functions\output_final\output"
    move_and_clean_json(base_directory)
