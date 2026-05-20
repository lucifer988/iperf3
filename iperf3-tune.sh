#!/usr/bin/env bash
#
# iperf3-tune.sh — iperf3 高速低重传优化工具 (v2)
#
# 目标: 最大化 iperf3 测得带宽, 最小化重传率。
#       业务无感 NOT 重要 —— 我们激进调优。
#
# 用法:
#   iperf3-tune.sh detect                                  # 仅检测瓶颈
#   iperf3-tune.sh tune [--profile aggressive|extreme]     # 仅应用本机优化
#   iperf3-tune.sh bench --server IP [--port N] [--time S] # 仅跑测试
#   iperf3-tune.sh optimize --server IP [...]              # 完整流程
#   iperf3-tune.sh rollback                                # 回退
#   iperf3-tune.sh status                                  # 状态
#
# 设计要点 (相比 v1 的主要变化):
#   1. 函数间数据传递改用 JSON, 不再用 "|" 分隔符
#   2. 所有 awk 调用改用 -v 传参, 杜绝 shell 注入
#   3. ethtool 输出解析改成定位段头, 不再依赖固定行偏移
#   4. 网卡探测三级 fallback, 不再硬编码 ip route get 8.8.8.8
#   5. 多流寻优引入评分函数 score = bw * (1 - k * retrans_rate)
#   6. 每个并发数测 N 次取中位数, 滤掉单次噪声
#   7. SSH 优先 key, 仅在 --ssh-pass 显式给出时才用 sshpass
#   8. sysctl 应用前完整 backup, 回退按 backup 精确还原
#   9. read -p 默认非交互, 仅在 -t 0 (tty) + 无 --yes 时询问
#  10. 移除冗余的 "|| true" / "|| echo 0" 容错垃圾, errexit 真正生效
#

set -Eeuo pipefail
shopt -s nullglob

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------
readonly VERSION="2.0.0"
readonly SCRIPT_PATH="${BASH_SOURCE[0]}"
readonly SCRIPT_NAME="$(basename "${SCRIPT_PATH}")"

readonly CONFIG_DIR="${IPERF3_TUNE_CONFIG_DIR:-/etc/iperf3-tune}"
readonly STATE_DIR="${IPERF3_TUNE_STATE_DIR:-/var/lib/iperf3-tune}"
readonly LOG_DIR="${IPERF3_TUNE_LOG_DIR:-/var/log/iperf3-tune}"

readonly SYSCTL_FILE="/etc/sysctl.d/99-iperf3-tune.conf"
readonly SYSCTL_BACKUP="${STATE_DIR}/sysctl.before.txt"
readonly NIC_BACKUP="${STATE_DIR}/nic.before.json"
readonly STATE_FILE="${STATE_DIR}/state.json"
readonly PROGRESS_FILE="${STATE_DIR}/progress.json"
readonly PID_FILE="${STATE_DIR}/iperf3-tune.pid"

# 颜色 (仅 stderr 是 tty 时启用)
if [[ -t 2 ]]; then
    C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
    C_BLUE=$'\033[0;34m'; C_CYAN=$'\033[0;36m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_BOLD=""; C_RESET=""
fi

# ---------------------------------------------------------------------------
# 全局参数 (parse_args 填充)
# ---------------------------------------------------------------------------
CMD=""
SERVER=""
PORT=5201
DURATION=30
REPEATS=3
MAX_PARALLEL=32
PROFILE="aggressive"           # balanced | aggressive | extreme
DIRECTION="reverse"            # reverse(下行) | forward(上行)
CONGESTION="bbr"
RETRANS_THRESHOLD=1.0          # %，超过即视为不健康
RETRANS_PENALTY=10.0           # 评分函数中重传惩罚系数 k
SSH_HOST=""
SSH_USER="root"
SSH_KEY=""
SSH_PASS=""
SSH_PORT=22
INTERACTIVE=1                  # -t 0 时自动改 0
ASSUME_YES=0
VERBOSE=0
JSON_OUT=0
DETACH=0                       # --detach 时改 1, fork 到后台
PRIMARY_IFACE=""

# ---------------------------------------------------------------------------
# 日志 (统一输出到 stderr, 不污染函数返回的 stdout)
# ---------------------------------------------------------------------------
_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log()  { printf '%s[%s]%s %s\n' "${C_CYAN}"   "$(_ts)" "${C_RESET}" "$*" >&2; }
ok()   { printf '%s[%s] ✓%s %s\n' "${C_GREEN}" "$(_ts)" "${C_RESET}" "$*" >&2; }
warn() { printf '%s[%s] ⚠%s %s\n' "${C_YELLOW}" "$(_ts)" "${C_RESET}" "$*" >&2; }
err()  { printf '%s[%s] ✗%s %s\n' "${C_RED}"   "$(_ts)" "${C_RESET}" "$*" >&2; }
die()  { err "$*"; exit 1; }
vlog() { [[ $VERBOSE -eq 1 ]] && log "$@" || true; }

# 错误时打印调用栈，定位哪一行出的问题
on_err() {
    local rc=$?
    local line=${BASH_LINENO[0]:-?}
    err "脚本在第 ${line} 行失败 (exit=${rc})"
    exit "$rc"
}
trap on_err ERR

# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------
require_root() {
    [[ $EUID -eq 0 ]] || die "需要 root: sudo $SCRIPT_NAME $*"
}

# 数值比较 (用 awk, 避免引入 bc 的 fork 开销)
num_gt() { awk -v a="$1" -v b="$2" 'BEGIN {exit !(a+0 >  b+0)}'; }
num_lt() { awk -v a="$1" -v b="$2" 'BEGIN {exit !(a+0 <  b+0)}'; }
num_ge() { awk -v a="$1" -v b="$2" 'BEGIN {exit !(a+0 >= b+0)}'; }
num_le() { awk -v a="$1" -v b="$2" 'BEGIN {exit !(a+0 <= b+0)}'; }

# 百分比 (a/b * 100, 保留 2 位)
pct() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        if (b+0 == 0) { print "0.00"; exit }
        printf "%.2f", (a+0)/(b+0)*100
    }'
}

