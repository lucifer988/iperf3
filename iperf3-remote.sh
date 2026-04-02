#!/usr/bin/env bash
# iperf3-remote.sh - 远程双端联调包装脚本
set -euo pipefail

SERVER_SSH=""
SERVER_IP=""
SERVER_PORT=5201
TARGET_MBPS=1000
LOCAL_SCRIPT="./iperf3.sh"
REMOTE_TUNE=1
CLIENT_IP=""
LOCAL_ACTION="rollback"
REMOTE_KEEP=0
REMOTE_PERSIST=0
REMOTE_PROFILE="auto"
ASSUME_YES=0
LOCAL_PROFILE="balanced"
LOCAL_COARSE=""
LOCAL_FINE=""
LOCAL_OMIT=""
LOCAL_BIND=""
LOCAL_SKIP_RX_COPY=0
REPORT_DIR=""
SUMMARY_TSV=""
SUMMARY_JSON=""
RUN_TS="$(date +%Y%m%d_%H%M%S)"

usage() {
cat <<'EOF'
用法: sudo ./iperf3-remote.sh [选项]

必需参数:
  --server-ssh USER@HOST    SSH 登录信息（如 root@1.2.3.4）
  --server IP               服务端 IP（用于 iperf3 连接）

可选参数:
  --port PORT               iperf3 端口，默认 5201
  --target-mbps N           目标速率，默认 1000
  --client-ip IP            client IP（供服务端测 RTT；建议填写）
  --remote-profile NAME     auto|auto-all|bbr-fq|cubic-fq|cubic-fq_codel，默认 auto
  --local-script PATH       本地 iperf3.sh 路径，默认 ./iperf3.sh
  --local-keep              本地测速后保留运行态
  --local-persist           本地测速后持久化
  --yes                     非交互运行（自动采用默认策略）
  --profile NAME            透传给本地 iperf3.sh 的 profile
  --coarse-seconds N        透传给本地 iperf3.sh
  --fine-seconds N          透传给本地 iperf3.sh
  --omit N                  透传给本地 iperf3.sh
  --bind IP                 透传给本地 iperf3.sh 的 --bind
  --skip-rx-copy            透传给本地 iperf3.sh
  --remote-keep             远端测速后保留运行态，不自动回滚
  --remote-persist          远端持久化 sysctl（隐含 --remote-keep）
  --no-remote-tune          跳过远程调优
  --help                    显示帮助

示例:
  sudo ./iperf3-remote.sh \
    --server-ssh root@1.2.3.4 \
    --server 1.2.3.4 \
    --client-ip 5.6.7.8 \
    --remote-profile auto-all \
    --target-mbps 600
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-ssh) SERVER_SSH="$2"; shift 2 ;;
    --server) SERVER_IP="$2"; shift 2 ;;
    --port) SERVER_PORT="$2"; shift 2 ;;
    --target-mbps) TARGET_MBPS="$2"; shift 2 ;;
    --client-ip) CLIENT_IP="$2"; shift 2 ;;
    --remote-profile) REMOTE_PROFILE="$2"; shift 2 ;;
    --local-script) LOCAL_SCRIPT="$2"; shift 2 ;;
    --local-keep) LOCAL_ACTION="keep"; shift ;;
    --local-persist) LOCAL_ACTION="persist"; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --profile) LOCAL_PROFILE="$2"; shift 2 ;;
    --coarse-seconds) LOCAL_COARSE="$2"; shift 2 ;;
    --fine-seconds) LOCAL_FINE="$2"; shift 2 ;;
    --omit) LOCAL_OMIT="$2"; shift 2 ;;
    --bind) LOCAL_BIND="$2"; shift 2 ;;
    --skip-rx-copy) LOCAL_SKIP_RX_COPY=1; shift ;;
    --remote-keep) REMOTE_KEEP=1; shift ;;
    --remote-persist) REMOTE_PERSIST=1; REMOTE_KEEP=1; shift ;;
    --no-remote-tune) REMOTE_TUNE=0; shift ;;
    --help) usage; exit 0 ;;
    *) echo "未知参数: $1"; usage; exit 1 ;;
  esac
done

