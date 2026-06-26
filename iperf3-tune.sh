#!/usr/bin/env bash
#
# iperf3-tune.sh — iperf3 高速低重传优化工具 (v2.7.2)
#
# 目标: 最大化 iperf3 测得带宽 (尤其单流 -R 下行), 最小化重传率。
# 调优偏激进, 但 v2.7.0 起默认对生产环境更克制、更可控、可预演、可回退。
#
# 用法:
#   iperf3-tune.sh detect                                    # 仅检测瓶颈 (只读, 不改系统)
#   iperf3-tune.sh tune [--profile aggressive|extreme]       # 仅应用本机优化
#   iperf3-tune.sh bench --server IP [--port N] [--time S]   # 仅跑测试 (不改系统)
#   iperf3-tune.sh optimize --server IP [...]                # 完整流程
#   iperf3-tune.sh rollback                                  # 回退
#   iperf3-tune.sh status                                    # 状态
#
# v2.7.2 改动 (vs 2.7.1): SSH 不可达时不再反复超时
#   1. ★ SSH 可达性缓存此前在 $() 子shell里赋值会丢失, 导致 SSH 不可达时每个远端
#        枚举/拥塞/CPU helper 都重新探测一次 (每次最多等 ConnectTimeout 秒, --scan 下
#        可能累计数分钟卡顿)。新增 prime_ssh_reachable(): 在父 shell 先探一次并缓存,
#        子shell直接继承结果, 远端不可达时整轮只等一次。
#
# v2.7.1 改动 (vs 2.7.0): bug 修复
#   1. ★ 修复 iperf3-tuned init 报 "未知命令: init": 守护脚本此前用主脚本不识别的
#        命令名 init 调 parse_args, 导致定时任务初始化失败。改为用合法占位命令解析
#        选项后再修正 CMD, init 现可正常写入 /etc/iperf3-tune/config.json
#
# v2.7.0 改动 (vs 2.6.0): ★ 生产安全加固 ★
#   1. ★★★ 自动装依赖默认关闭: 不再默认 apt/yum/dnf/pacman 装包。缺依赖时只给出
#          手动安装命令并退出; 需要时显式 --auto-install 才会安装 (生产更可控)
#   2. ★★★ 新增 --dry-run: 预演模式, 打印将要修改的 sysctl/网卡/远端动作但不实际执行
#   3. ★★★ 优雅降级: 启动期 preflight 统一检查 (OS / root / sysfs / procfs),
#          一次性给出清晰可操作的错误, 而非中途崩溃打印调用栈
#   4. ★★★ SSH 不可达时优雅降级: 远端枚举/调优全部经统一可达性探测短路, 失败只 warn
#          并跳过远端步骤继续本地, 不再因一条 ssh 命令非零而提前退出
#   5. ★★ 主网卡探测失败不再 die: 返回空让调用方决定; 仅真正需要网卡的调优步骤跳过并提示
#   6. ★★ 改系统前显式列清单 + 二次确认: 明确告知会停 irqbalance / 改 MTU / 换拥塞算法 /
#          写 /etc/sysctl.d 等影响项; 非交互且无 --yes 时直接拒绝而非默默执行
#   7. ★★ 命令行密码加固: --ssh-pass 会告警(进 history/ps/审计); 新增 --ssh-ask-pass 交互读取;
#          --detach 时把命令行密码转存为 600 临时文件再后台跑, 避免 ps 暴露明文
#
# v2.6.0 改动 (vs 2.5.0): 双端 CPU 寻优 + 零拷贝发送端严格感知
#   1. ★★★ --scan-cpu 现在两端都扫: 用 iperf3 -A n/m 同时绑本端核(n)与远端 server 核(m),
#          发送端优先 (reverse 下先扫 server 发送核, 再扫本机接收核)
#   2. ★★★ --cpu-remote N 手动指定远端 server 绑核; 远端候选核经 SSH 读 server NUMA 枚举
#   3. ★★ reverse + SSH 时自动为发送端(server)选一个核并下发 (即使不扫描)
#   4. ★★ 零拷贝发送端严格感知: 明确 -Z 在 -R 下作用于 server (协商下发, server 用 sendfile),
#          并经 SSH 核实 server 端 iperf3 版本; 报告实际作用端
#
# v2.6.0 改动 (vs 2.5.0): 双端 CPU 寻优 + 零拷贝发送端严格感知
#   1. ★★★ --scan-cpu 现在两端都扫: 用 iperf3 -A n/m 同时绑本端核(n)与远端 server 核(m),
#          发送端优先 (reverse 下先扫 server 发送核, 再扫本机接收核)
#   2. ★★★ --cpu-remote N 手动指定远端 server 绑核; 远端候选核经 SSH 读 server NUMA 枚举
#   3. ★★ reverse + SSH 时自动为发送端(server)选一个核并下发 (即使不扫描)
#   4. ★★ 零拷贝发送端严格感知: 明确 -Z 在 -R 下作用于 server (协商下发, server 用 sendfile),
#          并经 SSH 核实 server 端 iperf3 版本; 报告实际作用端
#
# v2.5.0 改动 (vs 2.4.0): 单流自动寻优 + 方向感知
#   1. ★★★ --scan / --scan-window / --scan-congestion / --scan-cpu:
#          贪心顺序 拥塞算法→窗口→CPU 自动扫描选最优组合 (按带宽×重传评分)
#   2. ★★★ 方向感知: -R 下发送端=server, 拥塞算法扫描自动作用在 server (经 SSH)
#   3. ★★ 窗口扫描以 BDP 为锚生成多个倍数候选, 可用 --window-list 自定义
#   4. ★★ optimize 在 reverse 下明确把 server 端调优标为重点
#   5. ★ 扫描阶段用更短时长(--scan-time/--scan-repeats)加速, 最优组合再正式确认
#
# v2.4.0 改动 (vs 2.3.0): 单流专项优化
#   1. ★★★ 新增 --single: 仅测单流 (max-parallel=1)
#   2. ★★★ 单流自动绑核: 取网卡所在 NUMA node 的核, taskset + iperf3 -A; 多流不绑
#   3. ★★★ 按 RTT/BDP 自动算 TCP 窗口 (2.5×BDP), iperf3 -w; 可用 --window/--bandwidth 覆盖
#   4. ★★ iperf3 -Z 零拷贝默认开 (省发送侧 CPU), --no-zerocopy 关闭
#   5. ★★ tune 时停 irqbalance, 保持 IRQ 亲和稳定; rollback 时恢复
#   6. ★ --mtu N 设置 jumbo frame (本机 + 远端同步), rollback 还原
#
# v2.3.0 改动 (vs 2.2.0):
#   1. ★★★ 新增 install_dependencies(): 多发行版自动安装缺失依赖
#      支持 Debian/Ubuntu/Mint/Kali (apt), RHEL/CentOS/Rocky/Alma/Fedora/Amazon (dnf|yum),
#      Arch/Manjaro (pacman), Alpine (apk), openSUSE/SLES (zypper)
#   2. ★★★ check_dependencies 在 root 下自动调用 install, 远端 tune 不再因 ethtool 缺失而失败
#   3. ★ 新增 --no-auto-install 显式禁用自动安装
#   4. ★ 远端 SSH tune 上传脚本前先 ensure_remote_deps, 提前在远端装好依赖
#   5. ★ profile 默认对单流 -R 友好: aggressive 提高 tcp_notsent_lowat 默认值,
#      让发送侧 (server) 在单流下少阻塞
#   6. ★ aggressive 增加 tcp_window_clamp 上调, 避免单流被 16MB 默认窗口卡住
#

set -Eeuo pipefail
shopt -s nullglob

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------
readonly VERSION="2.7.2"
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
PROFILE="aggressive"        # balanced | aggressive | extreme
DIRECTION="reverse"         # reverse(下行) | forward(上行)
CONGESTION="bbr"
MSS=1448

# ---- v2.4.0: 单流优化相关 ----
WINDOW=""                  # 手动 TCP 窗口 (如 96M); 空=按 BDP 自动计算
BANDWIDTH=0                # 链路容量提示 Mbit/s, 用于自动算窗口; 0=用 NIC 标称速率
MTU=""                     # 设置网卡 MTU (如 9000 开 jumbo frame); 空=不改
PIN_CPU=""                 # 单流绑定的 本机 CPU 核; 空=自动取 NIC 所在 NUMA node
REMOTE_PIN_CPU=""          # 单流绑定的 远端(server) CPU 核; 经 iperf3 -A n/m 下发; 空=按需自动/不绑
ZEROCOPY=1                 # iperf3 -Z 零拷贝 (默认开, 单流省 CPU)
SINGLE_ONLY=0              # 仅测单流 (等价 --max-parallel 1)
IPERF3_WINDOW=""           # 运行期解析出的窗口 (内部用)

# ---- v2.5.0: 单流自动寻优 (扫描) ----
SCAN_WINDOW=0              # 扫描多个 TCP 窗口取最优
SCAN_CONGESTION=0          # 扫描多个拥塞算法取最优 (作用在发送端)
SCAN_CPU=0                 # 扫描多个 CPU 核取最优 (两端都扫, 发送端优先)
SCAN_ALL=0                 # 等价同时开三个扫描
WINDOW_LIST=""             # 自定义窗口列表 (逗号分隔, 如 32M,64M,128M); 空=按 BDP 生成
CONGESTION_LIST=""         # 自定义拥塞算法列表 (逗号分隔); 空=自动探测可用的 bbr/cubic/bbr2
SCAN_TIME=10               # 扫描阶段每次测试时长 (比正式短, 加快寻优)
SCAN_REPEATS=1             # 扫描阶段每点重复次数

RETRANS_THRESHOLD=3.0
RETRANS_PENALTY=10.0

SSH_HOST=""
SSH_USER="root"
SSH_KEY=""
SSH_PASS=""
SSH_PASS_FILE=""
SSH_PORT=22

INTERACTIVE=1
ASSUME_YES=0
VERBOSE=0
JSON_OUT=0
DETACH=0
# v2.7.0: 自动安装默认关闭 (生产安全). 需要时显式 --auto-install 才会动包管理器
AUTO_INSTALL=0
DRY_RUN=0                   # v2.7.0: 预演模式, 只打印不实际改系统
STOP_IRQBALANCE=1          # 调优时是否停 irqbalance (rollback 会恢复); --no-stop-irqbalance 关
SSH_ASK_PASS=0             # v2.7.0: 交互式读取 SSH 密码 (不进 history/argv)
SSH_REACHABLE=-1           # SSH 可达性缓存: -1 未检测 / 0 不可达 / 1 可达 (内部用)
_SSH_PASS_TMP=""           # 内部: --ssh-ask-pass 生成的临时密码文件, 退出时清理
PRIMARY_IFACE=""

# ---------------------------------------------------------------------------
# 日志
# ---------------------------------------------------------------------------
_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log()  { printf '%s[%s]%s %s\n' "${C_CYAN}"   "$(_ts)" "${C_RESET}" "$*" >&2; }
ok()   { printf '%s[%s] ✓%s %s\n' "${C_GREEN}"  "$(_ts)" "${C_RESET}" "$*" >&2; }
warn() { printf '%s[%s] ⚠%s %s\n' "${C_YELLOW}" "$(_ts)" "${C_RESET}" "$*" >&2; }
err()  { printf '%s[%s] ✗%s %s\n' "${C_RED}"    "$(_ts)" "${C_RESET}" "$*" >&2; }
die()  { err "$*"; exit 1; }
vlog() { [[ $VERBOSE -eq 1 ]] && log "$@" || true; }

on_err() {
    local rc=$?
    local frames=$(( ${#BASH_LINENO[@]} - 1 ))
    if (( frames > 0 )); then
        err "脚本失败 (exit=${rc}), 调用栈:"
        local i
        for (( i=0; i<frames; i++ )); do
            local src="${BASH_SOURCE[i+1]:-?}"
            local fn="${FUNCNAME[i+1]:-main}"
            local ln="${BASH_LINENO[i]:-?}"
            printf '  at %s (%s:%s)\n' "$fn" "$src" "$ln" >&2
        done
    else
        err "脚本失败 (exit=${rc}) 于第 ${BASH_LINENO[0]:-?} 行"
    fi
    exit "$rc"
}
trap on_err ERR

# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------
require_root() {
    [[ $EUID -eq 0 ]] || die "需要 root: sudo $SCRIPT_NAME $*"
}

# v2.7.0: 退出时清理临时密码文件 (--ssh-ask-pass 及 --detach 转存的密码文件)
_cleanup_tmp() {
    [[ -n "${_SSH_PASS_TMP:-}" && -f "${_SSH_PASS_TMP}" ]] && rm -f "${_SSH_PASS_TMP}" 2>/dev/null || true
    [[ -n "${IPERF3_TUNE_DETACH_PWFILE:-}" && -f "${IPERF3_TUNE_DETACH_PWFILE}" ]] && rm -f "${IPERF3_TUNE_DETACH_PWFILE}" 2>/dev/null || true
    return 0
}
trap _cleanup_tmp EXIT

# v2.7.0: 哪些命令会修改系统 (需要 root + 改前确认)
cmd_mutates_system() {
    case "$1" in
        tune|optimize|rollback) return 0 ;;
        *) return 1 ;;
    esac
}

# v2.7.0: 启动期统一环境检查. 一次性给出清晰、可操作的报错, 不再中途崩溃打印调用栈。
preflight_check() {
    local cmd="$1"

    # 1) 仅支持 Linux (依赖 sysctl / ethtool / procfs / sysfs)
    local os; os="$(uname -s 2>/dev/null || echo unknown)"
    if [[ "$os" != "Linux" ]]; then
        die "本工具依赖 Linux 的 sysctl / procfs / sysfs / ethtool, 不支持当前系统: ${os}"
    fi

    # 2) bash >= 4 (用到关联数组 / mapfile / ${x@Q})
    if (( BASH_VERSINFO[0] < 4 )); then
        die "需要 bash >= 4 (当前 ${BASH_VERSION}); macOS 自带 bash 3.2 不支持"
    fi

    # 3) 改系统的命令需要 root
    if cmd_mutates_system "$cmd"; then
        if [[ $EUID -ne 0 ]]; then
            die "命令 '${cmd}' 会修改系统配置, 需要 root: sudo $SCRIPT_NAME ${cmd} ..."
        fi
        # 4) 容器/受限环境: /proc/sys 不可写时提前提示 (tune/optimize 才真正需要写)
        if [[ "$cmd" == "tune" || "$cmd" == "optimize" ]]; then
            if [[ ! -w /proc/sys/net/ipv4 ]]; then
                warn "/proc/sys/net 不可写 (容器或受限内核?): sysctl 调优可能无效"
                warn "  如在容器内, 请在宿主机执行, 或赋予 --privileged / CAP_NET_ADMIN"
            fi
            if [[ ! -d /sys/class/net ]]; then
                warn "/sys/class/net 不存在或不完整: 网卡相关优化将被跳过"
            fi
        fi
    fi
    return 0
}

# v2.7.0: 改系统前的统一确认。--yes 跳过; 非交互(无 tty)且无 --yes 时直接拒绝, 不静默执行。
# 用法: confirm_or_die "操作描述" "影响项1" "影响项2" ...
confirm_or_die() {
    local title="$1"; shift
    [[ $ASSUME_YES -eq 1 ]] && return 0
    [[ $DRY_RUN -eq 1 ]] && return 0   # 预演不改系统, 无需确认

    warn "${C_BOLD}${title}${C_RESET}"
    local item
    for item in "$@"; do
        printf '       - %s\n' "$item" >&2
    done

    if [[ ! -t 0 ]]; then
        die "非交互环境 (无 tty)。如确认执行上述修改, 请显式加 --yes"
    fi
    local ans
    read -rp "继续? [y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]] || die "用户取消"
    return 0
}

# v2.7.0: 预演守卫。DRY_RUN 时打印动作并返回 0 (调用方应据此跳过真正的修改)。
# 用法: if dry_skip "将设置 MTU=9000"; then return; fi
dry_skip() {
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '%s[dry-run]%s 将执行: %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2
        return 0
    fi
    return 1
}

num_gt() { awk -v a="$1" -v b="$2" 'BEGIN {exit !(a+0 > b+0)}'; }
num_lt() { awk -v a="$1" -v b="$2" 'BEGIN {exit !(a+0 < b+0)}'; }
num_ge() { awk -v a="$1" -v b="$2" 'BEGIN {exit !(a+0 >= b+0)}'; }
num_le() { awk -v a="$1" -v b="$2" 'BEGIN {exit !(a+0 <= b+0)}'; }

pct() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        if (b+0 == 0) { print "0.00"; exit }
        printf "%.2f", (a+0)/(b+0)*100
    }'
}

