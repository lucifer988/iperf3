#!/usr/bin/env bash
#
# install.sh — iperf3-tune 一键安装
#
# 安装目标:
#   - /usr/local/sbin/iperf3-tune    (主脚本)
#   - /usr/local/sbin/iperf3-tuned   (daemon 脚本)
#   - /etc/iperf3-tune/              (配置目录)
#   - /var/lib/iperf3-tune/          (状态目录)
#   - /var/log/iperf3-tune/          (日志目录)
#
# 支持发行版:
#   - Debian / Ubuntu / Mint / Kali / Pop / Deepin
#   - RHEL / CentOS / Rocky / AlmaLinux / Fedora / Amazon Linux / Oracle Linux / openEuler
#   - Arch / Manjaro / EndeavourOS / Garuda
#   - Alpine
#   - openSUSE / SLES
#
# 不会自动启用 systemd timer, 装完手动跑:
#   sudo iperf3-tuned init
#   sudo iperf3-tuned install
#

set -Eeuo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/sbin}"

if [[ -t 1 ]]; then
    C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'; C_RED=$'\033[0;31m'
    C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
    C_GREEN=""; C_YELLOW=""; C_RED=""; C_BOLD=""; C_RESET=""
fi

say()  { printf '%s==>%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
warn() { printf '%s!! %s%s\n' "${C_YELLOW}" "$*" "${C_RESET}"; }
die()  { printf '%sERROR:%s %s\n' "${C_RED}" "${C_RESET}" "$*"; exit 1; }

[[ "$(uname -s)" == "Linux" ]] || die "本工具依赖 sysctl / ethtool / procfs / sysfs, 仅支持 Linux (当前: $(uname -s))"
[[ $EUID -eq 0 ]] || die "需要 root: sudo $0 $*"

# 1) 检测系统
say "检测系统..."
OS_ID="unknown"; OS_VER="unknown"; OS_LIKE=""
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VER="${VERSION_ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"
fi
echo "  OS:     $OS_ID $OS_VER"
echo "  Arch:   $(uname -m)"
echo "  Kernel: $(uname -r)"
echo "  CPU:    $(nproc) cores"
echo "  Mem:    $(awk '/MemTotal/ {printf "%.1f GB", $2/1024/1024}' /proc/meminfo)"

# 2) 选包名 + 安装
say "安装依赖..."

install_with_apt() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -q --no-install-recommends \
        jq iperf3 ethtool iproute2 sysstat bc tar iputils-ping
}
install_with_dnf() {
    dnf install -y -q epel-release 2>/dev/null || true
    dnf install -y -q jq iperf3 ethtool iproute sysstat bc tar iputils
}
install_with_yum() {
    yum install -y -q epel-release 2>/dev/null || true
    yum install -y -q jq iperf3 ethtool iproute sysstat bc tar iputils
}
install_with_pacman() {
    pacman -Sy --noconfirm --needed jq iperf3 ethtool iproute2 sysstat bc tar iputils
}
install_with_apk() {
    apk update >/dev/null 2>&1 || true
    apk add --no-cache jq iperf3 ethtool iproute2 sysstat bc tar iputils-ping
}
install_with_zypper() {
    zypper --non-interactive refresh >/dev/null 2>&1 || true
    zypper --non-interactive install --no-recommends \
        jq iperf3 ethtool iproute2 sysstat bc tar iputils
}

# 优先按 ID 选择, 不识别则按 ID_LIKE 兜底
id_lower="$(echo "$OS_ID" | tr '[:upper:]' '[:lower:]')"
like_lower="$(echo "$OS_LIKE" | tr '[:upper:]' '[:lower:]')"

case "$id_lower" in
    debian|ubuntu|raspbian|linuxmint|kali|elementary|pop|deepin|zorin|mx|parrot|tuxedo|neon|peppermint|lmde)
        install_with_apt
        ;;
    centos|rhel|rocky|almalinux|ol|cloudlinux|scientific|virtuozzo|euleros|openeuler)
        if command -v dnf >/dev/null 2>&1; then install_with_dnf
        else install_with_yum; fi
        ;;
    fedora)
        install_with_dnf
        ;;
    amzn)
        if command -v dnf >/dev/null 2>&1; then install_with_dnf
        else install_with_yum; fi
        ;;
    arch|manjaro|endeavouros|garuda|artix|arcolinux|cachyos)
        install_with_pacman
        ;;
    alpine|postmarketos)
        install_with_apk
        ;;
    opensuse-leap|opensuse-tumbleweed|opensuse|sles|sled)
        install_with_zypper
        ;;
    *)
        # 按 ID_LIKE 兜底
        case "$like_lower" in
            *debian*|*ubuntu*) install_with_apt ;;
            *rhel*|*fedora*|*centos*)
                if command -v dnf >/dev/null 2>&1; then install_with_dnf
                else install_with_yum; fi
                ;;
            *arch*)  install_with_pacman ;;
            *suse*)  install_with_zypper ;;
            *)
                # 按可用工具二级兜底
                if command -v apt-get >/dev/null 2>&1; then install_with_apt
                elif command -v dnf >/dev/null 2>&1; then install_with_dnf
                elif command -v yum >/dev/null 2>&1; then install_with_yum
                elif command -v pacman >/dev/null 2>&1; then install_with_pacman
                elif command -v apk >/dev/null 2>&1; then install_with_apk
                elif command -v zypper >/dev/null 2>&1; then install_with_zypper
                else
                    warn "未识别的发行版 ($OS_ID), 也找不到已知包管理器"
                    warn "请手动安装: jq iperf3 ethtool iproute2 sysstat bc tar"
                fi
                ;;
        esac
        ;;
