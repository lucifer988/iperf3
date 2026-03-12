# iperf3 自动调优脚本

包含两个脚本：
- `iperf3.sh` - 本地调优脚本
- `iperf3-remote.sh` - 远程调优包装脚本（推荐）

---

## 快速开始

### 方式1：使用 iperf3-remote.sh（推荐，自动调优两端）

```bash
# 下载脚本
curl -fsSL https://raw.githubusercontent.com/lucifer988/iperf3/main/iperf3-remote.sh -o ~/iperf3-remote.sh
curl -fsSL https://raw.githubusercontent.com/lucifer988/iperf3/main/iperf3.sh -o ~/iperf3.sh
chmod +x ~/iperf3-remote.sh ~/iperf3.sh

# 运行（会自动调优服务端并测速）
sudo ~/iperf3-remote.sh \
  --server-ssh root@1.2.3.4 \
  --server 1.2.3.4 \
  --target-mbps 600

# 免密码运行
sshpass -p '密码' sudo -E ~/iperf3-remote.sh \
  --server-ssh root@1.2.3.4 \
  --server 1.2.3.4 \
  --target-mbps 600
```

**iperf3-remote.sh 会自动：**
1. SSH 到服务端，根据 RTT/BDP 动态调优发送缓冲
2. 启动 iperf3 server
3. 调用 iperf3.sh 本地测速
4. 测完后清理服务端

### 方式2：只用 iperf3.sh（仅本地调优）

```bash
sudo ./iperf3.sh \
  --server 1.2.3.4 \
  --port 5201 \
  --target-mbps 1000 \
  --max-mbps 1000 \
  --profile balanced \
  --persist \
  --yes
```

---

# iperf3.sh 详细文档

一个面向 **iperf3 单流反向测试（`-R`）** 的自动调优脚本，适合在 **中国大陆 client / 境外 server** 这类高 RTT 场景中使用。

它的设计目标不是"把所有参数穷举一遍"，而是：

- 按 RTT 估算 BDP
- 自动生成合理的 `-w` 候选
- 用 **两阶段搜索**（粗筛 + 复测 + 确认）缩短总耗时
- 在 **client 侧** 优化接收缓冲与相关 sysctl
- 在可选的 **SSH 模式** 下，直接调优真正的发送端（server）的 `cc/qdisc`
- 自动记录 CSV / JSON / Markdown 报告
- 支持 **回滚 / 保留运行态 / 持久化**

---

## 1. 这脚本解决什么问题

很多人会用：

```bash
iperf3 -c SERVER -R
```

来测试"境外到大陆"的回程带宽，但真正开始调参数时，经常会遇到几个问题：

1. **调错机器**：`-R` 是 server 发、client 收，真正控制大发送流拥塞控制算法的是 server。
2. **测试太慢**：几十组参数每组跑 30 秒，很容易一轮十几二十分钟。
3. **窗口乱设**：`-w` 太小吃不满，太大又容易不合理或者没有收益。
4. **结果不稳定**：慢启动、历史 metrics、偶发抖动都会干扰结论。

这个脚本就是把这些坑尽量处理掉，变成一个可以直接运行的、适合反向单流场景的调优工具。

---

## 2. 核心思路

### `-R` 的真实语义

在 `iperf3 -R` 模式下：

- **server 发送数据**
- **client 接收数据**

所以：

- 在 **client** 上最值得优先调的是：
  - `net.core.rmem_max`
  - `net.ipv4.tcp_rmem`
  - `net.ipv4.tcp_moderate_rcvbuf`
  - `net.ipv4.tcp_mtu_probing`
  - `-w`
- 在 **server** 上最值得优先调的是：
  - `net.ipv4.tcp_congestion_control`
  - `net.core.default_qdisc`
  - `tc qdisc replace ...`

因此，这个脚本默认就按这个逻辑设计：

- **默认模式**：只优化本地 client 接收侧
- **推荐模式**：通过 `--server-ssh` + `--remote-tune 1`，顺手把远端 sender 一起调掉

---

## 3. 功能特性

- 单流反向测试（`iperf3 -R`）自动调优
- 两阶段搜索：
  - 粗筛（coarse）
  - 复测（fine）
  - 最终确认（confirm）
