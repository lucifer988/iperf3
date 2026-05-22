# iperf3-tune

**面向高带宽链路的 iperf3 自动调优与基准测试工具**

`iperf3-tune` 是一个用于 **检测瓶颈、应用 TCP/网卡调优、运行 iperf3 多流寻优、后台监控与回退** 的 Linux 工具。它的核心目标是：

> 在 iperf3 场景下尽可能提升带宽 (尤其单流 `-R` 下行), 并尽可能降低 TCP 重传率。

相比保守型系统优化工具,本项目会主动调整 sysctl、网卡 offload、ring buffer、RPS/RFS/XPS、IRQ 亲和性等参数。因此它更适合裸金属、高速 VPS、跨机房链路、长肥管道、10G/25G+ 链路等场景。

---

## v2.3.0 关键变更

1. **★★★ 远端依赖自动安装**
   远端 SSH 同步调优时,若远端缺少 `ethtool`、`jq`、`iperf3` 等依赖,会**自动识别发行版并安装**,不再因为"远端 tune 执行失败"中断流程。

   支持的发行版与包管理器:
   - Debian/Ubuntu/Mint/Kali/Pop/Deepin → `apt`
   - RHEL/CentOS/Rocky/Alma/Fedora/Amazon/Oracle/openEuler → `dnf`/`yum`
   - Arch/Manjaro/EndeavourOS/Garuda → `pacman`
   - Alpine → `apk`
   - openSUSE/SLES → `zypper`

2. **★★★ 本机依赖也自动安装**
   `iperf3-tune` 在 root 下检测到缺失依赖会自动安装(可用 `--no-auto-install` 关闭)。

3. **★ aggressive profile 单流友好优化**
   针对 `iperf3 -R` 单流场景,放宽:
   - `tcp_notsent_lowat`: 128 KB → 4 MB (减少单流阻塞)
   - `tcp_limit_output_bytes`: 1 MB → 4 MB (减少 BBR pacing 抖动)

4. **★ extreme profile 增强**
   - `tcp_notsent_lowat`: 16 MB
   - `tcp_limit_output_bytes`: 16 MB

5. **新参数** `--no-auto-install`: 显式禁用自动安装。

---

## 调优原理 (面向单流 `iperf3 -R`)

`iperf3 -R` 意味着 client 接收、server 发送。要最大化客户端读到的速率,需要在**两端**做好以下事情:

### 服务端 (sender / 发送侧)
| 参数 | 作用 |
|---|---|
| `net.core.wmem_max`, `net.ipv4.tcp_wmem` | 增大发送缓冲,允许 BDP 内全部在飞 |
| `net.ipv4.tcp_limit_output_bytes` | BBR pacing 限制,过小会卡单流 |
| `net.ipv4.tcp_notsent_lowat` | 应用层 vs 内核 buffer 节流阈值 |
| `tcp_congestion_control = bbr` | 单流跨网最佳拥塞控制 |
| `default_qdisc = fq` | BBR 必需的发送排队 |
| `tcp_slow_start_after_idle = 0` | 空闲后不重置 cwnd |
| TSO / GSO offload | 硬件分段,降低 CPU |
| TX ring buffer 拉满 | 减少 ring 溢出 |

### 客户端 (receiver / 接收侧)
| 参数 | 作用 |
|---|---|
| `net.core.rmem_max`, `net.ipv4.tcp_rmem` | 增大接收缓冲,这是单流上限的硬决定因素 |
| `net.ipv4.tcp_moderate_rcvbuf = 1` | 内核自适应 rmem |
| GRO offload | 硬件合并小包 |
| RX ring buffer 拉满 | 减少 ring 溢出 |
| RPS/RFS | 软件 fanout 到多核, 单 RX 队列网卡尤其重要 |

### 两端共享
| 参数 | 作用 |
|---|---|
| `tcp_window_scaling = 1` | 不开就只能 64 KB 窗口 |
| `tcp_timestamps = 1` | 准确测 RTT |
| `tcp_sack = 1`, `tcp_dsack = 1` | 选择性重传,避免整窗重传 |
| `tcp_mtu_probing = 1` | 自适应 PMTU |

### 不调的事情
- iperf3 命令行 `-w` 显式窗口大小:**不建议**,会关掉内核 autotune,反而限速。靠 `tcp_rmem`/`tcp_wmem` 让内核自适应。
- `--cport` 之类 niche 参数:与速率无关。
- `-Z` (zerocopy):仅 server side 发送,可减 CPU 但不增速率,且对部分内核有兼容问题。

---

## 项目结构

```
iperf3-tune/
├── install.sh            # 一键安装
├── uninstall.sh          # 完整卸载
├── iperf3-tune.sh        # 主脚本 (detect/tune/bench/optimize/rollback/status)
├── iperf3-tuned.sh       # daemon (init/install/run/canary)
└── README.md             # 本文件
```

---

## 安装