# 中位数
median() {
    [[ $# -eq 0 ]] && { echo 0; return; }
    printf '%s\n' "$@" | sort -g | awk '
        { a[NR]=$1 }
        END {
            if (NR==0) { print 0; exit }
            if (NR%2==1) printf "%.4f\n", a[(NR+1)/2]
            else         printf "%.4f\n", (a[NR/2] + a[NR/2+1]) / 2
        }
    '
}

# 检查依赖
check_dependencies() {
    local need=("$@")
    [[ ${#need[@]} -eq 0 ]] && need=(jq iperf3 ethtool ip awk sed grep sort tee)
    local missing=()
    for c in "${need[@]}"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        err "缺少依赖: ${missing[*]}"
        err "  Debian/Ubuntu: apt-get install -y jq iperf3 ethtool iproute2 sysstat"
        err "  RHEL/CentOS:   yum install -y jq iperf3 ethtool iproute2 sysstat"
        exit 1
    fi
    if [[ -n "$SSH_PASS" ]] && ! command -v sshpass >/dev/null 2>&1; then
        die "使用 --ssh-pass 需要 sshpass, 但未安装"
    fi
}

# 探测主网卡 (三级 fallback)
detect_primary_iface() {
    [[ -n "$PRIMARY_IFACE" ]] && { echo "$PRIMARY_IFACE"; return; }

    local iface=""

    # 1) IPv4 默认路由
    iface=$(ip -4 route show default 2>/dev/null \
        | awk '$1=="default"{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' \
        | head -1)

    # 2) IPv6 默认路由
    if [[ -z "$iface" ]]; then
        iface=$(ip -6 route show default 2>/dev/null \
            | awk '$1=="default"{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' \
            | head -1)
    fi

    # 3) /sys/class/net 下第一个 state=up 的物理网卡
    if [[ -z "$iface" ]]; then
        local d name state
        for d in /sys/class/net/*/; do
            name=$(basename "$d")
            [[ "$name" == "lo" ]] && continue
            [[ -e "$d/device" ]] || continue              # 跳过虚接口 (bridge/veth)
            state=$(cat "$d/operstate" 2>/dev/null || echo "")
            if [[ "$state" == "up" ]]; then
                iface="$name"
                break
            fi
        done
    fi

    [[ -n "$iface" ]] || die "无法探测主网卡, 用 PRIMARY_IFACE=eth0 显式指定"
    [[ -e "/sys/class/net/$iface" ]] || die "网卡 $iface 不存在"

    PRIMARY_IFACE="$iface"
    echo "$iface"
}

# 创建工作目录 (root only)
ensure_dirs() {
    [[ -d "$CONFIG_DIR" ]] || mkdir -p "$CONFIG_DIR"
    [[ -d "$STATE_DIR"  ]] || mkdir -p "$STATE_DIR"
    [[ -d "$LOG_DIR"    ]] || mkdir -p "$LOG_DIR"
    chmod 700 "$CONFIG_DIR" "$STATE_DIR"
}

# ---------------------------------------------------------------------------
# 瓶颈检测 (每个函数返回一个 JSON 字符串到 stdout)
# ---------------------------------------------------------------------------
detect_cpu() {
    log "检测 CPU 瓶颈..."
    local iface; iface=$(detect_primary_iface)
    local cpu_cores; cpu_cores=$(nproc)

    # 软中断速率
    local s1 s2
    s1=$(awk '$1=="softirq"{sum=0; for(i=2;i<=NF;i++) sum+=$i; print sum}' /proc/stat)
    sleep 1
    s2=$(awk '$1=="softirq"{sum=0; for(i=2;i<=NF;i++) sum+=$i; print sum}' /proc/stat)
    local softirq_rate=$((s2 - s1))

    # 网卡中断队列数
    local irq_queues
    irq_queues=$(grep -E "${iface}(-|\$)" /proc/interrupts 2>/dev/null | wc -l)

    # CPU 使用率 (mpstat 不存在则用 /proc/stat)
    local cpu_usage="0"
    if command -v mpstat >/dev/null 2>&1; then
        cpu_usage=$(mpstat 1 1 2>/dev/null \
            | awk '/^Average:[[:space:]]+all/ {printf "%.1f", 100-$NF}' || echo 0)
    fi

    # RPS 状态
    local rps_enabled=0 f
    for f in /sys/class/net/"$iface"/queues/rx-*/rps_cpus; do
        [[ -f "$f" ]] || continue
        local v; v=$(cat "$f" 2>/dev/null | tr -d ',0')
        if [[ -n "$v" ]]; then rps_enabled=1; break; fi
    done

    # 评估
    local bottleneck="none" severity=0 recommend=""
    if [[ $irq_queues -lt $cpu_cores ]] && [[ $cpu_cores -gt 2 ]] && [[ $rps_enabled -eq 0 ]]; then
        bottleneck="cpu_interrupt_imbalance"; severity=2
        recommend="网卡中断队列 ($irq_queues) < CPU 核心 ($cpu_cores) 且 RPS 未启用"
    fi
    if [[ $softirq_rate -gt 100000 ]]; then
        bottleneck="cpu_softirq_high"; severity=3
        recommend="软中断速率过高 (${softirq_rate}/s), 需启用网卡硬件 offload"
    fi
    if num_gt "$cpu_usage" 80; then
        bottleneck="cpu_usage_high"; severity=2
        recommend="CPU 使用率 ${cpu_usage}% 过高"
    fi

    jq -n \
        --arg b "$bottleneck" --argjson s "$severity" --arg r "$recommend" \
        --argjson cores "$cpu_cores" --argjson irq "$irq_queues" \
        --argjson sir "$softirq_rate" --arg cpu "$cpu_usage" \
        --argjson rps "$rps_enabled" \
        '{
            bottleneck: $b, severity: $s, recommend: $r,
            cpu_cores: $cores, irq_queues: $irq, softirq_rate: $sir,
            cpu_usage_pct: ($cpu|tonumber), rps_enabled: ($rps==1)
        }'
}

detect_memory() {
    log "检测内存瓶颈..."
    local total_kb avail_kb
    total_kb=$(awk '/^MemTotal:/  {print $2}' /proc/meminfo)
    avail_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
    local total_gb avail_gb
    total_gb=$(awk -v k="$total_kb" 'BEGIN {printf "%.2f", k/1024/1024}')
    avail_gb=$(awk -v k="$avail_kb" 'BEGIN {printf "%.2f", k/1024/1024}')

    local rmem_max wmem_max
    rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)
    wmem_max=$(sysctl -n net.core.wmem_max 2>/dev/null || echo 0)

    local bottleneck="none" severity=0 recommend=""
    if num_lt "$avail_gb" 0.5; then
        bottleneck="memory_critical"; severity=4
        recommend="可用内存仅 ${avail_gb}GB"
    elif num_lt "$total_gb" 2; then
        bottleneck="memory_low"; severity=2
        recommend="物理内存 ${total_gb}GB 偏小, 建议 profile=balanced"
    fi

    jq -n \
        --arg b "$bottleneck" --argjson s "$severity" --arg r "$recommend" \
        --arg tot "$total_gb" --arg av "$avail_gb" \
        --argjson rm "$rmem_max" --argjson wm "$wmem_max" \
        '{
            bottleneck: $b, severity: $s, recommend: $r,
            total_gb: ($tot|tonumber), available_gb: ($av|tonumber),
            rmem_max: $rm, wmem_max: $wm
        }'
}

# 稳健的 ethtool 输出解析:
# 不依赖固定行偏移, 而是定位 "Pre-set maximums" 和 "Current hardware settings" 段头,
# 然后在各自段内 grep 字段
_ethtool_ring() {
    local iface="$1" section="$2" field="$3"
    # section: "max" or "cur"; field: RX, TX, RX-Mini, RX-Jumbo
    ethtool -g "$iface" 2>/dev/null | awk -v sec="$section" -v fld="$field" '
        /^Pre-set maximums:/        { in_max=1; in_cur=0; next }
        /^Current hardware settings:/ { in_max=0; in_cur=1; next }
        {
            if ((sec=="max" && in_max) || (sec=="cur" && in_cur)) {
                if ($1 == fld":") { print $2; exit }
            }
        }
    '
}

detect_nic() {
    log "检测网卡瓶颈..."
    local iface; iface=$(detect_primary_iface)

    local nic_speed="0"
    if [[ -r /sys/class/net/"$iface"/speed ]]; then
        nic_speed=$(cat /sys/class/net/"$iface"/speed 2>/dev/null)
        [[ "$nic_speed" =~ ^-?[0-9]+$ ]] || nic_speed=0
    fi

    local gro tso lro gso
    gro=$(ethtool -k "$iface" 2>/dev/null | awk '/^generic-receive-offload:/ {print $2; exit}')
    tso=$(ethtool -k "$iface" 2>/dev/null | awk '/^tcp-segmentation-offload:/ {print $2; exit}')
    lro=$(ethtool -k "$iface" 2>/dev/null | awk '/^large-receive-offload:/    {print $2; exit}')
    gso=$(ethtool -k "$iface" 2>/dev/null | awk '/^generic-segmentation-offload:/ {print $2; exit}')

    local rx_cur tx_cur rx_max tx_max
    rx_cur=$(_ethtool_ring "$iface" cur RX)
    tx_cur=$(_ethtool_ring "$iface" cur TX)
    rx_max=$(_ethtool_ring "$iface" max RX)
    tx_max=$(_ethtool_ring "$iface" max TX)

    local mtu="1500"
    [[ -r /sys/class/net/"$iface"/mtu ]] && mtu=$(cat /sys/class/net/"$iface"/mtu)

    local bottleneck="none" severity=0 recommend=""
    if [[ "$gro" == "off" || "$tso" == "off" ]]; then
        bottleneck="nic_offload_disabled"; severity=2
        recommend="GRO/TSO 未启用 (gro=$gro tso=$tso)"
    fi
    if [[ -n "$rx_cur" && -n "$rx_max" ]] \
       && [[ "$rx_cur" =~ ^[0-9]+$ && "$rx_max" =~ ^[0-9]+$ ]] \
       && [[ $rx_cur -lt $rx_max ]]; then
        bottleneck="nic_ring_small"; severity=1
        recommend="RX ring 当前 $rx_cur < 最大 $rx_max"
    fi

    jq -n \
        --arg iface "$iface" --argjson speed "$nic_speed" \
        --arg gro "${gro:-unknown}" --arg tso "${tso:-unknown}" \
        --arg lro "${lro:-unknown}" --arg gso "${gso:-unknown}" \
        --arg rxc "${rx_cur:-0}" --arg txc "${tx_cur:-0}" \
        --arg rxm "${rx_max:-0}" --arg txm "${tx_max:-0}" \
        --argjson mtu "$mtu" \
        --arg b "$bottleneck" --argjson s "$severity" --arg r "$recommend" \
        '{
            iface: $iface, speed_mbps: $speed, mtu: $mtu,
            offload: { gro: $gro, tso: $tso, lro: $lro, gso: $gso },
            ring: { rx_cur: ($rxc|tonumber), tx_cur: ($txc|tonumber),
                    rx_max: ($rxm|tonumber), tx_max: ($txm|tonumber) },
            bottleneck: $b, severity: $s, recommend: $r
        }'
}

detect_all() {
    local cpu mem nic
    cpu=$(detect_cpu)
    mem=$(detect_memory)
    nic=$(detect_nic)

    # 取最大严重度 (jq -rn: -r raw 输出去引号, -n 不读 stdin)
    local max_sev primary
    read -r max_sev primary < <(jq -rn \
        --argjson c "$cpu" --argjson m "$mem" --argjson n "$nic" '
        [{name:"cpu",sev:$c.severity},{name:"memory",sev:$m.severity},{name:"nic",sev:$n.severity}]
        | sort_by(-.sev)
        | .[0]
        | "\(.sev) \(.name)"
    ')

    jq -n \
        --arg ts "$(date -Iseconds)" \
        --arg primary "$primary" --argjson max_sev "$max_sev" \
        --argjson cpu "$cpu" --argjson mem "$mem" --argjson nic "$nic" \
        '{
            timestamp: $ts,
            primary_bottleneck: $primary, max_severity: $max_sev,
            cpu: $cpu, memory: $mem, nic: $nic
        }'
}

# 可读地打印 detect_all 的报告
print_report() {
    local report_json="$1"
    echo "" >&2
    log "${C_BOLD}========== 系统瓶颈报告 ==========${C_RESET}"
    jq -r '
        "主网卡:        \(.nic.iface) (\(.nic.speed_mbps) Mbps, MTU \(.nic.mtu))",
        "CPU 核心:      \(.cpu.cpu_cores)  中断队列: \(.cpu.irq_queues)  RPS: \(.cpu.rps_enabled)",
        "软中断速率:    \(.cpu.softirq_rate)/s   CPU 使用率: \(.cpu.cpu_usage_pct)%",
        "内存:          \(.memory.total_gb)GB (可用 \(.memory.available_gb)GB)",
        "TCP 缓冲区:    rmem_max=\(.memory.rmem_max)  wmem_max=\(.memory.wmem_max)",
        "网卡 offload:  gro=\(.nic.offload.gro)  tso=\(.nic.offload.tso)  gso=\(.nic.offload.gso)  lro=\(.nic.offload.lro)",
        "Ring buffer:   rx=\(.nic.ring.rx_cur)/\(.nic.ring.rx_max)  tx=\(.nic.ring.tx_cur)/\(.nic.ring.tx_max)",
        "主要瓶颈:      \(.primary_bottleneck) (severity \(.max_severity)/4)"
    ' <<<"$report_json" >&2

    local recs
    recs=$(jq -r '
        [.cpu, .memory, .nic]
        | map(select(.bottleneck != "none"))
        | .[] | "  - \(.bottleneck): \(.recommend)"
    ' <<<"$report_json")
    if [[ -n "$recs" ]]; then
        echo "" >&2
        log "${C_YELLOW}建议:${C_RESET}"
        echo "$recs" >&2
    fi
}

# ---------------------------------------------------------------------------
# sysctl profile 生成
# ---------------------------------------------------------------------------
# 三档 profile, 越往后越激进:
#   balanced   : 64MB 缓冲, 适合 1G/2.5G 链路, 业务影响小
#   aggressive : 256MB 缓冲, 适合 10G 链路, 业务有轻微影响 (默认)
#   extreme    : 1GB 缓冲 + 关 ECN + 关 slow_start_after_idle, 适合 25G+ 或长肥管道
build_sysctl() {
    local profile="$1"
    local cores; cores=$(nproc)

    # 基础项 (三档共享)
    cat <<'BASE'
# ---- iperf3-tune: base ----
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.core.netdev_max_backlog = 30000
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 65535
BASE

    # BBR + fq
    cat <<BBR
# ---- iperf3-tune: bbr ----
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = ${CONGESTION}
BBR

    case "$profile" in
        balanced)
            cat <<'EOF'
# ---- iperf3-tune: balanced (64MB) ----
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_mem = 786432 1048576 1572864
EOF
            ;;
        aggressive)
            cat <<EOF
# ---- iperf3-tune: aggressive (256MB) ----
net.core.rmem_max = 268435456
net.core.wmem_max = 268435456
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 1048576 268435456
net.ipv4.tcp_wmem = 4096 1048576 268435456
net.ipv4.tcp_mem = 4194304 6291456 8388608
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_limit_output_bytes = 1048576
net.core.rps_sock_flow_entries = 32768
EOF
            ;;
        extreme)
            cat <<EOF
