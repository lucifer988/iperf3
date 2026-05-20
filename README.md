# iperf3-tune

iperf3 高速低重传优化工具 (v2)。

相比原版 `iperf3-enhanced`,本工程做了一次完整重写,核心目标只剩两个:**iperf3 测得带宽更高**、**重传率更低**。其他考量(业务无感、最小影响)被显式放弃,因此调优可以更激进。

---

## 与原版对比

| 项目 | 原版 v1 | v2 (本工程) |
|---|---|---|
| 文件数 | 7 个独立脚本 | 2 个脚本 + 1 个安装 + 1 个卸载 |
| 函数间传值 | `\|` 分隔字符串(含中文 + 数字)易碎 | JSON + `jq` |
| awk 调用 | `awk "BEGIN { ... $var }"` 注入风险 | `awk -v` 全量 -v 传参 |
| ethtool 解析 | `getline; getline; getline` 固定行偏移 | 段头定位 + 字段名匹配 |
| 网卡探测 | `ip route get 8.8.8.8` 一招鲜 | 三级 fallback (默认路由 v4/v6/物理 up) |
| SSH 密码 | `sshpass` 命令行明文 | 优先 SSH key,密码路径加 deprecation |
| 寻优算法 | 取最高带宽,5% 增益就停 | 评分函数 `bw × (1 − k × retrans_rate)`,可调权重 |
| 测试稳定性 | 单次结果即采纳 | 每档跑 N 次取中位数 (默认 3) |
| sysctl 回退 | 删配置文件 + `sysctl --system` | 完整 backup 每一个 key 当前值,精确还原 |
| daemon 非交互 | `read -p` 在 cron 下静默走 else | `-t 0` 检测 + `--yes` |
| 已知 bug | README 里列了 11 个 | 同类问题已系统性消除 |

---

## 安装

```bash
git clone <repo> iperf3-tune
cd iperf3-tune
sudo ./install.sh
```

安装脚本会:

- 检测发行版,自动 `apt`/`yum` 装齐 `jq iperf3 ethtool iproute2 sysstat bc`
- 检查 BBR 模块
- 把 `iperf3-tune` 和 `iperf3-tuned` 装到 `/usr/local/sbin/`
- 创建 `/etc/iperf3-tune/`、`/var/lib/iperf3-tune/`、`/var/log/iperf3-tune/`

不会自动改任何 sysctl,也不会自动启 systemd timer。

---

## 用法

### 子命令

| 命令 | 作用 |
|---|---|
| `iperf3-tune detect` | 仅检测,打印瓶颈报告 (CPU / 内存 / 网卡) |
| `iperf3-tune tune` | 仅应用 sysctl + 网卡 offload + RPS/RFS/XPS |
| `iperf3-tune bench --server IP` | 仅跑测试 (单流 + 多流寻优),不改 sysctl |
| `iperf3-tune optimize --server IP` | 完整流程: detect → tune → 远端同步 → bench |
| `iperf3-tune rollback` | 回退所有改动 (用 backup 文件精确还原) |
| `iperf3-tune status` | 显示当前状态 |
| `iperf3-tuned init` | 初始化 daemon 配置 (交互或参数式) |
| `iperf3-tuned install` | 安装 systemd timer (主任务每周日 22:00 + canary 每 6h) |
| `iperf3-tuned uninstall` | 卸载 timer |

### 关键选项

```
--profile NAME       balanced | aggressive | extreme  (默认 aggressive)
--congestion ALGO    bbr | cubic | ...  (默认 bbr)
--time SECS          单次测试时长 (默认 30)
--repeats N          每档重复次数 (默认 3,取中位数)
--max-parallel N     最大并发流 (默认 32)
--retrans-threshold  超过此重传率即提前停止寻优 (默认 1.0%)
--retrans-penalty K  评分函数中的重传惩罚系数 (默认 10)
--ssh-host HOST      远端 iperf3 服务器 (用于同步调优)
--ssh-user USER      默认 root
--ssh-key PATH       SSH 私钥 (如果用 key 认证)
--ssh-pass PASS      SSH 密码 (走 SSHPASS env, ps 看不到)
--ssh-pass-file PATH 从文件读密码 (推荐, 不进 bash_history)
--direction r|f      reverse=下行(默认), forward=上行
-y, --yes            非交互
--json               JSON 输出
```

