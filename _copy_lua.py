import os, shutil, glob

base = r"c:\脚本\TrollAutoTouch"
src_lib = os.path.join(base, "_tmp_extracted", "Payload", "TrollAutoScript.app", "svip", "lib")
dst_lua = os.path.join(base, "TrollAutoTouch", "Resources", "lua")
src_res = os.path.join(base, "_tmp_extracted", "Payload", "TrollAutoScript.app", "svip", "res")

# 清空目标并重建
if os.path.isdir(dst_lua):
    shutil.rmtree(dst_lua)
os.makedirs(dst_lua, exist_ok=True)

# 复制 lib 下所有内容（包含子目录和所有文件类型）
total = 0
for root, dirs, files in os.walk(src_lib):
    rel = os.path.relpath(root, src_lib)
    dest_dir = os.path.join(dst_lua, rel) if rel != "." else dst_lua
    os.makedirs(dest_dir, exist_ok=True)
    for f in files:
        src_path = os.path.join(root, f)
        dst_path = os.path.join(dest_dir, f)
        shutil.copy2(src_path, dst_path)
        total += 1

print(f"Copied {total} files from lib/")

# 复制 res/ (OCR 模型等)
if os.path.isdir(src_res):
    dst_res = os.path.join(dst_lua, "res")
    os.makedirs(dst_res, exist_ok=True)
    res_count = 0
    for root, dirs, files in os.walk(src_res):
        rel = os.path.relpath(root, src_res)
        dest_dir = os.path.join(dst_res, rel) if rel != "." else dst_res
        os.makedirs(dest_dir, exist_ok=True)
        for f in files:
            src_path = os.path.join(root, f)
            dst_path = os.path.join(dest_dir, f)
            shutil.copy2(src_path, dst_path)
            res_count += 1
    print(f"Copied {res_count} resource files")
else:
    print("res/ not found, skipping OCR resources")

# 验证
lua_count = sum(1 for _ in glob.glob(os.path.join(dst_lua, "**", "*.lua"), recursive=True))
print(f"Total .lua files: {lua_count}")
total_files = sum(1 for _ in glob.glob(os.path.join(dst_lua, "**", "*"), recursive=True))
print(f"Total files in lua/: {total_files}")
