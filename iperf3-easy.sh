#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_SCRIPT="$SCRIPT_DIR/iperf3-easy.sh"

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
  --improve-mbps-threshold N
  --improve-score-threshold N
  --max-stale-rounds N
  --skip-rx-copy
  --rollback                跑完回滚（默认；交互模式会在结束时再次询问）
  --keep                    跑完保留运行态
  --persist                 跑完持久化本地/远端运行态
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
  ACTION="ask"
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
    keep) action_flag="--keep"; REMOTE_KEEP=1 ;;
    persist) action_flag="--persist"; REMOTE_KEEP=1; REMOTE_PERSIST=1 ;;
    ask) action_flag="--rollback" ;;
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
  local_engine_main "${cmd[@]:1}" | tee "$log_file"
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
    'best_score': '',
    'best_sender_retrans': '',
    'best_local_retrans': '',
    'report_path': '',
}

report_match = re.search(r'结构化汇总：\s*(.+)', text)
if report_match:
    report_path = report_match.group(1).strip()
    meta['report_path'] = report_path
    try:
        obj = json.loads(Path(report_path).read_text(encoding='utf-8', errors='ignore'))
        best = obj.get('best', {}) or {}
        meta['best_mbps'] = str(best.get('mbps', ''))
        meta['best_cc'] = str(best.get('cc', ''))
        meta['best_qdisc'] = str(best.get('qdisc', ''))
        meta['best_win'] = str(best.get('window', ''))
        meta['best_score'] = str(best.get('score', ''))
        meta['best_sender_retrans'] = str(best.get('sender_retrans', ''))
        meta['best_local_retrans'] = str(best.get('local_retrans_delta', ''))
        print(json.dumps(meta, ensure_ascii=False))
        raise SystemExit
    except Exception:
        pass

patterns = {
    'best_mbps': r'最佳中位数吞吐：\s*([0-9.]+)\s*Mbps',
    'best_cc': r'最佳参数：.*?cc=([^,\s]+)',
    'best_qdisc': r'最佳参数：.*?qdisc=([^,\s]+)',
    'best_win': r'最佳参数：.*?w(?:in)?=([^,\s]+)',
    'best_score': r'综合评分：\s*([0-9.+-]+)',
    'best_sender_retrans': r'sender_retrans（中位数）：\s*([0-9-]+)',
    'best_local_retrans': r'本地 TcpRetransSegs Δ（中位数）：\s*([0-9-]+)',
    'report_path': r'结构化汇总：\s*(.+)',
}
for key, pattern in patterns.items():
    m = re.search(pattern, text)
    if m:
        meta[key] = m.group(1).strip()
print(json.dumps(meta, ensure_ascii=False))
PY2
}

write_auto_all_summary_json() {
  local rows="$1" best_profile="$2" best_mbps="$3" best_score="$4" best_log="$5"
  python3 - "$rows" "$best_profile" "$best_mbps" "$best_score" "$best_log" "$SUMMARY_JSON" <<'PY2'
import json, sys
rows_text, best_profile, best_mbps, best_score, best_log, out = sys.argv[1:]
items = []
for line in rows_text.splitlines():
    if not line.strip():
        continue
    profile, mbps, score, sender_retrans, local_retrans, cc, qdisc, win, log, report = line.split('|', 9)
    items.append({
        "profile": profile,
        "best_mbps": float(mbps or 0),
        "best_score": float(score or 0),
        "best_sender_retrans": int(float(sender_retrans or 0)),
        "best_local_retrans": int(float(local_retrans or 0)),
        "local_cc": cc,
        "local_qdisc": qdisc,
        "local_win": win,
        "log": log,
        "report": report,
    })
obj = {
    "best_profile": best_profile,
    "best_mbps": float(best_mbps or 0),
    "best_score": float(best_score or 0),
    "best_log": best_log,
    "best_reason": "prefer higher score first, then higher mbps",
    "profiles": items,
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(obj, f, ensure_ascii=False, indent=2)
PY2
}

print_auto_all_summary() {
  local best_profile="$1" best_mbps="$2" best_score="$3" best_log="$4" all_rows="$5"
  echo
  echo "[*] auto-all 汇总"
  echo "[*] 最佳远端 profile: $best_profile"
  echo "[*] 最佳吞吐: ${best_mbps} Mbps"
  echo "[*] 最佳综合评分: ${best_score}"
  echo "[*] 选择理由: 优先综合评分，若评分相同再选更高吞吐"
  [[ -n "$best_log" ]] && echo "[*] 最佳日志: $best_log"
  echo "[*] 各 profile 对比:"
  printf '%s\n' "$all_rows" | while IFS='|' read -r profile mbps score sender_retrans local_retrans cc qdisc win log report; do
    [[ -n "$profile" ]] || continue
    printf '    - %-14s %10s Mbps | score=%s | retrans=%s/%s | local(cc=%s qdisc=%s win=%s) | log=%s' \
      "$profile" "$mbps" "${score:-?}" "${sender_retrans:-?}" "${local_retrans:-?}" "${cc:-?}" "${qdisc:-?}" "${win:-?}" "$log"
    [[ -n "$report" ]] && printf ' | report=%s' "$report"
    printf '\n'
  done
}



print_auto_all_reuse_hint() {
  local best_profile="$1"
  echo
  echo "[*] 下次若要直接复用当前最优远端档位，可优先试："
  printf '    sudo ./iperf3-easy.sh --server %q --server-ssh %q --server-ssh-port %q --target-mbps %q --remote-profile %q --yes\n' \
    "$SERVER" "$SERVER_SSH" "$SERVER_SSH_PORT" "$TARGET_MBPS" "$best_profile"
  if [[ -n "$REMOTE_RTT_MS" ]]; then
    printf '    # 如需保留 RTT 估值，再补：--remote-rtt-ms %q\n' "$REMOTE_RTT_MS"
  fi
  if [[ -n "$CLIENT_IP" ]]; then
    printf '    # 如需让远端直测你的公网地址，再补：--client-ip %q\n' "$CLIENT_IP"
  fi
}

# ===== embedded local tuning engine =====
SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="5.0.1"
TTY="/dev/tty"

IPERF3_BIN="/usr/bin/iperf3"
[[ -x "$IPERF3_BIN" ]] || IPERF3_BIN="/bin/iperf3"

ASSUME_YES=0
PROFILE="fast"            # fast | balanced | exhaustive
SERVER_IP=""
PORT=5201
TARGET_MBPS=1000
OVERSEAS_MAX_MBPS=1000
PING_INTERVAL="0.2"
PING_COUNT=12
MTU_PROBING=1              # 0/1/2
STOP_EARLY=1
SWEEP_LOCAL_SENDER=0       # 高级选项：额外扫描本地 cc/qdisc（-R 模式下默认关闭）
SKIP_RX_COPY=0             # 高级选项：iperf3 --skip-rx-copy
CLIENT_BIND_IP=""
LOG_BASE_DIR="."
ACTION_ON_FINISH="ask"    # ask | rollback | keep | persist

# profile defaults（可被命令行覆盖）
COARSE_DURATION=8
FINE_DURATION=15
OMIT_SECONDS=3
TOP_N=2
FINE_REPEATS=2
BUFFER_MIN_MB=32
BUFFER_CAP_MB=256
IMPROVE_MBPS_THRESHOLD=0.8
IMPROVE_SCORE_THRESHOLD=5
MAX_STALE_ROUNDS=2

# 显式参数覆盖标记（避免 profile 默认值覆盖用户手工指定）
COARSE_SET=0
FINE_SET=0
OMIT_SET=0
PING_COUNT_SET=0
TOP_N_SET=0
FINE_REPEATS_SET=0

# 运行态变量
BACKUP_DONE=0
LOG_DIR=""
SUMMARY_CSV=""
BEST_HELPER=""
IFACE=""
DEST_IP_FOR_METRICS=""
CURRENT_LOCAL_PROFILE=""
CURRENT_QDISC_CHANGED=0
RESTORE_AT_EXIT=1
PERSIST_DONE=0
RUN_INDEX=0

# 只备份/恢复真正会动到的 sysctl
SYSCTL_KEYS=(
  net.core.rmem_max
  net.core.wmem_max
  net.ipv4.tcp_rmem
  net.ipv4.tcp_wmem
  net.ipv4.tcp_mtu_probing
  net.ipv4.tcp_no_metrics_save
  net.ipv4.tcp_moderate_rcvbuf
  net.ipv4.tcp_congestion_control
  net.core.default_qdisc
)
declare -A SYSCTL_OLD=()

declare -a CC_LIST=()
declare -a QDISC_LIST=()
declare -a WIN_LIST=()

declare -A BEST_META=()

local_usage() {
cat <<'USAGE'
用法：
  sudo bash iperf3-easy.sh [选项]

核心选项：
  --server HOST               iperf3 server IP/域名
  --port PORT                 iperf3 端口，默认 5201
  --target-mbps N             目标单流 Mbps，默认 1000
  --max-mbps N                海外机器/链路最大可用 Mbps，用于估算 BDP，默认 1000
  --profile NAME              fast | balanced | exhaustive，默认 fast
  --mtu-probing N             0/1/2，默认 1
  --bind IP                   指定本地源地址（传给 iperf3 -B）
  --log-dir DIR               日志父目录，默认当前目录

时长相关：
  --coarse-seconds N          粗筛测试时长（不含 omit）
  --fine-seconds N            精测测试时长（不含 omit）
  --omit N                    omit 秒数，默认 3
  --ping-count N              ping 次数，默认 12
  --ping-interval SEC         ping 间隔秒数，默认 0.2
  --top-n N                   粗筛后进入精测的候选数，默认 2
  --fine-repeats N            每个精测候选重复次数，默认 2
  --improve-mbps-threshold N  提前停止时认定“仍有明显提升”的 Mbps 阈值，默认 0.8
  --improve-score-threshold N 提前停止时认定“仍有明显提升”的综合评分阈值，默认 5
  --max-stale-rounds N        达标后允许连续“无明显提升”的轮数，默认 2

行为开关：
  --stop-early                达标后提前结束（默认开启）
  --no-stop-early             达标后不提前结束
  --sweep-local-sender        额外扫描本地 cc/qdisc（高级；更慢；-R 场景通常非主因）
  --skip-rx-copy              传给 iperf3 --skip-rx-copy（更偏压测极限，不像真实业务）
  --rollback                  结束后自动回滚
  --keep                      结束后保留运行态
  --persist                   结束后持久化（并保留运行态）
  --yes                       全程使用默认值，不交互
  --help                      显示帮助

示例：
  sudo bash iperf3.sh \
    --server 1.2.3.4 --port 5201 --target-mbps 1000 --max-mbps 1000

  sudo bash iperf3.sh \
    --server speed.example.com --profile balanced --persist --yes
USAGE
}

log()  { printf '[*] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "必须 sudo/root 运行"; }
have_cmd()  { command -v "$1" >/dev/null 2>&1; }

read_tty() {
    local __var="$1" __prompt="$2" __val=""
    if [[ -r "$TTY" ]]; then
        IFS= read -r -p "$__prompt" __val < "$TTY" || __val=""
    else
        IFS= read -r -p "$__prompt" __val || __val=""
    fi
    printf -v "$__var" '%s' "$__val"
}

prompt_default() {
    local q="$1" def="$2" ans=""
    if [[ "$ASSUME_YES" -eq 1 ]]; then
        printf '%s\n' "$def"
        return 0
    fi
    read_tty ans "$q [$def]: "
    printf '%s\n' "${ans:-$def}"
}

prompt_yesno() {
    local q="$1" def="$2" ans=""
    if [[ "$ASSUME_YES" -eq 1 ]]; then
        [[ "$def" =~ ^([yY]|yes|YES)$ ]] && return 0 || return 1
    fi
    read_tty ans "$q (y/n) [$def]: "
    ans="${ans:-$def}"
    case "$ans" in
        y|Y|yes|YES) return 0 ;;
        n|N|no|NO)   return 1 ;;
        *)
            warn "请输入 y 或 n"
            prompt_yesno "$q" "$def"
            return $?
            ;;
    esac
}

