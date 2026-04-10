#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_SCRIPT="$SCRIPT_DIR/iperf3.sh"

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
AUTO_INSTALL=1

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
  --install                 自动安装本地/远端缺失依赖（apt）
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
    --install) AUTO_INSTALL=1; shift ;;
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

if [[ "$INTERACTIVE" -eq 1 ]]; then
  run_interactive
fi

[[ -n "$SERVER" ]] || die "必须提供 --server，或使用 --interactive"
[[ "$SERVER_SSH_PORT" =~ ^[0-9]+$ ]] || die "--server-ssh-port 必须是整数"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "--port 必须是整数"
[[ "$TARGET_MBPS" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--target-mbps 必须是数字"

ensure_local_deps() {
  local missing=0
  for c in ssh sshpass iperf3 python3 ip ping sysctl tc awk sed grep; do
    command -v "$c" >/dev/null 2>&1 || { warn "本机缺少依赖: $c"; missing=1; }
  done
  if [[ "$missing" -eq 1 ]]; then
    if [[ "$AUTO_INSTALL" -eq 1 ]] && command -v apt-get >/dev/null 2>&1; then
      log "正在本机自动安装依赖..."
      apt-get update && apt-get install -y iperf3 openssh-client sshpass python3 iproute2 iputils-ping
    else
      die "本机依赖不完整，请先安装：apt-get update && apt-get install -y iperf3 openssh-client sshpass python3 iproute2 iputils-ping"
    fi
  fi
}

build_ssh_cmd() {
  SSH_CMD=(ssh -p "$SERVER_SSH_PORT" -o StrictHostKeyChecking=accept-new)
  if [[ -n "$SERVER_SSH_PASS" ]]; then
    SSH_CMD=(sshpass -p "$SERVER_SSH_PASS" "${SSH_CMD[@]}" -o PreferredAuthentications=password -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1)
  fi
}

ensure_remote_deps() {
  local script='set -e; miss=""; command -v iperf3 >/dev/null 2>&1 || miss="$miss iperf3"; command -v ip >/dev/null 2>&1 || miss="$miss iproute2"; command -v ping >/dev/null 2>&1 || miss="$miss iputils-ping"; if [ -n "$miss" ]; then if command -v apt-get >/dev/null 2>&1; then export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y iperf3 iproute2 iputils-ping; else exit 12; fi; fi'
  "${SSH_CMD[@]}" "$SERVER_SSH" "$script"
}

RUN_TS="$(date +%Y%m%d_%H%M%S)"
REPORT_DIR=""
SUMMARY_TSV=""
SUMMARY_JSON=""
REMOTE_TUNE=1
REMOTE_KEEP=0
REMOTE_PERSIST=0

remote_bootstrap() {
  "${SSH_CMD[@]}" "$SERVER_SSH" "CLIENT_IP='$CLIENT_IP' REMOTE_RTT_MS='$REMOTE_RTT_MS' PORT='$PORT' TARGET_MBPS='$TARGET_MBPS' REMOTE_PERSIST='$REMOTE_PERSIST' REMOTE_PROFILE='$REMOTE_PROFILE' bash -s" <<'REMOTE_SCRIPT'
set -euo pipefail
PID_FILE=/tmp/iperf3-server.pid
LOG_FILE=/tmp/iperf3-server.log
STATE_FILE=/tmp/iperf3_remote_profile.state

measure_rtt_ms() {
  local target="$1"
  [[ -n "$target" ]] || { echo 50; return 0; }
  local out line avg
  if [[ "$target" == *:* ]]; then
    out="$(ping -6 -n -c 10 -i 0.2 "$target" 2>/dev/null || true)"
  else
    out="$(ping -n -c 10 -i 0.2 "$target" 2>/dev/null || true)"
  fi
  line="$(printf '%s\n' "$out" | awk '/rtt min\/avg\/max|round-trip min\/avg\/max/ {print; exit}')"
  avg="$(printf '%s' "$line" | awk -F'/' 'NF>=2 {print $2}')"
  [[ -n "$avg" ]] && echo "$avg" || echo 50
}

resolve_rtt_ms() {
  if [[ -n "${REMOTE_RTT_MS:-}" ]]; then
    echo "$REMOTE_RTT_MS"
    return 0
  fi
  if [[ -n "${CLIENT_IP:-}" ]]; then
    measure_rtt_ms "$CLIENT_IP"
    return 0
  fi
  echo 50
}

backup_key() {
  local key="$1" file="$2"
  sysctl "$key" > "$file" 2>/dev/null || true
}

choose_profile() {
  if [[ "$REMOTE_PROFILE" != "auto" && "$REMOTE_PROFILE" != "auto-all" ]]; then
    printf '%s\n' "$REMOTE_PROFILE"
    return 0
  fi
  if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    printf '%s\n' 'bbr-fq'
  else
    printf '%s\n' 'cubic-fq_codel'
  fi
}

apply_profile() {
  local profile="$1" qdisc cc iface
  case "$profile" in
    bbr-fq) cc=bbr; qdisc=fq ;;
    cubic-fq) cc=cubic; qdisc=fq ;;
    cubic-fq_codel) cc=cubic; qdisc=fq_codel ;;
    *) echo "未知远端 profile: $profile" >&2; return 1 ;;
  esac
  sysctl -w net.ipv4.tcp_congestion_control="$cc" >/dev/null 2>&1 || true
  sysctl -w net.core.default_qdisc="$qdisc" >/dev/null 2>&1 || true
  iface="$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')"
  if [[ -n "$iface" ]]; then
    tc qdisc replace dev "$iface" root "$qdisc" >/dev/null 2>&1 || true
  fi
  printf '%s\n' "$profile" > "$STATE_FILE"
  echo "[远程] 已应用 profile: $profile (cc=$cc qdisc=$qdisc iface=${iface:-unknown})"
}