esac

# 3) 检查关键依赖
MISSING=()
for cmd in jq iperf3 ethtool ip sysctl awk; do
    command -v "$cmd" >/dev/null 2>&1 || MISSING+=("$cmd")
done
[[ ${#MISSING[@]} -gt 0 ]] && die "依赖缺失: ${MISSING[*]}"

# 4) 检查 BBR 内核支持
say "检查 BBR 支持..."
if modprobe tcp_bbr 2>/dev/null; then
    if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        echo "  BBR: 可用"
    else
        warn "  BBR 模块加载了但不在 available 列表里, 可能内核版本太老"
    fi
else
    warn "  BBR 模块加载失败 (内核 < 4.9 ?), profile 仍可用但拥塞控制会回退"
fi

# 5) 创建目录
say "创建目录..."
mkdir -p /etc/iperf3-tune /var/lib/iperf3-tune /var/log/iperf3-tune
chmod 700 /etc/iperf3-tune /var/lib/iperf3-tune
chmod 755 /var/log/iperf3-tune

# 6) 安装脚本
say "安装脚本到 ${INSTALL_DIR}/"
install -m 0755 "${SRC_DIR}/iperf3-tune.sh"  "${INSTALL_DIR}/iperf3-tune"
install -m 0755 "${SRC_DIR}/iperf3-tuned.sh" "${INSTALL_DIR}/iperf3-tuned"
# daemon 脚本会 source 主脚本, 它通过 $SCRIPT_DIR 寻找, 我们打个兼容符号
ln -sf "${INSTALL_DIR}/iperf3-tune" "${INSTALL_DIR}/iperf3-tune.sh" 2>/dev/null || true

# 7) 验证
say "验证安装..."
if "${INSTALL_DIR}/iperf3-tune" --help >/dev/null 2>&1; then
    echo "  iperf3-tune: OK"
else
    die "iperf3-tune 调用失败"
fi

# 8) 结束
cat <<EOF

${C_BOLD}========== 安装完成 ==========${C_RESET}

下一步:

${C_BOLD}# 1) 仅检测当前系统瓶颈 (不修改任何东西)${C_RESET}
  sudo iperf3-tune detect

${C_BOLD}# 2) 仅本机调优, 不跑测试${C_RESET}
  sudo iperf3-tune tune --profile aggressive

${C_BOLD}# 3) 完整流程: 检测 + 调优 + (远端同步) + 测试${C_RESET}
  sudo iperf3-tune optimize \\
      --server 1.2.3.4 \\
      --ssh-host 1.2.3.4 --ssh-key ~/.ssh/id_rsa \\
      --profile aggressive --time 30 --repeats 3

${C_BOLD}# 4) 启用每周自动重新优化 + 6 小时金丝雀监控${C_RESET}
  sudo iperf3-tuned init        # 交互式配置
  sudo iperf3-tuned install     # 安装 systemd timer

${C_BOLD}# 5) 不满意?随时回退${C_RESET}
  sudo iperf3-tune rollback

profile 三档区别:
  - balanced   : 64MB 缓冲区,  适合 1G/2.5G 链路
  - aggressive : 256MB 缓冲区, 适合 10G 链路 (推荐)
  - extreme    : 1GB 缓冲区,   适合 25G+ 或长肥管道, 业务影响显著

v2.3.0 新特性:
  ★ 远端 SSH 同步调优时, 缺失依赖会自动安装 (apt/dnf/yum/pacman/apk/zypper)
  ★ aggressive profile 针对单流 iperf3 -R 优化
    (放宽 tcp_notsent_lowat / tcp_limit_output_bytes)
EOF