apply_profile_defaults() {
    case "$PROFILE" in
        fast)
            [[ "$COARSE_SET" -eq 1 ]] || COARSE_DURATION=8
            [[ "$FINE_SET" -eq 1 ]] || FINE_DURATION=15
            [[ "$OMIT_SET" -eq 1 ]] || OMIT_SECONDS=3
            [[ "$TOP_N_SET" -eq 1 ]] || TOP_N=2
            [[ "$FINE_REPEATS_SET" -eq 1 ]] || FINE_REPEATS=2
            [[ "$PING_COUNT_SET" -eq 1 ]] || PING_COUNT=12
            ;;
        balanced)
            [[ "$COARSE_SET" -eq 1 ]] || COARSE_DURATION=10
            [[ "$FINE_SET" -eq 1 ]] || FINE_DURATION=20
            [[ "$OMIT_SET" -eq 1 ]] || OMIT_SECONDS=3
            [[ "$TOP_N_SET" -eq 1 ]] || TOP_N=3
            [[ "$FINE_REPEATS_SET" -eq 1 ]] || FINE_REPEATS=2
            [[ "$PING_COUNT_SET" -eq 1 ]] || PING_COUNT=15
            ;;
        exhaustive)
            [[ "$COARSE_SET" -eq 1 ]] || COARSE_DURATION=12
            [[ "$FINE_SET" -eq 1 ]] || FINE_DURATION=25
            [[ "$OMIT_SET" -eq 1 ]] || OMIT_SECONDS=3
            [[ "$TOP_N_SET" -eq 1 ]] || TOP_N=4
            [[ "$FINE_REPEATS_SET" -eq 1 ]] || FINE_REPEATS=2
            [[ "$PING_COUNT_SET" -eq 1 ]] || PING_COUNT=20
            ;;
        *)
            die "--profile 只能是 fast / balanced / exhaustive"
            ;;
    esac
}

sanitize_name() {
    tr -cs '[:alnum:]._:-' '_' <<<"$1" | sed 's/^_//; s/_$//'
}

clamp_int() {
    local v="$1" min="$2" max="$3"
    (( v < min )) && { printf '%s\n' "$min"; return 0; }
    (( v > max )) && { printf '%s\n' "$max"; return 0; }
    printf '%s\n' "$v"
}

bytes_to_iperf_unit() {
    local b="$1"
    if (( b % (1024*1024*1024) == 0 )); then
        printf '%sG\n' "$(( b/(1024*1024*1024) ))"
    elif (( b % (1024*1024) == 0 )); then
        printf '%sM\n' "$(( b/(1024*1024) ))"
    elif (( b % 1024 == 0 )); then
        printf '%sK\n' "$(( b/1024 ))"
    else
        printf '%s\n' "$b"
    fi
}

mbps_from_bps() {
    python3 - "$1" <<'PY'
import sys
print(f"{float(sys.argv[1]) / 1e6:.2f}")
PY
}

sort_windows() {
    python3 - "$@" <<'PY'
import re, sys
vals = []
for item in sys.argv[1:]:
    s = item.strip().upper()
    if s == 'AUTO':
        vals.append((-1, 'auto'))
        continue
    m = re.fullmatch(r'(\d+)([KMGT]?)', s)
    if not m:
        continue
    n = int(m.group(1))
    unit = m.group(2)
    scale = {'':1, 'K':1024, 'M':1024**2, 'G':1024**3, 'T':1024**4}[unit]
    vals.append((n * scale, s))
vals = sorted(dict(vals).items(), key=lambda x: x[0])
out = []
seen = set()
for _, s in vals:
    s2 = s.lower() if s == 'auto' else s
    if s2 not in seen:
        seen.add(s2)
        out.append(s2)
print('\n'.join(out))
PY
}