[[ -z "$SERVER_SSH" ]] && { echo "错误: 缺少 --server-ssh"; usage; exit 1; }
[[ -z "$SERVER_IP" ]] && { echo "错误: 缺少 --server"; usage; exit 1; }
[[ -x "$LOCAL_SCRIPT" ]] || { echo "错误: 本地脚本不存在或不可执行: $LOCAL_SCRIPT" >&2; exit 1; }
[[ "$REMOTE_PROFILE" =~ ^(auto|auto-all|bbr-fq|cubic-fq|cubic-fq_codel)$ ]] || { echo "错误: --remote-profile 非法" >&2; exit 1; }

echo "[*] 远程调优目标: $SERVER_SSH"
echo "[*] 服务端 IP: $SERVER_IP"
echo "[*] 目标速率: ${TARGET_MBPS} Mbps"
echo "[*] 远端 profile: ${REMOTE_PROFILE}"
[[ -n "$CLIENT_IP" ]] && echo "[*] Client IP: $CLIENT_IP"
echo

REPORT_DIR="remote-auto-report_${SERVER_IP//[^[:alnum:]._-]/_}_${RUN_TS}"
mkdir -p "$REPORT_DIR"
SUMMARY_TSV="$REPORT_DIR/summary.tsv"
SUMMARY_JSON="$REPORT_DIR/summary.json"

printf "profile	best_mbps	local_cc	local_qdisc	local_win	log	report
" > "$SUMMARY_TSV"

remote_bootstrap() {
  ssh "$SERVER_SSH" "CLIENT_IP='$CLIENT_IP' SERVER_PORT='$SERVER_PORT' TARGET_MBPS='$TARGET_MBPS' REMOTE_PERSIST='$REMOTE_PERSIST' REMOTE_PROFILE='$REMOTE_PROFILE' bash -s" <<'REMOTE_SCRIPT'
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
RTT="$(measure_rtt_ms "$CLIENT_IP")"
echo "[远程] RTT: ${RTT} ms"
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
nohup iperf3 -s -p "$SERVER_PORT" > "$LOG_FILE" 2>&1 &
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
  ssh "$SERVER_SSH" "REMOTE_PROFILE='$profile' bash -s" <<'REMOTE_APPLY'
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
  case "$LOCAL_ACTION" in
    keep) action_flag="--keep" ;;
    persist) action_flag="--persist" ;;
  esac
  "$LOCAL_SCRIPT" \
    --server "$SERVER_IP" \
    --port "$SERVER_PORT" \
    --target-mbps "$TARGET_MBPS" \
    --max-mbps "$TARGET_MBPS" \
    --profile balanced \
    "$action_flag" \
    --yes | tee "$log_file"
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
  printf '%s
' "$all_rows" | while IFS='|' read -r profile mbps cc qdisc win log report; do
    [[ -n "$profile" ]] || continue
    printf '    - %-14s %10s Mbps | local(cc=%s qdisc=%s win=%s) | log=%s'       "$profile" "$mbps" "${cc:-?}" "${qdisc:-?}" "${win:-?}" "$log"
    [[ -n "$report" ]] && printf ' | report=%s' "$report"
    printf '
'
  done
}

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
    SUMMARY_ROWS+="${profile}|${mbps}|${cc}|${qdisc}|${win}|${out_file}|${report}"$'
'
    if awk "BEGIN {exit !($mbps > $BEST_MBPS)}"; then
      BEST_MBPS="$mbps"
      BEST_PROFILE="$profile"
      BEST_LOG="$out_file"
    fi
  done
  echo
  echo "[*] 双端联合搜索完成"
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
if [[ $REMOTE_TUNE -eq 1 && $REMOTE_KEEP -eq 0 ]]; then
  echo "[*] 步骤 3: 清理服务端..."
  ssh "$SERVER_SSH" bash -s <<'CLEANUP'
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
echo "[远程] 停止 iperf3 server..."
if [[ -f "$PID_FILE" ]]; then
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$PID_FILE"
fi
echo "[远程] 恢复参数..."
restore_key net.core.rmem_max /tmp/iperf3_rmem_max.bak
restore_key net.core.wmem_max /tmp/iperf3_wmem_max.bak
restore_key net.ipv4.tcp_wmem /tmp/iperf3_tcp_wmem.bak
restore_key net.ipv4.tcp_congestion_control /tmp/iperf3_cc.bak
restore_key net.core.default_qdisc /tmp/iperf3_qdisc.bak
rm -f /tmp/iperf3_*.bak /tmp/iperf3_remote_profile.state
echo "[远程] 清理完成"
CLEANUP
else
  echo "[*] 步骤 3: 跳过远端回滚（按你的参数保留远端运行态）"
fi

echo
echo "[*] 全部完成！"