- 自动 RTT 测量与 BDP 估算
- 自动生成 `-w` 候选，包含 `auto`
- `-O` 跳过慢启动阶段
- `--get-server-output` 获取服务端输出
- 本地 sysctl 快照、自动回滚
- 远端 SSH 调优、远端回滚、远端持久化
- 输出完整日志：
  - 每次测试 JSON
  - 每次测试 stderr
  - 汇总 CSV
  - Markdown 报告
- 支持非交互模式，适合脚本化、CI、批量执行

---

## 4. 依赖要求

### 本地（运行脚本的机器）

需要 Linux，且建议以 `root` 或 `sudo` 运行。

依赖命令：

- `bash`
- `iperf3`
- `python3`
- `ip`
- `tc`
- `sysctl`
- `ping`
- `awk`
- `sed`
- `grep`
- `ss`

### 远端（可选）

如果你启用远端调优：

```bash
--server-ssh root@your-server --remote-tune 1
```

则远端机器需要：

- 可通过 SSH 免密或可批处理方式登录
- 远端具备 root 权限
- 安装 `bash`、`ip`、`tc`、`sysctl`

---

## 5. 安装方法

```bash
git clone <your-repo-url>
cd <your-repo>
chmod +x iperf3.sh
```

也可以直接下载单文件：

```bash
chmod +x iperf3.sh
```

---

## 6. 最常用的用法

### 6.1 交互模式

```bash
sudo ./iperf3.sh
```

脚本会按提示询问：

- server 地址
- 端口
- 目标吞吐
- 最大带宽
- 最终是回滚、保留还是持久化

### 6.2 非交互，本地接收端优化

```bash
sudo ./iperf3.sh \
  --server 1.2.3.4 \
  --port 5201 \
  --target-mbps 1000 \
  --max-mbps 1000 \
  --rollback \
  --yes
```

### 6.3 非交互，持久化配置

```bash
sudo ./iperf3.sh \
  --server 1.2.3.4 \
  --target-mbps 1000 \
  --max-mbps 1000 \
  --persist \
  --yes
```

### 6.4 指定 profile

```bash
sudo ./iperf3.sh \
  --server 1.2.3.4 \
  --profile balanced \
  --persist \
  --yes
```

### 6.5 ping 不通时手工给 RTT

```bash
sudo ./iperf3.sh \
  --server your-domain.com \
  --target-mbps 1000 \
  --max-mbps 1000 \
  --yes
```

---

## 7. 参数说明

### 基础参数

| 参数 | 说明 | 默认值 |
|---|---|---:|
| `--server HOST` | iperf3 server 地址 | 必填 |
| `--port PORT` | iperf3 端口 | `5201` |
| `--target-mbps N` | 目标吞吐 Mbps | `1000` |
| `--max-mbps N` | 服务端可用最大带宽 Mbps，用于估算 BDP | `1000` |
| `--ping-interval SEC` | ping 间隔 | `0.2` |
| `--ping-count N` | ping 次数 | `12` |

### 搜索策略

| 参数 | 说明 | 默认值 |
|---|---|---:|
| `--coarse-seconds N` | 粗筛时长 | `8` |
| `--fine-seconds N` | 精测时长 | `15` |
| `--omit N` | omit 秒数 | `3` |
| `--ping-count N` | ping 次数 | `12` |
| `--ping-interval SEC` | ping 间隔秒数 | `0.2` |
| `--top-n N` | 粗筛后进入精测的候选数 | `2` |
| `--fine-repeats N` | 每个候选精测重复次数 | `2` |

### 本地接收侧参数

| 参数 | 说明 | 默认值 |
|---|---|---:|
| `--mtu-probing {0|1|2}` | `tcp_mtu_probing` | `1` |
| `--max-buf-mb N` | rmem/wmem 上限 MB | `256` |
| `--min-buf-mb N` | rmem/wmem 下限 MB | `32` |
| `--max-win-mb N` | 单个 `-w` 候选最大值 MB | `128` |
| `--bind-dev DEV` | client 侧绑定网卡 | 空 |
| `--bind-addr ADDR` | client 侧绑定源地址 | 空 |
| `--client-qdisc NAME` | client 侧 root qdisc（可选） | 空 |

### 其他参数