```bash
git clone https://github.com/lucifer988/iperf3.git iperf3-tune
cd iperf3-tune
sudo ./install.sh
```

`install.sh` 会:
- 自动识别发行版,装好 `jq iperf3 ethtool iproute2 sysstat bc tar` 等
- 加载 `tcp_bbr` 模块
- 把 `iperf3-tune` 与 `iperf3-tuned` 装到 `/usr/local/sbin/`
- 创建 `/etc/iperf3-tune/`, `/var/lib/iperf3-tune/`, `/var/log/iperf3-tune/`

验证:
```bash
iperf3-tune --version    # 2.3.0
iperf3-tune --help
```

---

## 快速开始

### 第 1 步:远端跑 iperf3 server
```bash
# 远端
iperf3 -s -p 5201
# 或让 optimize 替你拉起 (会自动尝试)
```

放行 TCP 5201 (firewalld / ufw / iptables 任意一种)。

### 第 2 步:本机检测瓶颈
```bash
sudo iperf3-tune detect
```
只读不改。

### 第 3 步:完整优化 (推荐 `--detach`,SSH 断也不丢任务)
```bash
sudo iperf3-tune optimize --detach \
    --server 1.2.3.4 \
    --ssh-host 1.2.3.4 --ssh-user root --ssh-key ~/.ssh/id_rsa \
    --profile aggressive \
    --time 30 --repeats 3
```

这条命令会:
1. **检测**本机 CPU/内存/网卡瓶颈
2. **本机调优**:写 `/etc/sysctl.d/99-iperf3-tune.conf` 并 `sysctl -p`, 调整网卡 offload/ring/RPS/RFS/XPS/IRQ
3. **远端同步**:SCP 上传脚本,SSH 执行 `iperf3-tune tune` (★ 远端缺依赖会自动装)
4. **测试**:单流基准 + 多流寻优 (1/2/4/8/16/32) + 链路诊断

### 第 4 步:查看进度与结果
```bash
sudo iperf3-tune watch     # 实时进度
sudo iperf3-tune tail      # 跟随日志
sudo iperf3-tune status    # 最近一次结果
sudo iperf3-tune stop      # 中断后台任务
```

---

## 命令总览

### `iperf3-tune` 主命令

| 命令 | 改系统 | 说明 |
|---|---|---|
| `detect` | 否 | 检测 CPU/内存/网卡瓶颈 |
| `tune` | 是 | 仅应用本机 sysctl + 网卡优化 |
| `bench` | 否 | 仅跑 iperf3 测试 |
| `optimize` | 是 | 完整流程:检测+调优+远端+测试 |
| `rollback` | 是 | 回退本机 sysctl,并尝试远端回退 |
| `status` | 否 | 查看当前状态 |
| `watch` | 否 | 实时查看后台任务进度 |
| `tail` | 否 | 跟随后台日志 |
| `stop` | 是 | 停止后台任务及 iperf3 子进程 |

### `iperf3-tuned` daemon 命令

| 命令 | 说明 |
|---|---|
| `init` | 初始化配置 (写 `/etc/iperf3-tune/config.json`) |
| `install` | 安装 systemd timer:每周日 22:00 + 每 6h canary |
| `uninstall` | 卸载 timer |
| `run` | 立即跑一次完整 optimize |
| `canary` | 手动金丝雀检查 |
| `rollback` | 回退本机+远端 |
| `status` | daemon / baseline / canary 状态 |

---

## 关键参数

### 测试参数
| 参数 | 默认 | 说明 |
|---|---|---|
| `--server IP` | — | iperf3 服务端 (bench/optimize 必填) |
| `--port N` | 5201 | iperf3 端口 |
| `--time SECS` | 30 | 单次测试时长,≥5 |
| `--repeats N` | 3 | 每档重复次数,取中位 |
| `--max-parallel N` | 32 | 最大并发流 |
| `--direction reverse\|forward` | reverse | reverse = `-R` 下行测试 |
| `--mss N` | 1448 | 估算重传率用 MSS |

### 调优参数
| 参数 | 默认 | 说明 |
|---|---|---|
| `--profile NAME` | aggressive | balanced/aggressive/extreme |
| `--congestion ALGO` | bbr | bbr / cubic / 其他 |
| `--retrans-threshold PCT` | 3.0 | 超此值提前停止寻优 |
| `--retrans-penalty K` | 10.0 | 评分函数重传惩罚 |

### SSH (远端同步)
| 参数 | 默认 | 说明 |
|---|---|---|
| `--ssh-host HOST` | — | 远端 IP |
| `--ssh-user USER` | root | SSH 用户 |
| `--ssh-port N` | 22 | SSH 端口 |
| `--ssh-key PATH` | — | 私钥 |
| `--ssh-pass PASS` | — | 密码 (经 sshpass) |
| `--ssh-pass-file PATH` | — | 从文件读密码 (推荐,权限须 600) |