median() {
    [[ $# -eq 0 ]] && { echo 0; return; }
    printf '%s\n' "$@" | sort -g | awk '
        { a[NR]=$1 }
        END {
            if (NR==0) { print 0; exit }
            if (NR%2==1) printf "%.4f\n", a[(NR+1)/2]
            else printf "%.4f\n", (a[NR/2] + a[NR/2+1]) / 2
        }
    '
}

# ---------------------------------------------------------------------------
# ★ 多发行版自动安装依赖 (v2.3.0 新增)
# ---------------------------------------------------------------------------

# 探测发行版与包管理器, 输出 "distro|pkg_mgr"
detect_distro() {
    local distro="unknown" pkg_mgr=""

    # 解析 /etc/os-release 而不是 source 它. 原因:
    # 1) 文件里的 VERSION="..." 会与脚本顶部的 `readonly VERSION` 冲突, 报
    #    "VERSION: readonly variable" 并中断后续赋值, 让 ID/ID_LIKE 拿不到
    # 2) 其他变量 (HOME_URL, BUG_REPORT_URL...) 也会污染脚本命名空间
    _read_os_release_field() {
        awk -v key="$1" -F= '
            $1 == key {
                v = $0; sub(/^[^=]*=/, "", v); gsub(/^["'\'']|["'\'']$/, "", v)
                print v; exit
            }
        ' /etc/os-release 2>/dev/null
    }

    if [[ -r /etc/os-release ]]; then
        local _id _idlike
        _id=$(_read_os_release_field ID)
        _idlike=$(_read_os_release_field ID_LIKE)
        local id_lower="${_id,,}"
        local id_like_lower="${_idlike,,}"

        case "$id_lower" in
            debian|ubuntu|raspbian|linuxmint|kali|elementary|pop|deepin|zorin|mx|parrot|tuxedo|neon|peppermint|lmde)
                distro="debian"; pkg_mgr="apt"
                ;;
            centos|rhel|rocky|almalinux|ol|cloudlinux|scientific|virtuozzo|euleros|openeuler)
                distro="rhel"
                command -v dnf >/dev/null 2>&1 && pkg_mgr="dnf" || pkg_mgr="yum"
                ;;
            fedora)
                distro="fedora"; pkg_mgr="dnf"
                ;;
            amzn)
                distro="amazon"
                command -v dnf >/dev/null 2>&1 && pkg_mgr="dnf" || pkg_mgr="yum"
                ;;
            arch|manjaro|endeavouros|garuda|artix|arcolinux|cachyos)
                distro="arch"; pkg_mgr="pacman"
                ;;
            alpine|postmarketos)
                distro="alpine"; pkg_mgr="apk"
                ;;
            opensuse-leap|opensuse-tumbleweed|opensuse|sles|sled)
                distro="suse"; pkg_mgr="zypper"
                ;;
            gentoo)
                distro="gentoo"; pkg_mgr="emerge"
                ;;
            *)
                # ID 不识别时按 ID_LIKE 兜底
                case "$id_like_lower" in
                    *debian*|*ubuntu*) distro="debian"; pkg_mgr="apt" ;;
                    *rhel*|*fedora*|*centos*)
                        distro="rhel"
                        command -v dnf >/dev/null 2>&1 && pkg_mgr="dnf" || pkg_mgr="yum"
                        ;;
                    *arch*) distro="arch"; pkg_mgr="pacman" ;;
                    *suse*) distro="suse"; pkg_mgr="zypper" ;;
                esac
                ;;
        esac
    fi

    # 兜底: 按系统中存在的包管理器二进制判断
    if [[ -z "$pkg_mgr" ]]; then
        if command -v apt-get >/dev/null 2>&1;  then distro="debian"; pkg_mgr="apt"
        elif command -v dnf >/dev/null 2>&1;    then distro="rhel";   pkg_mgr="dnf"
        elif command -v yum >/dev/null 2>&1;    then distro="rhel";   pkg_mgr="yum"
        elif command -v pacman >/dev/null 2>&1; then distro="arch";   pkg_mgr="pacman"
        elif command -v apk >/dev/null 2>&1;    then distro="alpine"; pkg_mgr="apk"
        elif command -v zypper >/dev/null 2>&1; then distro="suse";   pkg_mgr="zypper"
        elif command -v emerge >/dev/null 2>&1; then distro="gentoo"; pkg_mgr="emerge"
        fi
    fi

    echo "${distro}|${pkg_mgr}"
}

# 将 "命令名" 转为 "包名" (各发行版不一致)
# 用法: map_pkg_name <distro> <cmd>
map_pkg_name() {
    local distro="$1" cmd="$2"
    case "$distro" in
        debian)
            case "$cmd" in
                ip|tc)    echo "iproute2" ;;
                mpstat)   echo "sysstat" ;;
                sshpass)  echo "sshpass" ;;
                ping)     echo "iputils-ping" ;;
                ss)       echo "iproute2" ;;
                *)        echo "$cmd" ;;
            esac
            ;;
        rhel|fedora|amazon)
            case "$cmd" in
                ip|tc)    echo "iproute" ;;
                mpstat)   echo "sysstat" ;;
                sshpass)  echo "sshpass" ;;
                ping)     echo "iputils" ;;
                ss)       echo "iproute" ;;
                *)        echo "$cmd" ;;
            esac
            ;;
        arch)
            case "$cmd" in
                ip|tc|ss) echo "iproute2" ;;
                mpstat)   echo "sysstat" ;;
                sshpass)  echo "sshpass" ;;
                ping)     echo "iputils" ;;
                *)        echo "$cmd" ;;
            esac
            ;;
        alpine)
            case "$cmd" in
                ip|tc|ss) echo "iproute2" ;;
                mpstat)   echo "sysstat" ;;
                sshpass)  echo "sshpass" ;;
                ping)     echo "iputils-ping" ;;
                jq)       echo "jq" ;;
                ethtool)  echo "ethtool" ;;
                *)        echo "$cmd" ;;
            esac
            ;;
        suse)
            case "$cmd" in
                ip|tc|ss) echo "iproute2" ;;
                mpstat)   echo "sysstat" ;;
                sshpass)  echo "sshpass" ;;
                ping)     echo "iputils" ;;
                *)        echo "$cmd" ;;
            esac
            ;;
        gentoo)
            case "$cmd" in
                ip|tc|ss) echo "sys-apps/iproute2" ;;
                mpstat)   echo "app-admin/sysstat" ;;
                sshpass)  echo "net-misc/sshpass" ;;
                jq)       echo "app-misc/jq" ;;
                ethtool)  echo "sys-apps/ethtool" ;;
                iperf3)   echo "net-misc/iperf" ;;
                *)        echo "$cmd" ;;
            esac
            ;;
        *)
            echo "$cmd"
            ;;
    esac
}

# 实际执行安装. 失败返回非零.
# 用法: install_packages_with <pkg_mgr> <pkg1> <pkg2> ...
install_packages_with() {
    local pkg_mgr="$1"; shift
    local -a pkgs=("$@")
    [[ ${#pkgs[@]} -eq 0 ]] && return 0

    case "$pkg_mgr" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            # update 失败也尝试 install (网络间歇问题不应阻塞)
            apt-get update -qq >/dev/null 2>&1 || warn "apt-get update 失败, 继续 install"
            apt-get install -y -q --no-install-recommends "${pkgs[@]}"
            ;;
        dnf)
            # 尝试启用 EPEL (失败无所谓, 大多数包不在 EPEL)
            dnf install -y -q epel-release >/dev/null 2>&1 || true
            dnf install -y -q "${pkgs[@]}"
            ;;
        yum)
            yum install -y -q epel-release >/dev/null 2>&1 || true
            yum install -y -q "${pkgs[@]}"
            ;;
        pacman)
            # -Sy 同步源, --noconfirm 跳过确认, --needed 已装的跳过
            pacman -Sy --noconfirm --needed "${pkgs[@]}"
            ;;
        apk)
            apk update >/dev/null 2>&1 || true
            apk add --no-cache "${pkgs[@]}"
            ;;
        zypper)
            zypper --non-interactive refresh >/dev/null 2>&1 || true
            zypper --non-interactive install --no-recommends "${pkgs[@]}"
            ;;
        emerge)
            emerge --quiet --noreplace "${pkgs[@]}"
            ;;
        *)
            err "未支持的包管理器: $pkg_mgr"
            return 1
            ;;
    esac
}

