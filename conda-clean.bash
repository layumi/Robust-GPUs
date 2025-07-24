#!/bin/bash

# 遍历 /home 下的每个目录（假设是用户目录）
for user_dir in /home/*; do
    if [ -d "$user_dir" ]; then
        username=$(basename "$user_dir")

        echo "Processing user: $username"

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