echo "[远程] 测量 RTT..."
RTT="$(resolve_rtt_ms)"
echo "[远程] RTT: ${RTT} ms"
if [[ -z "${REMOTE_RTT_MS:-}" && -z "${CLIENT_IP:-}" ]]; then
  echo "[远程] 未提供 client IP，使用保守默认 RTT=50ms"
fi
BDP=$(awk "BEGIN {print int(${TARGET_MBPS} * 1000000 / 8 * ${RTT} / 1000)}")
WMEM_MAX=$(awk "BEGIN {print int(${BDP} * 4)}")
[[ $WMEM_MAX -lt 16777216 ]] && WMEM_MAX=16777216
[[ $WMEM_MAX -gt 134217728 ]] && WMEM_MAX=134217728
PROFILE_CHOSEN="$(choose_profile)"

echo "[远程] BDP: $BDP bytes"
echo "[远程] WMEM_MAX: $WMEM_MAX bytes"
echo "[远程] 备份当前参数..."
backup_key net.core.rmem_max /tmp/iperf3_rmem_max.bak
backup_key net.core.wmem_max /tmp/iperf3_wmem_max.bak
backup_key net.ipv4.tcp_wmem /tmp/iperf3_tcp_wmem.bak
backup_key net.ipv4.tcp_congestion_control /tmp/iperf3_cc.bak
backup_key net.core.default_qdisc /tmp/iperf3_qdisc.bak

echo "[远程] 应用调优参数..."
sysctl -w net.core.rmem_max="$WMEM_MAX" >/dev/null
sysctl -w net.core.wmem_max="$WMEM_MAX" >/dev/null
sysctl -w net.ipv4.tcp_wmem="4096 87380 $WMEM_MAX" >/dev/null
apply_profile "$PROFILE_CHOSEN"

echo "[远程] 启动 iperf3 server..."
if [[ -f "$PID_FILE" ]]; then
  old_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
    kill "$old_pid" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$PID_FILE"
fi
nohup iperf3 -s -p "$PORT" > "$LOG_FILE" 2>&1 &
echo $! > "$PID_FILE"
sleep 2
if ! kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "[远程] iperf3 server 启动失败" >&2
  exit 1
fi

