#!/bin/bash

# 遍历 /home 下的每个目录（假设是用户目录）
for user_dir in /home/*; do
    if [ -d "$user_dir" ]; then
        username=$(basename "$user_dir")

        echo "Processing user: $username"

        installer_files_found=$(sudo -u "$username" find "$user_dir" -maxdepth 1 -type f \( -name "Anaconda*.sh" -o -name "Miniconda*.sh" \))
        
        if [ -n "$installer_files_found" ]; then
            echo "找到安装文件: $installer_files_found"
            sudo -u "$username" find "$user_dir" -maxdepth 1 -type f \( -name "Anaconda*.sh" -o -name "Miniconda*.sh" \) -delete
            echo "已删除 .sh 安装文件。"
        else
            echo "未找到 .sh 安装文件。"
        fi
        
        # 检查用户是否安装了 conda
        conda_path="$user_dir/miniconda3/bin/conda"
        if [ ! -f "$conda_path" ]; then
            conda_path="$user_dir/anaconda3/bin/conda"
        fi

        if [ -f "$conda_path" ]; then
            echo "Running conda clean for user: $username"
            sudo "$conda_path" clean --all --yes
        else
            echo "Conda not found in home directory of $username"
        fi
    fi
done
~
