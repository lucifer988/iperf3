#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_SCRIPT="$SCRIPT_DIR/iperf3.sh"
REMOTE_SCRIPT="$SCRIPT_DIR/iperf3-remote.sh"

SERVER="${IPERF3_SERVER:-}"
SERVER_SSH="${IPERF3_SERVER_SSH:-}"
SERVER_SSH_PASS="${IPERF3_SERVER_SSH_PASS:-}"
SERVER_SSH_PORT="${IPERF3_SERVER_SSH_PORT:-22}"
CLIENT_IP="${IPERF3_CLIENT_IP:-}"
REMOTE_RTT_MS="${IPERF3_REMOTE_RTT_MS:-}"
TARGET_MBPS="${IPERF3_TARGET_MBPS:-1000}"
PORT="${IPERF3_PORT:-5201}"
PROFILE="${IPERF3_PROFILE:-balanced}"
REMOTE_PROFILE="${IPERF3_REMOTE_PROFILE:-auto-all}"
COARSE_SECONDS="${IPERF3_COARSE_SECONDS:-}"
FINE_SECONDS="${IPERF3_FINE_SECONDS:-}"
OMIT_SECONDS="${IPERF3_OMIT_SECONDS:-}"
BIND_IP="${IPERF3_BIND_IP:-}"
SKIP_RX_COPY=0
ACTION="${IPERF3_ACTION:-rollback}"
YES=0
LOCAL_ONLY=0

usage() {
cat <<'USAGE'
用法：
  sudo ./iperf3-easy.sh --server SERVER [选项]

最简双端模式（推荐）：
  sudo ./iperf3-easy.sh \
    --server 1.2.3.4 \
    --server-ssh root@1.2.3.4 \
    --target-mbps 1000 \
    --yes

仅本地模式：
  sudo ./iperf3-easy.sh \
    --server 1.2.3.4 \
    --local-only \
    --target-mbps 1000 \
    --yes

参数：
  --server IP/HOST           iperf3 server 地址
  --server-ssh USER@HOST     远端 SSH（提供后自动走双端联调）
  --server-ssh-pass PASS     可选；SSH 密码（需本机已安装 sshpass）
  --server-ssh-port PORT     可选；SSH 端口，默认 22
  --client-ip IP             可选；你的本地公网 IP（服务端能直 ping 时再填）
  --remote-rtt-ms N          可选；没有公网 IP 时手动指定 RTT 估值
  --target-mbps N            目标单流速率，默认 1000
  --port N                   端口，默认 5201
  --profile NAME             fast|balanced|exhaustive，默认 balanced
  --remote-profile NAME      auto|auto-all|bbr-fq|cubic-fq|cubic-fq_codel
  --coarse-seconds N         透传到底层脚本
  --fine-seconds N           透传到底层脚本
  --omit N                   透传到底层脚本
  --bind IP                  透传到底层脚本
  --skip-rx-copy             透传到底层脚本
  --rollback                 跑完回滚（默认）
  --keep                     跑完保留本地运行态
  --persist                  跑完持久化本地运行态
  --local-only               强制只跑本地模式
  --yes                      非交互
  --help                     查看帮助

也支持环境变量：
  IPERF3_SERVER
  IPERF3_SERVER_SSH
  IPERF3_SERVER_SSH_PASS
  IPERF3_SERVER_SSH_PORT
  IPERF3_CLIENT_IP
  IPERF3_REMOTE_RTT_MS
  IPERF3_TARGET_MBPS
  IPERF3_PORT
  IPERF3_PROFILE
  IPERF3_REMOTE_PROFILE
  IPERF3_COARSE_SECONDS
  IPERF3_FINE_SECONDS
  IPERF3_OMIT_SECONDS
  IPERF3_BIND_IP
  IPERF3_ACTION
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server) SERVER="$2"; shift 2 ;;
    --server-ssh) SERVER_SSH="$2"; shift 2 ;;
    --server-ssh-pass) SERVER_SSH_PASS="$2"; shift 2 ;;
    --server-ssh-port) SERVER_SSH_PORT="$2"; shift 2 ;;
    --client-ip) CLIENT_IP="$2"; shift 2 ;;
    --remote-rtt-ms) REMOTE_RTT_MS="$2"; shift 2 ;;
    --target-mbps) TARGET_MBPS="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --remote-profile) REMOTE_PROFILE="$2"; shift 2 ;;
    --coarse-seconds) COARSE_SECONDS="$2"; shift 2 ;;
    --fine-seconds) FINE_SECONDS="$2"; shift 2 ;;
    --omit) OMIT_SECONDS="$2"; shift 2 ;;
    --bind) BIND_IP="$2"; shift 2 ;;
    --skip-rx-copy) SKIP_RX_COPY=1; shift ;;
    --rollback) ACTION="rollback"; shift ;;
    --keep) ACTION="keep"; shift ;;
    --persist) ACTION="persist"; shift ;;
    --local-only) LOCAL_ONLY=1; shift ;;
    --yes) YES=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "$SERVER" ]] || { echo "错误：必须提供 --server" >&2; usage; exit 1; }
