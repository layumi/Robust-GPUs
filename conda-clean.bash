#!/bin/bash

# 遍历 /home 下的每个目录（假设是用户目录）
for user_dir in /home/*; do
    if [ -d "$user_dir" ]; then
        username=$(basename "$user_dir")

        echo "Processing user: $username"

        # === 清理 pip 缓存（最重要部分）===
        pip_cache_dir="$user_dir/.cache/pip"
        if [ -d "$pip_cache_dir" ]; then
            echo "  → 找到 pip 缓存: $(du -sh "$pip_cache_dir" 2>/dev/null | cut -f1)"
            sudo rm -rf "$pip_cache_dir"
            echo "  → 已删除 $username 的 .cache/pip 文件夹"
        else
            echo "  → $username 没有 pip 缓存目录"
        fi

        if [ -n "$installer_files_found" ]; then
            echo "找到安装文件: $installer_files_found"
            sudo -u "$username" find "$user_dir" -maxdepth 1 -type f \( -name "Anaconda*.sh" -o -name "Miniconda*.sh" \) -delete
            echo "已删除 .sh 安装文件。"
        else
            echo "未找到 .sh 安装文件。"
        fi

        # 检查用户是否安装了 conda
        conda_path="$user_dir/miniconda3/bin/conda"
        pip_path="$user_dir/miniconda3/bin/pip"
        if [ ! -f "$conda_path" ]; then
            conda_path="$user_dir/anaconda3/bin/conda"
            pip_path="$user_dir/anaconda3/bin/pip"
        fi

        if [ -f "$conda_path" ]; then
            echo "Running conda clean for user: $username"
            sudo "$conda_path" clean --all --yes
            sudo "$pip_path" cache purge
        else
            echo "Conda not found in home directory of $username"
        fi
    fi
done