sysctl_get() {
    sysctl -n "$1" 2>/dev/null || true
}

sysctl_set() {
    local key="$1" value="$2"
    sysctl -w "$key=$value" >/dev/null
}

backup_sysctls() {
    local key
    for key in "${SYSCTL_KEYS[@]}"; do
        SYSCTL_OLD["$key"]="$(sysctl_get "$key")"
    done
}

restore_sysctls() {
    local key value
    for key in "${SYSCTL_KEYS[@]}"; do
        value="${SYSCTL_OLD[$key]:-}"
        [[ -z "$value" ]] && continue
        sysctl -w "$key=$value" >/dev/null 2>&1 || true
    done
}

clear_qdisc_best_effort() {
    local iface="$1"
    [[ -n "$iface" ]] || return 0
    tc qdisc del dev "$iface" root >/dev/null 2>&1 || true
    CURRENT_QDISC_CHANGED=0
    CURRENT_LOCAL_PROFILE=""
}

cleanup() {
    local rc=$?
    if [[ "$BACKUP_DONE" -eq 1 && "$RESTORE_AT_EXIT" -eq 1 ]]; then
        log "退出清理：回滚运行态（best-effort）..."
        restore_sysctls
        [[ "$CURRENT_QDISC_CHANGED" -eq 1 ]] && clear_qdisc_best_effort "$IFACE"
    fi
    exit "$rc"
}
trap cleanup EXIT INT TERM

local_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --server) SERVER_IP="${2:-}"; shift 2 ;;
            --port) PORT="${2:-}"; shift 2 ;;
            --target-mbps) TARGET_MBPS="${2:-}"; shift 2 ;;
            --max-mbps) OVERSEAS_MAX_MBPS="${2:-}"; shift 2 ;;
            --profile) PROFILE="${2:-}"; shift 2 ;;
            --mtu-probing) MTU_PROBING="${2:-}"; shift 2 ;;
            --bind) CLIENT_BIND_IP="${2:-}"; shift 2 ;;
            --log-dir) LOG_BASE_DIR="${2:-}"; shift 2 ;;
            --coarse-seconds) COARSE_DURATION="${2:-}"; COARSE_SET=1; shift 2 ;;
            --fine-seconds) FINE_DURATION="${2:-}"; FINE_SET=1; shift 2 ;;
            --omit) OMIT_SECONDS="${2:-}"; OMIT_SET=1; shift 2 ;;
            --ping-count) PING_COUNT="${2:-}"; PING_COUNT_SET=1; shift 2 ;;
            --ping-interval) PING_INTERVAL="${2:-}"; shift 2 ;;
            --top-n) TOP_N="${2:-}"; TOP_N_SET=1; shift 2 ;;
            --fine-repeats) FINE_REPEATS="${2:-}"; FINE_REPEATS_SET=1; shift 2 ;;
            --improve-mbps-threshold) IMPROVE_MBPS_THRESHOLD="${2:-}"; shift 2 ;;
            --improve-score-threshold) IMPROVE_SCORE_THRESHOLD="${2:-}"; shift 2 ;;
            --max-stale-rounds) MAX_STALE_ROUNDS="${2:-}"; shift 2 ;;
            --stop-early) STOP_EARLY=1; shift ;;
            --no-stop-early) STOP_EARLY=0; shift ;;
            --sweep-local-sender) SWEEP_LOCAL_SENDER=1; shift ;;
            --skip-rx-copy) SKIP_RX_COPY=1; shift ;;
            --rollback) ACTION_ON_FINISH="rollback"; shift ;;
            --keep) ACTION_ON_FINISH="keep"; shift ;;
            --persist) ACTION_ON_FINISH="persist"; shift ;;
            --yes) ASSUME_YES=1; shift ;;
            --help|-h) local_usage; exit 0 ;;
            *) die "未知参数：$1（用 --help 查看）" ;;
        esac
    done
}

