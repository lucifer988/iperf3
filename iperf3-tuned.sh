#!/usr/bin/env bash
#
# iperf3-tuned.sh — 定时任务 / 金丝雀监控
#
# 通过 source iperf3-tune.sh 复用所有函数
# 由 systemd timer (默认每周日 22:00) 触发
#
# 子命令:
#   init        初次配置, 写 /etc/iperf3-tune/config.json
#   install     安装 systemd timer
#   uninstall   卸载 systemd timer
#   run         立即跑一次完整流程
#   canary      金丝雀检查 (每 6 小时由独立 timer 调用)
#   status      状态
#

set -Eeuo pipefail

# Source 主脚本 (仅加载函数, 不跑 main)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_SCRIPT="${SCRIPT_DIR}/iperf3-tune.sh"
[[ -f "$MAIN_SCRIPT" ]] || { echo "找不到 $MAIN_SCRIPT" >&2; exit 1; }
# shellcheck source=./iperf3-tune.sh
source "$MAIN_SCRIPT"

readonly CONFIG_FILE="${CONFIG_DIR}/config.json"
readonly BASELINE_FILE="${STATE_DIR}/baseline.json"
readonly CANARY_FILE="${STATE_DIR}/canary.json"
readonly DAEMON_LOG="${LOG_DIR}/daemon.log"

readonly SYSTEMD_SERVICE="/etc/systemd/system/iperf3-tuned.service"
readonly SYSTEMD_TIMER="/etc/systemd/system/iperf3-tuned.timer"
readonly SYSTEMD_CANARY_SERVICE="/etc/systemd/system/iperf3-tuned-canary.service"
readonly SYSTEMD_CANARY_TIMER="/etc/systemd/system/iperf3-tuned-canary.timer"

setup_daemon_log() {
    ensure_dirs
    exec 2> >(tee -a "$DAEMON_LOG" >&2)
}

read_config() {
    [[ -f "$CONFIG_FILE" ]] || die "未初始化, 先运行: $0 init ..."
    SERVER=$(jq -r '.server' "$CONFIG_FILE")
    PORT=$(jq -r '.port // 5201' "$CONFIG_FILE")
    DURATION=$(jq -r '.duration // 30' "$CONFIG_FILE")
    REPEATS=$(jq -r '.repeats // 3' "$CONFIG_FILE")
    MAX_PARALLEL=$(jq -r '.max_parallel // 32' "$CONFIG_FILE")
    PROFILE=$(jq -r '.profile // "aggressive"' "$CONFIG_FILE")
    SSH_HOST=$(jq -r '.ssh_host // ""' "$CONFIG_FILE")
    SSH_USER=$(jq -r '.ssh_user // "root"' "$CONFIG_FILE")
    SSH_KEY=$(jq -r '.ssh_key // ""' "$CONFIG_FILE")
    SSH_PASS=$(jq -r '.ssh_pass // ""' "$CONFIG_FILE")
    SSH_PORT=$(jq -r '.ssh_port // 22' "$CONFIG_FILE")
}