### 典型流程 (用 IP + root + 密码)

> ⚠ **测试期间 SSH 容易被打满的带宽挤断**(本工具就是干这事的)。
> 推荐用 `--detach` 让脚本脱离 SSH 在后台跑,然后在另一个 SSH 窗口
> 用 `iperf3-tune watch` 看实时进度。脚本会**每完成一档增量保存**到
> `/var/lib/iperf3-tune/progress.json`,所以即使 SSH 断了已测出的数据也不丢。

```bash
# 0) 仅看现状, 不动系统
sudo iperf3-tune detect

# 1) ★ 推荐: 后台运行 ★
sudo iperf3-tune optimize --detach \
    --server 1.2.3.4 \
    --ssh-host 1.2.3.4 --ssh-user root --ssh-pass 'YOUR_PASSWORD' \
    --profile aggressive --time 30 --repeats 3
# → 立即返回 PID, 可以关 SSH 窗口

# 2) 在任意 SSH 窗口看进度 (每 3 秒刷新一次, Ctrl-C 退出但任务继续)
sudo iperf3-tune watch
# 或者跟日志
sudo iperf3-tune tail
# 中途想停
sudo iperf3-tune stop

# 1b) 前台运行 (短测试 5 分钟以内, SSH 不会断的话可以这么跑)
sudo iperf3-tune optimize \
    --server 1.2.3.4 \
    --ssh-host 1.2.3.4 --ssh-user root --ssh-pass 'YOUR_PASSWORD' \
    --profile aggressive --time 30 --repeats 3

# 1c) 更安全: 密码放文件 (不进 bash_history)
echo -n 'YOUR_PASSWORD' | sudo tee /root/.iperf3-ssh.pass >/dev/null
sudo chmod 600 /root/.iperf3-ssh.pass
sudo iperf3-tune optimize --detach --server 1.2.3.4 \
    --ssh-host 1.2.3.4 --ssh-user root \
    --ssh-pass-file /root/.iperf3-ssh.pass \
    --profile aggressive

# 3) 测试不满意 → 升级到 extreme 重测
sudo iperf3-tune optimize --detach --server 1.2.3.4 \
    --ssh-host 1.2.3.4 --ssh-pass 'YOUR_PASSWORD' \
    --profile extreme

# 4) 不满意 → 立即回退本机 + 远端
sudo iperf3-tune rollback \
    --ssh-host 1.2.3.4 --ssh-pass 'YOUR_PASSWORD'

# 5) 满意 → 装定时任务 (交互式问密码, 静默输入)
sudo iperf3-tuned init
sudo iperf3-tuned install
```

### 处理 SSH 断连

`--detach` 模式底层用 `setsid` 把脚本启动到新的进程会话里,完全脱离 SSH 的 controlling terminal。SSH 断了之后:

- 后台进程**不会**收到 SIGHUP,继续跑
- PID 写在 `/var/lib/iperf3-tune/iperf3-tune.pid`
- 标准输出/错误重定向到 `/var/log/iperf3-tune/run-YYYYMMDD-HHMMSS.log`
- 每完成一档,`progress.json` 立即落盘

重新连上 SSH 后:

```bash
sudo iperf3-tune watch    # 看进度
sudo iperf3-tune status   # 看任务是否还在跑
sudo iperf3-tune tail     # tail -f 日志
```

如果你的 SSH 经常断,也可以在客户端 `~/.ssh/config` 加心跳:

```
Host *
    ServerAliveInterval 15
    ServerAliveCountMax 6
    TCPKeepAlive yes
```

### 关于密码安全

