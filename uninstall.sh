#!/usr/bin/env bash
#
# uninstall.sh — 完整卸载 iperf3-tune
#
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "需要 root: sudo $0 $*" >&2; exit 1; }

INSTALL_DIR="${INSTALL_DIR:-/usr/local/sbin}"

echo "==> 停止并卸载 systemd timer..."
systemctl disable --now iperf3-tuned.timer 2>/dev/null || true
systemctl disable --now iperf3-tuned-canary.timer 2>/dev/null || true
rm -f /etc/systemd/system/iperf3-tuned*.service \
      /etc/systemd/system/iperf3-tuned*.timer
systemctl daemon-reload || true

echo "==> 回退 sysctl 优化..."
if [[ -x "${INSTALL_DIR}/iperf3-tune" ]]; then
    "${INSTALL_DIR}/iperf3-tune" rollback || true
fi

echo "==> 删除脚本..."
rm -f "${INSTALL_DIR}/iperf3-tune" \
      "${INSTALL_DIR}/iperf3-tune.sh" \
      "${INSTALL_DIR}/iperf3-tuned"

echo "==> 保留以下目录 (含配置/历史数据), 如需彻底清理请手动 rm:"
echo "    /etc/iperf3-tune/"
echo "    /var/lib/iperf3-tune/"
echo "    /var/log/iperf3-tune/"
echo "    /etc/sysctl.d/99-iperf3-tune.conf  (rollback 后已自动删除)"

echo "==> 卸载完成"
