#!/bin/bash

echo "搜索 /home 和 /data 下"
echo "下载超过 2 年  或  名称包含 Qwen2 / Qwen2.5 的模型"
echo "============================================================"

tmpfile=$(mktemp)

find /home /data -type d -path "*/.cache/huggingface/hub/*" \( \
    -iname "*qwen2*" -o \
    -iname "*Qwen2*" -o \
    -mtime +730 \
\) 2>/dev/null | while read -r dir; do

    # 只保留真正的模型主目录（models--开头的）
    if [[ "$dir" =~ /models-- ]]; then
        size_bytes=$(du -sb "$dir" 2>/dev/null | cut -f1)
        size_h=$(du -sh "$dir" 2>/dev/null | cut -f1)
        user=$(echo "$dir" | awk -F'/' '{if($2=="home" || $2=="data") print $3; else print "unknown"}')
        mtime=$(stat -c %y "$dir" 2>/dev/null | cut -d' ' -f1)
        echo -e "${size_bytes}\t${size_h}\t${user}\t${mtime}\t${dir}" >> "$tmpfile"
    fi
done

if [ -s "$tmpfile" ]; then
    # 按大小从大到小排序输出
    sort -nr "$tmpfile" | while IFS=$'\t' read -r bytes size user mtime path; do
        printf "%-8s %-12s %-12s %s\n" "$size" "[$user]" "$mtime" "$path"
    done

    echo "------------------------------------------------------------"
    echo "按用户汇总占用："
    awk -F'\t' '{sum[$3]+=$1} END {
        for (u in sum) printf "%-12s %.1f GB\n", u, sum[u]/1024/1024/1024
    }' "$tmpfile" | sort -k2 -nr
else
    echo "未找到符合条件的模型"
fi

rm -f "$tmpfile"
echo "============================================================"