# ---- iperf3-tune: extreme (1GB, 业务影响显著) ----
net.core.rmem_max = 1073741824
net.core.wmem_max = 1073741824
net.core.rmem_default = 4194304
net.core.wmem_default = 4194304
net.ipv4.tcp_rmem = 4096 4194304 1073741824
net.ipv4.tcp_wmem = 4096 4194304 1073741824
net.ipv4.tcp_mem = 16777216 33554432 67108864
net.core.netdev_budget = 1200
net.core.netdev_budget_usecs = 16000
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_limit_output_bytes = 4194304
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_fastopen = 3
net.core.rps_sock_flow_entries = 65536
# 极限场景禁用反向路径过滤, 避免多路径包被丢
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
EOF
            ;;
        *)
            die "未知 profile: $profile (可选 balanced/aggressive/extreme)"
            ;;
    esac
}

# 备份所有将被修改的 sysctl 当前值
backup_sysctl() {
    log "备份当前 sysctl 值到 $SYSCTL_BACKUP"
    local keys
    keys=$(build_sysctl "$PROFILE" | awk -F' *= *' '/^[a-z]/ {print $1}' | sort -u)
    : > "$SYSCTL_BACKUP"
    local k v
    while IFS= read -r k; do
        v=$(sysctl -n "$k" 2>/dev/null || echo "__UNSET__")
        printf '%s = %s\n' "$k" "$v" >> "$SYSCTL_BACKUP"
    done <<<"$keys"
    ok "已备份 $(wc -l <"$SYSCTL_BACKUP") 项 sysctl"
}

# 写 sysctl 配置文件并加载
write_and_apply_sysctl() {
    local profile="$1"
    log "应用 sysctl profile: ${C_BOLD}${profile}${C_RESET}"
    backup_sysctl

    {
        echo "# Generated by $SCRIPT_NAME at $(date -Iseconds)"
        echo "# profile=$profile, congestion=$CONGESTION"
        echo "# 用 '$SCRIPT_NAME rollback' 回退"
        echo ""
        build_sysctl "$profile"
    } > "$SYSCTL_FILE"

    chmod 644 "$SYSCTL_FILE"

    # 一次性加载, 出错的项打印但不中断
    local out
    if out=$(sysctl -p "$SYSCTL_FILE" 2>&1); then
        ok "sysctl 已应用 ($(echo "$out" | wc -l) 项)"
    else
        warn "部分 sysctl 应用失败 (可能是当前内核不支持的键):"
        echo "$out" | grep -E "error|cannot|unknown" >&2 || true
    fi
}