echo "[远程] iperf3 server 已启动，PID=$(cat "$PID_FILE")"
if [[ "$REMOTE_PERSIST" == "1" ]]; then
  printf '%s\n' "net.core.rmem_max=$WMEM_MAX" "net.core.wmem_max=$WMEM_MAX" "net.ipv4.tcp_wmem=4096 87380 $WMEM_MAX" > /etc/sysctl.d/99-iperf3-remote-tune.conf
  sysctl --system >/dev/null 2>&1 || true
  echo "[远程] 已持久化 sysctl 到 /etc/sysctl.d/99-iperf3-remote-tune.conf"
fi
REMOTE_SCRIPT
}

remote_apply_profile() {
  local profile="$1"
  "${SSH_CMD[@]}" "$SERVER_SSH" "REMOTE_PROFILE='$profile' bash -s" <<'REMOTE_APPLY'
set -euo pipefail
apply_profile() {
  local profile="$1" qdisc cc iface
  case "$profile" in
    bbr-fq) cc=bbr; qdisc=fq ;;
    cubic-fq) cc=cubic; qdisc=fq ;;
    cubic-fq_codel) cc=cubic; qdisc=fq_codel ;;
    *) echo "未知远端 profile: $profile" >&2; exit 1 ;;
  esac
  sysctl -w net.ipv4.tcp_congestion_control="$cc" >/dev/null 2>&1 || true
  sysctl -w net.core.default_qdisc="$qdisc" >/dev/null 2>&1 || true
  iface="$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')"
  if [[ -n "$iface" ]]; then
    tc qdisc replace dev "$iface" root "$qdisc" >/dev/null 2>&1 || true
  fi
  printf '%s\n' "$profile" > /tmp/iperf3_remote_profile.state
  echo "[远程] 切换到 profile=$profile cc=$cc qdisc=$qdisc iface=${iface:-unknown}"
}
apply_profile "$REMOTE_PROFILE"
REMOTE_APPLY
}

run_local_once() {
  local log_file="$1"
  local action_flag="--rollback"
  local -a cmd
  case "$ACTION" in
    keep) action_flag="--keep" ;;
    persist) action_flag="--persist" ;;
  esac
  cmd=(
    "$LOCAL_SCRIPT"
    --server "$SERVER"
    --port "$PORT"
    --target-mbps "$TARGET_MBPS"
    --max-mbps "$TARGET_MBPS"
    --profile "$PROFILE"
    "$action_flag"
  )
  [[ -n "$COARSE_SECONDS" ]] && cmd+=(--coarse-seconds "$COARSE_SECONDS")
  [[ -n "$FINE_SECONDS" ]] && cmd+=(--fine-seconds "$FINE_SECONDS")
  [[ -n "$OMIT_SECONDS" ]] && cmd+=(--omit "$OMIT_SECONDS")
  [[ -n "$BIND_IP" ]] && cmd+=(--bind "$BIND_IP")
  [[ "$SKIP_RX_COPY" -eq 1 ]] && cmd+=(--skip-rx-copy)
  [[ "$YES" -eq 1 ]] && cmd+=(--yes)
  "${cmd[@]}" | tee "$log_file"
}

extract_best_mbps() {
  local f="$1"
  awk -F'：' '/最佳中位数吞吐/ {gsub(/ Mbps/,"",$2); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}' "$f"
}

extract_best_meta() {
  local f="$1"
  python3 - "$f" <<'PY2'
import json, re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding='utf-8', errors='ignore')
meta = {
    'best_mbps': '',
    'best_cc': '',
    'best_qdisc': '',
    'best_win': '',
    'report_path': '',
}
patterns = {
    'best_mbps': r'最佳中位数吞吐：\s*([0-9.]+)\s*Mbps',
    'best_cc': r'最佳参数：.*?cc=([^,\s]+)',
    'best_qdisc': r'最佳参数：.*?qdisc=([^,\s]+)',
    'best_win': r'最佳参数：.*?win=([^,\s]+)',
    'report_path': r'报告路径：\s*(.+)',
}
for key, pattern in patterns.items():
    m = re.search(pattern, text)
    if m:
        meta[key] = m.group(1).strip()