cmd_init() {
    require_root
    ensure_dirs

    log "${C_BOLD}初始化 iperf3-tuned 配置${C_RESET}"

    local server port duration repeats profile
    local ssh_host ssh_user ssh_key ssh_pass auth_choice

    if [[ $INTERACTIVE -eq 1 ]]; then
        read -rp "iperf3 服务端 IP: " server
        read -rp "iperf3 端口 [5201]: " port
        read -rp "单次测试时长秒 [30]: " duration
        read -rp "每档重复次数 [3]: " repeats
        read -rp "profile (balanced/aggressive/extreme) [aggressive]: " profile
        read -rp "远端 SSH 主机 IP (回车跳过远端同步): " ssh_host
        if [[ -n "$ssh_host" ]]; then
            read -rp "  SSH 用户 [root]: " ssh_user
            read -rp "  认证方式 [1=密码 2=私钥] [1]: " auth_choice
            if [[ "$auth_choice" == "2" ]]; then
                read -rp "  SSH 私钥路径 [~/.ssh/id_rsa]: " ssh_key
                [[ -z "$ssh_key" ]] && ssh_key="$HOME/.ssh/id_rsa"
            else
                read -rsp "  SSH 密码: " ssh_pass
                echo
            fi
        fi
    else
        server="$SERVER"; port="$PORT"; duration="$DURATION"; repeats="$REPEATS"
        profile="$PROFILE"; ssh_host="$SSH_HOST"; ssh_user="$SSH_USER"
        ssh_key="$SSH_KEY"; ssh_pass="$SSH_PASS"
    fi

    [[ -z "$server" ]] && die "server 不能为空"
    port="${port:-5201}"
    duration="${duration:-30}"
    repeats="${repeats:-3}"
    profile="${profile:-aggressive}"
    ssh_user="${ssh_user:-root}"

    jq -n \
        --arg server "$server" --argjson port "$port" \
        --argjson duration "$duration" --argjson repeats "$repeats" \
        --argjson max_parallel 32 --arg profile "$profile" \
        --arg ssh_host "$ssh_host" --arg ssh_user "$ssh_user" \
        --arg ssh_key "$ssh_key" --arg ssh_pass "$ssh_pass" \
        --argjson ssh_port 22 \
        '{server:$server, port:$port, duration:$duration, repeats:$repeats,
          max_parallel:$max_parallel, profile:$profile,
          ssh_host:$ssh_host, ssh_user:$ssh_user,
          ssh_key:$ssh_key, ssh_pass:$ssh_pass, ssh_port:$ssh_port}' \
        > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"

    ok "配置已写入 $CONFIG_FILE (权限 600)"
    if [[ -n "$ssh_pass" ]]; then
        warn "密码以明文存储于 $CONFIG_FILE, 请确认只有 root 可读"
    fi
    log "运行 '$0 install' 安装定时任务"
}

cmd_run() {
    require_root
    setup_daemon_log
    read_config
    log "${C_BOLD}========== 定时任务触发, 时间 $(date) ==========${C_RESET}"

    # v2.7.0: 守护进程在无 tty 环境运行, 显式跳过交互确认 (等价 --yes)
    ASSUME_YES=1

    cmd_optimize

    # v2.9.0: 仅在结果有效 (非 failed) 时更新 baseline, 避免失败结果覆盖已知良好基线
    if [[ -f "$STATE_FILE" ]] && [[ "$(jq -r '.status // "ok"' "$STATE_FILE" 2>/dev/null)" != "failed" ]]; then
        cp "$STATE_FILE" "$BASELINE_FILE"
        ok "baseline 已保存到 $BASELINE_FILE"
    else
        warn "本次优化失败或无有效结果, 保留原 baseline 不更新"
    fi
}

