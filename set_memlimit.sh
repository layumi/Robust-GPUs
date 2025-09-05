#!/bin/bash
# 用法: sudo ./set_memlimit.sh [内存大小]
# 例如: sudo ./set_memlimit.sh 60G

set -e

LIMIT=${1:-60G}   # 默认限制 60G，如果没有传参

echo "==> 设置每个用户最大内存限制为 $LIMIT"

# 配置 user-.slice (所有普通用户都会受限)
sudo mkdir -p /etc/systemd/system/user-.slice.d
cat <<EOF | sudo tee /etc/systemd/system/user-.slice.d/memory.conf > /dev/null
[Slice]
MemoryMax=$LIMIT
EOF

# 配置 sshd.service 避免 OOM 杀死
echo "==> 保护 sshd.service，避免被 OOM 杀掉"
sudo mkdir -p /etc/systemd/system/sshd.service.d
cat <<EOF | sudo tee /etc/systemd/system/sshd.service.d/oom.conf > /dev/null
[Service]
OOMScoreAdjust=-1000
EOF

# 重新加载 systemd 配置
echo "==> 重新加载 systemd 配置..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload

# 重启 sshd 以应用保护
echo "==> 重启 sshd..."
sudo systemctl restart sshd

echo "✅ 配置完成: 每个用户内存限制 $LIMIT，sshd 已保护"
