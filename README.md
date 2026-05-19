# iperf3 双端 Sysctl 自动调优

> 自动调优并持久化 **客户端 + 服务端** 的网络内核参数，提升 `iperf3 -R` 吞吐，尽量降低重传。

## 🚀 最新优化（2026版）

本项目已进行**深度性能优化**，针对高带宽、长距离链路场景：

### 核心优化特性

✅ **BBR v2/v3 自动检测** - 优先使用最新BBR版本，配合fq队列pacing模式  
✅ **MTU路径自动检测** - 探测最优MTU避免分片，降低CPU开销  
✅ **网卡硬件加速** - GRO/LRO/TSO/GSO全开，环形缓冲区最大化  
✅ **多核CPU优化** - RPS/RFS/XPS智能分布，避免单核瓶颈  
✅ **ECN显式拥塞通知** - 配合BBR提前感知拥塞，减少丢包  
✅ **初始拥塞窗口=20** - 快速启动，减少慢启动时间  
✅ **智能重传评分** - 基于重传率而非绝对数量，避免高带宽误判  
✅ **更激进的TCP内存** - 高BDP链路不受内存限制  

### 新增TCP参数（21个）

```
net.ipv4.tcp_window_scaling=1      # 大窗口支持
net.ipv4.tcp_timestamps=1          # 精确RTT测量
net.ipv4.tcp_sack=1                # 选择性确认
net.ipv4.tcp_slow_start_after_idle=0  # 禁用空闲后慢启动
net.ipv4.tcp_fastopen=3            # TCP快速打开
net.ipv4.tcp_no_metrics_save=1     # 禁用缓存指标
net.ipv4.tcp_ecn=1                 # ECN拥塞通知
net.ipv4.tcp_init_cwnd=20          # 初始拥塞窗口
net.ipv4.tcp_adv_win_scale=1       # 接收窗口优化
net.core.netdev_max_backlog=16384  # 网卡接收队列
net.core.somaxconn=4096            # 连接队列
net.core.rps_sock_flow_entries=32768  # RFS流表
```

---

## 它解决什么问题

这个脚本面向 `iperf3 -R` 场景，**提供SSH后完全自动化**：

- ✅ 自动安装依赖（iperf3、iproute2、ethtool等）
- ✅ 自动检测RTT和最优MTU
- ✅ 自动优化网卡offload和CPU分布
- ✅ 客户端接收侧 sysctl 调优
- ✅ 服务端发送侧 sysctl 调优
- ✅ 远端 profile 比较：`bbr3-fq / bbr2-fq / bbr-fq / cubic-fq / cubic-fq_codel`
- ✅ 自动搜索更优组合
- ✅ 结果可选：**回滚 / 保留 / 持久化**

持久化后：

- 客户端写入：`/etc/sysctl.d/99-iperf3-client-tune.conf`
- 服务端写入：`/etc/sysctl.d/99-iperf3-remote-tune.conf`

---

## 适合谁

适合这些场景：

- 你测的是 `iperf3 -R`（服务端发送，客户端接收）
- 本地能 SSH 到服务端
- 你想自动调优双端，而不是手工改 sysctl
- 高带宽场景（100Mbps - 10Gbps+）
- 长距离链路（RTT > 10ms）
- 希望最大化单流吞吐，最小化重传

---

## 快速开始

### 方式一：交互模式（推荐）

```bash
git clone https://github.com/lucifer988/iperf3.git
cd iperf3
chmod +x iperf3-easy.sh
sudo ./iperf3-easy.sh --interactive
```

交互模式会询问：
1. 服务端IP/域名
2. SSH用户名和密码
3. SSH端口（默认22）
4. 目标带宽（默认1000Mbps）
5. iperf3端口（默认5201）
6. 可选：RTT估值、本地公网IP

跑完后脚本会再问你一次：

1. 仅查看结果并回滚
2. 保留最佳运行态
3. **持久化最佳配置（推荐）**

---

## 非交互示例

### 完整双端调优

```bash
sudo ./iperf3-easy.sh \
  --server 1.2.3.4 \
  --server-ssh root@1.2.3.4 \
  --server-ssh-pass '你的SSH密码' \
  --server-ssh-port 22 \
  --target-mbps 1000 \
  --persist \
  --yes
```