[[ -x "$LOCAL_SCRIPT" ]] || { echo "错误：找不到 $LOCAL_SCRIPT" >&2; exit 1; }
[[ -x "$REMOTE_SCRIPT" ]] || { echo "错误：找不到 $REMOTE_SCRIPT" >&2; exit 1; }

run_local() {
  local -a cmd
  cmd=("$LOCAL_SCRIPT" --server "$SERVER" --port "$PORT" --target-mbps "$TARGET_MBPS" --max-mbps "$TARGET_MBPS" --profile "$PROFILE")
  [[ -n "$COARSE_SECONDS" ]] && cmd+=(--coarse-seconds "$COARSE_SECONDS")
  [[ -n "$FINE_SECONDS" ]] && cmd+=(--fine-seconds "$FINE_SECONDS")
  [[ -n "$OMIT_SECONDS" ]] && cmd+=(--omit "$OMIT_SECONDS")
  [[ -n "$BIND_IP" ]] && cmd+=(--bind "$BIND_IP")
  [[ "$SKIP_RX_COPY" -eq 1 ]] && cmd+=(--skip-rx-copy)
  case "$ACTION" in
    rollback) cmd+=(--rollback) ;;
    keep) cmd+=(--keep) ;;
    persist) cmd+=(--persist) ;;
  esac
  [[ "$YES" -eq 1 ]] && cmd+=(--yes)
  echo "[*] 模式：本地调优"
  printf '[*] 执行: %q ' "${cmd[@]}"; printf '\n'
  exec "${cmd[@]}"
}

run_remote() {
  local -a cmd
  cmd=("$REMOTE_SCRIPT" --server-ssh "$SERVER_SSH" --server "$SERVER" --port "$PORT" --target-mbps "$TARGET_MBPS" --remote-profile "$REMOTE_PROFILE" --profile "$PROFILE")
  [[ -n "$SERVER_SSH_PASS" ]] && cmd+=(--server-ssh-pass "$SERVER_SSH_PASS")
  [[ -n "$SERVER_SSH_PORT" ]] && cmd+=(--server-ssh-port "$SERVER_SSH_PORT")
  [[ -n "$CLIENT_IP" ]] && cmd+=(--client-ip "$CLIENT_IP")
  [[ -n "$REMOTE_RTT_MS" ]] && cmd+=(--remote-rtt-ms "$REMOTE_RTT_MS")
  [[ -n "$COARSE_SECONDS" ]] && cmd+=(--coarse-seconds "$COARSE_SECONDS")
  [[ -n "$FINE_SECONDS" ]] && cmd+=(--fine-seconds "$FINE_SECONDS")
  [[ -n "$OMIT_SECONDS" ]] && cmd+=(--omit "$OMIT_SECONDS")
  [[ -n "$BIND_IP" ]] && cmd+=(--bind "$BIND_IP")
  [[ "$SKIP_RX_COPY" -eq 1 ]] && cmd+=(--skip-rx-copy)
  case "$ACTION" in
    keep) cmd+=(--local-keep) ;;
    persist) cmd+=(--local-persist) ;;
    rollback) : ;;
  esac
  [[ "$YES" -eq 1 ]] && cmd+=(--yes)
  echo "[*] 模式：双端联调"
  printf '[*] 执行: %q ' "${cmd[@]}"; printf '\n'
  exec "${cmd[@]}"
}

if [[ "$LOCAL_ONLY" -eq 1 || -z "$SERVER_SSH" ]]; then
  run_local
else
  run_remote
fi