print(json.dumps(meta, ensure_ascii=False))
PY2
}

write_auto_all_summary_json() {
  local rows="$1" best_profile="$2" best_mbps="$3" best_log="$4"
  python3 - "$rows" "$best_profile" "$best_mbps" "$best_log" "$SUMMARY_JSON" <<'PY2'
import json, sys
rows_text, best_profile, best_mbps, best_log, out = sys.argv[1:]
items = []
for line in rows_text.splitlines():
    if not line.strip():
        continue
    profile, mbps, cc, qdisc, win, log, report = line.split('|', 6)
    items.append({
        "profile": profile,
        "best_mbps": float(mbps or 0),
        "local_cc": cc,
        "local_qdisc": qdisc,
        "local_win": win,
        "log": log,
        "report": report,
    })
obj = {
    "best_profile": best_profile,
    "best_mbps": float(best_mbps or 0),
    "best_log": best_log,
    "profiles": items,
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(obj, f, ensure_ascii=False, indent=2)
PY2
}

print_auto_all_summary() {
  local best_profile="$1" best_mbps="$2" best_log="$3" all_rows="$4"
  echo
  echo "[*] auto-all 汇总"
  echo "[*] 最佳远端 profile: $best_profile"
  echo "[*] 最佳吞吐: ${best_mbps} Mbps"
  [[ -n "$best_log" ]] && echo "[*] 最佳日志: $best_log"
  echo "[*] 各 profile 对比:"
  printf '%s\n' "$all_rows" | while IFS='|' read -r profile mbps cc qdisc win log report; do
    [[ -n "$profile" ]] || continue
    printf '    - %-14s %10s Mbps | local(cc=%s qdisc=%s win=%s) | log=%s' \
      "$profile" "$mbps" "${cc:-?}" "${qdisc:-?}" "${win:-?}" "$log"
    [[ -n "$report" ]] && printf ' | report=%s' "$report"
    printf '\n'
  done
}


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
  log "模式：双端联调"
  log "自动目标：高吞吐、低重传"
  build_ssh_cmd
  ensure_remote_deps

  echo "[*] 远程调优目标: $SERVER_SSH"
  echo "[*] SSH 端口: $SERVER_SSH_PORT"
  echo "[*] 服务端 IP: $SERVER"
  echo "[*] 目标速率: ${TARGET_MBPS} Mbps"
  echo "[*] 远端 profile: ${REMOTE_PROFILE}"
  [[ -n "$SERVER_SSH_PASS" ]] && echo "[*] SSH 认证: 密码模式"
  [[ -n "$CLIENT_IP" ]] && echo "[*] Client IP: $CLIENT_IP"
  [[ -n "$REMOTE_RTT_MS" ]] && echo "[*] 手动 RTT: ${REMOTE_RTT_MS} ms"
  echo

  REPORT_DIR="remote-auto-report_${SERVER//[^[:alnum:]._-]/_}_${RUN_TS}"
  mkdir -p "$REPORT_DIR"
  SUMMARY_TSV="$REPORT_DIR/summary.tsv"
  SUMMARY_JSON="$REPORT_DIR/summary.json"
  printf 'profile\tbest_mbps\tlocal_cc\tlocal_qdisc\tlocal_win\tlog\treport\n' > "$SUMMARY_TSV"

  if [[ $REMOTE_TUNE -eq 1 ]]; then
    echo "[*] 步骤 1: SSH 到服务端执行调优..."
    remote_bootstrap
    echo "[*] 远程调优完成"
    echo
  fi

  echo "[*] 步骤 2: 本地测速..."
  if [[ "$REMOTE_PROFILE" == "auto-all" ]]; then
    mkdir -p remote-profile-logs
    BEST_PROFILE=""
    BEST_MBPS="0"
    BEST_LOG=""
    SUMMARY_ROWS=""
    for profile in bbr-fq cubic-fq cubic-fq_codel; do
      echo "[*] 测试远端 profile: $profile"
      [[ $REMOTE_TUNE -eq 1 ]] && remote_apply_profile "$profile"
      out_file="remote-profile-logs/${profile}.log"
      run_local_once "$out_file"
      mbps="$(extract_best_mbps "$out_file")"
      [[ -z "$mbps" ]] && mbps=0
      meta_json="$(extract_best_meta "$out_file")"
      cc="$(python3 - <<'PY2' "$meta_json"
import json, sys
print(json.loads(sys.argv[1]).get('best_cc',''))
PY2
)"
      qdisc="$(python3 - <<'PY2' "$meta_json"