validate_numbers() {
    [[ -n "$SERVER_IP" ]] || die "必须提供 --server，或交互输入 server 地址"
    [[ "$PORT" =~ ^[0-9]+$ ]] || die "端口必须是整数"
    [[ "$TARGET_MBPS" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--target-mbps 必须是数字"
    [[ "$OVERSEAS_MAX_MBPS" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--max-mbps 必须是数字"
    [[ "$PING_INTERVAL" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--ping-interval 必须是数字"
    [[ "$PING_COUNT" =~ ^[0-9]+$ ]] || die "--ping-count 必须是整数"
    [[ "$COARSE_DURATION" =~ ^[0-9]+$ ]] || die "--coarse-seconds 必须是整数"
    [[ "$FINE_DURATION" =~ ^[0-9]+$ ]] || die "--fine-seconds 必须是整数"
    [[ "$OMIT_SECONDS" =~ ^[0-9]+$ ]] || die "--omit 必须是整数"
    [[ "$TOP_N" =~ ^[0-9]+$ ]] || die "--top-n 必须是整数"
    [[ "$FINE_REPEATS" =~ ^[0-9]+$ ]] || die "--fine-repeats 必须是整数"
    [[ "$IMPROVE_MBPS_THRESHOLD" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--improve-mbps-threshold 必须是数字"
    [[ "$IMPROVE_SCORE_THRESHOLD" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--improve-score-threshold 必须是数字"
    [[ "$MAX_STALE_ROUNDS" =~ ^[0-9]+$ ]] || die "--max-stale-rounds 必须是整数"
    [[ "$MTU_PROBING" =~ ^[012]$ ]] || die "--mtu-probing 只能是 0/1/2"
}

precheck_commands() {
    local c
    for c in ip sysctl tc ping awk sed grep python3 ss nstat sort date mktemp getent; do
        have_cmd "$c" || die "缺少命令：$c"
    done
    [[ -x "$IPERF3_BIN" ]] || die "找不到 iperf3（请先安装 iperf3）"
}

interactive_fill() {
    [[ -n "$SERVER_IP" ]] || SERVER_IP="$(prompt_default '请输入【境外 iperf3 server IP/域名】' '2.2.2.2')"
    [[ -n "$PORT" ]] || PORT="$(prompt_default '请输入 iperf3 端口' '5201')"
    [[ -n "$TARGET_MBPS" ]] || TARGET_MBPS="$(prompt_default '目标单流 Mbps（例如 1000）' '1000')"
    [[ -n "$OVERSEAS_MAX_MBPS" ]] || OVERSEAS_MAX_MBPS="$(prompt_default '海外机器最大网速 Mbps' '1000')"
}

init_logs() {
    local ts safe
    ts="$(date +%F_%H-%M-%S)"
    safe="$(sanitize_name "$SERVER_IP")"
    LOG_DIR="$LOG_BASE_DIR/results_autotune_${safe}_${ts}"
    mkdir -p "$LOG_DIR"
    SUMMARY_CSV="$LOG_DIR/summary.csv"
    BEST_HELPER="$LOG_DIR/run_best.sh"
    printf 'phase,run_id,cc,qdisc,window,mbps,sender_retrans,local_retrans_delta,score,rc,json_file,err_file\n' > "$SUMMARY_CSV"
}

resolve_iface() {
    IFACE="$(ip route get "$SERVER_IP" 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' || true)"
    [[ -n "$IFACE" ]] && log "检测到出接口：$IFACE" || warn "未检测到出接口，qdisc 实时应用将跳过"
}

resolve_dest_ip_for_metrics() {
    if [[ "$SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$SERVER_IP" == *:* ]]; then
        DEST_IP_FOR_METRICS="$SERVER_IP"
        return 0
    fi
    DEST_IP_FOR_METRICS="$(getent ahosts "$SERVER_IP" 2>/dev/null | awk 'NR==1{print $1; exit}' || true)"
}

measure_rtt_and_bdp() {
    local ping_out rtt_line rtt_avg_ms rtt_avg_s bdp_bytes
    local -a ping_cmd
    ping_out="$LOG_DIR/ping.txt"

    if [[ "$SERVER_IP" == *:* ]]; then
        ping_cmd=(ping -6 -n -i "$PING_INTERVAL" -c "$PING_COUNT" "$SERVER_IP")
    else
        ping_cmd=(ping -n -i "$PING_INTERVAL" -c "$PING_COUNT" "$SERVER_IP")
    fi

    log "测量 RTT：${ping_cmd[*]}"
    "${ping_cmd[@]}" > "$ping_out" 2>&1 || die "ping 失败，请检查连通性"
    cat "$ping_out"

    rtt_line="$(grep -E 'rtt min/avg/max|round-trip min/avg/max' "$ping_out" | tail -n 1 | sed 's/.*= //')"
    rtt_avg_ms="$(awk -F'/' 'NF>=2 {print $2}' <<<"$rtt_line")"
    [[ -n "$rtt_avg_ms" ]] || die "解析 RTT 失败"

    rtt_avg_s="$(python3 - "$rtt_avg_ms" <<'PY'
import sys
print(f"{float(sys.argv[1])/1000.0:.6f}")
PY
)"
    bdp_bytes="$(python3 - "$OVERSEAS_MAX_MBPS" "$rtt_avg_s" <<'PY'
import sys
mbps=float(sys.argv[1])
rtt=float(sys.argv[2])
print(int(mbps * 1e6 / 8.0 * rtt))
PY
)"

    printf '%s|%s|%s\n' "$rtt_avg_ms" "$rtt_avg_s" "$bdp_bytes"
}

choose_bufmax_bytes() {
    local bdp_bytes="$1" min_bytes cap_bytes raw
    min_bytes=$(( BUFFER_MIN_MB * 1024 * 1024 ))
    cap_bytes=$(( BUFFER_CAP_MB * 1024 * 1024 ))
    raw=$(( bdp_bytes * 4 ))
    (( raw < min_bytes )) && raw="$min_bytes"
    clamp_int "$raw" "$min_bytes" "$cap_bytes"
}

build_window_list() {
    local bdp_bytes="$1" bufmax_bytes="$2"
    local req_cap raw
    local -a raw_bytes=()
    local -a fixed_bytes=()
    local -A seen=()
    local -a tmp=()
    local sorted

    req_cap=$(( bufmax_bytes / 2 ))
    (( req_cap < 256*1024 )) && req_cap=$((256*1024))

    raw_bytes+=( $(( bdp_bytes / 4 )) )
    raw_bytes+=( $(( bdp_bytes / 2 )) )
    raw_bytes+=( "$bdp_bytes" )
    [[ "$PROFILE" != "fast" ]] && raw_bytes+=( $(( bdp_bytes * 2 )) )

    fixed_bytes+=( $((4*1024*1024)) $((8*1024*1024)) )
    [[ "$PROFILE" != "fast" ]] && fixed_bytes+=( $((16*1024*1024)) )
    [[ "$PROFILE" == "exhaustive" ]] && fixed_bytes+=( $((32*1024*1024)) )

    for raw in "${raw_bytes[@]}" "${fixed_bytes[@]}"; do
        raw="$(clamp_int "$raw" $((256*1024)) "$req_cap")"
        (( raw <= 0 )) && continue
        [[ -n "${seen[$raw]:-}" ]] && continue
        seen[$raw]=1
        tmp+=( "$(bytes_to_iperf_unit "$raw")" )
    done

    sorted="$(sort_windows auto "${tmp[@]}")"
    mapfile -t WIN_LIST < <(printf '%s\n' "$sorted" | sed '/^$/d')
}

choose_local_sender_lists() {
    local current_cc
    current_cc="$(sysctl_get net.ipv4.tcp_congestion_control)"
    if [[ "$SWEEP_LOCAL_SENDER" -eq 1 ]]; then
        if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
            CC_LIST=(bbr cubic)
        else
            warn "系统未发现 BBR，可用拥塞控制中不含 bbr；将仅测试 cubic"
            CC_LIST=(cubic)
        fi
        QDISC_LIST=(fq fq_codel)
    else
        CC_LIST=("${current_cc:-keep}")
        QDISC_LIST=(keep)
    fi
}

apply_receiver_profile() {
    local bufmax="$1" mtu_probing="$2"
    local tcp_def=$((1024*1024))

    sysctl_set net.core.rmem_max "$bufmax"
    sysctl_set net.core.wmem_max "$bufmax"
    sysctl_set net.ipv4.tcp_rmem "4096 $tcp_def $bufmax"
    sysctl_set net.ipv4.tcp_wmem "4096 $tcp_def $bufmax"
    sysctl_set net.ipv4.tcp_moderate_rcvbuf 1
    sysctl_set net.ipv4.tcp_mtu_probing "$mtu_probing"
    sysctl_set net.ipv4.tcp_no_metrics_save 1
}

apply_local_sender_profile() {
    local cc="$1" qdisc="$2" iface="$3"
    local want="$cc|$qdisc"
    [[ "$SWEEP_LOCAL_SENDER" -eq 1 ]] || return 0
    [[ "$CURRENT_LOCAL_PROFILE" == "$want" ]] && return 0

    if [[ "$cc" == "bbr" ]]; then
        modprobe tcp_bbr >/dev/null 2>&1 || true
        if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
            warn "BBR 不可用，跳过此 profile"
            return 1
        fi
    fi

    sysctl_set net.ipv4.tcp_congestion_control "$cc"
    sysctl_set net.core.default_qdisc "$qdisc"

    if [[ -n "$iface" ]]; then
        if tc qdisc replace dev "$iface" root "$qdisc" >/dev/null 2>&1; then
            CURRENT_QDISC_CHANGED=1
        else
            warn "tc qdisc replace dev $iface root $qdisc 失败（非致命）"
        fi
    fi

    CURRENT_LOCAL_PROFILE="$want"
    return 0
}

clear_tcp_metrics_entry() {
    [[ -n "$DEST_IP_FOR_METRICS" ]] || return 0
    ip tcp_metrics delete "$DEST_IP_FOR_METRICS" >/dev/null 2>&1 || true
}

nstat_get() {
    local file="$1" key="$2"
    awk -v k="$key" '$1==k {print $2; found=1} END{if(!found) print 0}' "$file" 2>/dev/null
}

parse_iperf_json() {
    local json_file="$1"
    python3 - "$json_file" <<'PY'
import json, sys

bps = 0
retrans = -1
try:
    with open(sys.argv[1], 'r', encoding='utf-8', errors='ignore') as f:
        data = json.load(f)
    end = data.get('end', {}) or {}

    for path in [
        ('sum_received', 'bits_per_second'),
        ('sum', 'bits_per_second'),
        ('sum_sent', 'bits_per_second'),
    ]:
        obj = end.get(path[0], {}) or {}
        val = obj.get(path[1], 0) or 0
        if val:
            bps = int(val)
            break

    if not bps:
        streams = end.get('streams', []) or []
        for st in streams:
            for side in ('receiver', 'sender'):
                obj = st.get(side, {}) or {}
                val = obj.get('bits_per_second', 0) or 0
                if val:
                    bps = int(val)
                    break
            if bps:
                break

    sum_sent = end.get('sum_sent', {}) or {}
    if 'retransmits' in sum_sent and sum_sent.get('retransmits') is not None:
        retrans = int(sum_sent.get('retransmits') or 0)
    else:
        streams = end.get('streams', []) or []
        vals = []
        for st in streams:
            s = st.get('sender', {}) or {}
            if s.get('retransmits') is not None:
                vals.append(int(s.get('retransmits') or 0))
        if vals:
            retrans = sum(vals)
except Exception:
    pass
print(f"{bps}\t{retrans}")
PY
}

run_iperf_once() {
    local phase="$1" cc="$2" qdisc="$3" win="$4" duration="$5"
    local run_id err_file json_file n_before n_after r1 r2 local_rdelta rc
    local parse_out bps sender_retrans mbps score
    local safe_cc safe_qdisc safe_win
    local -a cmd=()
    local -a warg=()
    local -a timeout_cmd=()

    RUN_INDEX=$(( RUN_INDEX + 1 ))
    run_id=$(printf '%03d' "$RUN_INDEX")

    safe_cc="$(sanitize_name "$cc")"
    safe_qdisc="$(sanitize_name "$qdisc")"
    safe_win="$(sanitize_name "$win")"

    json_file="$LOG_DIR/${phase}_${run_id}_${safe_cc}_${safe_qdisc}_w${safe_win}.json"
    err_file="$LOG_DIR/${phase}_${run_id}.err"
    n_before="$LOG_DIR/nstat_before_${phase}_${run_id}.txt"
    n_after="$LOG_DIR/nstat_after_${phase}_${run_id}.txt"

    if ! apply_local_sender_profile "$cc" "$qdisc" "$IFACE"; then
        printf '%s,%s,%s,%s,%s,0,-1,0,-999999,1,%s,%s\n' \
          "$phase" "$run_id" "$cc" "$qdisc" "$win" "/dev/null" "$err_file" >> "$SUMMARY_CSV"
        return 1
    fi

    clear_tcp_metrics_entry
    nstat -az > "$n_before" 2>/dev/null || true

    [[ "$win" != "auto" ]] && warg=(-w "$win") || warg=()

    cmd=("$IPERF3_BIN" -c "$SERVER_IP" -p "$PORT" -R -J --get-server-output -O "$OMIT_SECONDS" -t "$duration")
    [[ -n "$CLIENT_BIND_IP" ]] && cmd+=( -B "$CLIENT_BIND_IP" )
    [[ "$SKIP_RX_COPY" -eq 1 ]] && cmd+=( --skip-rx-copy )
    cmd+=( "${warg[@]}" )

    if have_cmd timeout; then
        timeout_cmd=(timeout --signal=TERM $(( duration + OMIT_SECONDS + 20 ))s)
    fi

    log "[$phase/$run_id] 测试：cc=$cc qdisc=$qdisc -w=$win -t=$duration -O=$OMIT_SECONDS"
    set +e
    if [[ ${#timeout_cmd[@]} -gt 0 ]]; then
        "${timeout_cmd[@]}" "${cmd[@]}" > "$json_file" 2> "$err_file"
    else
        "${cmd[@]}" > "$json_file" 2> "$err_file"
    fi
    rc=$?
    set -e

    nstat -az > "$n_after" 2>/dev/null || true
    r1="$(nstat_get "$n_before" TcpRetransSegs)"
    r2="$(nstat_get "$n_after"  TcpRetransSegs)"
    local_rdelta=$(( r2 - r1 ))

    if [[ ! -s "$json_file" || "$rc" -ne 0 ]]; then
        warn "[$phase/$run_id] iperf3 返回 rc=$rc，详情见 $err_file"
        printf '%s,%s,%s,%s,%s,0,-1,%s,-999999,%s,%s,%s\n' \
          "$phase" "$run_id" "$cc" "$qdisc" "$win" "$local_rdelta" "$rc" "$json_file" "$err_file" >> "$SUMMARY_CSV"
        return 1
    fi

    parse_out="$(parse_iperf_json "$json_file")"
    bps="$(awk -F'\t' '{print $1}' <<<"$parse_out")"
    sender_retrans="$(awk -F'\t' '{print $2}' <<<"$parse_out")"
    [[ -n "$bps" ]] || bps=0
    [[ -n "$sender_retrans" ]] || sender_retrans=-1
    mbps="$(mbps_from_bps "$bps")"
    score="$(compute_run_score "$mbps" "$sender_retrans" "$local_rdelta")"

    log "[$phase/$run_id] => ${mbps} Mbps | sender_retrans=${sender_retrans} | local TcpRetransSegs Δ=${local_rdelta} | score=${score} | rc=$rc"
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$phase" "$run_id" "$cc" "$qdisc" "$win" "$mbps" "$sender_retrans" "$local_rdelta" "$score" "$rc" "$json_file" "$err_file" >> "$SUMMARY_CSV"
    return 0
}

compute_run_score() {
    local mbps="$1" sender_retrans="$2" local_retrans="$3"
    python3 - "$mbps" "$sender_retrans" "$local_retrans" <<'PY'
import sys
mbps = float(sys.argv[1])
sender = int(float(sys.argv[2]))
local = int(float(sys.argv[3]))
penalty = 0.0
if sender >= 0:
    penalty += sender * 25.0
if local >= 0:
    penalty += local * 5.0
score = mbps - penalty
print(f"{score:.2f}")
PY
}

write_final_summary_json() {
    python3 - "$SUMMARY_CSV" "$LOG_DIR/final-summary.json" \
      "${BEST_META[phase]:-}" "${BEST_META[cc]:-}" "${BEST_META[qdisc]:-}" "${BEST_META[win]:-}" \
      "${BEST_META[mbps]:-0}" "${BEST_META[sender_retrans]:--1}" "${BEST_META[local_retrans]:--1}" \
      "${BEST_META[score]:-0}" "$BEST_HELPER" <<'PY'
import csv, json, sys
csv_path, out_path, phase, cc, qdisc, win, mbps, sender, local, score, best_helper = sys.argv[1:]
runs = []
with open(csv_path, newline="", encoding="utf-8", errors="ignore") as f:
    for row in csv.DictReader(f):
        runs.append(row)
obj = {"best": {"phase": phase, "cc": cc, "qdisc": qdisc, "window": win, "mbps": float(mbps), "sender_retrans": int(float(sender)), "local_retrans_delta": int(float(local)), "score": float(score), "helper": best_helper}, "runs": runs}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(obj, f, ensure_ascii=False, indent=2)
PY
}

rank_candidates() {
    local phase="$1" top_n="$2"
    python3 - "$SUMMARY_CSV" "$phase" "$top_n" <<'PY'
import csv, statistics, sys
from collections import defaultdict

csv_path, phase, top_n = sys.argv[1], sys.argv[2], int(sys.argv[3])
rows = []
with open(csv_path, newline='', encoding='utf-8', errors='ignore') as f:
    for row in csv.DictReader(f):
        if row['phase'] != phase:
            continue
        try:
            rc = int(row['rc'])
            mbps = float(row['mbps'])
            sender_retrans = int(row['sender_retrans'])
            local_retrans = int(row['local_retrans_delta'])
            score = float(row.get('score', mbps))
        except Exception:
            continue
        if rc != 0 or mbps <= 0:
            continue
        key = (row['cc'], row['qdisc'], row['window'])
        rows.append((key, mbps, sender_retrans, local_retrans, score))

groups = defaultdict(list)
for rec in rows:
    groups[rec[0]].append(rec[1:])

ranked = []
for key, items in groups.items():
    mbps_vals = [x[0] for x in items]
    sender_vals = [10**12 if x[1] < 0 else x[1] for x in items]
    local_vals = [x[2] for x in items]
    score_vals = [x[3] for x in items]
    ranked.append((
        statistics.median(score_vals),
        statistics.median(mbps_vals),
        statistics.median(sender_vals),
        statistics.median(local_vals),
        len(items),
        key,
    ))

ranked.sort(key=lambda x: (-x[0], x[2] if x[2] >= 0 else 10**12, x[3], -x[1], x[5]))
for med_score, med_mbps, med_sender, med_local, n, key in ranked[:top_n]:
    cc, qdisc, win = key
    sender_out = -1 if med_sender >= 10**12 else int(med_sender)
    print(f"{cc}|{qdisc}|{win}|{med_mbps:.2f}|{sender_out}|{int(med_local)}|{n}|{med_score:.2f}")
PY
}

should_stop_after_fine_round() {
    local rounds_done="$1" current_best_score="$2" current_best_mbps="$3" target_mbps="$4" last_best_score="$5" last_best_mbps="$6" stale_rounds="$7"
    python3 - "$rounds_done" "$current_best_score" "$current_best_mbps" "$target_mbps" "$last_best_score" "$last_best_mbps" "$stale_rounds" "$IMPROVE_SCORE_THRESHOLD" "$IMPROVE_MBPS_THRESHOLD" "$MAX_STALE_ROUNDS" <<'PY_STOP'
import sys
rounds_done = int(sys.argv[1])
current_best_score = float(sys.argv[2])
current_best_mbps = float(sys.argv[3])
target_mbps = float(sys.argv[4])
last_best_score = float(sys.argv[5])
last_best_mbps = float(sys.argv[6])
stale_rounds = int(sys.argv[7])
score_threshold = float(sys.argv[8])
mbps_threshold = float(sys.argv[9])
max_stale_rounds = int(sys.argv[10])
if rounds_done <= 0:
    print(0)
    raise SystemExit
reached_target = current_best_mbps >= target_mbps
score_gain = current_best_score - last_best_score
mbps_gain = current_best_mbps - last_best_mbps
improved = (score_gain >= score_threshold) or (mbps_gain >= mbps_threshold)
should_stop = reached_target and stale_rounds >= max_stale_rounds and not improved
print(1 if should_stop else 0)
PY_STOP
}

write_best_helper() {
    local best_cc="$1" best_qdisc="$2" best_win="$3"
    cat > "$BEST_HELPER" <<EOF
#!/usr/bin/env bash
# Auto-generated by $SCRIPT_NAME v$SCRIPT_VERSION
set -euo pipefail
IPERF3_BIN="$IPERF3_BIN"
SERVER_IP="$SERVER_IP"
PORT="$PORT"
CMD=("\$IPERF3_BIN" -c "\$SERVER_IP" -p "\$PORT" -R -J --get-server-output)
EOF
    if [[ -n "$CLIENT_BIND_IP" ]]; then
        printf 'CMD+=( -B %q )\n' "$CLIENT_BIND_IP" >> "$BEST_HELPER"
    fi
    if [[ "$SKIP_RX_COPY" -eq 1 ]]; then
        printf 'CMD+=( --skip-rx-copy )\n' >> "$BEST_HELPER"
    fi
    if [[ "$best_win" != "auto" ]]; then
        printf 'CMD+=( -w %q )\n' "$best_win" >> "$BEST_HELPER"
    fi
    cat >> "$BEST_HELPER" <<'EOF_HELPER'
CMD+=( "$@" )
printf 'Running: %q ' "${CMD[@]}"; printf '\n'
exec "${CMD[@]}"
EOF_HELPER
    chmod +x "$BEST_HELPER"
}

persist_best() {
    local bufmax="$1" best_cc="$2" best_qdisc="$3"
    local sysctl_file="/etc/sysctl.d/99-iperf3-client-tune.conf"
    local svc_file="/etc/systemd/system/iperf3-qdisc.service"
    local tcp_def=$((1024*1024))

    cat > "$sysctl_file" <<EOF
# Generated by $SCRIPT_NAME v$SCRIPT_VERSION
# Reverse single-flow iperf3 tuning (client-side receive focus)
net.core.rmem_max=$bufmax
net.core.wmem_max=$bufmax
net.ipv4.tcp_rmem=4096 $tcp_def $bufmax
net.ipv4.tcp_wmem=4096 $tcp_def $bufmax
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_mtu_probing=$MTU_PROBING
EOF

    if [[ "$SWEEP_LOCAL_SENDER" -eq 1 ]]; then
        cat >> "$sysctl_file" <<EOF
net.ipv4.tcp_congestion_control=$best_cc
net.core.default_qdisc=$best_qdisc
EOF
    fi

    sysctl --system >/dev/null 2>&1 || true

    if [[ "$SWEEP_LOCAL_SENDER" -eq 1 && -n "$IFACE" ]]; then
        cat > "$svc_file" <<EOF
[Unit]
Description=Apply qdisc for iperf3 reverse singleflow tuning
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/sbin/tc qdisc replace dev $IFACE root $best_qdisc
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable --now iperf3-qdisc.service >/dev/null 2>&1 || true
    fi

    PERSIST_DONE=1
    log "已持久化本地 sysctl：$sysctl_file"
}

print_aggregated_top() {
    python3 - "$SUMMARY_CSV" <<'PY'
import csv, statistics, sys
from collections import defaultdict
rows = []
with open(sys.argv[1], newline='', encoding='utf-8', errors='ignore') as f:
    for row in csv.DictReader(f):
        try:
            rc = int(row['rc'])
            mbps = float(row['mbps'])
            sender_retrans = int(row['sender_retrans'])
            local_retrans = int(row['local_retrans_delta'])
            score = float(row.get('score', mbps))
        except Exception:
            continue
        if rc != 0 or mbps <= 0:
            continue
        key = (row['phase'], row['cc'], row['qdisc'], row['window'])
        rows.append((key, mbps, sender_retrans, local_retrans, score))

groups = defaultdict(list)
for key, mbps, sender, local, score in rows:
    groups[key].append((mbps, sender, local, score))

ranked = []
for (phase, cc, qdisc, window), items in groups.items():
    mbps_vals = [x[0] for x in items]
    sender_vals = [10**12 if x[1] < 0 else x[1] for x in items]
    local_vals = [x[2] for x in items]
    score_vals = [x[3] for x in items]
    ranked.append((
        statistics.median(score_vals),
        statistics.median(mbps_vals),
        statistics.median(sender_vals),
        statistics.median(local_vals),
        len(items),
        phase, cc, qdisc, window,
    ))
ranked.sort(key=lambda x: (-x[0], x[2] if x[2] >= 0 else 10**12, x[3], -x[1], x[5], x[6], x[7]))
for i, row in enumerate(ranked[:5], 1):
    med_score, med_mbps, med_sender, med_local, n, phase, cc, qdisc, window = row
    sender_out = -1 if med_sender >= 10**12 else int(med_sender)
    print(f"{i}. score={med_score:.2f} | {med_mbps:.2f} Mbps | sender_retrans={sender_out} | localΔ={int(med_local)} | runs={n} | phase={phase} | cc={cc} qdisc={qdisc} w={window}")
PY
}

select_best_overall() {
    local ranked phase_for_best
    ranked="$(rank_candidates fine 1)"
    if [[ -n "$ranked" ]]; then
        phase_for_best="fine"
    else
        ranked="$(rank_candidates coarse 1)"
        phase_for_best="coarse"
    fi
    [[ -n "$ranked" ]] || return 1

    IFS='|' read -r BEST_META[cc] BEST_META[qdisc] BEST_META[win] BEST_META[mbps] BEST_META[sender_retrans] BEST_META[local_retrans] BEST_META[runs] BEST_META[score] <<< "$ranked"
    BEST_META[phase]="$phase_for_best"
    return 0
}

local_engine_main() {
    local RTT_AVG_MS RTT_AVG_S BDP_BYTES BUF_MAX_BYTES
    local coarse_ranked fine_candidates choice
    local line cc qdisc win i reached_flag rounds_done=0 stale_rounds=0
    local current_best_line current_best_score current_best_mbps last_best_score=-999999 last_best_mbps=0 stop_now=0

    local_parse_args "$@"
    apply_profile_defaults
    interactive_fill
    validate_numbers
    need_root
    precheck_commands

    echo "===================================================================="
    echo " iperf3 单流反向(-R) 自动调优脚本 v${SCRIPT_VERSION}"
    echo " 默认优先优化接收缓冲/窗口；本地 cc/qdisc 扫描仅在高级模式启用"
    echo "===================================================================="
    echo

    backup_sysctls
    BACKUP_DONE=1
    init_logs
    resolve_iface
    resolve_dest_ip_for_metrics

    log "日志目录：$LOG_DIR"
    [[ -n "$DEST_IP_FOR_METRICS" ]] && log "tcp_metrics 目标地址：$DEST_IP_FOR_METRICS"

    IFS='|' read -r RTT_AVG_MS RTT_AVG_S BDP_BYTES <<< "$(measure_rtt_and_bdp)"
    BUF_MAX_BYTES="$(choose_bufmax_bytes "$BDP_BYTES")"

    apply_receiver_profile "$BUF_MAX_BYTES" "$MTU_PROBING"
    choose_local_sender_lists
    build_window_list "$BDP_BYTES" "$BUF_MAX_BYTES"

    echo
    log "avg RTT: ${RTT_AVG_MS} ms"
    log "估算 BDP: ${BDP_BYTES} bytes"
    log "BUF_MAX: ${BUF_MAX_BYTES} bytes"
    log "窗口候选：${WIN_LIST[*]}"
    log "本地 sender-factor 扫描：$([[ "$SWEEP_LOCAL_SENDER" -eq 1 ]] && echo 开启 || echo 关闭)"
    echo

    log "阶段 1：粗筛（${COARSE_DURATION}s，omit=${OMIT_SECONDS}s）"
    for cc in "${CC_LIST[@]}"; do
        for qdisc in "${QDISC_LIST[@]}"; do
            for win in "${WIN_LIST[@]}"; do
                run_iperf_once coarse "$cc" "$qdisc" "$win" "$COARSE_DURATION" || true
            done
        done
    done

    coarse_ranked="$(rank_candidates coarse "$TOP_N")"
    [[ -n "$coarse_ranked" ]] || die "所有粗筛测试都失败了，请检查 server 端、端口、防火墙、链路质量。"

    echo
    log "粗筛 Top ${TOP_N}（优先综合评分，其次低重传、再看高吞吐）："
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        IFS='|' read -r cc qdisc win _ <<< "$line"
        printf '    - cc=%s qdisc=%s w=%s\n' "$cc" "$qdisc" "$win"
    done <<< "$coarse_ranked"

    if [[ "$STOP_EARLY" -eq 1 ]]; then
        reached_flag="$(python3 - "$TARGET_MBPS" "$coarse_ranked" <<'PY'
import sys
threshold = float(sys.argv[1])
ranked = sys.argv[2].splitlines()
best = 0.0
for line in ranked:
    parts = line.split('|')
    if len(parts) >= 4:
        try:
            best = max(best, float(parts[3]))
        except Exception:
            pass
print(1 if best >= threshold else 0)
PY
)"
        reached_flag="$(tr -d '[:space:]' <<<"$reached_flag")"
        if [[ "$reached_flag" == "1" ]]; then
            reached=1
            log "粗筛阶段已达到目标 ${TARGET_MBPS} Mbps，精测只验证当前最佳候选。"
            fine_candidates="$(sed -n '1p' <<<"$coarse_ranked")"
        else
            fine_candidates="$coarse_ranked"
        fi
    else
        fine_candidates="$coarse_ranked"
    fi

    echo
    log "阶段 2：精测（${FINE_DURATION}s，每轮重复 ${FINE_REPEATS} 次）"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        IFS='|' read -r cc qdisc win _ <<< "$line"
        for (( i=1; i<=FINE_REPEATS; i++ )); do
            run_iperf_once fine "$cc" "$qdisc" "$win" "$FINE_DURATION" || true
        done

        rounds_done=$((rounds_done + 1))
        current_best_line="$(rank_candidates fine 1 | sed -n '1p')"
        if [[ -n "$current_best_line" ]]; then
            current_best_score="$(awk -F'|' '{print $8}' <<< "$current_best_line")"
            current_best_mbps="$(awk -F'|' '{print $4}' <<< "$current_best_line")"
            if python3 - "$current_best_score" "$last_best_score" "$current_best_mbps" "$last_best_mbps" "$IMPROVE_SCORE_THRESHOLD" "$IMPROVE_MBPS_THRESHOLD" <<'PY_IMPROVE' >/dev/null
import sys
current_score=float(sys.argv[1])
last_score=float(sys.argv[2])
current_mbps=float(sys.argv[3])
last_mbps=float(sys.argv[4])
score_threshold=float(sys.argv[5])
mbps_threshold=float(sys.argv[6])
raise SystemExit(0 if ((current_score-last_score) >= score_threshold or (current_mbps-last_mbps) >= mbps_threshold) else 1)
PY_IMPROVE
            then
                stale_rounds=0
            else
                stale_rounds=$((stale_rounds + 1))
            fi
            log "精测进展：best=${current_best_mbps} Mbps score=${current_best_score} | stale_rounds=${stale_rounds}/${MAX_STALE_ROUNDS}"
            stop_now="$(should_stop_after_fine_round "$rounds_done" "$current_best_score" "$current_best_mbps" "$TARGET_MBPS" "$last_best_score" "$last_best_mbps" "$stale_rounds")"
            stop_now="$(tr -d '[:space:]' <<< "$stop_now")"
            last_best_score="$current_best_score"
            last_best_mbps="$current_best_mbps"
            if [[ "$STOP_EARLY" -eq 1 && "$stop_now" == "1" ]]; then
                log "精测阶段提前结束：已达到目标吞吐，且连续 ${stale_rounds} 轮无明显提升。"
                break
            fi
        fi
    done <<< "$fine_candidates"

    select_best_overall || die "未选出有效最佳结果。"
    write_best_helper "${BEST_META[cc]}" "${BEST_META[qdisc]}" "${BEST_META[win]}"

    echo
    echo "====================== 最终结论 ======================"
    echo "目标单流：${TARGET_MBPS} Mbps"
    echo "最佳阶段：${BEST_META[phase]}"
    echo "最佳中位数吞吐：${BEST_META[mbps]} Mbps"
    echo "最佳参数：cc=${BEST_META[cc]}, qdisc=${BEST_META[qdisc]}, -w=${BEST_META[win]}"
    echo "综合评分：${BEST_META[score]}（越高越好；已惩罚重传）"
    echo "sender_retrans（中位数）：${BEST_META[sender_retrans]}"
    echo "本地 TcpRetransSegs Δ（中位数）：${BEST_META[local_retrans]}"
    echo "汇总表：${SUMMARY_CSV}"
    echo "推荐运行脚本：${BEST_HELPER}"
    write_final_summary_json
    echo "结构化汇总：${LOG_DIR}/final-summary.json"
    echo "======================================================"
    echo
    echo "[*] Top 5 聚合结果（按综合评分降序，其次低重传、再看高吞吐）："
    print_aggregated_top
    echo

    echo "[*] 推荐后续命令："
    if [[ "${BEST_META[win]}" == "auto" ]]; then
        echo "    ${IPERF3_BIN} -c ${SERVER_IP} -p ${PORT} -R --get-server-output -J"
    else
        echo "    ${IPERF3_BIN} -c ${SERVER_IP} -p ${PORT} -R --get-server-output -J -w ${BEST_META[win]}"
    fi
    echo

    case "$ACTION_ON_FINISH" in
        rollback)
            restore_sysctls
            [[ "$CURRENT_QDISC_CHANGED" -eq 1 ]] && clear_qdisc_best_effort "$IFACE"
            RESTORE_AT_EXIT=0
            log "已回滚到脚本运行前（best-effort）。"
            ;;
        keep)
            if [[ "$SWEEP_LOCAL_SENDER" -eq 1 ]]; then
                apply_local_sender_profile "${BEST_META[cc]}" "${BEST_META[qdisc]}" "$IFACE" || true
            fi
            RESTORE_AT_EXIT=0
            log "已保留最佳运行态；注意 -w 仍需在 iperf3 命令中显式使用。"
            ;;
        persist)
            if [[ "$SWEEP_LOCAL_SENDER" -eq 1 ]]; then
                apply_local_sender_profile "${BEST_META[cc]}" "${BEST_META[qdisc]}" "$IFACE" || true
            fi
            persist_best "$BUF_MAX_BYTES" "${BEST_META[cc]}" "${BEST_META[qdisc]}"
            RESTORE_AT_EXIT=0
            log "已持久化最佳运行态；注意 -w 仍需在 iperf3 命令中显式使用。"
            ;;
        ask)
            echo "接下来你决定："
            echo " 1) 保留最佳参数到当前运行态（不持久化）"
            echo " 2) 保留并持久化（重启仍生效；-w 仍需命令行显式带上）"
            echo " 3) 回滚到脚本运行前"
            choice="$(prompt_default '请选择 1/2/3' '3')"
            case "$choice" in
                1)
                    if [[ "$SWEEP_LOCAL_SENDER" -eq 1 ]]; then
                        apply_local_sender_profile "${BEST_META[cc]}" "${BEST_META[qdisc]}" "$IFACE" || true
                    fi
                    RESTORE_AT_EXIT=0
                    log "已保留最佳运行态；注意 -w 仍需在 iperf3 命令中显式使用。"
                    ;;
                2)
                    if [[ "$SWEEP_LOCAL_SENDER" -eq 1 ]]; then
                        apply_local_sender_profile "${BEST_META[cc]}" "${BEST_META[qdisc]}" "$IFACE" || true
                    fi
                    persist_best "$BUF_MAX_BYTES" "${BEST_META[cc]}" "${BEST_META[qdisc]}"
                    RESTORE_AT_EXIT=0
                    log "已持久化最佳运行态；注意 -w 仍需在 iperf3 命令中显式使用。"
                    ;;
                *)
                    restore_sysctls
                    [[ "$CURRENT_QDISC_CHANGED" -eq 1 ]] && clear_qdisc_best_effort "$IFACE"
                    RESTORE_AT_EXIT=0
                    log "已回滚到脚本运行前（best-effort）。"
                    ;;
            esac
            ;;
    esac

    echo
    log "完成。日志目录：$LOG_DIR"
}

# ===== end embedded local tuning engine =====

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
  local_engine_main "${cmd[@]:1}"
}

run_remote() {
  log "模式：双端联调"
  log "主线目标：调优并持久化双端 sysctl.conf / sysctl.d，以提高吞吐、降低重传"
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
    BEST_SCORE="-999999"
    BEST_LOG=""
    SUMMARY_ROWS=""
    for profile in bbr-fq cubic-fq cubic-fq_codel; do
      echo "[*] 测试远端 profile: $profile"
      if [[ $REMOTE_TUNE -eq 1 ]] && ! remote_apply_profile "$profile"; then
        echo "[!] 跳过 profile=$profile：远端切换失败"
        SUMMARY_ROWS+="${profile}|0|-999999|-1|-1|?|?|?|remote-profile-logs/${profile}.log|REMOTE_APPLY_FAILED"$'\n'
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$profile" "0" "-999999" "-1" "-1" "?" "?" "?" "remote-profile-logs/${profile}.log" "REMOTE_APPLY_FAILED" >> "$SUMMARY_TSV"
        continue
      fi
      out_file="remote-profile-logs/${profile}.log"
      if ! run_local_once "$out_file"; then
        echo "[!] 跳过 profile=$profile：本地调优/测速失败"
        SUMMARY_ROWS+="${profile}|0|-999999|-1|-1|?|?|?|${out_file}|LOCAL_RUN_FAILED"$'\n'
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$profile" "0" "-999999" "-1" "-1" "?" "?" "?" "$out_file" "LOCAL_RUN_FAILED" >> "$SUMMARY_TSV"
        continue
      fi
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
      score="$(python3 - <<'PY2' "$meta_json"
import json, sys
print(json.loads(sys.argv[1]).get('best_score',''))
PY2
)"
      sender_retrans="$(python3 - <<'PY2' "$meta_json"
import json, sys
print(json.loads(sys.argv[1]).get('best_sender_retrans',''))
PY2
)"
      local_retrans="$(python3 - <<'PY2' "$meta_json"
import json, sys
print(json.loads(sys.argv[1]).get('best_local_retrans',''))
PY2
)"
      report="$(python3 - <<'PY2' "$meta_json"