- `--ssh-pass PASS`: 密码以 `SSHPASS` 环境变量传给 `sshpass -e` 子进程,`ps`/`top` 看不到密码,但带密码的命令本身会进 `~/.bash_history`。**用单引号包密码**,防止 `$`/`!` 等被 shell 转义。
- `--ssh-pass-file PATH`: 密码从文件读,文件权限必须 `600`,否则脚本拒绝运行。推荐方式。
- `iperf3-tuned init`: 交互式静默输入(`read -s`),密码写入 `/etc/iperf3-tune/config.json`,权限 `600`,仅 root 可读。

---

## profile 详解

三档预设,**越往后越激进、对其他业务影响越大**。

### balanced (64MB 缓冲, 1G/2.5G 链路)

```
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
```

### aggressive (256MB, 10G 链路, **默认**)

balanced 基础上:

```
net.core.rmem_max = 268435456
net.core.wmem_max = 268435456
net.core.netdev_budget = 600
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_limit_output_bytes = 1048576
net.core.rps_sock_flow_entries = 32768
```

### extreme (1GB, 25G+ 或长肥管道)

aggressive 基础上:

```
net.core.rmem_max = 1073741824
net.core.wmem_max = 1073741824
net.ipv4.tcp_ecn = 0                # 关闭 ECN
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_limit_output_bytes = 4194304
net.ipv4.conf.all.rp_filter = 0     # 禁用反向路径校验
```

---

## 寻优算法

每个并发数测试结束后,按下式打分:

```
score = bandwidth_mbps × max(0, 1 − k × retrans_rate_pct / 100)
```

默认 `k=10`,意思是 **1% 重传率会扣掉 10% 的评分**。

候选并发数: `1, 2, 4, 8, 16, 32`。早停条件:

1. 当前重传率 > `--retrans-threshold` (默认 1%)
2. 当前评分相对前一档下降 > 5%

最终选评分最高的并发数。

调参方向:

- 你更看重低重传 → 增大 `--retrans-penalty` (如 `--retrans-penalty 20`)
- 你完全不在乎重传,只要带宽 → `--retrans-penalty 0`

---

## 文件布局

| 路径 | 内容 |
|---|---|
| `/usr/local/sbin/iperf3-tune`  | 主脚本 |
| `/usr/local/sbin/iperf3-tuned` | daemon 脚本 |
| `/etc/iperf3-tune/config.json` | daemon 配置 (含 SSH 信息) |
| `/etc/sysctl.d/99-iperf3-tune.conf` | 应用后的 sysctl |
| `/var/lib/iperf3-tune/sysctl.before.txt` | 应用前的 sysctl 快照 (回退用) |
| `/var/lib/iperf3-tune/nic.before.json` | 应用前的网卡设置快照 |
| `/var/lib/iperf3-tune/state.json` | 最近一次 bench 结果 |
| `/var/lib/iperf3-tune/baseline.json` | 上次 daemon 跑出的最优结果 |
| `/var/lib/iperf3-tune/canary.json` | 金丝雀检查历史 |
| `/var/log/iperf3-tune/daemon.log` | daemon 日志 |

---

## 卸载

```bash
sudo ./uninstall.sh
```

会停 systemd timer、跑 `rollback` 还原 sysctl、删除脚本。**配置和历史数据保留**,如需彻底清理:

```bash
sudo rm -rf /etc/iperf3-tune /var/lib/iperf3-tune /var/log/iperf3-tune
```

---

## 已知限制

- iperf3 测试本身是合成流量,这套工具对**真实业务流量**(短连接 HTTP、QUIC、TLS 握手等)**不一定带来等比例改善**。这是项目的目标取舍,不是 bug。
- `extreme` profile 关闭了 ECN 和反向路径过滤,**在公网环境会显著降低安全性**,仅建议在受控网络/裸金属之间使用。
- BBR 需要内核 ≥ 4.9。更老的内核会回退到 cubic,部分调优效果会打折。
- 金丝雀监控只跑 3 天 (18 次采样),超过这个窗口需要重新触发 `iperf3-tuned run` 或等待下一个周日。

---

## License

MIT