import json, sys
print(json.loads(sys.argv[1]).get('best_qdisc',''))
PY2
)"
      win="$(python3 - <<'PY2' "$meta_json"
import json, sys
print(json.loads(sys.argv[1]).get('best_win',''))
PY2
)"
      report="$(python3 - <<'PY2' "$meta_json"
import json, sys
print(json.loads(sys.argv[1]).get('report_path',''))
PY2
)"
      echo "[*] profile=$profile best_mbps=$mbps local_best=(cc=${cc:-?} qdisc=${qdisc:-?} win=${win:-?})"
      SUMMARY_ROWS+="${profile}|${mbps}|${cc}|${qdisc}|${win}|${out_file}|${report}"$'\n'
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$profile" "$mbps" "$cc" "$qdisc" "$win" "$out_file" "$report" >> "$SUMMARY_TSV"
      if awk "BEGIN {exit !($mbps > $BEST_MBPS)}"; then
        BEST_MBPS="$mbps"
        BEST_PROFILE="$profile"
        BEST_LOG="$out_file"
      fi
    done
    write_auto_all_summary_json "$SUMMARY_ROWS" "$BEST_PROFILE" "$BEST_MBPS" "$BEST_LOG"
    print_auto_all_summary "$BEST_PROFILE" "$BEST_MBPS" "$BEST_LOG" "$SUMMARY_ROWS"
    echo "[*] 汇总 TSV: $SUMMARY_TSV"
    echo "[*] 汇总 JSON: $SUMMARY_JSON"
    if [[ -n "$BEST_PROFILE" && $REMOTE_TUNE -eq 1 ]]; then
      remote_apply_profile "$BEST_PROFILE"
    fi
  else
    single_log="$REPORT_DIR/single-run.log"
    run_local_once "$single_log"
    echo "[*] 运行日志: $single_log"
  fi

  echo
  if [[ $REMOTE_TUNE -eq 1 && $REMOTE_KEEP -eq 0 && "$ACTION" == "rollback" ]]; then
    echo "[*] 步骤 3: 清理服务端..."
    "${SSH_CMD[@]}" "$SERVER_SSH" bash -s <<'CLEANUP'
set -euo pipefail
PID_FILE=/tmp/iperf3-server.pid
restore_key() {
  local key="$1" file="$2"
  if [[ -f "$file" ]]; then
    local old_val
    old_val="$(awk -F= '{print $2}' "$file" | xargs)"
    [[ -n "$old_val" ]] && sysctl -w "$key=$old_val" >/dev/null 2>&1 || true
  fi
}
if [[ -f "$PID_FILE" ]]; then
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$PID_FILE"
fi
restore_key net.core.rmem_max /tmp/iperf3_rmem_max.bak
restore_key net.core.wmem_max /tmp/iperf3_wmem_max.bak
restore_key net.ipv4.tcp_wmem /tmp/iperf3_tcp_wmem.bak
restore_key net.ipv4.tcp_congestion_control /tmp/iperf3_cc.bak
restore_key net.core.default_qdisc /tmp/iperf3_qdisc.bak
rm -f /tmp/iperf3_*.bak /tmp/iperf3_remote_profile.state
CLEANUP
  fi

  echo
  echo "[*] 全部完成！"
}

ensure_local_deps
if [[ "$LOCAL_ONLY" -eq 1 || -z "$SERVER_SSH" ]]; then
  run_local
else
  if [[ -n "$SERVER_SSH_PASS" ]] && ! have_cmd sshpass; then
    die "你传了 SSH 密码，但本机没有 sshpass。先安装：apt-get update && apt-get install -y sshpass"
  fi
  run_remote
fi
