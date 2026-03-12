#!/usr/bin/env bash
# iperf3-remote.sh - 远程调优包装脚本
set -euo pipefail

SERVER_SSH=""
SERVER_IP=""
SERVER_PORT=5201
TARGET_MBPS=1000
LOCAL_SCRIPT="./iperf3.sh"
REMOTE_TUNE=1

usage() {
cat <<'EOF'
用法: sudo ./iperf3-remote.sh [选项]

必需参数:
  --server-ssh USER@HOST    SSH 登录信息（如 root@1.2.3.4）
  --server IP               服务端 IP（用于 iperf3 连接）

可选参数:
  --port PORT               iperf3 端口，默认 5201
  --target-mbps N           目标速率，默认 1000
  --no-remote-tune          跳过远程调优
  --help                    显示帮助

示例:
  sudo ./iperf3-remote.sh \
    --server-ssh root@1.2.3.4 \
    --server 1.2.3.4 \
    --target-mbps 600
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-ssh) SERVER_SSH="$2"; shift 2;;
    --server) SERVER_IP="$2"; shift 2;;
    --port) SERVER_PORT="$2"; shift 2;;
    --target-mbps) TARGET_MBPS="$2"; shift 2;;
    --no-remote-tune) REMOTE_TUNE=0; shift;;
    --help) usage; exit 0;;
    *) echo "未知参数: $1"; usage; exit 1;;
  esac
done

[[ -z "$SERVER_SSH" ]] && { echo "错误: 缺少 --server-ssh"; usage; exit 1; }
[[ -z "$SERVER_IP" ]] && { echo "错误: 缺少 --server"; usage; exit 1; }

echo "[*] 远程调优目标: $SERVER_SSH"
echo "[*] 服务端 IP: $SERVER_IP"
echo "[*] 目标速率: ${TARGET_MBPS} Mbps"
echo

if [[ $REMOTE_TUNE -eq 1 ]]; then
  echo "[*] 步骤 1: SSH 到服务端执行调优..."
  
  ssh "$SERVER_SSH" bash <<'REMOTE_SCRIPT'
set -e
echo "[远程] 备份当前参数..."
sysctl net.core.rmem_max > /tmp/iperf3_rmem_max.bak 2>/dev/null || true
sysctl net.core.wmem_max > /tmp/iperf3_wmem_max.bak 2>/dev/null || true
sysctl net.ipv4.tcp_wmem > /tmp/iperf3_tcp_wmem.bak 2>/dev/null || true

echo "[远程] 调大发送缓冲..."
sysctl -w net.core.rmem_max=134217728
sysctl -w net.core.wmem_max=134217728
sysctl -w net.ipv4.tcp_wmem="4096 87380 134217728"
sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null || sysctl -w net.ipv4.tcp_congestion_control=cubic

echo "[远程] 启动 iperf3 server..."
pkill -9 iperf3 2>/dev/null || true
nohup iperf3 -s -p 5201 > /tmp/iperf3-server.log 2>&1 &
sleep 2
echo "[远程] iperf3 server 已启动"
REMOTE_SCRIPT

  echo "[*] 远程调优完成"
  echo
fi

echo "[*] 步骤 2: 本地测速..."
"$LOCAL_SCRIPT" \
  --server "$SERVER_IP" \
  --port "$SERVER_PORT" \
  --target-mbps "$TARGET_MBPS" \
  --max-mbps "$TARGET_MBPS" \
  --profile balanced \
  --persist \
  --yes

echo
echo "[*] 步骤 3: 清理服务端..."
ssh "$SERVER_SSH" bash <<'CLEANUP'
set -e
echo "[远程] 停止 iperf3 server..."
pkill -9 iperf3 2>/dev/null || true

echo "[远程] 恢复参数..."
if [[ -f /tmp/iperf3_rmem_max.bak ]]; then
  OLD_VAL=$(cat /tmp/iperf3_rmem_max.bak | awk '{print $NF}')
  sysctl -w net.core.rmem_max="$OLD_VAL" 2>/dev/null || true
fi
if [[ -f /tmp/iperf3_wmem_max.bak ]]; then
  OLD_VAL=$(cat /tmp/iperf3_wmem_max.bak | awk '{print $NF}')
  sysctl -w net.core.wmem_max="$OLD_VAL" 2>/dev/null || true
fi
if [[ -f /tmp/iperf3_tcp_wmem.bak ]]; then
  OLD_VAL=$(cat /tmp/iperf3_tcp_wmem.bak | cut -d= -f2- | xargs)
  sysctl -w net.ipv4.tcp_wmem="$OLD_VAL" 2>/dev/null || true
fi

rm -f /tmp/iperf3_*.bak
echo "[远程] 清理完成"
CLEANUP

echo
echo "[*] 全部完成！"