### 后台与依赖管理
| 参数 | 说明 |
|---|---|
| `-d`, `--detach` | bench/optimize 入后台,脱离 SSH |
| `--no-auto-install` | **新增**:禁用自动安装依赖 |
| `-y`, `--yes` | 非交互,跳过确认 |
| `-v`, `--verbose` | 详细日志 + 保留 iperf3 原始 JSON |
| `--json` | JSON 输出 |

---

## profile 三档

| Profile | 缓冲区 | 适用 | 风险 |
|---|---|---|---|
| `balanced` | 64 MB | 1G/2.5G,共享机器 | 低 |
| `aggressive` | 256 MB | 10G,默认推荐,**针对单流 -R 优化** | 中 |
| `extreme` | 1 GB | 25G+,长肥管道 | 高 (关 ECN/RPF) |

---

## 寻优算法

### 候选并发数
默认 `1, 2, 4, 8, 16, 32`,受 `--max-parallel` 限制。

### 评分函数
\[
\text{score} = \text{bandwidth\_mbps} \times \max(0,\ 1 - k \times \text{retrans\_rate\_pct} / 100)
\]

其中 \(k\) = `--retrans-penalty` (默认 10)。即 1% 重传率扣 10% 评分。

如果你**只看带宽**,设 `--retrans-penalty 0`。

### 早停
- 单流外的某档重传率 > `--retrans-threshold` (默认 3.0%) → 停止
- 单流允许 ≤ 10% 重传 (因为多流可能改善)
- 当前评分 < 前一档 95% → 停止

---

## 后台运行

高速链路 `iperf3` 容易把 SSH 打卡顿甚至断开。所以建议:

```bash
sudo iperf3-tune optimize --detach ...
```

后台模式:
- `setsid` 脱离 SSH controlling terminal
- PID 写 `/var/lib/iperf3-tune/iperf3-tune.pid`
- 日志在 `/var/log/iperf3-tune/run-*.log`
- 每完成一档增量写 `/var/lib/iperf3-tune/progress.json`

SSH 客户端 `~/.ssh/config`:
```
Host *
    ServerAliveInterval 15
    ServerAliveCountMax 6
    TCPKeepAlive yes
```

---

## 回退

```bash
# 本机
sudo iperf3-tune rollback

# 本机 + 远端
sudo iperf3-tune rollback \
    --ssh-host 1.2.3.4 --ssh-key ~/.ssh/id_rsa
```

`rollback` 做的事:
- 删除 `/etc/sysctl.d/99-iperf3-tune.conf`
- 把每个被改过的 sysctl 项还原到备份值
- 远端如有部署也执行同样动作

> 部分 ethtool offload 改动(尤其 LRO)运行时不可逆,最干净的还原是 `rollback` + reboot。

---

## 卸载

```bash
sudo ./uninstall.sh
```

会:
1. 停 / 删 systemd timer
2. `iperf3-tune rollback` 回退 sysctl
3. 删脚本

保留配置/日志/历史数据。彻底清理:
```bash
sudo rm -rf /etc/iperf3-tune /var/lib/iperf3-tune /var/log/iperf3-tune
```

---

## 常见问题

### Q1: 报错 `远端 tune 执行失败` / `缺少依赖: ethtool` 怎么办?

**v2.3.0 已修复**:远端会自动安装。如果你装的还是旧版,升级即可。如果新版仍失败,请贴日志:
```
sudo iperf3-tune optimize --verbose ...   # 看完整远端输出
```

可能原因:
- 远端无外网,装不了包 → 手动安装依赖
- 远端 root 都无权运行 `apt`/`yum` → 改用有权限的用户
- 容器里的精简发行版没有包管理器 → 手动准备好镜像

### Q2: 单流 `-R` 速度上不去?

按这个顺序排查:
1. `sudo iperf3-tune detect` 看瓶颈是 CPU/内存/网卡
2. 看 RTT:`ping -c 20 server`,RTT × 带宽 = BDP,确保 `rmem_max` ≥ 2×BDP
3. NIC 标称速率 (`/sys/class/net/<iface>/speed`) 是否被中间链路或 ISP 限制
4. 试 `--profile extreme`(若内存足够,1 GB 缓冲)
5. 服务端 / 客户端 **任一**没装 BBR → 退化为 cubic,长肥管道掉速

### Q3: 重传率多少算正常?

按 RTT 分:
- LAN (RTT < 5ms): < 0.1% 正常,> 1% 有问题
- 同区域 (RTT 5-50ms): < 1% 正常
- 跨境 (RTT > 100ms): < 3% 正常,BBR 设计内

### Q4: `iperf3 -R` 和不带 `-R` 有什么区别?

- **不带 `-R` (forward / 上行)**:client 发,server 收。client 拼写入侧 (wmem)
- **带 `-R` (reverse / 下行)**:server 发,client 收。**client 拼读出侧 (rmem),server 拼写入侧**

本工具默认 `reverse`,如果你测的是上行,加 `--direction forward`。

---

## License

MIT