# 备份网卡硬件设置 (offload, ring buffer)
backup_nic() {
    local iface; iface=$(detect_primary_iface)
    log "备份网卡 $iface 当前设置到 $NIC_BACKUP"
    local offload ring
    offload=$(ethtool -k "$iface" 2>/dev/null | awk -F': ' 'NR>1 {gsub(/ \[fixed\]/,"",$2); print $1"="$2}' | tr '\n' ';')
    ring=$(ethtool -g "$iface" 2>/dev/null | awk '
        /^Current hardware settings:/ { incur=1; next }
        incur && /^[A-Z]/ { gsub(":","",$1); printf "%s=%s;", $1, $2 }
    ')
    jq -n --arg iface "$iface" --arg offload "$offload" --arg ring "$ring" \
        '{iface:$iface, offload:$offload, ring:$ring}' > "$NIC_BACKUP"
}

# 网卡硬件优化: 启用所有 offload + 拉满 ring buffer + RPS/RFS/XPS
apply_nic_tuning() {
    local iface; iface=$(detect_primary_iface)
    local cores; cores=$(nproc)

    log "应用网卡硬件优化 (iface=$iface)"
    backup_nic

    # 1) 启用硬件 offload (失败的项打印 warn 但继续)
    local feat
    for feat in gro tso gso sg rx tx rxhash rxvlan txvlan; do
        if ethtool -K "$iface" "$feat" on >/dev/null 2>&1; then
            vlog "  ${feat}: on"
        else
            vlog "  ${feat}: skip (not supported)"
        fi
    done
    # LRO 在转发场景可能丢包, 仅终端用例启用
    ethtool -K "$iface" lro on >/dev/null 2>&1 || true

    # 2) Ring buffer 拉到最大
    local rx_max tx_max
    rx_max=$(_ethtool_ring "$iface" max RX)
    tx_max=$(_ethtool_ring "$iface" max TX)
    if [[ "$rx_max" =~ ^[0-9]+$ && $rx_max -gt 0 ]]; then
        if ethtool -G "$iface" rx "$rx_max" tx "${tx_max:-$rx_max}" >/dev/null 2>&1; then
            ok "  ring buffer: rx=$rx_max tx=${tx_max:-$rx_max}"
        else
            warn "  ring buffer 设置失败 (可能是 virtio 等不支持)"
        fi
    fi

    # 3) RPS / RFS / XPS 多核分布
    #    cpu_mask 是 cores bit 全置 1
    local cpu_mask
    cpu_mask=$(printf '%x' "$(( (1 << cores) - 1 ))")
    local q
    for q in /sys/class/net/"$iface"/queues/rx-*/rps_cpus; do
        [[ -f "$q" ]] && echo "$cpu_mask" > "$q" 2>/dev/null && vlog "  RPS: $q = $cpu_mask"
    done
    for q in /sys/class/net/"$iface"/queues/rx-*/rps_flow_cnt; do
        [[ -f "$q" ]] && echo 4096 > "$q" 2>/dev/null && vlog "  RFS: $q = 4096"
    done
    for q in /sys/class/net/"$iface"/queues/tx-*/xps_cpus; do
        [[ -f "$q" ]] && echo "$cpu_mask" > "$q" 2>/dev/null && vlog "  XPS: $q = $cpu_mask"
    done
    ok "  RPS/RFS/XPS 已启用 (mask=$cpu_mask)"

    # 4) IRQ 亲和性: 把网卡中断分散到不同 CPU
    if [[ -x /usr/sbin/set_irq_affinity ]]; then
        /usr/sbin/set_irq_affinity "$iface" >/dev/null 2>&1 && ok "  IRQ affinity 已分散"
    else
        # 手动版: 找到本网卡的 IRQ, 轮询绑定到各核
        local irqs i=0
        irqs=$(awk -v p="$iface" '$NF ~ p {sub(":","",$1); print $1}' /proc/interrupts)
        if [[ -n "$irqs" ]]; then
            for irq in $irqs; do
                local mask; mask=$(printf '%x' $((1 << (i % cores))))
                echo "$mask" > "/proc/irq/$irq/smp_affinity" 2>/dev/null || true
                i=$((i + 1))
            done
            ok "  IRQ affinity 已手动分散 ($i 个中断)"
        fi
    fi
}

# ---------------------------------------------------------------------------
# iperf3 测试
# ---------------------------------------------------------------------------
# 跑一次 iperf3, 输出 JSON 文件路径; 失败返回非零
run_iperf3() {
    local server="$1" port="$2" streams="$3" duration="$4" out="$5"
    local -a args=(
        -c "$server" -p "$port" -P "$streams" -t "$duration"
        -O 2                     # 忽略前 2 秒 slow start
        --connect-timeout 5000   # 5 秒连接超时
        -J
    )
    [[ "$DIRECTION" == "reverse" ]] && args+=(-R)
    iperf3 "${args[@]}" > "$out" 2>/dev/null
}

# 从 iperf3 JSON 提取 (bandwidth_mbps, retransmits, segments_sent, retrans_rate_pct)
parse_iperf3() {
    local f="$1"
    # 兼容 sum_received / sum_sent 字段位置
    jq -r '
        def bps:
            if .end.sum_received? then .end.sum_received.bits_per_second
            elif .end.sum? then .end.sum.bits_per_second
            else 0 end;
        def retrans:
            if .end.streams then ([.end.streams[].sender.retransmits // 0] | add)
            elif .end.sum_sent then (.end.sum_sent.retransmits // 0)
            else 0 end;
        def segs:
            if .end.streams then ([.end.streams[].sender.packets // 0] | add)
            else 0 end;
        "\(bps / 1000000)|\(retrans)|\(segs)"
    ' "$f" 2>/dev/null
}

# 在一个并发数下跑 N 次, 取中位数
bench_streams() {
    local server="$1" port="$2" streams="$3" duration="$4" repeats="$5"

    local bws=() rts=() rrs=()
    local i tmp result mbps rt sg rr
    for ((i=1; i<=repeats; i++)); do
        tmp=$(mktemp /tmp/iperf3-tune.XXXXXX.json)
        if ! run_iperf3 "$server" "$port" "$streams" "$duration" "$tmp"; then
            warn "  第 $i 次测试失败"
            rm -f "$tmp"
            continue
        fi
        result=$(parse_iperf3 "$tmp")
        rm -f "$tmp"
        IFS='|' read -r mbps rt sg <<<"$result"
        # retrans_rate = retrans / segments * 100
        if [[ "$sg" =~ ^[0-9]+$ && $sg -gt 0 ]]; then
            rr=$(pct "$rt" "$sg")
        else
            rr="0.00"
        fi
        bws+=("$mbps"); rts+=("$rt"); rrs+=("$rr")
        vlog "  run $i/$repeats: ${mbps} Mbps, retrans=$rt (${rr}%)"
        [[ $i -lt $repeats ]] && sleep 2  # 间隔, 让 TCP 状态稳定
    done

    [[ ${#bws[@]} -eq 0 ]] && { echo '{"streams":'"$streams"',"ok":false}'; return; }

    local med_bw med_rt med_rr
    med_bw=$(median "${bws[@]}")
    med_rt=$(median "${rts[@]}")
    med_rr=$(median "${rrs[@]}")

    # 评分函数: score = bandwidth * max(0, 1 - k * retrans_rate / 100)
    # k 默认 10 => 1% 重传扣 10% 分
    local score
    score=$(awk -v bw="$med_bw" -v rr="$med_rr" -v k="$RETRANS_PENALTY" \
        'BEGIN {p=1-k*rr/100; if(p<0)p=0; printf "%.4f", bw*p}')

    jq -n \
        --argjson streams "$streams" \
        --arg bw "$med_bw" --arg rt "$med_rt" --arg rr "$med_rr" --arg sc "$score" \
        --argjson n "${#bws[@]}" \
        '{
            streams: $streams, ok: true,
            samples: $n,
            bandwidth_mbps: ($bw|tonumber),
            retransmits:    ($rt|tonumber),
            retrans_rate_pct: ($rr|tonumber),
            score: ($sc|tonumber)
        }'
}

# 多并发数寻优. 返回 JSON 数组 + 最优配置
# 副作用: 每完成一档就把进度落盘到 $STATE_DIR/progress.json,
#         保证即使被 SSH 断了/被 kill 了, 已测出来的数据也不丢
find_optimal_parallel() {
    local server="$1" port="$2" duration="$3" repeats="$4" max_p="$5"
    local progress_file="${STATE_DIR}/progress.json"

    log "${C_BOLD}========== 多流寻优 ==========${C_RESET}"
    log "服务端: $server:$port  方向: $DIRECTION  时长: ${duration}s × $repeats 次"

    # 初始化进度文件
    if [[ -d "$STATE_DIR" ]]; then
        jq -n \
            --arg ts "$(date -Iseconds)" --arg server "$server" \
            --argjson port "$port" --argjson duration "$duration" \
            --argjson repeats "$repeats" --argjson pid "$$" \
            '{
                started: $ts, pid: $pid, server: $server, port: $port,
                duration: $duration, repeats: $repeats,
                status: "running", results: []
            }' > "$progress_file"
    fi

    local results=()
    local streams
    local prev_score=0
    for streams in 1 2 4 8 16 32; do
        [[ $streams -gt $max_p ]] && break
        log "${C_BOLD}测试 $streams 流${C_RESET}"
        local r
        r=$(bench_streams "$server" "$port" "$streams" "$duration" "$repeats")
        results+=("$r")

        # 增量落盘: 哪怕下一秒被 kill 了, 这一档的结果也已经存了
        if [[ -f "$progress_file" ]]; then
            jq --argjson r "$r" --arg ts "$(date -Iseconds)" \
                '.results += [$r] | .last_update = $ts' \
                "$progress_file" > "${progress_file}.tmp" \
                && mv "${progress_file}.tmp" "$progress_file"
        fi

        local ok bw rr sc
        ok=$(jq -r '.ok' <<<"$r")
        [[ "$ok" != "true" ]] && continue
        bw=$(jq -r '.bandwidth_mbps' <<<"$r")
        rr=$(jq -r '.retrans_rate_pct' <<<"$r")
        sc=$(jq -r '.score' <<<"$r")

        printf '  → %s%d 流%s: %s%.2f Mbps%s  重传率 %s%.3f%%%s  评分 %s%.2f%s\n' \
            "${C_BOLD}" "$streams" "${C_RESET}" \
            "${C_CYAN}" "$bw" "${C_RESET}" \
            "${C_YELLOW}" "$rr" "${C_RESET}" \
            "${C_GREEN}" "$sc" "${C_RESET}" >&2

        # 早停 1: 重传率严重超标
        if num_gt "$rr" "$RETRANS_THRESHOLD"; then
            warn "  重传率 $rr% > 阈值 $RETRANS_THRESHOLD%, 提前停止寻优"
            break
        fi

        # 早停 2: 评分下降 (前一档更优)
        if [[ $streams -gt 1 ]] && num_lt "$sc" "$(awk -v s="$prev_score" 'BEGIN{print s*0.95}')"; then
            warn "  评分相对前一档下降 >5%, 提前停止寻优"
            break
        fi
        prev_score=$sc
    done

    # 汇成数组并找出 best
    local arr; arr=$(printf '%s\n' "${results[@]}" | jq -s '.')
    local best; best=$(jq '[.[] | select(.ok)] | sort_by(-.score) | .[0]' <<<"$arr")

    # 标记完成
    if [[ -f "$progress_file" ]]; then
        jq --arg ts "$(date -Iseconds)" --argjson best "$best" \
            '.status = "finished" | .finished = $ts | .best = $best' \
            "$progress_file" > "${progress_file}.tmp" \
            && mv "${progress_file}.tmp" "$progress_file"
    fi

    echo ""
    log "${C_BOLD}========== 寻优结果 ==========${C_RESET}"
    jq -r '.[] | select(.ok) | "  \(.streams) 流: \(.bandwidth_mbps) Mbps | 重传率 \(.retrans_rate_pct)% | 评分 \(.score)"' \
        <<<"$arr" >&2
    local best_s best_bw best_rr
    best_s=$(jq -r '.streams' <<<"$best")
    best_bw=$(jq -r '.bandwidth_mbps' <<<"$best")
    best_rr=$(jq -r '.retrans_rate_pct' <<<"$best")
    ok "最优: ${C_BOLD}${best_s} 流${C_RESET}, ${best_bw} Mbps, 重传率 ${best_rr}%"

    jq -n --argjson all "$arr" --argjson best "$best" \
        '{all: $all, best: $best}'
}

# ---------------------------------------------------------------------------
# 远端 SSH 调优 (在远端 iperf3 服务器上也跑一次 tune)
# ---------------------------------------------------------------------------
# SSH 通用选项 (所有调用点共用, 避免重复)
_ssh_opts() {
    printf '%s\n' \
        -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=10 \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=3
}

# 密码模式额外选项: 强制密码认证, 跳过 pubkey 尝试 (否则 sshpass 可能匹配不到 prompt)
_ssh_password_opts() {
    printf '%s\n' \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        -o NumberOfPasswordPrompts=1
}

_ssh() {
    local cmd="$*"
    local -a opts; mapfile -t opts < <(_ssh_opts)

    if [[ -n "$SSH_KEY" ]]; then
        ssh "${opts[@]}" -i "$SSH_KEY" -p "$SSH_PORT" \
            "${SSH_USER}@${SSH_HOST}" "$cmd"
    elif [[ -n "$SSH_PASS" ]]; then
        local -a popts; mapfile -t popts < <(_ssh_password_opts)
        # 用 SSHPASS env, 不用 -p, 这样 sshpass 子进程的 ps 看不到密码
        SSHPASS="$SSH_PASS" sshpass -e ssh \
            "${opts[@]}" "${popts[@]}" -p "$SSH_PORT" \
            "${SSH_USER}@${SSH_HOST}" "$cmd"
    else
        ssh "${opts[@]}" -p "$SSH_PORT" \
            "${SSH_USER}@${SSH_HOST}" "$cmd"
    fi
}

_scp() {
    local src="$1" dst="$2"
    local -a opts; mapfile -t opts < <(_ssh_opts)

    if [[ -n "$SSH_KEY" ]]; then
        scp "${opts[@]}" -i "$SSH_KEY" -P "$SSH_PORT" \
            "$src" "${SSH_USER}@${SSH_HOST}:$dst"
    elif [[ -n "$SSH_PASS" ]]; then
        local -a popts; mapfile -t popts < <(_ssh_password_opts)
        SSHPASS="$SSH_PASS" sshpass -e scp \
            "${opts[@]}" "${popts[@]}" -P "$SSH_PORT" \
            "$src" "${SSH_USER}@${SSH_HOST}:$dst"
    else
        scp "${opts[@]}" -P "$SSH_PORT" \
            "$src" "${SSH_USER}@${SSH_HOST}:$dst"
    fi
}

remote_apply_tuning() {
    [[ -z "$SSH_HOST" ]] && { warn "未提供 --ssh-host, 跳过远端优化"; return; }
    log "${C_BOLD}========== 远端 ${SSH_HOST} 应用同等优化 ==========${C_RESET}"

    if [[ -z "$SSH_KEY" && -z "$SSH_PASS" ]]; then
        log "未提供 --ssh-key 或 --ssh-pass, 假设已配置免密"
    fi

    if ! _ssh "echo ok" >/dev/null 2>&1; then
        warn "SSH 测试失败, 跳过远端优化"
        return 1
    fi

    log "上传脚本到远端 /tmp/iperf3-tune.sh"
    _scp "$SCRIPT_PATH" /tmp/iperf3-tune.sh
    _ssh "chmod +x /tmp/iperf3-tune.sh && sudo /tmp/iperf3-tune.sh tune --profile $PROFILE --yes" || {
        warn "远端 tune 执行失败"
        return 1
    }
    ok "远端优化完成"
}

# ---------------------------------------------------------------------------
# 状态保存 / 回退
# ---------------------------------------------------------------------------
save_state() {
    ensure_dirs
    local content="$1"
    echo "$content" > "$STATE_FILE"
    chmod 600 "$STATE_FILE"
}

cmd_rollback() {
    require_root
    log "${C_BOLD}========== 回退 ==========${C_RESET}"

    # 1) 删除 sysctl 配置文件并恢复 backup 中的值
    if [[ -f "$SYSCTL_FILE" ]]; then
        rm -f "$SYSCTL_FILE"
        ok "已删除 $SYSCTL_FILE"
    fi
    if [[ -f "$SYSCTL_BACKUP" ]]; then
        local line k v
        while IFS= read -r line; do
            k=$(awk -F' *= *' '{print $1}' <<<"$line")
            v=$(awk -F' *= *' '{print $2}' <<<"$line")
            [[ -z "$k" || "$k" =~ ^# ]] && continue
            if [[ "$v" == "__UNSET__" ]]; then
                continue   # 没法 unset, 但也不该是关键项
            fi
            sysctl -w "$k=$v" >/dev/null 2>&1 || warn "无法恢复 $k"
        done < "$SYSCTL_BACKUP"
        ok "已从 backup 恢复 sysctl"
    fi
    sysctl --system >/dev/null 2>&1 || true

    # 2) 远端同步回退 (如果有 SSH 信息)
    if [[ -n "$SSH_HOST" ]]; then
        log "远端同步回退..."
        _ssh "sudo /tmp/iperf3-tune.sh rollback" 2>&1 | sed 's/^/  [remote] /' >&2 || true
    fi

    ok "回退完成"
}

cmd_status() {
    log "${C_BOLD}========== iperf3-tune 状态 ==========${C_RESET}"
    if [[ -f "$SYSCTL_FILE" ]]; then
        ok "sysctl 配置已应用: $SYSCTL_FILE"
        log "  当前活跃 profile: $(awk -F'profile=' '/profile=/ {print $2; exit}' "$SYSCTL_FILE" | awk -F',' '{print $1}')"
    else
        warn "sysctl 配置未应用 (运行 '$SCRIPT_NAME tune' 启用)"
    fi
    if [[ -f "$STATE_FILE" ]]; then
        log "最近测试结果:"
        jq -r '
            if .best then "  最优并发: \(.best.streams) 流, \(.best.bandwidth_mbps) Mbps, 重传率 \(.best.retrans_rate_pct)%"
            else "  无测试记录" end
        ' "$STATE_FILE" 2>/dev/null || echo "  (state.json 损坏)" >&2
    fi
    local iface
    iface=$(detect_primary_iface 2>/dev/null || echo "?")
    if [[ "$iface" != "?" ]]; then
        log "网卡 $iface 当前拥塞算法: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
        log "网卡 $iface 当前 qdisc:    $(tc qdisc show dev "$iface" 2>/dev/null | head -1 | awk '{print $2}')"
    fi
    # 显示后台任务状态
    if [[ -f "$PID_FILE" ]]; then
        local pid; pid=$(cat "$PID_FILE" 2>/dev/null)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            log "${C_GREEN}● 有后台任务运行中 (PID $pid)${C_RESET}"
            log "  查看进度: $SCRIPT_NAME watch"
            log "  跟随日志: $SCRIPT_NAME tail"
            log "  停止任务: $SCRIPT_NAME stop"
        fi
    fi
}

# ---------------------------------------------------------------------------
# 后台运行 / 进度监控 (针对 SSH 断了进度全丢的问题)
# ---------------------------------------------------------------------------
# 把自己 fork 到后台, 立即返回 PID. 即使 SSH 断了进程也继续跑.
# 关键: setsid 脱离 controlling terminal, 重定向 std{in,out,err}
detach_self() {
    ensure_dirs

    # 已有任务在跑?
    if [[ -f "$PID_FILE" ]]; then
        local old; old=$(cat "$PID_FILE" 2>/dev/null)
        if [[ -n "$old" ]] && kill -0 "$old" 2>/dev/null; then
            die "已有 iperf3-tune 在后台跑 (PID $old). 用 'stop' 终止, 或 'watch' 查看"
        fi
        rm -f "$PID_FILE"
    fi

    local ts; ts=$(date +%Y%m%d-%H%M%S)
    local logfile="${LOG_DIR}/run-${ts}.log"

    log "${C_BOLD}========== 切换到后台运行 ==========${C_RESET}"
    log "  日志文件: ${C_CYAN}$logfile${C_RESET}"
    log "  PID 文件: $PID_FILE"
    log ""
    log "查看实时进度 (新开一个 SSH 终端):"
    log "  ${C_BOLD}$SCRIPT_NAME watch${C_RESET}        # 滚动看每档结果"
    log "  ${C_BOLD}$SCRIPT_NAME tail${C_RESET}         # tail -f 日志"
    log "  ${C_BOLD}$SCRIPT_NAME stop${C_RESET}         # 终止任务"
    log ""

    # 从原参数里剔除 --detach / -d, 避免子进程再 fork
    local -a child_args=()
    local skip_next=0
    local a
    for a in "${DETACH_ORIG_ARGS[@]}"; do
        if [[ $skip_next -eq 1 ]]; then skip_next=0; continue; fi
        case "$a" in
            --detach|-d) ;;
            *) child_args+=("$a") ;;
        esac
    done

    # 给 child 一个 env 标记, 避免万一逻辑 bug 导致循环 fork
    # setsid 是关键: 创建新 session, 脱离 SSH 的 controlling terminal,
    # SIGHUP (SSH 断时发的) 不会被传到子进程
    IPERF3_TUNE_DAEMONIZED=1 \
        setsid bash "$SCRIPT_PATH" "${child_args[@]}" \
        </dev/null >"$logfile" 2>&1 &
    local new_pid=$!
    disown 2>/dev/null || true

    echo "$new_pid" > "$PID_FILE"
    ok "已启动后台任务 PID=$new_pid"
    log "现在可以安全关掉这个 SSH 窗口了 ✓"
    exit 0
}

cmd_watch() {
    local last_count=-1
    local pid=""

    [[ -f "$PID_FILE" ]] && pid=$(cat "$PID_FILE" 2>/dev/null)

    if [[ ! -f "$PROGRESS_FILE" ]]; then
        warn "找不到 $PROGRESS_FILE, 还没开始测试"
        return 1
    fi

    log "${C_BOLD}监控中... Ctrl-C 退出 (任务在后台继续跑)${C_RESET}"
    echo "" >&2

    while true; do
        local count status server port
        count=$(jq -r '.results | length' "$PROGRESS_FILE" 2>/dev/null || echo 0)
        status=$(jq -r '.status' "$PROGRESS_FILE" 2>/dev/null || echo unknown)

        # 只在有新结果时打印
        if [[ "$count" != "$last_count" ]]; then
            clear 2>/dev/null || printf '\033[2J\033[H'
            server=$(jq -r '.server' "$PROGRESS_FILE")
            port=$(jq -r '.port' "$PROGRESS_FILE")
            printf '%s========== iperf3-tune 实时进度 ==========%s\n' "${C_BOLD}" "${C_RESET}" >&2
            printf '服务端:  %s:%s\n' "$server" "$port" >&2
            printf '开始:    %s\n' "$(jq -r '.started' "$PROGRESS_FILE")" >&2
            printf '更新:    %s\n' "$(jq -r '.last_update // .started' "$PROGRESS_FILE")" >&2

            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                printf '%s● 运行中%s (PID %s)\n' "${C_GREEN}" "${C_RESET}" "$pid" >&2
            elif [[ "$status" == "finished" ]]; then
                printf '%s✓ 已完成%s\n' "${C_GREEN}" "${C_RESET}" >&2
            else
                printf '%s○ 进程不存在 (可能被 kill)%s\n' "${C_YELLOW}" "${C_RESET}" >&2
            fi
            echo "" >&2

            printf '%s已测出 %s 档:%s\n' "${C_BOLD}" "$count" "${C_RESET}" >&2
            jq -r '.results[] | "  \(.streams) 流: \(.bandwidth_mbps) Mbps   重传率 \(.retrans_rate_pct)%   评分 \(.score)"' \
                "$PROGRESS_FILE" >&2 2>/dev/null

            if [[ "$status" == "finished" ]]; then
                echo "" >&2
                local best_s best_bw best_rr
                best_s=$(jq -r '.best.streams // "?"' "$PROGRESS_FILE")
                best_bw=$(jq -r '.best.bandwidth_mbps // "?"' "$PROGRESS_FILE")
                best_rr=$(jq -r '.best.retrans_rate_pct // "?"' "$PROGRESS_FILE")
                printf '%s最优: %s 流, %s Mbps, 重传率 %s%%%s\n' \
                    "${C_GREEN}${C_BOLD}" "$best_s" "$best_bw" "$best_rr" "${C_RESET}" >&2
                break
            fi
            last_count=$count
        fi

        # 任务死了, 但状态没标 finished → 异常退出
        if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null && [[ "$status" != "finished" ]]; then
            echo "" >&2
            warn "后台进程已退出但未标记完成, 可能崩溃或被 kill"
            break
        fi

        sleep 3
    done
}

cmd_tail() {
    # 找最新的 run-*.log
    local latest
    latest=$(ls -1t "${LOG_DIR}"/run-*.log 2>/dev/null | head -1)
    if [[ -z "$latest" ]]; then
        die "找不到日志文件 ($LOG_DIR/run-*.log)"
    fi
    log "跟随日志: $latest"
    log "(Ctrl-C 退出, 后台任务继续运行)"
    echo "" >&2
    tail -F "$latest"
}

cmd_stop() {
    [[ -f "$PID_FILE" ]] || die "没有运行中的后台任务"
    local pid; pid=$(cat "$PID_FILE")
    if ! kill -0 "$pid" 2>/dev/null; then
        warn "PID $pid 已不存在, 清理 PID 文件"
        rm -f "$PID_FILE"
        return
    fi

    log "正在终止 PID $pid 及其所有子进程..."
    # 先 TERM 整个进程组 (setsid 起来的, pgid == pid)
    kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        warn "TERM 后仍未退出, 用 KILL"
        kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
        sleep 1
    fi
    # 顺便 kill 残留的 iperf3 进程
    pkill -KILL -f 'iperf3 -c' 2>/dev/null || true

    rm -f "$PID_FILE"
    ok "已停止"
}

# ---------------------------------------------------------------------------
# 子命令实现
# ---------------------------------------------------------------------------
cmd_detect() {
    local report; report=$(detect_all)
    if [[ $JSON_OUT -eq 1 ]]; then
        echo "$report"
    else
        print_report "$report"
    fi
}

cmd_tune() {
    require_root
    ensure_dirs
    log "${C_BOLD}========== 应用本机优化 ==========${C_RESET}"
    write_and_apply_sysctl "$PROFILE"
    apply_nic_tuning
    ok "本机优化完成"
}

cmd_bench() {
    [[ -z "$SERVER" ]] && die "bench 需要 --server"
    log "${C_BOLD}========== 基准测试 ==========${C_RESET}"

    # 单流基准
    log "1) 单流基准 (${DURATION}s × $REPEATS)"
    local single; single=$(bench_streams "$SERVER" "$PORT" 1 "$DURATION" "$REPEATS")
    local s_bw s_rr
    s_bw=$(jq -r '.bandwidth_mbps' <<<"$single")
    s_rr=$(jq -r '.retrans_rate_pct' <<<"$single")
    ok "单流: ${s_bw} Mbps, 重传率 ${s_rr}%"
    echo "" >&2

    # 多流寻优
    log "2) 多流寻优"
    local optimal; optimal=$(find_optimal_parallel "$SERVER" "$PORT" "$DURATION" "$REPEATS" "$MAX_PARALLEL")
    local best_s best_bw best_rr improvement
    best_s=$(jq -r '.best.streams' <<<"$optimal")
    best_bw=$(jq -r '.best.bandwidth_mbps' <<<"$optimal")
    best_rr=$(jq -r '.best.retrans_rate_pct' <<<"$optimal")
    improvement=$(awk -v a="$best_bw" -v b="$s_bw" 'BEGIN {
        if (b+0 == 0) print "N/A"; else printf "%.1f%%", (a-b)/b*100
    }')

    echo "" >&2
    log "${C_BOLD}========== 最终对比 ==========${C_RESET}"
    printf '  单流:   %s%.2f Mbps%s  重传率 %.3f%%\n' "${C_CYAN}" "$s_bw" "${C_RESET}" "$s_rr" >&2
    printf '  多流:   %s%.2f Mbps%s  重传率 %.3f%%  (%s 流)\n' "${C_GREEN}" "$best_bw" "${C_RESET}" "$best_rr" "$best_s" >&2
    printf '  提升:   %s%s%s\n' "${C_BOLD}" "$improvement" "${C_RESET}" >&2

    # 保存
    ensure_dirs
    local out; out=$(jq -n \
        --arg ts "$(date -Iseconds)" \
        --argjson single "$single" --argjson optimal "$optimal" \
        --arg improve "$improvement" \
        '{timestamp:$ts, single:$single, best:$optimal.best, all:$optimal.all, improvement:$improve}')
    save_state "$out"
    [[ $JSON_OUT -eq 1 ]] && echo "$out"
    ok "结果已保存到 $STATE_FILE"
}

cmd_optimize() {
    [[ -z "$SERVER" ]] && die "optimize 需要 --server"
    require_root

    # 步骤 1: 检测
    log "${C_BOLD}━━━ 步骤 1/4: 检测瓶颈 ━━━${C_RESET}"
    local report; report=$(detect_all)
    print_report "$report"

    # 根据内存情况自动降级 profile
    local mem_total
    mem_total=$(jq -r '.memory.total_gb' <<<"$report")
    if num_lt "$mem_total" 2 && [[ "$PROFILE" != "balanced" ]]; then
        warn "内存 ${mem_total}GB < 2GB, 降级 profile 为 balanced"
        PROFILE="balanced"
    fi

    # 步骤 2: 本机优化
    echo "" >&2
    log "${C_BOLD}━━━ 步骤 2/4: 应用本机优化 (profile=$PROFILE) ━━━${C_RESET}"
    write_and_apply_sysctl "$PROFILE"
    apply_nic_tuning

    # 步骤 3: 远端同步
    if [[ -n "$SSH_HOST" ]]; then
        echo "" >&2
        log "${C_BOLD}━━━ 步骤 3/4: 远端同步 ━━━${C_RESET}"
        remote_apply_tuning || warn "远端优化失败, 继续本地测试"
    else
        log "(跳过步骤 3: 未提供 --ssh-host)"
    fi

    # 步骤 4: 测试
    echo "" >&2
    log "${C_BOLD}━━━ 步骤 4/4: 测试验证 ━━━${C_RESET}"
    cmd_bench
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
${C_BOLD}iperf3-tune${C_RESET} v${VERSION} — iperf3 高速低重传优化工具

${C_BOLD}用法${C_RESET}
  $SCRIPT_NAME <command> [options]

${C_BOLD}命令${C_RESET}
  detect                    检测系统瓶颈
  tune                      仅应用本机 sysctl + 网卡优化
  bench                     运行 iperf3 测试 (单流 + 多流寻优)
  optimize                  完整流程: detect → tune → (远端) → bench
  rollback                  回退到优化前
  status                    显示当前状态
  watch                     实时看后台任务进度 (滚动显示每档结果)
  tail                      tail -f 当前后台任务的日志
  stop                      停止后台任务

${C_BOLD}选项${C_RESET}
  --server IP               iperf3 服务端 IP (bench/optimize 必需)
  --port N                  端口 (默认 5201)
  --time SECS               单次测试时长秒 (默认 30)
  --repeats N               每个并发数测试次数 (默认 3, 取中位数)
  --max-parallel N          最大并发流 (默认 32)
  --profile NAME            sysctl profile: balanced | aggressive | extreme
                            (默认 aggressive)
  --congestion ALGO         拥塞算法 (默认 bbr)
  --direction reverse|forward  下行/上行 (默认 reverse)
  --retrans-threshold PCT   重传率阈值, 超过则提前停止寻优 (默认 1.0)
  --retrans-penalty K       评分函数中重传惩罚系数 (默认 10.0)
  -d, --detach              后台运行 (推荐用于 bench/optimize)
                            SSH 断了也继续跑, 用 watch/tail 看进度

${C_BOLD}远端 SSH 选项${C_RESET}
  --ssh-host HOST           远端 iperf3 服务器
  --ssh-user USER           SSH 用户 (默认 root)
  --ssh-port N              SSH 端口 (默认 22)
  --ssh-key PATH            SSH 私钥路径
  --ssh-pass PASS           SSH 密码 (走 SSHPASS env, ps 看不到, 但会进
                            shell history; 用单引号包起来防止 \$ 等转义)
  --ssh-pass-file PATH      SSH 密码文件 (推荐, 文件权限必须 600)

${C_BOLD}通用${C_RESET}
  -y, --yes                 非交互模式 (跳过确认)
  -v, --verbose             详细日志
  --json                    JSON 格式输出
  -h, --help                显示此帮助

${C_BOLD}示例${C_RESET}
  # 仅检测
  sudo $SCRIPT_NAME detect

  # 仅本机调优 (激进档)
  sudo $SCRIPT_NAME tune --profile aggressive

  # ★ 推荐: 后台运行, 测试期间 SSH 断了也不影响 ★
  sudo $SCRIPT_NAME optimize --detach \\
      --server 1.2.3.4 \\
      --ssh-host 1.2.3.4 --ssh-user root --ssh-pass 'YOUR_PASSWORD' \\
      --profile aggressive --time 30 --repeats 3

  # 在另一个 SSH 窗口看进度
  sudo $SCRIPT_NAME watch       # 滚动看每档结果 (每 3 秒刷新)
  sudo $SCRIPT_NAME tail        # tail -f 完整日志
  sudo $SCRIPT_NAME stop        # 中途想停掉

  # 前台运行 (短测试, SSH 不会断)
  sudo $SCRIPT_NAME optimize --server 1.2.3.4 \\
      --ssh-host 1.2.3.4 --ssh-user root --ssh-pass 'YOUR_PASSWORD' \\
      --profile aggressive --time 30 --repeats 3

  # 更安全: 密码放文件
  echo -n 'YOUR_PASSWORD' > /root/.iperf3-ssh.pass
  chmod 600 /root/.iperf3-ssh.pass
  sudo $SCRIPT_NAME optimize --server 1.2.3.4 \\
      --ssh-host 1.2.3.4 --ssh-user root --ssh-pass-file /root/.iperf3-ssh.pass \\
      --profile aggressive

  # 极限档 (业务影响显著, 但带宽更高)
  sudo $SCRIPT_NAME optimize --server 1.2.3.4 \\
      --ssh-host 1.2.3.4 --ssh-pass 'PASSWORD' \\
      --profile extreme --time 60 --repeats 5

  # 仅测试 (不改 sysctl)
  $SCRIPT_NAME bench --server 1.2.3.4 --time 30 --repeats 3

  # 回退 (本机 + 远端同步)
  sudo $SCRIPT_NAME rollback --ssh-host 1.2.3.4 --ssh-pass 'PASSWORD'

${C_BOLD}评分函数${C_RESET}
  寻优时, 每个并发数的"评分"按下式计算:
    score = bandwidth_mbps × max(0, 1 - k × retrans_rate_pct / 100)
  默认 k=10, 即 1% 重传率会扣掉 10% 评分。最优配置取评分最高者。
  调 --retrans-penalty K 可让算法更看重低重传 (K↑) 或纯带宽 (K=0)。
EOF
}

parse_args() {
    [[ $# -eq 0 ]] && { usage; exit 0; }

    # 保留原始 argv 用于 detach 时 fork 子进程
    DETACH_ORIG_ARGS=("$@")

    CMD="$1"; shift

    case "$CMD" in
        -h|--help|help)   usage; exit 0 ;;
        -V|--version)     echo "$SCRIPT_NAME $VERSION"; exit 0 ;;
        detect|tune|bench|optimize|rollback|status|watch|tail|stop) ;;
        *) err "未知命令: $CMD"; usage; exit 2 ;;
    esac

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --server)               SERVER="$2"; shift 2 ;;
            --port)                 PORT="$2"; shift 2 ;;
            --time)                 DURATION="$2"; shift 2 ;;
            --repeats)              REPEATS="$2"; shift 2 ;;
            --max-parallel)         MAX_PARALLEL="$2"; shift 2 ;;
            --profile)              PROFILE="$2"; shift 2 ;;
            --congestion)           CONGESTION="$2"; shift 2 ;;
            --direction)            DIRECTION="$2"; shift 2 ;;
            --retrans-threshold)    RETRANS_THRESHOLD="$2"; shift 2 ;;
            --retrans-penalty)      RETRANS_PENALTY="$2"; shift 2 ;;
            --ssh-host)             SSH_HOST="$2"; shift 2 ;;
            --ssh-user)             SSH_USER="$2"; shift 2 ;;
            --ssh-port)             SSH_PORT="$2"; shift 2 ;;
            --ssh-key)              SSH_KEY="$2"; shift 2 ;;
            --ssh-pass)             SSH_PASS="$2"; shift 2 ;;
            --ssh-pass-file)
                [[ -r "$2" ]] || die "--ssh-pass-file: 无法读取 $2"
                # 文件权限 > 077 (即 group/other 可读) 直接拒绝, 这密码也太裸了
                local perm
                perm=$(stat -c '%a' "$2" 2>/dev/null || stat -f '%Lp' "$2" 2>/dev/null)
                if [[ -n "$perm" ]] && (( 10#$perm & 077 )); then
                    die "--ssh-pass-file: $2 权限 $perm 太宽松, 改成 600 (chmod 600 $2)"
                fi
                # 只取第一行, 去掉尾换行
                SSH_PASS=$(head -n1 "$2" | tr -d '\r\n')
                [[ -n "$SSH_PASS" ]] || die "--ssh-pass-file: $2 内容为空"
                shift 2 ;;
            -d|--detach)            DETACH=1; shift ;;
            -y|--yes)               ASSUME_YES=1; shift ;;
            -v|--verbose)           VERBOSE=1; shift ;;
            --json)                 JSON_OUT=1; shift ;;
            -h|--help)              usage; exit 0 ;;
            --)                     shift; break ;;
            *)                      err "未知选项: $1"; usage; exit 2 ;;
        esac
    done

    # tty 检测
    [[ -t 0 ]] || INTERACTIVE=0
    [[ $ASSUME_YES -eq 1 ]] && INTERACTIVE=0

    # 简单校验
    [[ "$PROFILE" =~ ^(balanced|aggressive|extreme)$ ]] \
        || die "--profile 只能是 balanced/aggressive/extreme"
    [[ "$DIRECTION" =~ ^(reverse|forward)$ ]] \
        || die "--direction 只能是 reverse/forward"
    [[ "$PORT" =~ ^[0-9]+$ ]] && [[ $PORT -ge 1 && $PORT -le 65535 ]] \
        || die "--port 不合法"
    [[ "$DURATION" =~ ^[0-9]+$ ]] && [[ $DURATION -ge 5 ]] \
        || die "--time 至少 5 秒"
    [[ "$REPEATS" =~ ^[0-9]+$ ]] && [[ $REPEATS -ge 1 ]] \
        || die "--repeats 至少 1"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    # watch/tail/stop 不需要依赖检查 (只读 progress.json / 日志 / kill)
    case "$CMD" in
        watch)  cmd_watch; return ;;
        tail)   cmd_tail; return ;;
        stop)   require_root; cmd_stop; return ;;
    esac

    check_dependencies

    # 后台运行: 仅对耗时长的命令 (bench/optimize) 有意义
    if [[ $DETACH -eq 1 ]] && [[ "${IPERF3_TUNE_DAEMONIZED:-0}" != "1" ]]; then
        case "$CMD" in
            bench|optimize) detach_self ;;
            *) warn "--detach 只对 bench/optimize 有效, 忽略" ;;
        esac
    fi

    # 在 daemon 模式下记录 PID (便于 stop)
    if [[ "${IPERF3_TUNE_DAEMONIZED:-0}" == "1" ]]; then
        ensure_dirs
        echo "$$" > "$PID_FILE"
        # 退出时清理 PID 文件
        trap 'rm -f "$PID_FILE"' EXIT
    fi

    case "$CMD" in
        detect)    cmd_detect ;;
        tune)      cmd_tune ;;
        bench)     cmd_bench ;;
        optimize)  cmd_optimize ;;
        rollback)  cmd_rollback ;;
        status)    cmd_status ;;
        *)         usage; exit 2 ;;
    esac
}

# 仅在直接执行时跑 main, 被 source 时只加载函数 (供 daemon 复用)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
