#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_SCRIPT="$SCRIPT_DIR/iperf3.sh"
REMOTE_SCRIPT="$SCRIPT_DIR/iperf3-remote.sh"

SERVER="${IPERF3_SERVER:-}"
SERVER_SSH="${IPERF3_SERVER_SSH:-}"
SERVER_SSH_PASS="${IPERF3_SERVER_SSH_PASS:-}"
SERVER_SSH_PORT="${IPERF3_SERVER_SSH_PORT:-22}"
PORT="${IPERF3_PORT:-5201}"
TARGET_MBPS="${IPERF3_TARGET_MBPS:-1000}"
CLIENT_IP="${IPERF3_CLIENT_IP:-}"
REMOTE_RTT_MS="${IPERF3_REMOTE_RTT_MS:-}"
PROFILE="${IPERF3_PROFILE:-balanced}"
REMOTE_PROFILE="${IPERF3_REMOTE_PROFILE:-auto-all}"
COARSE_SECONDS="${IPERF3_COARSE_SECONDS:-}"
FINE_SECONDS="${IPERF3_FINE_SECONDS:-}"
OMIT_SECONDS="${IPERF3_OMIT_SECONDS:-}"
BIND_IP="${IPERF3_BIND_IP:-}"
SKIP_RX_COPY=0
ACTION="rollback"
YES=0
LOCAL_ONLY=0
INTERACTIVE=0

usage() {
cat <<'USAGE'
用法：
  sudo ./iperf3-easy.sh [选项]
  sudo ./iperf3-easy.sh --interactive

最适合“本地无公网 IP + 只会 SSH 到服务端”的方式：
  sudo ./iperf3-easy.sh --interactive

参数：
  --interactive             交互模式，只问你 SSH 信息和目标网速
  --server IP/HOST          iperf3 服务端地址
  --server-ssh USER@HOST    SSH 登录地址，例如 root@1.2.3.4
  --server-ssh-pass PASS    SSH 密码（需本机已安装 sshpass）
  --server-ssh-port PORT    SSH 端口，默认 22
  --client-ip IP            可选；你的公网 IP（服务端能直 ping 时再填）
  --remote-rtt-ms N         可选；无公网 IP 时手动 RTT 估值
  --target-mbps N           目标单流 Mbps，默认 1000
  --port N                  iperf3 端口，默认 5201
  --profile fast|balanced|exhaustive
  --remote-profile auto|auto-all|bbr-fq|cubic-fq|cubic-fq_codel
  --coarse-seconds N
  --fine-seconds N
  --omit N
  --bind IP
  --skip-rx-copy
  --rollback                跑完回滚（默认）
  --keep                    跑完保留运行态
  --persist                 跑完持久化本地运行态
  --local-only              仅做本地调优
  --yes                     非交互
  --help                    显示帮助
USAGE
}

log() { printf '[*] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

tty_read() {
  local __var="$1" __prompt="$2" __val=""
  IFS= read -r -p "$__prompt" __val
  printf -v "$__var" '%s' "$__val"
}

prompt_default() {
  local __outvar="$1" prompt="$2" def="$3" ans=""
  tty_read ans "$prompt [$def]: "
  printf -v "$__outvar" '%s' "${ans:-$def}"
}

prompt_secret() {
  local __outvar="$1" prompt="$2" ans=""
  read -r -s -p "$prompt: " ans
  echo
  printf -v "$__outvar" '%s' "$ans"
}

prompt_optional() {
  local __outvar="$1" prompt="$2" ans=""
  tty_read ans "$prompt (可留空): "
  printf -v "$__outvar" '%s' "$ans"
}

autotune_profile() {
  local target="$1"
  local rtt="${2:-}"

  PROFILE="balanced"
  REMOTE_PROFILE="auto-all"

  if [[ "$target" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    if awk "BEGIN {exit !($target <= 300)}"; then
      PROFILE="fast"
    elif awk "BEGIN {exit !($target >= 2000)}"; then
      PROFILE="exhaustive"
    fi
  fi

  if [[ -n "$rtt" ]] && [[ "$rtt" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    if awk "BEGIN {exit !($rtt <= 60 && $target <= 500)}"; then
      PROFILE="fast"
      REMOTE_PROFILE="auto"
    elif awk "BEGIN {exit !($rtt >= 180 || $target >= 3000)}"; then
      PROFILE="exhaustive"
      REMOTE_PROFILE="auto-all"
    fi
  fi
}

run_interactive() {
  local server_ip="" ssh_host="" ssh_user="root" ssh_pass="" ssh_port="22" target="1000" port_in="5201"
  local manual_rtt="" local_public_ip=""

  echo
  echo "=== iperf3 一键调优向导 ==="
  echo "默认按你的场景：本地无公网 IP，通过 SSH 控服务端。"
  echo

  prompt_default server_ip "服务端 IP / 域名" "1.2.3.4"
  prompt_default ssh_user "SSH 用户" "root"
  prompt_default ssh_host "SSH 地址（一般和服务端 IP 一样）" "$server_ip"
  prompt_secret ssh_pass "SSH 密码"
  prompt_default ssh_port "SSH 端口" "22"
  prompt_default target "目标单流 Mbps" "1000"
  prompt_default port_in "iperf3 端口" "5201"
  prompt_optional manual_rtt "如果你知道大概 RTT（毫秒）就填，不知道直接回车"
  prompt_optional local_public_ip "如果你本地有可达公网 IP 就填，不然回车"

  SERVER="$server_ip"
  SERVER_SSH="${ssh_user}@${ssh_host}"
  SERVER_SSH_PASS="$ssh_pass"
  SERVER_SSH_PORT="$ssh_port"
  TARGET_MBPS="$target"
  PORT="$port_in"
  REMOTE_RTT_MS="$manual_rtt"
  CLIENT_IP="$local_public_ip"

  autotune_profile "$TARGET_MBPS" "$REMOTE_RTT_MS"

  echo
  log "已自动选择 profile=$PROFILE remote-profile=$REMOTE_PROFILE"
  if [[ -z "$CLIENT_IP" && -z "$REMOTE_RTT_MS" ]]; then
    warn "你没填公网 IP / RTT，脚本会用保守 RTT 估值进行远端预调。"
  fi
  YES=1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interactive) INTERACTIVE=1; shift ;;
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
    *) die "未知参数: $1" ;;
  esac
done

[[ -x "$LOCAL_SCRIPT" ]] || die "找不到 $LOCAL_SCRIPT"
[[ -x "$REMOTE_SCRIPT" ]] || die "找不到 $REMOTE_SCRIPT"

if [[ "$INTERACTIVE" -eq 1 ]]; then
  run_interactive
fi

[[ -n "$SERVER" ]] || die "必须提供 --server，或使用 --interactive"
[[ "$SERVER_SSH_PORT" =~ ^[0-9]+$ ]] || die "--server-ssh-port 必须是整数"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "--port 必须是整数"
[[ "$TARGET_MBPS" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--target-mbps 必须是数字"

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
  log "模式：本地调优"
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
  log "模式：双端联调"
  log "自动目标：高吞吐、低重传"
  exec "${cmd[@]}"
}

if [[ "$LOCAL_ONLY" -eq 1 || -z "$SERVER_SSH" ]]; then
  run_local
else
  if [[ -n "$SERVER_SSH_PASS" ]] && ! have_cmd sshpass; then
    die "你传了 SSH 密码，但本机没有 sshpass。先安装：apt-get update && apt-get install -y sshpass"
  fi
  run_remote
fi
