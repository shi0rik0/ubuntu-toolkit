#!/bin/bash

# mysu-edit - 用 sudo 权限编辑文件（仅 Linux）
# 用法: mysu-edit <file>

set -e

if [ "$#" -ne 1 ]; then
    echo "用法: $0 <file>" >&2
    exit 1
fi

ORIGINAL_FILE="$1"

if [ ! -e "$ORIGINAL_FILE" ]; then
    echo "错误: 文件 '$ORIGINAL_FILE' 不存在" >&2
    exit 1
fi

# 获取原始文件权限（八进制）
ORIGINAL_PERMS=$(stat -c "%a" "$ORIGINAL_FILE")

# 创建临时文件
TEMP_FILE=$(mktemp)
chmod 777 "$TEMP_FILE"

# 用 sudo 读取原文件内容到临时文件
sudo cat "$ORIGINAL_FILE" > "$TEMP_FILE"

# 输出临时文件路径
echo "$TEMP_FILE"

# 提示并等待用户操作
echo "请编辑上述临时文件，完成后按回车继续..."
read -r

# 用 sudo 将编辑后的内容写回原文件
sudo cp "$TEMP_FILE" "$ORIGINAL_FILE"

# 恢复原始权限
sudo chmod "$ORIGINAL_PERMS" "$ORIGINAL_FILE"

# 清理
rm -f "$TEMP_FILE"

echo "更新完成。"
