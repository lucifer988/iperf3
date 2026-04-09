#!/usr/bin/env bash
set -Eeuo pipefail

# 复制成 iperf3-onekey-password.sh 后，改下面这些变量。

SERVER_IP="1.2.3.4"
SSH_HOST="1.2.3.4"
SSH_USER="root"
SSH_PASS="replace_me"
SSH_PORT="22"
TARGET_MBPS="1000"

# 没有公网 IP 时可以留空，或者手动给一个 RTT 估值。
CLIENT_IP=""
REMOTE_RTT_MS="180"

# fast | balanced | exhaustive
PROFILE="balanced"

# auto | auto-all | bbr-fq | cubic-fq | cubic-fq_codel
REMOTE_PROFILE="auto-all"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cmd=(
  sudo "$SCRIPT_DIR/iperf3-easy.sh"
  --server "$SERVER_IP"
  --server-ssh "${SSH_USER}@${SSH_HOST}"
  --server-ssh-pass "$SSH_PASS"
  --server-ssh-port "$SSH_PORT"
  --target-mbps "$TARGET_MBPS"
  --profile "$PROFILE"
  --remote-profile "$REMOTE_PROFILE"
  --yes
)

[[ -n "$CLIENT_IP" ]] && cmd+=(--client-ip "$CLIENT_IP")
[[ -n "$REMOTE_RTT_MS" ]] && cmd+=(--remote-rtt-ms "$REMOTE_RTT_MS")

exec "${cmd[@]}"