### 只调本地（已有优化好的服务端）

```bash
sudo ./iperf3-easy.sh \
  --server 1.2.3.4 \
  --target-mbps 1000 \
  --local-only \
  --persist \
  --yes
```

### 指定profile和测试时长

```bash
sudo ./iperf3-easy.sh \
  --server 1.2.3.4 \
  --server-ssh root@1.2.3.4 \
  --server-ssh-pass 'password' \
  --target-mbps 5000 \
  --profile exhaustive \
  --remote-profile auto-all \
  --coarse-seconds 15 \
  --fine-seconds 30 \
  --persist \
  --yes
```

---

## 持久化内容

### 客户端（接收端优化）

写入 `/etc/sysctl.d/99-iperf3-client-tune.conf`：

```ini
# 基础缓冲区（根据BDP自动计算）
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 1048576 67108864
net.ipv4.tcp_wmem=4096 1048576 67108864

# TCP 接收优化
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_no_metrics_save=1

# 高性能优化
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_fastopen=3

# ECN 和拥塞窗口优化
net.ipv4.tcp_ecn=1
net.ipv4.tcp_init_cwnd=20
net.ipv4.tcp_adv_win_scale=1

# 连接队列
net.core.netdev_max_backlog=16384
net.core.somaxconn=4096

# CPU 分布优化
net.core.rps_sock_flow_entries=32768

# 拥塞控制和队列调度（如果启用本地发送测试）
net.ipv4.tcp_congestion_control=bbr3
net.core.default_qdisc=fq
```

### 服务端（发送端优化）

写入 `/etc/sysctl.d/99-iperf3-remote-tune.conf`：

```ini
# 基础缓冲区
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 87380 67108864

# 高性能优化（同客户端）
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_no_metrics_save=1

# ECN 和拥塞窗口优化
net.ipv4.tcp_ecn=1
net.ipv4.tcp_init_cwnd=20
net.ipv4.tcp_adv_win_scale=1

# 连接队列
net.core.netdev_max_backlog=16384
net.core.somaxconn=4096

# CPU 分布优化
net.core.rps_sock_flow_entries=32768

# TCP 内存（动态计算）
net.ipv4.tcp_mem=32768 65536 131072
```

### 网卡优化（自动应用）

客户端（接收优化）：
- GRO/LRO/TSO/GSO/RX/TX/SG 全部开启
- 接收环形缓冲区扩大到最大
- RPS/RFS 多核分布

服务端（发送优化）：
- TSO/GSO/GRO/SG/TX 开启
- 发送环形缓冲区扩大到最大
- XPS 发送队列CPU绑定

---

## 结果文件

常见输出：

- `summary.csv` - 所有测试结果汇总
- `final-summary.json` - 最终推荐配置
- `run_best.sh` - 复用最佳配置的命令
- `remote-auto-report_*/summary.tsv` - 远端profile对比
- `remote-auto-report_*/summary.json` - 远端profile详细数据

如果启用了 `auto-all`：

- 会比较不同远端 profile（bbr3-fq/bbr2-fq/bbr-fq/cubic-fq/cubic-fq_codel）
- 按 **综合评分优先** 选最佳 profile
- 输出推荐复用命令

---

## 参数说明

### 核心参数

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `--server` | iperf3 服务端IP/域名 | 必填 |
| `--server-ssh` | SSH登录地址（如 root@1.2.3.4） | 必填（非local-only） |
| `--server-ssh-pass` | SSH密码 | 必填（需安装sshpass） |
| `--server-ssh-port` | SSH端口 | 22 |
| `--target-mbps` | 目标单流带宽（Mbps） | 1000 |
| `--port` | iperf3端口 | 5201 |

### Profile选项

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `--profile` | 本地测试策略：fast/balanced/exhaustive | fast |
| `--remote-profile` | 远端profile：auto/auto-all/bbr3-fq/bbr2-fq/bbr-fq/cubic-fq/cubic-fq_codel | auto-all |

- `fast`: 粗筛8秒，精测15秒，top 2候选
- `balanced`: 粗筛10秒，精测20秒，top 3候选
- `exhaustive`: 粗筛12秒，精测25秒，top 4候选

### 动作选项