# 自动安装一组依赖命令
# 用法: install_dependencies cmd1 cmd2 ...
install_dependencies() {
    local -a missing=("$@")
    [[ ${#missing[@]} -eq 0 ]] && return 0

    [[ $EUID -eq 0 ]] || {
        err "无 root 权限, 无法自动安装: ${missing[*]}"
        return 1
    }

    local di distro pkg_mgr
    di=$(detect_distro)
    distro="${di%%|*}"
    pkg_mgr="${di##*|}"

    if [[ -z "$pkg_mgr" ]]; then
        err "无法识别发行版或包管理器, 请手动安装: ${missing[*]}"
        return 1
    fi

    log "检测到 ${C_BOLD}${distro}${C_RESET} (${pkg_mgr}), 自动安装缺失依赖: ${missing[*]}"

    # 把 cmd 名映射到包名 (去重)
    local -a pkgs=()
    local cmd p
    declare -A seen=()
    for cmd in "${missing[@]}"; do
        p=$(map_pkg_name "$distro" "$cmd")
        if [[ -z "${seen[$p]:-}" ]]; then
            pkgs+=("$p")
            seen[$p]=1
        fi
    done

    if install_packages_with "$pkg_mgr" "${pkgs[@]}"; then
        ok "依赖安装完成: ${pkgs[*]}"
    else
        err "依赖安装失败: ${pkgs[*]}"
        err "  请手动安装后重试"
        return 1
    fi

    # 再校验一次
    local still_missing=()
    for cmd in "${missing[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || still_missing+=("$cmd")
    done
    if [[ ${#still_missing[@]} -gt 0 ]]; then
        err "下列命令仍然找不到 (包安装可能未提供它们): ${still_missing[*]}"
        return 1
    fi
    return 0
}

# 检查依赖. v2.7.0: 默认不自动安装。仅当显式 --auto-install 且 root 时才装包。
check_dependencies() {
    local need=("$@")
    [[ ${#need[@]} -eq 0 ]] && need=(jq iperf3 ethtool ip awk sed grep sort tee)

    local missing=()
    for c in "${need[@]}"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "缺少依赖: ${missing[*]}"
        if [[ $AUTO_INSTALL -eq 1 && $EUID -eq 0 ]]; then
            log "已开启 --auto-install, 尝试自动安装..."
            if install_dependencies "${missing[@]}"; then
                ok "依赖就绪"
            else
                err "自动安装失败, 请手动安装后重试:"
                _print_manual_install_hint
                exit 1
            fi
        else
            err "缺少必要依赖, 请手动安装 (生产环境默认不自动装包):"
            _print_manual_install_hint
            if [[ $EUID -eq 0 ]]; then
                err "  或显式允许脚本自动安装: 在命令后追加 ${C_BOLD}--auto-install${C_RESET}"
            fi
            exit 1
        fi
    fi

    # sshpass 是按需依赖, 仅 --ssh-pass / --ssh-pass-file / --ssh-ask-pass 时需要
    if [[ -n "$SSH_PASS" || -n "$SSH_PASS_FILE" ]] && ! command -v sshpass >/dev/null 2>&1; then
        if [[ $AUTO_INSTALL -eq 1 && $EUID -eq 0 ]]; then
            log "需要 sshpass, 自动安装..."
            install_dependencies sshpass || die "sshpass 安装失败, 请手动安装或改用 --ssh-key"
        else
            err "SSH 密码认证需要 sshpass, 但未安装。"
            err "  手动安装 (Debian/Ubuntu): apt-get install -y sshpass"
            err "  或改用更安全的 SSH 私钥: ${C_BOLD}--ssh-key ~/.ssh/id_rsa${C_RESET}"
            die "缺少 sshpass"
        fi
    fi
}

_print_manual_install_hint() {
    err "    Debian/Ubuntu: apt-get install -y jq iperf3 ethtool iproute2 sysstat"
    err "    RHEL/CentOS:   yum install -y jq iperf3 ethtool iproute sysstat"
    err "    Arch:          pacman -S jq iperf3 ethtool iproute2 sysstat"
    err "    Alpine:        apk add jq iperf3 ethtool iproute2 sysstat"
}

# 探测主网卡 (三级 fallback)。
# v2.7.0: 探测不到不再 die, 而是返回空字符串 + 非零, 由调用方决定是否致命。
# 真正需要网卡的调优步骤会优雅跳过并提示 PRIMARY_IFACE=... 覆盖。
detect_primary_iface() {
    [[ -n "$PRIMARY_IFACE" ]] && { echo "$PRIMARY_IFACE"; return 0; }
    local iface=""

    # 无 sysfs (极端容器) 直接放弃, 不报错
    [[ -d /sys/class/net ]] || { echo ""; return 1; }

    iface=$(ip -4 route show default 2>/dev/null \
        | awk '$1=="default"{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' \
        | head -1)

    if [[ -z "$iface" ]]; then
        iface=$(ip -6 route show default 2>/dev/null \
            | awk '$1=="default"{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' \
            | head -1)
    fi

    if [[ -z "$iface" ]]; then
        local d name state
        for d in /sys/class/net/*/; do
            name=$(basename "$d")
            [[ "$name" == "lo" ]] && continue
            [[ -e "$d/device" ]] || continue
            state=$(cat "$d/operstate" 2>/dev/null || echo "")
            if [[ "$state" == "up" ]]; then
                iface="$name"
                break
            fi
        done
    fi

    if [[ -z "$iface" || ! -e "/sys/class/net/$iface" ]]; then
        echo ""
        return 1
    fi
    PRIMARY_IFACE="$iface"
    echo "$iface"
    return 0
}

# v2.7.0: 真正需要网卡的步骤用这个。拿不到则 warn 并返回非零, 调用方应跳过该步骤。
require_primary_iface() {
    local iface; iface=$(detect_primary_iface) || true
    if [[ -z "$iface" ]]; then
        warn "无法探测主网卡 (无默认路由 / 容器 / 多网卡策略路由?)"
        warn "  如需对网卡调优, 请显式指定: PRIMARY_IFACE=eth0 $SCRIPT_NAME ..."
        return 1
    fi
    echo "$iface"
    return 0
}

ensure_dirs() {
    [[ -d "$CONFIG_DIR" ]] || mkdir -p "$CONFIG_DIR"
    [[ -d "$STATE_DIR" ]]  || mkdir -p "$STATE_DIR"
    [[ -d "$LOG_DIR" ]]    || mkdir -p "$LOG_DIR"
    chmod 700 "$CONFIG_DIR" "$STATE_DIR"
}

# ---------------------------------------------------------------------------
# v2.4.0: 单流优化辅助
# ---------------------------------------------------------------------------
# 选一个网卡所在 NUMA node 上的 CPU 核 (尽量避开 CPU0)
pick_pin_cpu() {
    local iface="$1" node cpulist first second
    node=$(cat "/sys/class/net/$iface/device/numa_node" 2>/dev/null || echo -1)
    if [[ "$node" =~ ^[0-9]+$ ]] && [[ -r "/sys/devices/system/node/node$node/cpulist" ]]; then
        cpulist=$(cat "/sys/devices/system/node/node$node/cpulist")
    else
        cpulist="0-$(( $(nproc) - 1 ))"
    fi
    first=$(echo "$cpulist" | awk -F'[,-]' '{print $1}')
    if [[ "$first" == "0" ]]; then
        second=$(echo "$cpulist" | awk -F'[,-]' '{print $2}')
        [[ -n "$second" ]] && first="$second"
    fi
    echo "${first:-0}"
}

# 由带宽(Mbit/s)和 RTT(ms) 算 2.5×BDP 的窗口, 输出形如 "128M"
calc_window_human() {
    local mbit="$1" rtt_ms="$2"
    awk -v b="$mbit" -v r="$rtt_ms" 'BEGIN{
        bytes=(b*1000000/8)*(r/1000)*2.5;
        m=bytes/1048576;
        if(m<1)m=1;
        printf "%.0fM", m
    }'
}

# 解析单流绑核与窗口, 设置全局 PIN_CPU / IPERF3_WINDOW
resolve_pin_and_window() {
    local iface; iface=$(detect_primary_iface) || iface=""
    [[ -z "$PIN_CPU" ]] && PIN_CPU=$(pick_pin_cpu "$iface")

    # v2.6.0: reverse 下发送端是 server, 若有 SSH 且未指定, 自动选远端发送核 (经 -A n/m 下发)
    if sender_is_remote && [[ -z "$REMOTE_PIN_CPU" ]]; then
        local rc; rc=$(remote_cpu_candidates | awk '{print $1}')
        if [[ -n "$rc" ]]; then
            REMOTE_PIN_CPU="$rc"
            log "远端发送核(自动): server CPU ${C_BOLD}${REMOTE_PIN_CPU}${C_RESET} (经 iperf3 -A n/m 下发)"
        fi
    fi

    if [[ -n "$WINDOW" ]]; then
        IPERF3_WINDOW="$WINDOW"
        log "TCP 窗口: 手动 ${C_BOLD}${IPERF3_WINDOW}${C_RESET}; 本机核 ${C_BOLD}${PIN_CPU}${C_RESET}${REMOTE_PIN_CPU:+  远端核 ${C_BOLD}${REMOTE_PIN_CPU}${C_RESET}}; 零拷贝=$([[ $ZEROCOPY -eq 1 ]] && echo on || echo off)"
        return 0
    fi

    local rtt loss nic_speed bw
    IFS='|' read -r rtt loss <<<"$(measure_rtt "$SERVER")"
    if [[ "$BANDWIDTH" =~ ^[0-9]+$ && $BANDWIDTH -gt 0 ]]; then
        bw=$BANDWIDTH
    else
        nic_speed=0
        [[ -r "/sys/class/net/$iface/speed" ]] && nic_speed=$(cat "/sys/class/net/$iface/speed" 2>/dev/null || echo 0)
        [[ "$nic_speed" =~ ^[0-9]+$ ]] || nic_speed=0
        bw=$nic_speed
    fi

    if num_gt "$rtt" 0 && num_gt "$bw" 0; then
        IPERF3_WINDOW=$(calc_window_human "$bw" "$rtt")
        log "自动 TCP 窗口: RTT=${rtt}ms × ${bw}Mbit → ${C_BOLD}${IPERF3_WINDOW}${C_RESET} (2.5×BDP); 本机核 ${C_BOLD}${PIN_CPU}${C_RESET}${REMOTE_PIN_CPU:+  远端核 ${C_BOLD}${REMOTE_PIN_CPU}${C_RESET}}; 零拷贝=$([[ $ZEROCOPY -eq 1 ]] && echo on || echo off)"
    else
        IPERF3_WINDOW=""
        warn "无法测得 RTT(${rtt:-?}) 或链路速率(${bw:-?}), 使用内核自动窗口 (可用 --window/--bandwidth 指定); 本机核 ${PIN_CPU}${REMOTE_PIN_CPU:+  远端核 ${REMOTE_PIN_CPU}}"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# v2.5.0: 方向感知 (发送端) + 单流自动寻优
# ---------------------------------------------------------------------------
# -R(reverse) 时发送端是 server(远端); forward 时发送端是本机 client。
# 拥塞算法 / 发送缓冲 / 零拷贝 这些"发送侧"参数, 必须作用在发送端才有效。
sender_is_remote() { [[ "$DIRECTION" == "reverse" && -n "$SSH_HOST" ]]; }

sender_label() {
    if [[ "$DIRECTION" == "reverse" ]]; then
        if [[ -n "$SSH_HOST" ]]; then echo "远端 server ${SSH_HOST} (-R 下 server 是发送端)"
        else echo "远端 server (未提供 --ssh-host, 无法在发送端调参)"; fi
    else
        echo "本机 client (forward 下本机是发送端)"
    fi
}

# 发送端可用的拥塞算法列表
sender_available_congestion() {
    if sender_is_remote; then
        remote_run "sysctl -n net.ipv4.tcp_available_congestion_control" || echo "bbr cubic"
    else
        sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "bbr cubic"
    fi
}

# 发送端当前拥塞算法
sender_current_congestion() {
    if sender_is_remote; then
        remote_run "sysctl -n net.ipv4.tcp_congestion_control" || echo "$CONGESTION"
    else
        sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "$CONGESTION"
    fi
}

# 在发送端设置拥塞算法 (必要时先 modprobe)
set_sender_congestion() {
    local cc="$1"
    if [[ $DRY_RUN -eq 1 ]]; then
        log "[dry-run] 将在发送端($(sender_label))设置拥塞算法: ${cc}"
        return 0
    fi
    if sender_is_remote; then
        remote_run "modprobe tcp_${cc} 2>/dev/null; sysctl -w net.ipv4.tcp_congestion_control=${cc}" >/dev/null 2>&1 \
            || warn "远端设置拥塞算法 ${cc} 失败 (SSH 不可达或权限不足)"
    else
        modprobe "tcp_${cc}" >/dev/null 2>&1 || true
        sysctl -w "net.ipv4.tcp_congestion_control=${cc}" >/dev/null 2>&1 \
            || warn "本机设置拥塞算法 ${cc} 失败"
    fi
}

# 候选拥塞算法 (默认 bbr/cubic/bbr2 中发送端可用者)
congestion_candidates() {
    if [[ -n "$CONGESTION_LIST" ]]; then echo "${CONGESTION_LIST//,/ }"; return; fi
    local avail c out=()
    avail=$(sender_available_congestion)
    for c in bbr cubic bbr2; do
        echo " $avail " | grep -qw "$c" && out+=("$c")
    done
    [[ ${#out[@]} -eq 0 ]] && out=("$CONGESTION")
    echo "${out[*]}"
}

# 由 BDP 生成窗口候选 (单位 M), 以 1.0/1.5/2.0/2.5/3.0/4.0×BDP 为锚, 去重
window_candidates() {
    if [[ -n "$WINDOW_LIST" ]]; then echo "${WINDOW_LIST//,/ }"; return; fi
    local iface rtt loss bw nic_speed
    iface=$(detect_primary_iface) || iface=""
    IFS='|' read -r rtt loss <<<"$(measure_rtt "$SERVER")"
    if [[ "$BANDWIDTH" =~ ^[0-9]+$ && $BANDWIDTH -gt 0 ]]; then bw=$BANDWIDTH
    else
        nic_speed=0
        [[ -r "/sys/class/net/$iface/speed" ]] && nic_speed=$(cat "/sys/class/net/$iface/speed" 2>/dev/null || echo 0)
        [[ "$nic_speed" =~ ^[0-9]+$ ]] || nic_speed=0
        bw=$nic_speed
    fi
    if ! num_gt "$rtt" 0 || ! num_gt "$bw" 0; then
        echo "32M 64M 96M 128M 192M 256M"; return
    fi
    awk -v b="$bw" -v r="$rtt" 'BEGIN{
        bdp=(b*1000000/8)*(r/1000);
        split("1.0 1.5 2.0 2.5 3.0 4.0", f, " ");
        for(i=1;i<=6;i++){
            m=int(bdp*f[i]/1048576 + 0.5); if(m<4)m=4;
            if(!(m in seen)){seen[m]=1; printf "%dM ", m}
        }
    }'
}

# 展开 cpulist "0-3,8,10-11" 为单个核
_expand_cpulist() {
    local spec="$1" part a b
    for part in ${spec//,/ }; do
        if [[ "$part" == *-* ]]; then
            a=${part%-*}; b=${part#*-}
            seq "$a" "$b"
        else
            echo "$part"
        fi
    done
}

# CPU 候选 (网卡 NUMA node 上的核, 最多取前 4 个)
cpu_candidates() {
    local iface="$1" node cpulist
    node=$(cat "/sys/class/net/$iface/device/numa_node" 2>/dev/null || echo -1)
    if [[ "$node" =~ ^[0-9]+$ ]] && [[ -r "/sys/devices/system/node/node$node/cpulist" ]]; then
        cpulist=$(cat "/sys/devices/system/node/node$node/cpulist")
    else
        cpulist="0-$(( $(nproc) - 1 ))"
    fi
    _expand_cpulist "$cpulist" | awk 'NF' | sort -nu | head -4 | tr '\n' ' '
}

# 远端(server) CPU 候选: 经 SSH 读 server 默认路由网卡的 NUMA cpulist, 取前 4 个
# v2.7.0: SSH 不可达时安全回退, 不中断寻优
remote_cpu_candidates() {
    [[ -n "$SSH_HOST" ]] || { echo ""; return 0; }
    ssh_reachable || { echo ""; return 0; }
    local rif="" rnode="" rlist="" rnproc=""
    rif=$(remote_run "ip -o -4 route show default" \
        | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}') || rif=""
    rnproc=$(remote_run "nproc" | tr -dc '0-9') || rnproc=""
    if [[ -n "$rif" ]]; then
        rnode=$(remote_run "cat /sys/class/net/$rif/device/numa_node" | tr -dc '0-9-') || rnode=""
        if [[ "$rnode" =~ ^[0-9]+$ ]]; then
            rlist=$(remote_run "cat /sys/devices/system/node/node$rnode/cpulist") || rlist=""
        fi
    fi
    if [[ -z "$rlist" ]]; then
        if [[ "$rnproc" =~ ^[0-9]+$ && $rnproc -gt 0 ]]; then rlist="0-$((rnproc-1))"; else rlist="0-3"; fi
    fi
    _expand_cpulist "$rlist" | awk 'NF' | sort -nu | head -4 | tr '\n' ' '
}

# 零拷贝(-Z) 发送端严格报告: 说明实际作用在哪一端, 并在 reverse 下核实 server 端 iperf3
report_zerocopy() {
    if [[ $ZEROCOPY -ne 1 ]]; then log "零拷贝(-Z): ${C_BOLD}关闭${C_RESET} (--no-zerocopy)"; return; fi
    if [[ "$DIRECTION" == "reverse" ]]; then
        log "零拷贝(-Z): 发送端=${C_BOLD}server${C_RESET}; -Z 作为 iperf3 协商参数下发到 server, 由 server 用 sendfile 发流"
        if [[ -n "$SSH_HOST" ]]; then
            local rv
            rv=$(remote_run "iperf3 --version 2>/dev/null | head -1") || rv=""
            if [[ -n "$rv" ]]; then
                log "  server iperf3: ${rv} (需 ≥3.x 才支持 zerocopy 协商)"
            else
                warn "  无法读取 server 端 iperf3 版本 (SSH 不可达?), 请自行确认其支持 zerocopy"
            fi
        else
            warn "  未提供 --ssh-host: 无法核实 server 端 iperf3 是否真正使用 zerocopy 发送"
        fi
    else
        log "零拷贝(-Z): 发送端=${C_BOLD}本机 client${C_RESET}, 直接生效"
    fi
}

# 跑一次单流并打分, 输出 "score|bw|rr|rt" (失败为 -1)
_single_run_scored() {
    local j ok
    j=$(bench_streams "$SERVER" "$PORT" 1 "$SCAN_TIME" "$SCAN_REPEATS")
    ok=$(jq -r '.ok' <<<"$j")
    if [[ "$ok" != "true" ]]; then echo "-1|0|0|0"; return; fi
    jq -r '"\(.score)|\(.bandwidth_mbps)|\(.retrans_rate_pct)|\(.retransmits)"' <<<"$j"
}

# 扫本机 client 核, 设 PIN_CPU 为最优, 回显最优核
_scan_local_cpu() {
    local iface="$1" cands best=-1 bestc="$PIN_CPU" c score bw rr rt
    cands=$(cpu_candidates "$iface")
    log "  候选本机核: $cands"
    for c in $cands; do
        PIN_CPU="$c"
        IFS='|' read -r score bw rr rt <<<"$(_single_run_scored)"
        printf '    本机 CPU %s%-3s%s : %s%.2f Mbps%s  重传率 %s%%  评分 %s%.2f%s\n' \
            "${C_CYAN}" "$c" "${C_RESET}" "${C_CYAN}" "$bw" "${C_RESET}" "$rr" "${C_GREEN}" "$score" "${C_RESET}" >&2
        if num_gt "$score" "$best"; then best=$score; bestc=$c; fi
    done
    PIN_CPU="$bestc"; echo "$bestc"
}

# 扫远端 server 核 (经 -A n/m 下发), 设 REMOTE_PIN_CPU 为最优, 回显最优核
_scan_remote_cpu() {
    local cands best=-1 bestc="$REMOTE_PIN_CPU" c score bw rr rt
    cands=$(remote_cpu_candidates)
    if [[ -z "$cands" ]]; then
        warn "  无法枚举远端 CPU 核 (需 --ssh-host 且可读 /sys), 跳过远端核扫描; 可用 --cpu-remote 手动指定"
        echo "$bestc"; return
    fi
    log "  候选远端核: $cands"
    for c in $cands; do
        REMOTE_PIN_CPU="$c"
        IFS='|' read -r score bw rr rt <<<"$(_single_run_scored)"
        printf '    远端 CPU %s%-3s%s : %s%.2f Mbps%s  重传率 %s%%  评分 %s%.2f%s\n' \
            "${C_CYAN}" "$c" "${C_RESET}" "${C_CYAN}" "$bw" "${C_RESET}" "$rr" "${C_GREEN}" "$score" "${C_RESET}" >&2
        if num_gt "$score" "$best"; then best=$score; bestc=$c; fi
    done
    REMOTE_PIN_CPU="$bestc"; echo "$bestc"
}

# 单流自动寻优: 贪心顺序 拥塞算法 → 窗口 → CPU, 每步定下最优再进入下一步
single_stream_optimize() {
    local iface; iface=$(detect_primary_iface) || iface=""
    log "${C_BOLD}========== 单流自动寻优 ==========${C_RESET}"
    log "方向: $DIRECTION  发送端: ${C_BOLD}$(sender_label)${C_RESET}"
    log "扫描档每点 ${SCAN_TIME}s × ${SCAN_REPEATS} 次 (正式确认用 ${DURATION}s × ${REPEATS} 次)"

    local best_cc best_win best_cpu
    best_cc=$(sender_current_congestion)
    best_win="$IPERF3_WINDOW"
    best_cpu="$PIN_CPU"

    local score bw rr rt

    # ---- 步骤 1: 拥塞算法 (发送端) ----
    if [[ $SCAN_CONGESTION -eq 1 || $SCAN_ALL -eq 1 ]]; then
        if [[ "$DIRECTION" == "reverse" && -z "$SSH_HOST" ]]; then
            warn "reverse 模式下发送端是 server, 但未提供 --ssh-host, 无法在发送端切换拥塞算法, 跳过拥塞扫描"
        else
            log "${C_BOLD}── 扫描拥塞算法 (作用在发送端) ──${C_RESET}"
            local cands cbest_score=-1 cc
            cands=$(congestion_candidates)
            for cc in $cands; do
                if ! set_sender_congestion "$cc"; then
                    warn "  发送端无法切到 $cc, 跳过"; continue
                fi
                sleep 1
                IFS='|' read -r score bw rr rt <<<"$(_single_run_scored)"
                printf '  %s%-6s%s : %s%.2f Mbps%s  重传率 %s%%  评分 %s%.2f%s\n' \
                    "${C_CYAN}" "$cc" "${C_RESET}" "${C_CYAN}" "$bw" "${C_RESET}" "$rr" "${C_GREEN}" "$score" "${C_RESET}" >&2
                if num_gt "$score" "$cbest_score"; then cbest_score=$score; best_cc=$cc; fi
            done
            ok "  最优拥塞算法: ${C_BOLD}${best_cc}${C_RESET}"
        fi
    fi
    set_sender_congestion "$best_cc" || true

    # ---- 步骤 2: 窗口 ----
    if [[ $SCAN_WINDOW -eq 1 || $SCAN_ALL -eq 1 ]]; then
        log "${C_BOLD}── 扫描 TCP 窗口 (cc=${best_cc}) ──${C_RESET}"
        local wcands wbest_score=-1 w
        wcands=$(window_candidates)
        log "  候选窗口: $wcands"
        for w in $wcands; do
            IPERF3_WINDOW="$w"
            IFS='|' read -r score bw rr rt <<<"$(_single_run_scored)"
            printf '  %s%-6s%s : %s%.2f Mbps%s  重传率 %s%%  评分 %s%.2f%s\n' \
                "${C_CYAN}" "$w" "${C_RESET}" "${C_CYAN}" "$bw" "${C_RESET}" "$rr" "${C_GREEN}" "$score" "${C_RESET}" >&2
            if num_gt "$score" "$wbest_score"; then wbest_score=$score; best_win=$w; fi
        done
        ok "  最优窗口: ${C_BOLD}${best_win}${C_RESET}"
    fi
    IPERF3_WINDOW="$best_win"

    # ---- 步骤 3: CPU 核 (两端都调, 发送端优先) ----
    if [[ $SCAN_CPU -eq 1 || $SCAN_ALL -eq 1 ]]; then
        log "${C_BOLD}── 扫描 CPU 核 (两端, 发送端优先; cc=${best_cc} win=${best_win:-auto}) ──${C_RESET}"
        if sender_is_remote; then
            log "  发送端=远端 server → 先扫远端发送核 (经 -A n/m 下发)"
            _scan_remote_cpu >/dev/null
            log "  再扫本机接收核"
            _scan_local_cpu "$iface" >/dev/null
        else
            log "  发送端=本机 → 先扫本机发送核"
            _scan_local_cpu "$iface" >/dev/null
            if [[ -n "$SSH_HOST" ]]; then
                log "  再扫远端接收核 (经 -A n/m 下发)"
                _scan_remote_cpu >/dev/null
            else
                log "  未提供 --ssh-host, 跳过远端接收核扫描"
            fi
        fi
        best_cpu="$PIN_CPU"
        ok "  最优 CPU: 本机=${C_BOLD}${PIN_CPU}${C_RESET}${REMOTE_PIN_CPU:+  远端=${C_BOLD}${REMOTE_PIN_CPU}${C_RESET}}"
    fi
    best_cpu="$PIN_CPU"

    # ---- 最优组合正式确认 (用完整 DURATION/REPEATS) ----
    log "${C_BOLD}── 最优组合正式确认 ──${C_RESET}"
    log "  cc=${C_BOLD}${best_cc}${C_RESET}  window=${C_BOLD}${best_win:-auto}${C_RESET}  本机核=${C_BOLD}${best_cpu}${C_RESET}${REMOTE_PIN_CPU:+  远端核=${C_BOLD}${REMOTE_PIN_CPU}${C_RESET}}  zerocopy=$([[ $ZEROCOPY -eq 1 ]] && echo on || echo off)"
    CONGESTION="$best_cc"
    local final; final=$(bench_streams "$SERVER" "$PORT" 1 "$DURATION" "$REPEATS")

    # 组装 state (与 analyze_link / status 兼容: single=best=final, streams=1)
    jq -n \
        --arg ts "$(date -Iseconds)" \
        --arg server "$SERVER" --argjson port "$PORT" \
        --arg dir "$DIRECTION" --arg profile "$PROFILE" \
        --arg cc "$best_cc" --arg win "${best_win:-auto}" \
        --arg cpu "$best_cpu" --arg rcpu "${REMOTE_PIN_CPU:-}" \
        --arg sender "$(sender_label)" \
        --argjson final "$final" \
        '{
            timestamp: $ts, server: $server, port: $port,
            direction: $dir, profile: $profile, mode: "single-scan",
            sender: $sender,
            best_congestion: $cc, best_window: $win,
            best_cpu_local: $cpu, best_cpu_remote: $rcpu,
            single: $final, best: $final,
            all: [$final]
        }'
}

# ---------------------------------------------------------------------------
# 瓶颈检测
# ---------------------------------------------------------------------------
detect_cpu() {
    log "检测 CPU 瓶颈..."
    local iface; iface=$(detect_primary_iface) || iface=""
    local cpu_cores; cpu_cores=$(nproc)

    local s1 s2
    s1=$(awk '$1=="softirq"{sum=0; for(i=2;i<=NF;i++) sum+=$i; print sum}' /proc/stat)
    sleep 1
    s2=$(awk '$1=="softirq"{sum=0; for(i=2;i<=NF;i++) sum+=$i; print sum}' /proc/stat)
    local softirq_rate=$((s2 - s1))

    local irq_queues
    irq_queues=$(grep -E "${iface}(-|\$)" /proc/interrupts 2>/dev/null | wc -l)

    local cpu_usage="0"
    if command -v mpstat >/dev/null 2>&1; then
        cpu_usage=$(mpstat 1 1 2>/dev/null \
            | awk '/^Average:[[:space:]]+all/ {printf "%.1f", 100-$NF}' || echo 0)
    fi

    local rps_enabled=0 f
    for f in /sys/class/net/"$iface"/queues/rx-*/rps_cpus; do
        [[ -f "$f" ]] || continue
        local v; v=$(cat "$f" 2>/dev/null | tr -d ',0')
        if [[ -n "$v" ]]; then rps_enabled=1; break; fi
    done

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
    total_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
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

_ethtool_ring() {
    local iface="$1" section="$2" field="$3"
    ethtool -g "$iface" 2>/dev/null | awk -v sec="$section" -v fld="$field" '
        /^Pre-set maximums:/ { in_max=1; in_cur=0; next }
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
    local iface; iface=$(detect_primary_iface) || iface=""
    local nic_speed="0"
    if [[ -r /sys/class/net/"$iface"/speed ]]; then
        nic_speed=$(cat /sys/class/net/"$iface"/speed 2>/dev/null)
        [[ "$nic_speed" =~ ^-?[0-9]+$ ]] || nic_speed=0
    fi

    local gro tso lro gso
    gro=$(ethtool -k "$iface" 2>/dev/null | awk '/^generic-receive-offload:/ {print $2; exit}')
    tso=$(ethtool -k "$iface" 2>/dev/null | awk '/^tcp-segmentation-offload:/ {print $2; exit}')
    lro=$(ethtool -k "$iface" 2>/dev/null | awk '/^large-receive-offload:/ {print $2; exit}')
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

print_report() {
    local report_json="$1"
    echo "" >&2
    log "${C_BOLD}========== 系统瓶颈报告 ==========${C_RESET}"
    jq -r '
        "主网卡:       \(.nic.iface) (\(.nic.speed_mbps) Mbps, MTU \(.nic.mtu))",
        "CPU 核心:     \(.cpu.cpu_cores)    中断队列: \(.cpu.irq_queues)    RPS: \(.cpu.rps_enabled)",
        "软中断速率:   \(.cpu.softirq_rate)/s    CPU 使用率: \(.cpu.cpu_usage_pct)%",
        "内存:         \(.memory.total_gb)GB (可用 \(.memory.available_gb)GB)",
        "TCP 缓冲区:   rmem_max=\(.memory.rmem_max) wmem_max=\(.memory.wmem_max)",
        "网卡 offload: gro=\(.nic.offload.gro) tso=\(.nic.offload.tso) gso=\(.nic.offload.gso) lro=\(.nic.offload.lro)",
        "Ring buffer:  rx=\(.nic.ring.rx_cur)/\(.nic.ring.rx_max)  tx=\(.nic.ring.tx_cur)/\(.nic.ring.tx_max)",
        "主要瓶颈:     \(.primary_bottleneck) (severity \(.max_severity)/4)"
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
# RTT / 链路诊断
# ---------------------------------------------------------------------------
measure_rtt() {
    local target="$1"
    command -v ping >/dev/null 2>&1 || { echo "0|0"; return; }
    local pong
    pong=$(ping -c 10 -i 0.2 -W 2 "$target" 2>&1) || true

    local rtt
    rtt=$(echo "$pong" | grep -oE '[0-9]+\.[0-9]+/[0-9]+\.[0-9]+/[0-9]+\.[0-9]+' \
        | head -1 | awk -F'/' '{print $2}')

    local loss
    loss=$(echo "$pong" | awk '/packet loss/ {
        for (i=1; i<=NF; i++) if ($i ~ /%/) { gsub("%","",$i); print $i; exit }
    }')
    echo "${rtt:-0}|${loss:-0}"
}

analyze_link() {
    local state_json="$1"
    local nic_speed="${2:-0}"
    local rtt="${3:-0}"
    local loss="${4:-0}"

    local s_bw best_s best_bw best_rr
    s_bw=$(jq -r '.single.bandwidth_mbps' <<<"$state_json")
    best_s=$(jq -r '.best.streams' <<<"$state_json")
    best_bw=$(jq -r '.best.bandwidth_mbps' <<<"$state_json")
    best_rr=$(jq -r '.best.retrans_rate_pct' <<<"$state_json")

    echo "" >&2
    log "${C_BOLD}========== 链路分析 ==========${C_RESET}"

    local link_type
    if num_le "$rtt" 1;    then link_type="本机/回环"
    elif num_le "$rtt" 5;  then link_type="同机房 LAN"
    elif num_le "$rtt" 50; then link_type="同城/同区域"
    elif num_le "$rtt" 150;then link_type="跨地域"
    else                        link_type="跨境/长距离"
    fi

    if num_gt "$rtt" 0; then
        printf '  链路类型:     %s%s%s (RTT %s ms, ping 丢包 %s%%)\n' \
            "${C_CYAN}" "$link_type" "${C_RESET}" "$rtt" "$loss" >&2
    else
        printf '  链路类型:     未知 (ping 不可用)\n' >&2
    fi

    if num_gt "$nic_speed" 0; then
        local util
        util=$(awk -v bw="$best_bw" -v nic="$nic_speed" 'BEGIN {printf "%.1f", bw/nic*100}')
        printf '  带宽利用率:   %s%s%%%s (实测 %s Mbps / NIC 标称 %s Mbps)\n' \
            "${C_GREEN}" "$util" "${C_RESET}" "$best_bw" "$nic_speed" >&2
    fi

    local mult_gain
    mult_gain=$(awk -v s="$s_bw" -v b="$best_bw" 'BEGIN {
        if (s+0==0) {print "?"; exit}
        printf "%.1f%%", (b-s)/s*100
    }')
    printf '  多流提升:     %s (单流 %s → %s 流 %s Mbps)\n' \
        "$mult_gain" "$s_bw" "$best_s" "$best_bw" >&2

    local rt_grade rt_color rt_note
    if num_le "$rtt" 5; then
        if num_lt "$best_rr" 0.01;   then rt_grade="优秀"; rt_color="${C_GREEN}";  rt_note=""
        elif num_lt "$best_rr" 0.1;  then rt_grade="正常"; rt_color="${C_GREEN}";  rt_note=""
        elif num_lt "$best_rr" 1;    then rt_grade="偏高"; rt_color="${C_YELLOW}"; rt_note="LAN 链路通常 < 0.1%, 检查交换机/网线/双工"
        else                              rt_grade="异常"; rt_color="${C_RED}";    rt_note="LAN 链路严重丢包, 物理层问题"
        fi
    elif num_le "$rtt" 50; then
        if num_lt "$best_rr" 0.1;    then rt_grade="优秀"; rt_color="${C_GREEN}";  rt_note=""
        elif num_lt "$best_rr" 1;    then rt_grade="正常"; rt_color="${C_GREEN}";  rt_note=""
        elif num_lt "$best_rr" 3;    then rt_grade="偏高"; rt_color="${C_YELLOW}"; rt_note="可考虑 extreme profile 加大缓冲"
        else                              rt_grade="异常"; rt_color="${C_RED}";    rt_note="检查中间链路质量 (mtr)"
        fi
    else
        if num_lt "$best_rr" 1;      then rt_grade="优秀"; rt_color="${C_GREEN}";  rt_note="公网链路上很好的水平"
        elif num_lt "$best_rr" 3;    then rt_grade="正常"; rt_color="${C_GREEN}";  rt_note="BBR 设计内, 不影响吞吐"
        elif num_lt "$best_rr" 8;    then rt_grade="偏高"; rt_color="${C_YELLOW}"; rt_note="公网常见, 试 extreme profile"
        else                              rt_grade="异常"; rt_color="${C_RED}";    rt_note="跨境严重拥塞, 换时段或换线路"
        fi
    fi
    printf '  重传率评级:   %s%s%s (%s%%)\n' "${rt_color}" "$rt_grade" "${C_RESET}" "$best_rr" >&2
    [[ -n "$rt_note" ]] && printf '                → %s\n' "$rt_note" >&2

    echo "" >&2
    log "${C_BOLD}结论与建议:${C_RESET}"

    local nic_85
    nic_85=$(awk -v n="$nic_speed" 'BEGIN {printf "%.0f", n*0.85}')

    if num_gt "$nic_speed" 0 && num_ge "$best_bw" "$nic_85"; then
        ok "  已接近 NIC 标称速率 (${best_bw}/${nic_speed} Mbps), 两端 sysctl 已不是瓶颈"
    elif num_gt "$nic_speed" 2000 && num_gt "$best_bw" 800 && num_lt "$best_bw" 1100; then
        warn "  NIC ${nic_speed} Mbps 但实测只 ~1 Gbps, ${C_BOLD}中间链路或 ISP 限速 1G${C_RESET}"
        warn "  → 调 sysctl 无法突破, 排查中间路由: ${C_CYAN}mtr -rwc 50 ${SERVER:-target}${C_RESET}"
    elif num_gt "$nic_speed" 0 && num_lt "$best_bw" "$(awk -v n="$nic_speed" 'BEGIN {printf "%.0f", n*0.5}')"; then
        warn "  实测带宽不到 NIC 标称的 50%, 可能原因:"
        warn "    1) BDP 不够: RTT=${rtt}ms × ${best_bw}Mbps 需要 $(awk -v r="$rtt" -v b="$best_bw" 'BEGIN{printf "%.0f", r*b/8*1024}') 字节缓冲"
        warn "       → 试 extreme profile (1GB 缓冲)"
        warn "    2) 中间链路拥塞 (mtr/traceroute 排查)"
        warn "    3) 远端 server 的 CPU 或带宽瓶颈"
    fi

    if [[ "$best_s" == "1" ]]; then
        log "  寻优最优配置是 ${C_BOLD}单流${C_RESET}, 说明单 TCP 连接已经撑满链路, 多流没有意义"
    elif [[ "$best_s" -ge 4 ]]; then
        log "  最优配置 ${C_BOLD}${best_s} 流${C_RESET}, 推荐应用层用相同的并发数"
    fi

    echo "" >&2
    ok "  ${C_BOLD}本次调优已生效 ✓${C_RESET}"
    log "  sysctl 持久化在 $SYSCTL_FILE (重启保留)"
    log "  原始数据:    ${C_CYAN}jq . $STATE_FILE${C_RESET}"
    log "  回退所有改动: ${C_CYAN}sudo $SCRIPT_NAME rollback${C_RESET}"
}

# ---------------------------------------------------------------------------
# sysctl profile
# ---------------------------------------------------------------------------
build_sysctl() {
    local profile="$1"

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
            # v2.3.0: 针对单流 -R 优化
            #   - tcp_notsent_lowat 提到 4MB (原 128KB), 让发送侧少阻塞 (单流场景)
            #   - tcp_limit_output_bytes 提到 4MB (原 1MB), 减少 pacing 抖动
            #   - tcp_window_clamp 显式提到 256MB, 避免某些内核默认 16MB 上限卡住单流
            cat <<EOF
# ---- iperf3-tune: aggressive (256MB, 单流友好) ----
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
net.ipv4.tcp_notsent_lowat = 4194304
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_limit_output_bytes = 4194304
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
net.ipv4.tcp_notsent_lowat = 16777216
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_limit_output_bytes = 16777216
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

write_and_apply_sysctl() {
    local profile="$1"
    log "应用 sysctl profile: ${C_BOLD}${profile}${C_RESET}"

    if [[ $DRY_RUN -eq 1 ]]; then
        log "[dry-run] 将写入 ${SYSCTL_FILE} 并 sysctl -p, 内容预览:"
        build_sysctl "$profile" | sed 's/^/  | /' >&2
        log "[dry-run] 预演结束, 未写入文件、未应用 sysctl"
        return 0
    fi

    backup_sysctl

    {
        echo "# Generated by $SCRIPT_NAME at $(date -Iseconds)"
        echo "# profile=$profile, congestion=$CONGESTION"
        echo "# 用 '$SCRIPT_NAME rollback' 回退"
        echo ""
        build_sysctl "$profile"
    } > "$SYSCTL_FILE"
    chmod 644 "$SYSCTL_FILE"

    local out
    if out=$(sysctl -p "$SYSCTL_FILE" 2>&1); then
        ok "sysctl 已应用 ($(echo "$out" | wc -l) 项)"
    else
        warn "部分 sysctl 应用失败 (可能是当前内核不支持的键):"
        echo "$out" | grep -E "error|cannot|unknown" >&2 || true
    fi
}

backup_nic() {
    local iface; iface=$(detect_primary_iface) || iface=""
    [[ -z "$iface" ]] && { warn "无主网卡, 跳过网卡备份"; return 0; }
    log "备份网卡 $iface 当前设置到 $NIC_BACKUP"

    local offload ring mtu_cur
    offload=$(ethtool -k "$iface" 2>/dev/null | awk -F': ' 'NR>1 {gsub(/ \[fixed\]/,"",$2); print $1"="$2}' | tr '\n' ';')
    ring=$(ethtool -g "$iface" 2>/dev/null | awk '
        /^Current hardware settings:/ { incur=1; next }
        incur && /^[A-Z]/ { gsub(":","",$1); printf "%s=%s;", $1, $2 }
    ')
    mtu_cur=$(cat "/sys/class/net/$iface/mtu" 2>/dev/null || echo "")

    jq -n --arg iface "$iface" --arg offload "$offload" --arg ring "$ring" --arg mtu "$mtu_cur" \
        '{iface:$iface, offload:$offload, ring:$ring, mtu:$mtu}' > "$NIC_BACKUP"
}

apply_nic_tuning() {
    local iface; iface=$(detect_primary_iface) || iface=""
    if [[ -z "$iface" ]]; then
        warn "无法探测主网卡, 跳过网卡硬件优化 (sysctl 仍已生效)"
        warn "  如需对网卡调优: PRIMARY_IFACE=eth0 $SCRIPT_NAME ..."
        return 0
    fi
    local cores; cores=$(nproc)
    log "应用网卡硬件优化 (iface=$iface)"

    if [[ $DRY_RUN -eq 1 ]]; then
        log "[dry-run] 将对 ${iface} 执行: 备份当前设置 → 开启 gro/tso/gso/lro/offload → 调大 ring buffer"
        [[ $STOP_IRQBALANCE -eq 1 ]] && log "[dry-run]   停止 irqbalance (rollback 时恢复)"
        [[ -n "$MTU" ]] && log "[dry-run]   设置 MTU=${MTU}"
        log "[dry-run]   配置 RPS/RFS/XPS + 分散 IRQ 亲和"
        log "[dry-run] 预演结束, 未做任何修改"
        return 0
    fi

    backup_nic

    # v2.4.0: 停掉 irqbalance, 否则它会周期性打乱我们设的 IRQ 亲和。rollback 会恢复。
    if [[ $STOP_IRQBALANCE -eq 1 ]] && command -v systemctl >/dev/null 2>&1; then
        systemctl stop irqbalance >/dev/null 2>&1 && ok "  已停止 irqbalance (rollback 时恢复)" || true
    fi

    local feat
    for feat in gro tso gso sg rx tx rxhash rxvlan txvlan; do
        if ethtool -K "$iface" "$feat" on >/dev/null 2>&1; then
            vlog "  ${feat}: on"
        else
            vlog "  ${feat}: skip (not supported)"
        fi
    done
    # LRO 在转发场景可能丢包, 但单端用例 (iperf3 测试) 启用
    ethtool -K "$iface" lro on >/dev/null 2>&1 || true

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

    # v2.4.0: jumbo frame (两端及中间链路都需支持 9000 MTU 才有意义)
    if [[ -n "$MTU" ]]; then
        if ip link set dev "$iface" mtu "$MTU" >/dev/null 2>&1; then
            ok "  MTU 已设为 $MTU (jumbo frame; 请确认对端与中间链路同样支持)"
        else
            warn "  MTU 设为 $MTU 失败 (链路可能不支持)"
        fi
    fi

    local cpu_mask
    cpu_mask=$(printf '%x' "$(( (1 << cores) - 1 ))")

    local q
    for q in /sys/class/net/"$iface"/queues/rx-*/rps_cpus; do
        [[ -f "$q" ]] && echo "$cpu_mask" > "$q" 2>/dev/null && vlog "  RPS:   $q = $cpu_mask"
    done
    for q in /sys/class/net/"$iface"/queues/rx-*/rps_flow_cnt; do
        [[ -f "$q" ]] && echo 4096 > "$q" 2>/dev/null && vlog "  RFS:   $q = 4096"
    done
    for q in /sys/class/net/"$iface"/queues/tx-*/xps_cpus; do
        [[ -f "$q" ]] && echo "$cpu_mask" > "$q" 2>/dev/null && vlog "  XPS:   $q = $cpu_mask"
    done
    ok "  RPS/RFS/XPS 已启用 (mask=$cpu_mask)"

    if [[ -x /usr/sbin/set_irq_affinity ]]; then
        /usr/sbin/set_irq_affinity "$iface" >/dev/null 2>&1 && ok "  IRQ affinity 已分散"
    else
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
run_iperf3() {
    local server="$1" port="$2" streams="$3" duration="$4" out="$5"
    local -a args=(
        -c "$server" -p "$port" -P "$streams" -t "$duration"
        -O 2
        --connect-timeout 5000
        -J
    )
    [[ "$DIRECTION" == "reverse" ]] && args+=(-R)
    # v2.4.0: 零拷贝 (省发送侧 CPU, 对单流尤其有效)
    [[ $ZEROCOPY -eq 1 ]] && args+=(-Z)
    # v2.4.0: 按 BDP 计算的窗口
    [[ -n "$IPERF3_WINDOW" ]] && args+=(-w "$IPERF3_WINDOW")

    # v2.4.0/v2.6.0: 仅单流时绑核; -A n/m 同时绑本端(n)与远端 server(m, 经协商下发); 多流不绑
    local -a pre=()
    if [[ "$streams" -eq 1 && -n "$PIN_CPU" ]]; then
        local aff="$PIN_CPU"
        [[ -n "$REMOTE_PIN_CPU" ]] && aff="${PIN_CPU}/${REMOTE_PIN_CPU}"
        args+=(-A "$aff")
        command -v taskset >/dev/null 2>&1 && pre=(taskset -c "$PIN_CPU")
    fi

    if [[ ${#pre[@]} -gt 0 ]]; then
        "${pre[@]}" iperf3 "${args[@]}" > "$out" 2>/dev/null
    else
        iperf3 "${args[@]}" > "$out" 2>/dev/null
    fi
}

parse_iperf3() {
    local f="$1"
    local mss="${MSS:-1448}"

    jq -r --argjson mss "$mss" '
        def bps:
            if (.end.sum_received? // null) != null then .end.sum_received.bits_per_second
            elif (.end.sum? // null) != null then .end.sum.bits_per_second
            else 0 end;
        def retrans:
            if (.end.sum_sent.retransmits? // null) != null then .end.sum_sent.retransmits
            elif (.end.streams? // null) != null then ([.end.streams[].sender.retransmits // 0] | add)
            else 0 end;
        def bytes_sent:
            if (.end.sum_sent.bytes? // null) != null then .end.sum_sent.bytes
            elif (.end.streams? // null) != null then ([.end.streams[].sender.bytes // 0] | add)
            else 0 end;
        def segs:
            if bytes_sent > 0 then (bytes_sent / $mss | floor) else 0 end;
        "\(bps / 1000000)|\(retrans)|\(segs)|\(bytes_sent)"
    ' "$f" 2>/dev/null
}

bench_streams() {
    local server="$1" port="$2" streams="$3" duration="$4" repeats="$5"

    local bws=() rts=() rrs=() sgs=() bss=()
    local i tmp result mbps rt sg bs rr

    for ((i=1; i<=repeats; i++)); do
        tmp=$(mktemp /tmp/iperf3-tune.XXXXXX.json)

        if ! run_iperf3 "$server" "$port" "$streams" "$duration" "$tmp"; then
            warn "  第 $i 次测试失败"
            rm -f "$tmp"
            continue
        fi

        result=$(parse_iperf3 "$tmp")
        if [[ $VERBOSE -eq 1 ]]; then
            cp "$tmp" "${LOG_DIR}/last-iperf3-${streams}-${i}.json" 2>/dev/null || true
        fi
        rm -f "$tmp"

        IFS='|' read -r mbps rt sg bs <<<"$result"

        if [[ "$sg" =~ ^[0-9]+$ && $sg -gt 0 ]]; then
            rr=$(pct "$rt" "$sg")
        else
            rr="0.00"
        fi
        bws+=("$mbps"); rts+=("$rt"); rrs+=("$rr")
        sgs+=("$sg");   bss+=("$bs")

        vlog "  run $i/$repeats: ${mbps} Mbps retrans=${rt}/${sg} segs (${rr}%) bytes=${bs}"
        [[ $i -lt $repeats ]] && sleep 2
    done

    [[ ${#bws[@]} -eq 0 ]] && { echo '{"streams":'"$streams"',"ok":false}'; return; }

    local med_bw med_rt med_rr med_sg med_bs
    med_bw=$(median "${bws[@]}")
    med_rt=$(median "${rts[@]}")
    med_rr=$(median "${rrs[@]}")
    med_sg=$(median "${sgs[@]}")
    med_bs=$(median "${bss[@]}")

    local score
    score=$(awk -v bw="$med_bw" -v rr="$med_rr" -v k="$RETRANS_PENALTY" \
        'BEGIN {p=1-k*rr/100; if(p<0)p=0; printf "%.4f", bw*p}')

    jq -n \
        --argjson streams "$streams" \
        --arg bw "$med_bw" --arg rt "$med_rt" --arg rr "$med_rr" --arg sc "$score" \
        --arg sg "$med_sg" --arg bs "$med_bs" \
        --argjson n "${#bws[@]}" \
        '{
            streams: $streams, ok: true,
            samples: $n,
            bandwidth_mbps: ($bw|tonumber),
            retransmits: ($rt|tonumber),
            est_segments: ($sg|tonumber),
            bytes_sent: ($bs|tonumber),
            retrans_rate_pct: ($rr|tonumber),
            score: ($sc|tonumber)
        }'
}

find_optimal_parallel() {
    local server="$1" port="$2" duration="$3" repeats="$4" max_p="$5"
    local progress_file="${STATE_DIR}/progress.json"

    log "${C_BOLD}========== 多流寻优 ==========${C_RESET}"
    log "服务端: $server:$port  方向: $DIRECTION  时长: ${duration}s × $repeats 次"

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

        if [[ -f "$progress_file" ]]; then
            jq --argjson r "$r" --arg ts "$(date -Iseconds)" \
                '.results += [$r] | .last_update = $ts' \
                "$progress_file" > "${progress_file}.tmp" \
                && mv "${progress_file}.tmp" "$progress_file"
        fi

        local ok bw rt rr sc
        ok=$(jq -r '.ok' <<<"$r")
        [[ "$ok" != "true" ]] && continue
        bw=$(jq -r '.bandwidth_mbps'    <<<"$r")
        rt=$(jq -r '.retransmits'       <<<"$r")
        rr=$(jq -r '.retrans_rate_pct'  <<<"$r")
        sc=$(jq -r '.score'             <<<"$r")

        printf '  → %s%d 流%s: %s%.2f Mbps%s  重传 %s%s 次 (%s%%)%s  评分 %s%.2f%s\n' \
            "${C_BOLD}" "$streams" "${C_RESET}" \
            "${C_CYAN}" "$bw" "${C_RESET}" \
            "${C_YELLOW}" "$rt" "$rr" "${C_RESET}" \
            "${C_GREEN}" "$sc" "${C_RESET}" >&2

        if num_gt "$rr" "$RETRANS_THRESHOLD"; then
            if [[ $streams -eq 1 ]] && num_le "$rr" 10; then
                warn "  单流重传率 ${rr}% > 阈值 ${RETRANS_THRESHOLD}%,"
                warn "  但单流不早停 (多流可能改善), 继续测下一档"
            else
                warn "  重传率 ${rr}% > 阈值 ${RETRANS_THRESHOLD}%, 提前停止寻优"
                break
            fi
        fi

        if [[ $streams -gt 1 ]] && num_lt "$sc" "$(awk -v s="$prev_score" 'BEGIN{print s*0.95}')"; then
            warn "  评分相对前一档下降 >5%, 提前停止寻优"
            break
        fi

        prev_score=$sc
    done

    local arr; arr=$(printf '%s\n' "${results[@]}" | jq -s '.')
    local best; best=$(jq '[.[] | select(.ok)] | sort_by(-.score) | .[0]' <<<"$arr")

    if [[ -f "$progress_file" ]]; then
        jq --arg ts "$(date -Iseconds)" --argjson best "$best" \
            '.status = "finished" | .finished = $ts | .best = $best' \
            "$progress_file" > "${progress_file}.tmp" \
            && mv "${progress_file}.tmp" "$progress_file"
    fi

    echo ""
    log "${C_BOLD}========== 寻优结果 ==========${C_RESET}"
    jq -r '.[] | select(.ok) | "  \(.streams) 流: \(.bandwidth_mbps) Mbps  重传 \(.retransmits) 次 (\(.retrans_rate_pct)%)  评分 \(.score)"' \
        <<<"$arr" >&2

    local best_s best_bw best_rt best_rr
    best_s=$(jq -r '.streams'           <<<"$best")
    best_bw=$(jq -r '.bandwidth_mbps'   <<<"$best")
    best_rt=$(jq -r '.retransmits'      <<<"$best")
    best_rr=$(jq -r '.retrans_rate_pct' <<<"$best")
    ok "最优: ${C_BOLD}${best_s} 流${C_RESET}, ${best_bw} Mbps, 重传 ${best_rt} 次 (${best_rr}%)"

    # 返回完整数组 + best
    jq -n --argjson all "$arr" --argjson best "$best" '{all:$all, best:$best}'
}

# ---------------------------------------------------------------------------
# ★ SSH 远端同步调优 (v2.3.0 关键修复)
# ---------------------------------------------------------------------------

# 构造 SSH 命令前缀, 输出到 stdout (空格分隔). 使用方: read -ra arr <<<"$(_ssh_prefix)"
_ssh_prefix() {
    local -a base=(
        -p "$SSH_PORT"
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o ConnectTimeout=10
        -o ServerAliveInterval=15
        -o ServerAliveCountMax=4
        -o LogLevel=ERROR
    )
    if [[ -n "$SSH_KEY" ]]; then
        base+=(-i "$SSH_KEY" -o IdentitiesOnly=yes -o PreferredAuthentications=publickey)
    fi
    printf '%s\n' "${base[@]}"
}

# 在远端执行命令. 用法: ssh_remote <cmd> [args...]
ssh_remote() {
    local -a sshargs
    mapfile -t sshargs < <(_ssh_prefix)

    if [[ -n "$SSH_PASS" ]]; then
        SSHPASS="$SSH_PASS" sshpass -e ssh "${sshargs[@]}" "${SSH_USER}@${SSH_HOST}" "$@"
    elif [[ -n "$SSH_PASS_FILE" ]]; then
        sshpass -f "$SSH_PASS_FILE" ssh "${sshargs[@]}" "${SSH_USER}@${SSH_HOST}" "$@"
    else
        ssh "${sshargs[@]}" "${SSH_USER}@${SSH_HOST}" "$@"
    fi
}

# v2.7.0: 探测远端 SSH 可达性, 结果缓存到 SSH_REACHABLE。绝不让脚本因此退出。
# 返回: 0=可达, 1=不可达/未配置。首次探测会打印一次诊断。
ssh_reachable() {
    [[ -z "$SSH_HOST" ]] && { SSH_REACHABLE=0; return 1; }
    if [[ "$SSH_REACHABLE" == "1" ]]; then return 0; fi
    if [[ "$SSH_REACHABLE" == "0" ]]; then return 1; fi
    # 未检测过: 探一次
    local probe_err
    if probe_err=$(ssh_remote "echo OK" 2>&1); then
        SSH_REACHABLE=1
        return 0
    fi
    SSH_REACHABLE=0
    warn "SSH 不可达: ${SSH_USER}@${SSH_HOST}:${SSH_PORT} — 远端相关步骤将跳过 (本地继续)"
    if [[ -n "$probe_err" ]]; then
        printf '%s\n' "$probe_err" | sed 's/^/    | /' >&2
    fi
    return 1
}

# v2.7.0: 远端命令统一入口。SSH 不可达时直接返回非零 (不尝试), 永不中断调用方。
# 用法: out=$(remote_run "cmd") || out="fallback"
remote_run() {
    ssh_reachable || return 1
    ssh_remote "$@" 2>/dev/null || return 1
}

# v2.7.2: 在父 shell 里先探测一次 SSH 可达性并缓存。
# 必须在父 shell 调用 (而非 $(...) 子shell), 否则 SSH_REACHABLE 的赋值会随子shell丢失,
# 导致后续每个经 $() 调用的远端helper都重新探测一次 (SSH 不可达时每次最多等 ConnectTimeout)。
# 仅在远端确实会被用到时 (reverse + --ssh-host) 才探, 避免无谓告警。
prime_ssh_reachable() {
    sender_is_remote || return 0
    [[ "$SSH_REACHABLE" == "-1" ]] || return 0
    ssh_reachable || true
    return 0
}

# 上传文件到远端. 用法: scp_to_remote <local> <remote>
# OpenSSH 9.0+ scp 默认走 SFTP, 远端无 sftp-server 会失败.
# 先尝试 -O (强制旧 SCP 协议), 不识别 -O 的更老 scp 再 fallback 到默认.
scp_to_remote() {
    local src="$1" dst="$2"
    local -a sshargs
    mapfile -t sshargs < <(_ssh_prefix)
    # scp 用 -P, sed 把 -p PORT 改成 -P PORT
    local -a scpargs=()
    local i=0
    while [[ $i -lt ${#sshargs[@]} ]]; do
        if [[ "${sshargs[$i]}" == "-p" ]]; then
            scpargs+=("-P" "${sshargs[$((i+1))]}")
            i=$((i + 2))
        else
            scpargs+=("${sshargs[$i]}")
            i=$((i + 1))
        fi
    done

    _do_scp() {
        local -a extra=("$@")
        if [[ -n "$SSH_PASS" ]]; then
            SSHPASS="$SSH_PASS" sshpass -e scp "${extra[@]}" "${scpargs[@]}" "$src" "${SSH_USER}@${SSH_HOST}:${dst}"
        elif [[ -n "$SSH_PASS_FILE" ]]; then
            sshpass -f "$SSH_PASS_FILE" scp "${extra[@]}" "${scpargs[@]}" "$src" "${SSH_USER}@${SSH_HOST}:${dst}"
        else
            scp "${extra[@]}" "${scpargs[@]}" "$src" "${SSH_USER}@${SSH_HOST}:${dst}"
        fi
    }

    local err_out rc
    err_out=$(_do_scp -O 2>&1); rc=$?
    if (( rc == 0 )); then
        return 0
    fi
    # -O 选项在 OpenSSH < 8.7 不存在, 回退到默认 (走 SFTP)
    if [[ "$err_out" == *"unknown option"* || "$err_out" == *"invalid option"* ]]; then
        vlog "scp -O 不识别, 回退默认协议"
        _do_scp
        return $?
    fi
    # 是 -O 之外的失败, 直接报错 + 上下文
    err "scp 上传失败 (exit=$rc):"
    printf '%s\n' "$err_out" | sed 's/^/  | /' >&2
    return "$rc"
}

# 远端同步调优. 这是 optimize 流程的步骤 3/4
# ★ 关键修复: 远端缺依赖时, 通过远端脚本的 auto-install 自动安装
remote_tune() {
    [[ -z "$SSH_HOST" ]] && { warn "未提供 --ssh-host, 跳过远端同步"; return 0; }

    log "${C_BOLD}========== 远端 ${SSH_HOST} 应用同等优化 ==========${C_RESET}"

    if [[ $DRY_RUN -eq 1 ]]; then
        log "[dry-run] 将 SSH 到 ${SSH_USER}@${SSH_HOST}:${SSH_PORT}, 上传脚本并在远端执行:"
        log "[dry-run]   tune --profile ${PROFILE} --congestion ${CONGESTION}${MTU:+ --mtu ${MTU}} --yes"
        log "[dry-run]   并确保远端 iperf3 -s 在端口 ${PORT} 运行"
        log "[dry-run] 预演结束, 未连接远端、未做任何修改"
        return 0
    fi

    # 1) 探测远端 SSH 是否可达 (缓存结果; 保留 stderr 以便诊断)
    local probe_err probe_rc
    probe_err=$(ssh_remote "echo OK" 2>&1 >/dev/null); probe_rc=$?
    if (( probe_rc != 0 )); then
        SSH_REACHABLE=0
        err "无法 SSH 到远端 ${SSH_USER}@${SSH_HOST}:${SSH_PORT} (exit=$probe_rc)"
        if [[ -n "$probe_err" ]]; then
            err "  SSH 报错:"
            printf '%s\n' "$probe_err" | sed 's/^/    | /' >&2
        fi
        err "  请检查:"
        err "    1) 网络 / 防火墙 (ping / telnet 目标端口)"
        err "    2) 密钥或密码是否正确"
        err "    3) 远端 sshd 是否允许该用户登录 (PermitRootLogin / PasswordAuthentication)"
        return 1
    fi
    SSH_REACHABLE=1

    local remote_script="/tmp/iperf3-tune.sh"

    # 2) 上传脚本到远端
    log "上传脚本到远端 ${remote_script}"
    if ! scp_to_remote "$SCRIPT_PATH" "$remote_script"; then
        err "scp 上传失败 (见上方 scp 错误)"
        return 1
    fi
    ssh_remote "chmod 755 $remote_script" >/dev/null 2>&1 || true

    # 3) 在远端运行 tune. v2.7.0: 是否自动装依赖跟随本端选择 (默认不装)
    log "在远端执行 tune --profile=${PROFILE}"
    local rcmd
    rcmd="bash $remote_script tune --profile ${PROFILE} --congestion ${CONGESTION} --yes"
    [[ -n "$MTU" ]] && rcmd="$rcmd --mtu ${MTU}"
    [[ $VERBOSE -eq 1 ]] && rcmd="$rcmd --verbose"
    [[ $STOP_IRQBALANCE -eq 0 ]] && rcmd="$rcmd --no-stop-irqbalance"
    # 与本端一致地传递自动安装选择: 本端开 -> 远端也开; 本端关 -> 远端显式关
    if [[ $AUTO_INSTALL -eq 1 ]]; then
        rcmd="$rcmd --auto-install"
    else
        rcmd="$rcmd --no-auto-install"
    fi

    # 同时把远端输出落盘 + 实时回放到本地 stderr, 失败时打印最后几行
    local remote_log="${LOG_DIR}/remote-tune.$(date +%s).log"
    local rc=0
    ssh_remote "$rcmd" 2>&1 | tee "$remote_log" >&2 || rc=${PIPESTATUS[0]}
    if (( rc == 0 )); then
        ok "远端 tune 已完成 (日志: $remote_log)"
    else
        err "远端 tune 执行失败 (exit=$rc)"
        err "  完整远端日志: $remote_log"
        if [[ -s "$remote_log" ]]; then
            err "  最后 20 行:"
            tail -20 "$remote_log" | sed 's/^/    | /' >&2
        fi
        err "  常见原因:"
        err "    - 远端无 root / sudo 跑 (require_root 失败)"
        err "    - 远端无法装依赖 (apt/yum 源不通)"
        err "    - 远端容器没暴露 /proc/sys 写权限"
        err "    - 远端 /tmp 是 noexec 且没装 bash"
        return 1
    fi

    # 4) 检查 / 启动远端 iperf3 服务端
    log "检查远端 iperf3 服务端"
    if ssh_remote "pgrep -f 'iperf3 -s' >/dev/null" 2>/dev/null; then
        ok "远端 iperf3 -s 已运行"
    else
        warn "远端未发现 iperf3 -s, 尝试以 daemon 方式启动 (端口 ${PORT})"
        # 用 setsid + nohup 让 iperf3 脱离 SSH session
        ssh_remote "setsid nohup iperf3 -s -p ${PORT} -D >/tmp/iperf3-server.log 2>&1" \
            || warn "iperf3 -s -D 启动失败 (可能已绑定端口或被防火墙拦截)"
        sleep 2
        if ssh_remote "pgrep -f 'iperf3 -s' >/dev/null" 2>/dev/null; then
            ok "远端 iperf3 -s 已启动 (port ${PORT})"
        else
            warn "远端 iperf3 -s 启动后未检测到进程, 后续 bench 可能失败"
        fi
    fi

    return 0
}

remote_rollback() {
    [[ -z "$SSH_HOST" ]] && return 0
    log "${C_BOLD}========== 远端回退 ==========${C_RESET}"
    if ! ssh_remote "echo OK" >/dev/null 2>&1; then
        warn "无法 SSH 到远端, 跳过"
        return 0
    fi
    local remote_script="/tmp/iperf3-tune.sh"
    if ssh_remote "test -x $remote_script"; then
        ssh_remote "$remote_script rollback --yes" || warn "远端 rollback 返回非零"
    else
        warn "远端没有 $remote_script, 跳过 (可能从未做过 remote_tune)"
    fi
}

# ---------------------------------------------------------------------------
# 子命令实现
# ---------------------------------------------------------------------------
cmd_detect() {
    check_dependencies
    local report; report=$(detect_all)
    print_report "$report"
    if [[ $JSON_OUT -eq 1 ]]; then
        echo "$report"
    fi
}

# v2.7.0: 列出本次调优会对系统造成的影响项 (供改前确认 / dry-run 展示)
tuning_impact_items() {
    local -a items=()
    items+=("写入并加载 ${SYSCTL_FILE} (profile=${PROFILE}: 调大 TCP 缓冲/队列等内核参数)")
    items+=("切换 TCP 拥塞控制算法为 ${CONGESTION}, 默认 qdisc 改为 fq")
    [[ $STOP_IRQBALANCE -eq 1 ]] && items+=("停止 irqbalance 服务 (rollback 会恢复)")
    items+=("开启网卡 offload (gro/tso/gso/lro 等) 并调大 ring buffer")
    items+=("重设 RPS/RFS/XPS 与网卡 IRQ 亲和 (可能改变中断在 CPU 上的分布)")
    [[ -n "$MTU" ]] && items+=("把网卡 MTU 改为 ${MTU} (两端及中间链路都需支持, 否则可能丢包/不通)")
    [[ "$PROFILE" == "extreme" ]] && items+=("extreme 档: 关闭 rp_filter 反向路径过滤 + 1GB 缓冲, 对业务影响显著")
    if [[ "$DIRECTION" == "reverse" && -n "$SSH_HOST" ]]; then
        items+=("经 SSH 对远端 server ${SSH_HOST} 应用同等调优 (发送端是重点)")
    fi
    printf '%s\n' "${items[@]}"
}

cmd_tune() {
    require_root
    check_dependencies
    ensure_dirs

    local -a _items=()
    mapfile -t _items < <(tuning_impact_items)
    [[ $DRY_RUN -eq 1 ]] && log "${C_BOLD}[dry-run] 预演 tune, 以下修改不会真正执行${C_RESET}"
    confirm_or_die "即将修改本机网络栈 (profile=${PROFILE}), 涉及:" "${_items[@]}"

    write_and_apply_sysctl "$PROFILE"
    apply_nic_tuning
    if [[ $DRY_RUN -eq 1 ]]; then
        ok "dry-run 完成 (未修改系统)"
    else
        ok "本机调优完成"
    fi
}

cmd_bench() {
    check_dependencies
    ensure_dirs

    [[ -z "$SERVER" ]] && die "--server IP 必填"

    # v2.7.2: 先在父 shell 探一次 SSH 可达性并缓存, 之后 $() 里的远端helper直接复用,
    # 避免 SSH 不可达时反复 10s 超时 (尤其 --scan 多次调用远端枚举时)
    prime_ssh_reachable

    # v2.4.0: 解析单流绑核与 BDP 窗口
    resolve_pin_and_window
    # v2.6.0: 零拷贝发送端严格报告
    report_zerocopy

    # v2.5.0: 若开启任一扫描, 走单流自动寻优, 跳过多流寻优
    if [[ $SCAN_WINDOW -eq 1 || $SCAN_CONGESTION -eq 1 || $SCAN_CPU -eq 1 || $SCAN_ALL -eq 1 ]]; then
        local state; state=$(single_stream_optimize)
        echo "$state" > "$STATE_FILE"

        local nic_speed=0
        if [[ -r /sys/class/net/$(detect_primary_iface)/speed ]]; then
            nic_speed=$(cat /sys/class/net/$(detect_primary_iface)/speed 2>/dev/null || echo 0)
            [[ "$nic_speed" =~ ^-?[0-9]+$ ]] || nic_speed=0
        fi
        local rtt_loss rtt loss
        rtt_loss=$(measure_rtt "$SERVER"); IFS='|' read -r rtt loss <<<"$rtt_loss"
        analyze_link "$state" "$nic_speed" "$rtt" "$loss"

        ok "单流最优组合已写入 ${C_CYAN}${STATE_FILE}${C_RESET} (jq '.best_congestion,.best_window,.best_cpu_local,.best_cpu_remote' 查看)"
        [[ $JSON_OUT -eq 1 ]] && echo "$state"
        return 0
    fi

    log "${C_BOLD}========== iperf3 基准测试 ==========${C_RESET}"
    log "目标: $SERVER:$PORT  方向: $DIRECTION  时长: ${DURATION}s × $REPEATS 次"

    # 单流基准
    log "${C_BOLD}单流基准 (用于多流提升比较)${C_RESET}"
    local single; single=$(bench_streams "$SERVER" "$PORT" 1 "$DURATION" "$REPEATS")
    local s_bw s_rr
    s_bw=$(jq -r '.bandwidth_mbps'    <<<"$single")
    s_rr=$(jq -r '.retrans_rate_pct'  <<<"$single")
    ok "单流: ${s_bw} Mbps, 重传率 ${s_rr}%"

    # 多流寻优 (内部从 1 流开始, 但我们已经测过单流, 仍然让算法走完, 因为它的复测是中位数)
    local optimal; optimal=$(find_optimal_parallel "$SERVER" "$PORT" "$DURATION" "$REPEATS" "$MAX_PARALLEL")

    # 合成 state.json
    local state
    state=$(jq -n \
        --arg ts "$(date -Iseconds)" \
        --arg server "$SERVER" --argjson port "$PORT" \
        --arg dir "$DIRECTION" --arg profile "$PROFILE" \
        --argjson single "$single" \
        --argjson opt "$optimal" \
        '{
            timestamp: $ts, server: $server, port: $port,
            direction: $dir, profile: $profile,
            single: $single,
            all: $opt.all, best: $opt.best
        }')
    echo "$state" > "$STATE_FILE"

    # 链路分析
    local nic_speed=0
    if [[ -r /sys/class/net/$(detect_primary_iface)/speed ]]; then
        nic_speed=$(cat /sys/class/net/$(detect_primary_iface)/speed 2>/dev/null || echo 0)
        [[ "$nic_speed" =~ ^-?[0-9]+$ ]] || nic_speed=0
    fi
    local rtt_loss rtt loss
    rtt_loss=$(measure_rtt "$SERVER")
    IFS='|' read -r rtt loss <<<"$rtt_loss"
    analyze_link "$state" "$nic_speed" "$rtt" "$loss"

    if [[ $JSON_OUT -eq 1 ]]; then
        echo "$state"
    fi
}

# 完整流程: detect → tune → remote_tune → bench
cmd_optimize() {
    require_root
    check_dependencies
    ensure_dirs

    [[ -z "$SERVER" ]] && die "--server IP 必填"

    log "${C_BOLD}========== iperf3-tune optimize ==========${C_RESET}"
    log "目标 server: $SERVER:$PORT"
    log "profile: $PROFILE  direction: $DIRECTION  duration: ${DURATION}s repeats: $REPEATS"
    log "发送端: ${C_BOLD}$(sender_label)${C_RESET}"
    if [[ "$DIRECTION" == "reverse" ]]; then
        if [[ -n "$SSH_HOST" ]]; then
            log "  → -R 下 server 是发送端, ${C_BOLD}server 端调优是重点${C_RESET} (sysctl 发送缓冲 / 拥塞算法 / 网卡 offload / 中断亲和)"
        else
            warn "  → -R 下 server 是发送端, 但未提供 --ssh-host: 只能调本机(接收端), 发挥有限。强烈建议加 --ssh-host 同步调 server"
        fi
    fi
    [[ -n "$SSH_HOST" ]] && log "远端 SSH: ${SSH_USER}@${SSH_HOST}:${SSH_PORT}"

    local -a _items=()
    mapfile -t _items < <(tuning_impact_items)
    [[ $DRY_RUN -eq 1 ]] && log "${C_BOLD}[dry-run] 预演 optimize, 以下修改不会真正执行${C_RESET}"
    confirm_or_die "即将修改本机${SSH_HOST:+及远端 ${SSH_HOST}}网络栈 (profile=${PROFILE}), 涉及:" "${_items[@]}"

    # 步骤 1/4: 检测
    log "${C_BOLD}━━━ 步骤 1/4: 本机瓶颈检测 ━━━${C_RESET}"
    local report; report=$(detect_all)
    print_report "$report"

    # 步骤 2/4: 本机 tune
    if [[ "$DIRECTION" == "reverse" ]]; then
        log "${C_BOLD}━━━ 步骤 2/4: 本机优化 (reverse 下本机是接收端, 次要) ━━━${C_RESET}"
    else
        log "${C_BOLD}━━━ 步骤 2/4: 本机优化 (forward 下本机是发送端, 重点) ━━━${C_RESET}"
    fi
    write_and_apply_sysctl "$PROFILE"
    apply_nic_tuning

    # 步骤 3/4: 远端同步
    if [[ "$DIRECTION" == "reverse" ]]; then
        log "${C_BOLD}━━━ 步骤 3/4: 远端 server 优化 (reverse 下 server 是发送端, 重点) ━━━${C_RESET}"
    else
        log "${C_BOLD}━━━ 步骤 3/4: 远端同步 ━━━${C_RESET}"
    fi
    if ! remote_tune; then
        warn "远端优化失败, 继续本地测试"
    fi

    # 步骤 4/4: 测试
    if [[ $DRY_RUN -eq 1 ]]; then
        log "${C_BOLD}━━━ 步骤 4/4: iperf3 基准测试 (dry-run 跳过) ━━━${C_RESET}"
        ok "dry-run 完成: 仅预演, 未修改本机/远端, 未跑测试"
        return 0
    fi
    log "${C_BOLD}━━━ 步骤 4/4: iperf3 基准测试 ━━━${C_RESET}"
    cmd_bench
}

cmd_rollback() {
    require_root

    if [[ ! -f "$SYSCTL_BACKUP" ]]; then
        warn "无备份 ($SYSCTL_BACKUP 不存在), 可能从未应用过"
    else
        log "回退 sysctl 配置"
        # 删除我们的配置
        rm -f "$SYSCTL_FILE"
        # 还原备份的值
        local k v
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            k=$(echo "$line" | awk -F' *= *' '{print $1}')
            v=$(echo "$line" | awk -F' *= *' '{print $2}')
            [[ "$v" == "__UNSET__" ]] && continue
            sysctl -w "${k}=${v}" >/dev/null 2>&1 || warn "  $k 还原失败"
        done < "$SYSCTL_BACKUP"
        ok "sysctl 已回退"
    fi

    if [[ -f "$NIC_BACKUP" ]]; then
        local iface mtu_old
        iface=$(jq -r '.iface' "$NIC_BACKUP")
        mtu_old=$(jq -r '.mtu // ""' "$NIC_BACKUP")
        if [[ -n "$mtu_old" && "$mtu_old" =~ ^[0-9]+$ ]]; then
            ip link set dev "$iface" mtu "$mtu_old" >/dev/null 2>&1 \
                && ok "  MTU 已还原为 $mtu_old" || warn "  MTU 还原失败"
        fi
        log "回退网卡 $iface 设置 (offload/ring 备份在 $NIC_BACKUP, 不全自动还原)"
        warn "  注: 部分 offload 改动不可逆 (lro), 重启 + 移除 $SYSCTL_FILE 是最干净的还原"
    fi

    # v2.4.0: 恢复 irqbalance
    command -v systemctl >/dev/null 2>&1 && systemctl start irqbalance >/dev/null 2>&1 || true

    # 远端
    if [[ -n "$SSH_HOST" ]]; then
        remote_rollback
    fi

    ok "回退完成"
}

cmd_status() {
    log "${C_BOLD}========== iperf3-tune 状态 ==========${C_RESET}"

    if [[ -f "$SYSCTL_FILE" ]]; then
        ok "sysctl 配置: ${C_CYAN}${SYSCTL_FILE}${C_RESET} 已应用"
        head -3 "$SYSCTL_FILE" >&2
    else
        warn "未应用 sysctl 优化"
    fi

    local cur_cc cur_qdisc
    cur_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
    cur_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)
    log "当前拥塞控制: ${C_BOLD}${cur_cc}${C_RESET}    qdisc: ${C_BOLD}${cur_qdisc}${C_RESET}"

    if [[ -f "$STATE_FILE" ]]; then
        log "最近一次测试结果:"
        jq -r '
            "  时间:      \(.timestamp)",
            "  服务端:    \(.server):\(.port)",
            "  方向:      \(.direction)",
            "  profile:   \(.profile)",
            "  单流:      \(.single.bandwidth_mbps) Mbps  (\(.single.retrans_rate_pct)% 重传)",
            "  最优配置:  \(.best.streams) 流  \(.best.bandwidth_mbps) Mbps  (\(.best.retrans_rate_pct)% 重传)"
        ' "$STATE_FILE" >&2
    else
        warn "未运行过 bench (无 $STATE_FILE)"
    fi

    if [[ -f "$PID_FILE" ]]; then
        local pid; pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            log "后台任务运行中: PID=$pid"
        else
            warn "PID 文件存在但进程已退出, 残留 $PID_FILE"
        fi
    fi
}

cmd_watch() {
    local pf="$PROGRESS_FILE"
    if [[ ! -f "$pf" ]]; then
        die "无进度文件 ($pf), 当前没有后台任务"
    fi
    log "实时观察 (Ctrl-C 退出):"
    while true; do
        clear
        jq -r '
            "iperf3-tune 进度  状态: \(.status)",
            "服务端: \(.server):\(.port)",
            "开始:   \(.started)",
            "更新:   \(.last_update // "—")",
            "",
            (.results[] | "  \(.streams) 流: \(.bandwidth_mbps // "测试中") Mbps  重传 \(.retransmits // "—") (\(.retrans_rate_pct // "—")%)  评分 \(.score // "—")")
        ' "$pf" 2>/dev/null
        [[ "$(jq -r '.status' "$pf")" == "finished" ]] && break
        sleep 3
    done
}

cmd_tail() {
    local latest
    latest=$(ls -t "${LOG_DIR}"/run-*.log 2>/dev/null | head -1)
    [[ -n "$latest" ]] || die "无后台日志"
    log "tail $latest"
    tail -f "$latest"
}

cmd_stop() {
    require_root
    if [[ ! -f "$PID_FILE" ]]; then
        die "无后台任务 ($PID_FILE 不存在)"
    fi
    local pid; pid=$(cat "$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
        log "停止后台任务 PID=$pid"
        kill -TERM "$pid" 2>/dev/null || true
        sleep 1
        kill -KILL "$pid" 2>/dev/null || true
    fi
    pkill -f "iperf3 -c" 2>/dev/null || true
    rm -f "$PID_FILE"
    # v2.7.0: 后台进程被强杀时可能来不及清理转存的密码文件, 这里兜底删除
    rm -f "${STATE_DIR}/.detach-ssh.pw" 2>/dev/null || true
    ok "已停止"
}

# 把命令放入后台, 脱离 SSH terminal
# v2.7.0:
#   - 修正参数重复 bug (此前会把命令名传两次, 导致后台进程因 "未知选项" 直接退出)
#   - 命令行明文密码 (--ssh-pass) / 交互密码 (--ssh-ask-pass) 一律转存为 600 文件,
#     后台进程改用 --ssh-pass-file, 避免在 ps / 进程列表里暴露明文
detach_to_background() {
    require_root
    ensure_dirs
    local logfile="${LOG_DIR}/run-$(date '+%Y%m%d-%H%M%S').log"
    log "后台运行, 日志: $logfile"
    log "查看进度: sudo $SCRIPT_NAME watch"
    log "跟随日志: sudo $SCRIPT_NAME tail"
    log "停止任务: sudo $SCRIPT_NAME stop"

    # 1) 去掉 --detach/-d 避免无限递归; 同时把明文密码相关参数剥离, 改走 600 文件
    local pwfile=""
    local captured_pass=""
    local skip_next=0
    local -a clean_args=()
    local a
    for a in "$@"; do
        if [[ $skip_next -eq 1 ]]; then
            captured_pass="$a"; skip_next=0; continue
        fi
        case "$a" in
            --detach|-d)     continue ;;
            --ssh-pass)      skip_next=1; continue ;;   # 丢弃明文密码值
            --ssh-ask-pass)  continue ;;                # 已在 parse_args 读入并存到 _SSH_PASS_TMP
            *)               clean_args+=("$a") ;;
        esac
    done

    # 2) 决定后台进程使用的密码文件 (若有密码)
    if [[ -n "$captured_pass" ]]; then
        pwfile="${STATE_DIR}/.detach-ssh.pw"
        ( umask 077; printf '%s' "$captured_pass" > "$pwfile" )
        chmod 600 "$pwfile"
        unset captured_pass
    elif [[ -n "${_SSH_PASS_TMP:-}" && -f "${_SSH_PASS_TMP}" ]]; then
        pwfile="${STATE_DIR}/.detach-ssh.pw"
        ( umask 077; cat "$_SSH_PASS_TMP" > "$pwfile" )
        chmod 600 "$pwfile"
    elif [[ -n "$SSH_PASS_FILE" ]]; then
        # 用户本来就给了 pass-file, 透传即可 (clean_args 已含)
        :
    fi
    if [[ -n "$pwfile" ]]; then
        clean_args+=(--ssh-pass-file "$pwfile")
    fi

    # 3) 后台运行。把 detach 临时密码文件路径经环境变量下发, 让子进程退出时自动清理。
    local env_prefix=""
    [[ -n "$pwfile" ]] && env_prefix="IPERF3_TUNE_DETACH_PWFILE=${pwfile@Q} "
    setsid nohup bash -c "
        echo \$\$ > '$PID_FILE'
        ${env_prefix}exec '$SCRIPT_PATH' ${clean_args[*]@Q} > '$logfile' 2>&1
    " </dev/null >/dev/null 2>&1 &
    disown
    sleep 1
    ok "已脱离 SSH terminal (PID 在 $PID_FILE)"
    exit 0
}

# ---------------------------------------------------------------------------
# 用法与参数解析
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
${C_BOLD}iperf3-tune v${VERSION}${C_RESET} — iperf3 高速低重传调优工具

用法:
  $SCRIPT_NAME <命令> [选项]

命令:
  detect              检测系统瓶颈 (不修改任何配置)
  tune                仅应用本机 sysctl + 网卡优化
  bench               仅运行 iperf3 测试 (不改系统)
  optimize            完整流程: detect → tune → remote_tune → bench
  rollback            回退本机及远端的 sysctl 配置
  status              查看当前优化状态与最近测试结果
  watch               实时查看后台任务进度
  tail                跟随后台任务日志
  stop                停止后台任务

测试参数:
  --server IP                  iperf3 服务端地址 [bench/optimize 必填]
  --port N                     iperf3 端口 (默认 5201)
  --time SECS                  单次测试时长 (默认 30)
  --repeats N                  每档重复次数 (默认 3)
  --max-parallel N             最大并发流 (默认 32)
  --direction reverse|forward  reverse=下行(-R, 默认), forward=上行
  --mss N                      估算重传率用 MSS (默认 1448)

调优参数:
  --profile NAME               balanced | aggressive | extreme (默认 aggressive)
  --congestion ALGO            TCP 拥塞控制 (默认 bbr, 可选 cubic 等)
  --retrans-threshold PCT      重传率超过此值时提前停止寻优 (默认 3.0)
  --retrans-penalty K          评分函数重传惩罚系数 (默认 10.0)

单流优化参数 (v2.4.0 新增):
  --single                     仅测单流 (等价 --max-parallel 1)
  --window SIZE                手动 TCP 窗口, 如 96M; 不填则按 RTT×带宽 (2.5×BDP) 自动
  --bandwidth MBIT             链路容量提示 (Mbit/s) 用于自动算窗口; 不填用 NIC 标称速率
  --mtu N                      设置网卡 MTU, 如 9000 开 jumbo frame (两端都需支持)
  --cpu N                      单流绑定的 本机 CPU 核; 不填自动取 NIC 所在 NUMA node
  --cpu-remote N               单流绑定的 远端 server CPU 核 (经 iperf3 -A n/m 下发)
  --no-zerocopy                关闭 iperf3 -Z 零拷贝 (默认开)

单流自动寻优 (v2.5.0 新增, 贪心顺序: 拥塞算法→窗口→CPU):
  --scan                       同时扫描 拥塞算法 + 窗口 + CPU, 自动选最优组合
  --scan-window                只扫描 TCP 窗口 (以 BDP 为锚的多个倍数)
  --scan-congestion            只扫描拥塞算法 (作用在发送端; -R 时即 server, 需 --ssh-host)
  --scan-cpu                   扫描 CPU 核, 两端都调 (发送端优先; 远端核需 --ssh-host 枚举)
  --window-list L              自定义窗口候选, 逗号分隔, 如 32M,64M,128M,256M
  --congestion-list L          自定义拥塞算法候选, 逗号分隔, 如 bbr,cubic,bbr2
  --scan-time SECS             扫描阶段每点时长 (默认 10, 比正式短以加速)
  --scan-repeats N             扫描阶段每点重复次数 (默认 1)

SSH 参数 (远端同步调优):
  --ssh-host HOST              远端 iperf3 服务端地址
  --ssh-user USER              SSH 用户 (默认 root)
  --ssh-port N                 SSH 端口 (默认 22)
  --ssh-key PATH               SSH 私钥 (★ 生产最推荐)
  --ssh-ask-pass               交互式输入 SSH 密码 (不进 history/argv/ps, 推荐)
  --ssh-pass-file PATH         从文件读 SSH 密码 (权限须为 600/400)
  --ssh-pass PASS              SSH 密码明文 (不推荐: 会进 history/ps/审计日志)

后台:
  -d, --detach                 把 bench/optimize 放到后台运行
                               (命令行/交互密码会自动转存 600 文件, 不暴露在 ps)

依赖与安全 (v2.7.0):
  --auto-install               允许脚本自动安装缺失依赖 (默认关闭, 生产更可控)
  --no-auto-install            显式禁用自动安装 (默认即如此)
  --dry-run                    预演: 打印将修改的 sysctl/网卡/远端动作, 但不实际执行
  --no-stop-irqbalance         调优时不停止 irqbalance

其他:
  -y, --yes                    非交互, 跳过确认 (无 tty 时改系统必须显式加它)
  -v, --verbose                详细日志
  --json                       JSON 输出
  -h, --help                   显示本帮助
  -V, --version                显示版本

典型示例:
  ${C_CYAN}# 仅检测 (只读, 不改系统)${C_RESET}
  sudo $SCRIPT_NAME detect

  ${C_CYAN}# 预演: 看看会改哪些东西, 但不真正执行 (生产先跑这个)${C_RESET}
  sudo $SCRIPT_NAME optimize --dry-run \\
      --server 1.2.3.4 --ssh-host 1.2.3.4 --ssh-key ~/.ssh/id_rsa \\
      --profile aggressive

  ${C_CYAN}# 单流打满 + 最低重传 (本版重点): 自动绑核 + BDP 窗口 + 零拷贝${C_RESET}
  sudo $SCRIPT_NAME optimize --single \\
      --server 1.2.3.4 \\
      --ssh-host 1.2.3.4 --ssh-user root --ssh-key ~/.ssh/id_rsa \\
      --profile aggressive

  ${C_CYAN}# 单流全自动寻优: 扫拥塞算法(server端)+窗口+CPU, 选最优组合${C_RESET}
  sudo $SCRIPT_NAME optimize --scan \\
      --server 1.2.3.4 \\
      --ssh-host 1.2.3.4 --ssh-user root --ssh-key ~/.ssh/id_rsa \\
      --profile aggressive

  ${C_CYAN}# 完整流程 + 后台 (推荐, 高速链路避免 SSH 断开)${C_RESET}
  sudo $SCRIPT_NAME optimize --detach --yes \\
      --server 1.2.3.4 \\
      --ssh-host 1.2.3.4 --ssh-user root --ssh-key ~/.ssh/id_rsa \\
      --profile aggressive

  ${C_CYAN}# 需要用密码时: 交互输入 (不进 history/ps), 而不是 --ssh-pass 明文${C_RESET}
  sudo $SCRIPT_NAME optimize \\
      --server 1.2.3.4 \\
      --ssh-host 1.2.3.4 --ssh-ask-pass \\
      --profile aggressive

  ${C_CYAN}# 查看进度 / 日志 / 停止 / 回退${C_RESET}
  sudo $SCRIPT_NAME watch
  sudo $SCRIPT_NAME tail
  sudo $SCRIPT_NAME stop
  sudo $SCRIPT_NAME rollback --yes

更多文档: https://github.com/lucifer988/iperf3
EOF
}

parse_args() {
    [[ $# -eq 0 ]] && { usage; exit 1; }

    CMD="$1"; shift

    case "$CMD" in
        detect|tune|bench|optimize|rollback|status|watch|tail|stop|help|--help|-h|version|--version|-V)
            ;;
        *)
            err "未知命令: $CMD"
            usage
            exit 1
            ;;
    esac

    [[ -t 0 ]] || INTERACTIVE=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --server)          SERVER="$2"; shift 2 ;;
            --port)            PORT="$2"; shift 2 ;;
            --time|--duration) DURATION="$2"; shift 2 ;;
            --repeats)         REPEATS="$2"; shift 2 ;;
            --max-parallel)    MAX_PARALLEL="$2"; shift 2 ;;
            --direction)       DIRECTION="$2"; shift 2 ;;
            --mss)             MSS="$2"; shift 2 ;;

            --profile)         PROFILE="$2"; shift 2 ;;
            --congestion)      CONGESTION="$2"; shift 2 ;;
            --retrans-threshold) RETRANS_THRESHOLD="$2"; shift 2 ;;
            --retrans-penalty)   RETRANS_PENALTY="$2"; shift 2 ;;

            --single)          SINGLE_ONLY=1; shift ;;
            --window)          WINDOW="$2"; shift 2 ;;
            --bandwidth)       BANDWIDTH="$2"; shift 2 ;;
            --mtu)             MTU="$2"; shift 2 ;;
            --cpu)             PIN_CPU="$2"; shift 2 ;;
            --cpu-remote)      REMOTE_PIN_CPU="$2"; shift 2 ;;
            --no-zerocopy)     ZEROCOPY=0; shift ;;

            --scan)            SCAN_ALL=1; SINGLE_ONLY=1; shift ;;
            --scan-window)     SCAN_WINDOW=1; SINGLE_ONLY=1; shift ;;
            --scan-congestion) SCAN_CONGESTION=1; SINGLE_ONLY=1; shift ;;
            --scan-cpu)        SCAN_CPU=1; SINGLE_ONLY=1; shift ;;
            --window-list)     WINDOW_LIST="$2"; shift 2 ;;
            --congestion-list) CONGESTION_LIST="$2"; shift 2 ;;
            --scan-time)       SCAN_TIME="$2"; shift 2 ;;
            --scan-repeats)    SCAN_REPEATS="$2"; shift 2 ;;

            --ssh-host)        SSH_HOST="$2"; shift 2 ;;
            --ssh-user)        SSH_USER="$2"; shift 2 ;;
            --ssh-port)        SSH_PORT="$2"; shift 2 ;;
            --ssh-key)         SSH_KEY="$2"; shift 2 ;;
            --ssh-pass)        SSH_PASS="$2"; shift 2 ;;
            --ssh-pass-file)   SSH_PASS_FILE="$2"; shift 2 ;;
            --ssh-ask-pass)    SSH_ASK_PASS=1; shift ;;

            -d|--detach)       DETACH=1; shift ;;
            -y|--yes)          ASSUME_YES=1; shift ;;
            -v|--verbose)      VERBOSE=1; shift ;;
            --json)            JSON_OUT=1; shift ;;
            --dry-run)         DRY_RUN=1; shift ;;
            --auto-install)    AUTO_INSTALL=1; shift ;;
            --no-auto-install) AUTO_INSTALL=0; shift ;;
            --no-stop-irqbalance) STOP_IRQBALANCE=0; shift ;;
            -h|--help)         usage; exit 0 ;;
            -V|--version)      echo "$VERSION"; exit 0 ;;
            --)                shift; break ;;
            *)
                err "未知选项: $1"
                exit 1
                ;;
        esac
    done

    # v2.7.0: 交互式读取 SSH 密码 (不进 shell history / argv / ps), 写入 600 临时文件
    if [[ $SSH_ASK_PASS -eq 1 ]]; then
        [[ -n "$SSH_PASS" ]] && warn "同时给了 --ssh-pass 和 --ssh-ask-pass, 以交互输入为准"
        local _p1
        if [[ ! -t 0 ]]; then
            die "--ssh-ask-pass 需要交互终端 (tty)"
        fi
        read -rsp "请输入远端 SSH 密码: " _p1; echo >&2
        [[ -n "$_p1" ]] || die "密码为空"
        _SSH_PASS_TMP="$(mktemp "${TMPDIR:-/tmp}/iperf3-tune.pw.XXXXXX")" || die "无法创建临时密码文件"
        chmod 600 "$_SSH_PASS_TMP"
        printf '%s' "$_p1" > "$_SSH_PASS_TMP"
        unset _p1
        SSH_PASS=""              # 不走环境变量
        SSH_PASS_FILE="$_SSH_PASS_TMP"
    fi

    # 命令行明文密码告警 (会进入 shell history / ps / 审计日志)
    if [[ -n "$SSH_PASS" ]]; then
        warn "检测到命令行明文 --ssh-pass: 可能被 shell history / ps / 审计系统记录"
        warn "  更安全的方式: --ssh-key (私钥) / --ssh-ask-pass (交互输入) / --ssh-pass-file (600 文件)"
    fi

    # 从 ssh-pass-file 读密码 (优先级低于 --ssh-pass)
    if [[ -z "$SSH_PASS" && -n "$SSH_PASS_FILE" ]]; then
        [[ -r "$SSH_PASS_FILE" ]] || die "无法读取 SSH 密码文件: $SSH_PASS_FILE"
        local perm
        perm=$(stat -c "%a" "$SSH_PASS_FILE" 2>/dev/null || echo "")
        if [[ "$perm" != "600" && "$perm" != "400" ]]; then
            warn "SSH 密码文件 $SSH_PASS_FILE 权限 $perm 不安全, 建议 chmod 600"
        fi
        # 注意: 用文件方式时, 密码不进环境变量, 直接交给 sshpass -f
    fi

    # 校验
    case "$PROFILE" in
        balanced|aggressive|extreme) ;;
        *) die "--profile 必须是 balanced|aggressive|extreme" ;;
    esac

    # v2.4.0: --single 仅测单流
    [[ $SINGLE_ONLY -eq 1 ]] && MAX_PARALLEL=1
    if [[ -n "$MTU" ]]; then
        [[ "$MTU" =~ ^[0-9]+$ ]] || die "--mtu 必须是正整数 (如 9000)"
    fi
    if [[ "$BANDWIDTH" != "0" ]]; then
        [[ "$BANDWIDTH" =~ ^[0-9]+$ ]] || die "--bandwidth 必须是整数 Mbit/s"
    fi
    # v2.5.0: 扫描参数校验
    [[ "$SCAN_TIME" =~ ^[0-9]+$ ]] || die "--scan-time 必须是正整数"
    (( SCAN_TIME < 3 )) && die "--scan-time 不能小于 3 秒"
    [[ "$SCAN_REPEATS" =~ ^[0-9]+$ ]] || die "--scan-repeats 必须是正整数"
    (( SCAN_REPEATS < 1 )) && die "--scan-repeats 不能小于 1"
    case "$DIRECTION" in
        reverse|forward) ;;
        *) die "--direction 必须是 reverse|forward" ;;
    esac
    [[ "$DURATION" =~ ^[0-9]+$ ]] || die "--time 必须是正整数"
    (( DURATION < 5 )) && die "--time 不能小于 5 秒"
    [[ "$REPEATS" =~ ^[0-9]+$ ]] || die "--repeats 必须是正整数"
    (( REPEATS < 1 )) && die "--repeats 不能小于 1"

    # 防止函数末尾的 (( ... )) 在表达式为 0 时返回 1, 触发 ERR trap
    return 0
}