cmd_canary() {
    require_root
    setup_daemon_log
    read_config

    if [[ ! -f "$BASELINE_FILE" ]]; then
        warn "无 baseline, 跳过 canary"
        return 0
    fi

    log "${C_BOLD}========== 金丝雀检查 $(date) ==========${C_RESET}"

    local base_streams base_bw base_rr
    base_streams=$(jq -r '.best.streams // 4' "$BASELINE_FILE")
    base_bw=$(jq -r '.best.bandwidth_mbps // 0' "$BASELINE_FILE")
    base_rr=$(jq -r '.best.retrans_rate_pct // 0' "$BASELINE_FILE")
    log "Baseline: ${base_streams} 流, ${base_bw} Mbps, 重传率 ${base_rr}%"

    local cur; cur=$(bench_streams "$SERVER" "$PORT" "$base_streams" 10 1)
    local cur_bw cur_rr
    cur_bw=$(jq -r '.bandwidth_mbps' <<<"$cur")
    cur_rr=$(jq -r '.retrans_rate_pct' <<<"$cur")
    log "当前:     ${base_streams} 流, ${cur_bw} Mbps, 重传率 ${cur_rr}%"

    local bw_drop_pct rt_inc_pct
    bw_drop_pct=$(awk -v a="$base_bw" -v b="$cur_bw" \
        'BEGIN {if (a+0==0){print 0;exit} printf "%.1f", (a-b)/a*100}')
    rt_inc_pct=$(awk -v a="$base_rr" -v b="$cur_rr" \
        'BEGIN {if (a+0==0){if(b+0>0.5){print 100}else{print 0};exit} printf "%.1f", (b-a)/a*100}')
    log "带宽下降: ${bw_drop_pct}%  重传增加: ${rt_inc_pct}%"

    local check; check=$(jq -n \
        --arg ts "$(date -Iseconds)" \
        --arg bw "$cur_bw" --arg rr "$cur_rr" \
        --arg drop "$bw_drop_pct" --arg inc "$rt_inc_pct" \
        '{timestamp:$ts, bandwidth_mbps:($bw|tonumber), retrans_rate_pct:($rr|tonumber),
          bw_drop_pct:($drop|tonumber), retrans_increase_pct:($inc|tonumber)}')
    if [[ -f "$CANARY_FILE" ]]; then
        jq --argjson c "$check" '.checks += [$c]' "$CANARY_FILE" > "${CANARY_FILE}.tmp"
        mv "${CANARY_FILE}.tmp" "$CANARY_FILE"
    else
        jq -n --argjson c "$check" '{start_time: now, checks: [$c]}' > "$CANARY_FILE"
    fi

    local should_rollback=0
    if num_gt "$bw_drop_pct" 20; then
        warn "带宽下降 ${bw_drop_pct}% > 20%, 触发回退"
        should_rollback=1
    fi
    if num_gt "$rt_inc_pct" 100 && num_gt "$cur_rr" 0.5; then
        warn "重传率增加 ${rt_inc_pct}% > 100%, 触发回退"
        should_rollback=1
    fi

    if [[ $should_rollback -eq 1 ]]; then
        cmd_rollback
        mv "$BASELINE_FILE" "${BASELINE_FILE}.failed" 2>/dev/null || true
        return 1
    fi
    ok "金丝雀检查通过"
}

cmd_install_timer() {
    require_root
    # v2.9.0: 非 systemd 系统明确报错, 而非中途 systemctl 失败
    have_systemd || die "未检测到 systemd (无 systemctl 或 /run/systemd/system)。本守护的定时任务依赖 systemd timer。
  在 OpenRC/Alpine、SysVinit、runit 等非 systemd 系统上, 请改用 cron 调度, 例如:
    # /etc/crontab 每周日 22:00 跑一次 optimize
    0 22 * * 0 root ${MAIN_SCRIPT} optimize --server <IP> --yes >> ${DAEMON_LOG} 2>&1"
    [[ -f "$CONFIG_FILE" ]] || die "请先运行 '$0 init'"

    cat > "$SYSTEMD_SERVICE" <<EOF
[Unit]
Description=iperf3-tuned scheduled optimization
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_DIR}/iperf3-tuned.sh run
StandardOutput=append:${DAEMON_LOG}
StandardError=append:${DAEMON_LOG}
EOF

    cat > "$SYSTEMD_TIMER" <<EOF
[Unit]
Description=Weekly iperf3-tuned optimization

[Timer]
OnCalendar=Sun *-*-* 22:00:00
Persistent=true
RandomizedDelaySec=10min

[Install]
WantedBy=timers.target
EOF

    cat > "$SYSTEMD_CANARY_SERVICE" <<EOF
[Unit]
Description=iperf3-tuned canary check
After=network-online.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_DIR}/iperf3-tuned.sh canary
StandardOutput=append:${DAEMON_LOG}
StandardError=append:${DAEMON_LOG}
EOF

    cat > "$SYSTEMD_CANARY_TIMER" <<EOF
[Unit]
Description=Canary check every 6 hours