| 参数 | 说明 |
|------|------|
| `--interactive` | 交互模式，只问SSH和带宽 |
| `--rollback` | 跑完回滚（默认） |
| `--keep` | 跑完保留运行态 |
| `--persist` | 跑完持久化配置 |
| `--local-only` | 仅调优本地，不SSH到服务端 |
| `--yes` | 非交互模式 |

---

## 重要说明

### 1. 这个脚本主要持久化的是 sysctl

也就是双端内核参数和网卡优化。

### 2. `iperf3 -R` 下服务端更关键

因为 `-R` 模式真正发流的是服务端，服务端的拥塞控制和 qdisc 往往更重要。

### 3. BBR版本优先级

脚本会自动检测并按优先级使用：

1. **BBR v3** (tcp_bbr3) - 最新版本，性能最优
2. **BBR v2** (tcp_bbr2) - 改进版本
3. **BBR v1** (tcp_bbr) - 原始版本
4. **CUBIC** - 传统拥塞控制

### 4. 网卡优化自动应用

脚本会自动：
- 检测网卡接口
- 探测最优MTU
- 开启硬件offload
- 配置多核CPU分布
- 扩大环形缓冲区

### 5. 持久化后可选清理结果

交互模式下，如果你选择"持久化最佳配置"，脚本会再问一次是否清理本次本地测试结果目录。

- 只清理本地结果文件
- 不影响已经写入双端的持久化 sysctl 配置

---

## 性能提升预期

根据链路特性，优化后可能获得：

| 场景 | 优化前 | 优化后 | 提升 |
|------|--------|--------|------|
| 高带宽低延迟（1Gbps, RTT<10ms） | 800Mbps | 950Mbps+ | 15-20% |
| 高带宽中延迟（1Gbps, RTT 50ms） | 400Mbps | 900Mbps+ | 100%+ |
| 高带宽高延迟（1Gbps, RTT 200ms） | 100Mbps | 800Mbps+ | 700%+ |
| 超高带宽（10Gbps, RTT 50ms） | 3Gbps | 9Gbps+ | 200%+ |

*实际效果取决于网络质量、硬件性能和链路特性*

---

## 故障排查

### 1. SSH连接失败

```bash
# 确保能手动SSH登录
ssh root@1.2.3.4

# 安装sshpass（用于密码认证）
apt install sshpass  # Debian/Ubuntu
yum install sshpass  # CentOS/RHEL
```

### 2. BBR不可用

```bash
# 检查内核版本（需要4.9+）
uname -r

# 加载BBR模块
modprobe tcp_bbr
echo "tcp_bbr" >> /etc/modules-load.d/bbr.conf

# 检查可用拥塞控制
cat /proc/sys/net/ipv4/tcp_available_congestion_control
```

### 3. 权限不足

```bash
# 必须使用root或sudo
sudo ./iperf3-easy.sh --interactive
```

### 4. ethtool命令不存在

```bash
# 安装ethtool
apt install ethtool  # Debian/Ubuntu
yum install ethtool  # CentOS/RHEL
```

---

## 一句话总结

> 这个仓库的主线不是"单纯测速"，而是：**自动搜索并持久化双端更优的 sysctl 配置，再辅以最佳 iperf3 参数，通过MTU检测、网卡offload、CPU多核优化等深度调优，实现极致单流性能。**

---

## 技术细节

### 优化原理

1. **BDP计算** - 根据带宽和RTT计算带宽延迟积，设置合适的缓冲区
2. **MTU探测** - 使用ping -M do逐级探测，避免分片
3. **硬件卸载** - GRO聚合小包，TSO/GSO减少CPU开销
4. **多核分布** - RPS/RFS/XPS将网络处理分散到多核
5. **ECN协商** - 提前感知拥塞，减少丢包触发
6. **快速启动** - 初始拥塞窗口20，快速达到带宽上限
7. **智能评分** - 综合带宽、重传率、稳定性选择最优配置

### 评分算法

```python
score = mbps - (retrans_rate * 50 if retrans_rate > 0.01 else retrans_rate * 25)
```

- 优先考虑带宽
- 重传率>1%时加倍惩罚
- 避免高带宽下绝对重传数误判

---

## License

MIT

## 贡献

欢迎提交 Issue 和 Pull Request！