| 参数 | 说明 | 默认值 |
|---|---|---:|
| `--log-dir DIR` | 日志目录 | 当前目录 |
| `--rollback` | 结束后自动回滚 | - |
| `--keep` | 结束后保留运行态 | - |
| `--persist` | 结束后持久化 | - |
| `--yes` | 非交互模式 | 关闭 |
| `-h`, `--help` | 查看帮助 | - |

---

## 8. 输出内容

每次执行会生成一个独立日志目录，里面通常包括：

```text
results_autotune_<server>_<timestamp>/
├── environment.txt
├── ping.txt
├── sysctl_before_full.txt
├── client_qdisc_before.txt
├── summary_all_runs.csv
├── coarse_winners.tsv
├── fine_aggregate.csv
├── report.md
├── coarse_001_....json
├── coarse_001_....err
├── fine_00x_....json
├── fine_00x_....err
└── confirm_....json
```

其中最重要的是：

- `summary_all_runs.csv`：所有测试结果总表
- `fine_aggregate.csv`：复测阶段聚合结果
- `report.md`：适合直接查看或归档的最终报告
- `*.json`：iperf3 原始 JSON 结果
- `*.err`：该轮 iperf3 stderr

---

## 9. 最终动作说明

脚本结束后支持三种处理方式：

### `rollback`

回滚到运行脚本前的本地状态；如果启用了远端调优，也会一起回滚远端。

适合：

- 临时测速
- 基准测试
- 不希望污染系统配置

### `keep`

保留当前最佳参数到**当前运行态**，但不写入持久化配置。

适合：

- 想先观察几小时或几天
- 还不想写入 `/etc/sysctl.d/`

### `persist`

把最佳参数写入：

- 本地：`/etc/sysctl.d/99-iperf3-reverse-autotune.conf`
- 远端：`/etc/sysctl.d/99-iperf3-reverse-autotune.conf`

并在需要时创建 systemd service 来恢复 `qdisc`。

适合：

- 已经验证过结果稳定
- 想让重启后也继续生效

---

## 10. 推荐实践

### 推荐 1：使用 iperf3-remote.sh 调优两端

如果能 SSH 到 server，建议用 `iperf3-remote.sh`（自动调优服务端+本地）。

### 推荐 2：先用默认参数

默认的 `--profile balanced` 已经够用。

### 推荐 3：把 `--max-mbps` 填成真实上限

BDP 估算依赖服务端真实带宽，填准确才有效。

---

## 11. 已知注意事项

1. 这是 **单流** 调优脚本，不是多流聚合吞吐优化器。
2. 这是针对 **反向测试 `-R`** 设计的，不是正向 `client -> server` 的通用调优器。
3. 若远端 SSH 不能免密、不能 root、缺少 `tc/sysctl/ip`，远端调优将无法使用。
4. 某些云厂商内核、容器环境、受限 VPS 可能不允许修改部分 sysctl / qdisc。
5. `persist` 会写系统配置，请先确认你理解这些参数对业务流量的影响。

---

## 12. 一个典型工作流

### 临时测速

```bash
sudo ./iperf3.sh \
  --server 1.2.3.4 \
  --max-mbps 1000 \
  --rollback \
  --yes
```

### 找最优并暂时保留

```bash
sudo ./iperf3.sh \
  --server 1.2.3.4 \
  --max-mbps 1000 \
  --keep \
  --yes
```

### 确认稳定后持久化

```bash
sudo ./iperf3.sh \
  --server 1.2.3.4 \
  --max-mbps 1000 \
  --persist \
  --yes
```

---

## 13. 为什么叫 `iperf3.sh`

因为它就是一个可以直接复制、赋权、运行的单文件脚本：

```bash
chmod +x iperf3.sh
sudo ./iperf3.sh
```

适合：

- 自己机器上临时跑
- 上传 GitHub 直接给别人用
- 配合 issue / PR 做问题复现
- 放在运维工具仓库里长期维护

---

## 14. 免责声明

本脚本会修改系统网络参数与 qdisc。虽然脚本具备快照、回滚、异常退出自动清理逻辑，但在生产环境执行前，仍建议你：

- 先在测试环境验证
- 先使用 `rollback` 模式熟悉行为
- 再考虑 `persist`

---