# ---------------------------------------------------------------------------
# main (sourced 时不执行)
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    case "$CMD" in
        help|--help|-h)       usage; exit 0 ;;
        version|--version|-V) echo "$VERSION"; exit 0 ;;
    esac

    # v2.7.0: 启动期统一环境检查 (OS / bash / root / sysfs / procfs)
    preflight_check "$CMD"

    # 后台模式 (注意: "$@" 已包含命令名, 不再额外传 $CMD 以免重复)
    if [[ $DETACH -eq 1 ]]; then
        case "$CMD" in
            bench|optimize) detach_to_background "$@" ;;
            *) die "--detach 只能用于 bench / optimize" ;;
        esac
    fi

    # PID file (仅 bench/optimize 在前台跑时)。EXIT 时同时清理 PID 与临时密码文件。
    if [[ "$CMD" == "bench" || "$CMD" == "optimize" ]]; then
        ensure_dirs
        echo "$$" > "$PID_FILE"
        trap 'rm -f "$PID_FILE"; _cleanup_tmp' EXIT
    fi

    case "$CMD" in
        detect)   cmd_detect ;;
        tune)     cmd_tune ;;
        bench)    cmd_bench ;;
        optimize) cmd_optimize ;;
        rollback) cmd_rollback ;;
        status)   cmd_status ;;
        watch)    cmd_watch ;;
        tail)     cmd_tail ;;
        stop)     cmd_stop ;;
    esac
}

# 仅当作为脚本运行时执行 main; 被 iperf3-tuned.sh source 时跳过
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
