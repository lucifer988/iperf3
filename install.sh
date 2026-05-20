#!/usr/bin/env bash
#
# install.sh — iperf3-tune 一键安装
#
# 安装目标:
#   - /usr/local/sbin/iperf3-tune       (主脚本)
#   - /usr/local/sbin/iperf3-tuned      (daemon 脚本)
#   - /etc/iperf3-tune/                 (配置目录)
#   - /var/lib/iperf3-tune/             (状态目录)
#   - /var/log/iperf3-tune/             (日志目录)
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

[[ $EUID -eq 0 ]] || die "需要 root: sudo $0 $*"

# 1) 检测系统
say "检测系统..."
OS_ID="unknown"; OS_VER="unknown"
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VER="${VERSION_ID:-unknown}"
fi
echo "    OS:    $OS_ID $OS_VER"
echo "    Arch:  $(uname -m)"
echo "    Kernel: $(uname -r)"
echo "    CPU:   $(nproc) cores"
echo "    Mem:   $(awk '/MemTotal/ {printf "%.1f GB", $2/1024/1024}' /proc/meminfo)"

# 2) 安装依赖
say "安装依赖..."
DEPS_DEB="jq iperf3 ethtool iproute2 sysstat bc tar"
DEPS_RPM="jq iperf3 ethtool iproute sysstat bc tar"

case "$OS_ID" in
    debian|ubuntu|raspbian|linuxmint|kali)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        # shellcheck disable=SC2086
        apt-get install -y -q $DEPS_DEB
        ;;
    centos|rhel|rocky|almalinux|fedora|amzn)
        if command -v dnf >/dev/null 2>&1; then
            # shellcheck disable=SC2086
            dnf install -y -q epel-release || true
            # shellcheck disable=SC2086
            dnf install -y -q $DEPS_RPM
        else
            # shellcheck disable=SC2086
            yum install -y -q epel-release || true
            # shellcheck disable=SC2086
            yum install -y -q $DEPS_RPM
        fi
        ;;
    *)
        warn "未知发行版 ($OS_ID), 跳过自动安装依赖"
        warn "请手动确保安装了: $DEPS_DEB"
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
        echo "    BBR: 可用"
    else
        warn "    BBR 模块加载了但不在 available 列表里, 可能内核版本太老"
    fi
else
    warn "    BBR 模块加载失败 (内核 < 4.9 ?), profile 仍可用但拥塞控制会回退"
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
    echo "    iperf3-tune: OK"
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
  sudo iperf3-tuned init     # 交互式配置
  sudo iperf3-tuned install  # 安装 systemd timer

  ${C_BOLD}# 5) 不满意?随时回退${C_RESET}
  sudo iperf3-tune rollback

profile 三档区别:
  - balanced   : 64MB 缓冲区,  适合 1G/2.5G 链路
  - aggressive : 256MB 缓冲区, 适合 10G 链路 (推荐)
  - extreme    : 1GB 缓冲区,   适合 25G+ 或长肥管道, 业务影响显著

EOF
