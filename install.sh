#!/bin/bash

# 1. 获取当前脚本路径 DIR
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 2. 创建 ~/bin 目录（如果不存在）
BIN_DIR="$HOME/bin"
mkdir -p "$BIN_DIR"

# 3. 复制 DIR/scripts 下的 *.sh 文件到 ~/bin，并添加可执行权限，去除 .sh 后缀
SCRIPTS_DIR="$DIR/scripts"

if [ -d "$SCRIPTS_DIR" ]; then
    for script_file in "$SCRIPTS_DIR"/*.sh; do
        # 检查是否有匹配的文件（避免当没有 .sh 文件时循环执行）
        if [ -f "$script_file" ]; then
            # 获取文件名（不带路径）
            filename=$(basename "$script_file")
            # 去除 .sh 后缀
            new_filename="${filename%.sh}"
            # 目标路径
            target_file="$BIN_DIR/$new_filename"
            
            # 复制文件
            cp "$script_file" "$target_file"
            
            # 添加可执行权限
            chmod +x "$target_file"
            
            echo "已复制并设置权限: $target_file"
        fi
    done
else
    echo "警告: 脚本目录 $SCRIPTS_DIR 不存在"
fi

# 4. 检查 ~/bin 是否在 PATH 中，如果不在则添加
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo "检测到 ~/bin 不在 PATH 中，正在添加..."
    
    # 确定 shell 配置文件
    SHELL_CONFIG=""
    if [ -n "$BASH_VERSION" ]; then
        # Bash 环境
        if [ -f "$HOME/.bashrc" ]; then
            SHELL_CONFIG="$HOME/.bashrc"
        elif [ -f "$HOME/.bash_profile" ]; then
            SHELL_CONFIG="$HOME/.bash_profile"
        else
            SHELL_CONFIG="$HOME/.bashrc"
        fi
    elif [ -n "$ZSH_VERSION" ]; then
        # Zsh 环境
        SHELL_CONFIG="$HOME/.zshrc"
    else
        # 默认使用 .profile
        SHELL_CONFIG="$HOME/.profile"
    fi
    
    # 检查配置文件中是否已经包含添加 ~/bin 到 PATH 的行
    if ! grep -q "PATH.*$BIN_DIR" "$SHELL_CONFIG" 2>/dev/null; then
        echo "export PATH=\"\$PATH:$BIN_DIR\"" >> "$SHELL_CONFIG"
        echo "已将 ~/bin 添加到 $SHELL_CONFIG"
        echo "请重新加载配置文件或重新打开终端以使更改生效"
        echo "可以运行: source $SHELL_CONFIG"
    else
        echo "~/bin 已经在配置文件中配置过了"
    fi
else
    echo "~/bin 已经在 PATH 中"
fi

echo "脚本执行完成！"