[Timer]
OnUnitActiveSec=6h
OnBootSec=1h

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now iperf3-tuned.timer
    systemctl enable --now iperf3-tuned-canary.timer
    ok "systemd timer 已启用"
    systemctl list-timers | grep iperf3 >&2 || true
}

cmd_uninstall_timer() {
    require_root
    if ! have_systemd; then
        warn "未检测到 systemd, 跳过 systemd timer 卸载 (本机可能从未安装过)"
        rm -f "$SYSTEMD_SERVICE" "$SYSTEMD_TIMER" \
              "$SYSTEMD_CANARY_SERVICE" "$SYSTEMD_CANARY_TIMER" 2>/dev/null || true
        ok "已清理残留 unit 文件 (若有)"
        return 0
    fi
    systemctl disable --now iperf3-tuned.timer iperf3-tuned-canary.timer 2>/dev/null || true
    rm -f "$SYSTEMD_SERVICE" "$SYSTEMD_TIMER" \
          "$SYSTEMD_CANARY_SERVICE" "$SYSTEMD_CANARY_TIMER"
    systemctl daemon-reload
    ok "systemd timer 已卸载"
}

cmd_daemon_status() {
    log "${C_BOLD}========== daemon 状态 ==========${C_RESET}"
    if ! have_systemd; then
        warn "未检测到 systemd: 定时任务功能不可用 (本机非 systemd)"
        [[ -f "$CONFIG_FILE" ]] && log "配置: $(jq -c '.' "$CONFIG_FILE")"
        cmd_status
        return 0
    fi
    if systemctl is-enabled iperf3-tuned.timer >/dev/null 2>&1; then
        ok "主 timer:  已启用"
        systemctl list-timers iperf3-tuned.timer --no-pager 2>/dev/null | grep -v "^$" >&2 || true
    else
        warn "主 timer 未安装 (运行 'install')"
    fi
    if systemctl is-enabled iperf3-tuned-canary.timer >/dev/null 2>&1; then
        ok "canary timer: 已启用"
    fi
    [[ -f "$CONFIG_FILE" ]] && log "配置: $(jq -c '.' "$CONFIG_FILE")"
    [[ -f "$BASELINE_FILE" ]] && log "baseline 存在"
    [[ -f "$CANARY_FILE" ]] && {
        log "金丝雀检查记录:"
        jq -r '.checks[-5:][] | "  \(.timestamp): \(.bandwidth_mbps) Mbps, 重传率 \(.retrans_rate_pct)%, 跌幅 \(.bw_drop_pct)%"' "$CANARY_FILE" >&2 2>/dev/null || true
    }
    cmd_status
}

case "${1:-help}" in
    init)
        # 注意: 主脚本 parse_args 的命令白名单里没有 init, 直接 `parse_args init`
        # 会报 "未知命令: init"。这里用合法占位命令 detect 走完选项解析与校验,
        # 再把 CMD 修正回 init 供 cmd_init 使用 (cmd_init 只需要被解析到的全局变量)。
        shift
        parse_args detect "$@"
        CMD="init"
        cmd_init
        ;;
    install)   cmd_install_timer ;;
    uninstall) cmd_uninstall_timer ;;
    run)       cmd_run ;;
    canary)    cmd_canary ;;
    rollback)  shift; parse_args rollback "$@"; cmd_rollback ;;
    status)    cmd_daemon_status ;;
    help|-h|--help|*)
        cat <<EOF
iperf3-tuned — 定时任务 / 金丝雀监控

用法: $0 <command> [options]

命令:
  init [...]    初始化配置 (写 $CONFIG_FILE)
  install       安装 systemd timer (主任务每周日 22:00, canary 每 6h)
  uninstall     卸载 systemd timer
  run           立即跑一次完整 optimize 流程
  canary        手动触发一次金丝雀检查
  rollback      回退本机+远端
  status        显示状态

init 可接受全部 iperf3-tune.sh 的选项, 例如:
  $0 init --server 1.2.3.4 --port 5201 --profile aggressive --yes
或者交互式:
  $0 init
EOF
        ;;
esac