import json, sys
print(json.loads(sys.argv[1]).get('report_path',''))
PY2
)"
      [[ -z "$score" ]] && score=-999999
      [[ -z "$sender_retrans" ]] && sender_retrans=-1
      [[ -z "$local_retrans" ]] && local_retrans=-1
      echo "[*] profile=$profile best_mbps=$mbps best_score=$score retrans=${sender_retrans}/${local_retrans} local_best=(cc=${cc:-?} qdisc=${qdisc:-?} win=${win:-?})"
      SUMMARY_ROWS+="${profile}|${mbps}|${score}|${sender_retrans}|${local_retrans}|${cc}|${qdisc}|${win}|${out_file}|${report}"$'\n'
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$profile" "$mbps" "$score" "$sender_retrans" "$local_retrans" "$cc" "$qdisc" "$win" "$out_file" "$report" >> "$SUMMARY_TSV"
      if awk "BEGIN {exit !(($score > $BEST_SCORE) || (($score == $BEST_SCORE) && ($mbps > $BEST_MBPS)))}"; then
        BEST_MBPS="$mbps"
        BEST_SCORE="$score"
        BEST_PROFILE="$profile"
        BEST_LOG="$out_file"
      fi
    done
    write_auto_all_summary_json "$SUMMARY_ROWS" "$BEST_PROFILE" "$BEST_MBPS" "$BEST_SCORE" "$BEST_LOG"
    print_auto_all_summary "$BEST_PROFILE" "$BEST_MBPS" "$BEST_SCORE" "$BEST_LOG" "$SUMMARY_ROWS"
    [[ -n "$BEST_PROFILE" ]] && print_auto_all_reuse_hint "$BEST_PROFILE"
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
  if [[ "$ACTION" == "ask" ]]; then
    echo "接下来你决定："
    echo " 1) 仅查看结果并回滚（默认）"
    echo " 2) 保留最佳运行态（本地 + 远端）"
    echo " 3) 持久化最佳配置（本地 + 远端；推荐）"
    choice="$(prompt_default '请选择 1/2/3' '3')"
    case "$choice" in
      2)
        ACTION="keep"
        REMOTE_KEEP=1
        echo "[*] 已选择：保留最佳运行态"
        ;;
      3)
        ACTION="persist"
        REMOTE_KEEP=1
        REMOTE_PERSIST=1
        if [[ -n "$BEST_PROFILE" && $REMOTE_TUNE -eq 1 ]]; then
          echo "[*] 正在将最佳远端 profile 持久化到服务端..."
          "${SSH_CMD[@]}" "$SERVER_SSH" "REMOTE_PROFILE='$BEST_PROFILE' REMOTE_PERSIST='1' bash -s" <<'REMOTE_PERSIST_APPLY'
set -euo pipefail
profile="$REMOTE_PROFILE"
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
printf '%s\n' "net.ipv4.tcp_congestion_control=$cc" "net.core.default_qdisc=$qdisc" > /etc/sysctl.d/99-iperf3-remote-profile.conf
sysctl --system >/dev/null 2>&1 || true
echo "[远程] 已持久化 profile=$profile cc=$cc qdisc=$qdisc iface=${iface:-unknown}"
REMOTE_PERSIST_APPLY
        fi
        echo "[*] 已选择：持久化最佳配置（双端 sysctl 已落地；iperf3 的 -w 仍建议显式使用）"
        ;;
      *)
        ACTION="rollback"
        echo "[*] 已选择：仅查看结果并回滚"
        ;;
    esac
  fi

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

need_root
ensure_local_deps
if [[ "$LOCAL_ONLY" -eq 1 || -z "$SERVER_SSH" ]]; then
  run_local
else
  if [[ -n "$SERVER_SSH_PASS" ]] && ! have_cmd sshpass; then
    die "你传了 SSH 密码，但本机没有 sshpass。先安装：apt-get update && apt-get install -y sshpass"
  fi
  run_remote
fi
