# iperf3-tune

`iperf3-tune` 是一个面向 Linux 服务器的 iperf3 网络性能调优与测速工具，重点优化单流 `iperf3 -R` 下行带宽并尽量降低重传率。

它可以：

- 检测本机网络瓶颈（只读，不改系统）
- 调整 Linux 内核网络参数（sysctl）
- 调整网卡队列、MTU、offload、中断亲和等配置
- 通过 SSH 同步调优远端 iperf3 server（reverse 方向下 server 才是发送端）
- 运行 iperf3 基准测试并自动寻优（拥塞算法 / TCP 窗口 / CPU 绑核）
- 后台运行、查看进度、回退本机与远端配置

> 适用系统：Debian 11/12、Ubuntu 20.04/22.04/24.04，以及 RHEL 系、Arch、Alpine、openSUSE 等主流发行版
> 运行权限：`detect` / `bench` / `status` 只读，无需 root；`tune` / `optimize` / `rollback` 需要 root
> 典型场景：VPS、独立服务器、10G/25G/40G 网络、跨境链路、iperf3 单流调优

---

## ⚠️ 在生产环境使用前必读（v2.9.0）

这个工具会**激进地修改网络栈**以追求带宽。它默认对生产环境更克制，但你仍应理解它会动什么：

- **`tune` / `optimize` 会修改系统**：写 `/etc/sysctl.d/99-iperf3-tune.conf` 并 `sysctl -p`、切换 TCP 拥塞算法、停止 `irqbalance`、开启网卡 offload、调大 ring buffer、重设 RPS/RFS/XPS 与 IRQ 亲和；带 `--mtu` 时还会改网卡 MTU。这些动作可能影响已有连接、中断分布，MTU 不匹配甚至会导致网络不通。
- **v2.9.0：网卡改动现在完整可回退**，且 **LRO 默认不再开启**（对转发/桥接/虚拟化/抓包不友好，需 `--enable-lro` 才开）。只想调内核参数、完全不碰网卡硬件时用 `--no-nic-tune`。
- **先 `--dry-run` 预演**：任何 `tune` / `optimize` 都可以加 `--dry-run`，它会**只打印将要修改的内容、完全不动系统**。生产环境强烈建议先跑一遍。
- **改系统前会列清单 + 二次确认**：交互终端下会逐条列出影响项让你确认；**非交互（无 tty）环境下不会默默执行**，必须显式加 `--yes`。
- **默认不自动装依赖**：缺依赖时只会打印手动安装命令并退出，**不会**自动 `apt/yum/dnf/pacman` 装包。需要时显式加 `--auto-install`。
- **随时可回退**：`iperf3-tune rollback` 会还原 sysctl、MTU，并从备份**精确还原 offload（含 LRO）/ring buffer/RPS/XPS/IRQ 亲和**，按原始状态恢复 `irqbalance`（原本没开就不会被开起来）。
- **不要把密码写在命令行**：优先 `--ssh-key`，其次 `--ssh-ask-pass`（交互输入）或 `--ssh-pass-file`。`--ssh-pass 明文` 会进入 shell history / `ps` / 审计日志。

最稳妥的生产流程：

```bash
# 1) 只读检测，确认环境
sudo iperf3-tune detect

# 2) 预演，看看会改什么（不动系统）
sudo iperf3-tune optimize --dry-run \
  --server <SERVER_IP> --ssh-host <SERVER_IP> --ssh-key ~/.ssh/id_rsa \
  --profile aggressive

# 3) 确认无误后真正执行
sudo iperf3-tune optimize \
  --server <SERVER_IP> --ssh-host <SERVER_IP> --ssh-key ~/.ssh/id_rsa \
  --profile aggressive --yes

# 4) 不满意随时回退
sudo iperf3-tune rollback --ssh-host <SERVER_IP> --ssh-key ~/.ssh/id_rsa --yes
```

---

## 目录

- [1. 环境与前置条件](#1-环境与前置条件)
- [2. 安装](#2-安装)
- [3. 依赖管理](#3-依赖管理)
- [4. 命令总览](#4-命令总览)
- [5. 远端 SSH 与密码安全](#5-远端-ssh-与密码安全)
- [6. optimize 完整优化](#6-optimize-完整优化)
- [7. dry-run 预演](#7-dry-run-预演)
- [8. scan 自动寻优 / single 单流](#8-scan-自动寻优--single-单流)
- [9. 后台运行](#9-后台运行)
- [10. 查看结果与回退](#10-查看结果与回退)
- [11. profile 三档](#11-profile-三档)
- [12. 优雅降级行为](#12-优雅降级行为)
- [13. 常见问题](#13-常见问题)

---

## 1. 环境与前置条件

### 1.1 操作系统

仅支持 **Linux**。工具依赖 `sysctl` / procfs (`/proc/sys`) / sysfs (`/sys/class/net`) / `ethtool`，在 macOS、Windows、WSL1 上无法运行。启动时会做一次环境检查，不满足会给出**一行清晰报错**，而不是中途崩溃。

### 1.2 权限

| 命令 | 是否需要 root |
|---|---|
| `detect` `bench` `status` `watch` `tail` | 否（只读） |
| `tune` `optimize` `rollback` `stop` | 是 |

非 root 执行需要 root 的命令时，会直接提示 `sudo`，不会走到一半才失败。

### 1.3 容器 / 受限内核

容器内 `/proc/sys/net` 常常不可写、`/sys/class/net` 可能不完整。这种情况下工具**不会崩溃**：它会发出警告并跳过无法生效的步骤（例如网卡硬件优化），sysctl 能写则写。要在容器里真正调优，请在宿主机执行，或给容器 `--privileged` / `CAP_NET_ADMIN`。

### 1.4 远端 server（仅 reverse 同步调优时需要）

- 能 SSH 登录（key 或密码）
- 远端装有 `iperf3`
- 远端 sshd 允许该用户登录（注意 `PermitRootLogin` / `PasswordAuthentication`）

远端不可达时工具会**优雅降级**：跳过远端步骤、继续本地，详见[第 12 节](#12-优雅降级行为)。

---

## 2. 安装

```bash
git clone https://github.com/lucifer988/iperf3.git
cd iperf3
sudo ./install.sh
```

安装后生成：

```text
/usr/local/sbin/iperf3-tune
/usr/local/sbin/iperf3-tuned
```

验证：

```bash
iperf3-tune --version      # 应显示 2.9.0
iperf3-tune --help
```

> `install.sh` 会安装一组基础依赖（`jq iperf3 ethtool iproute2 sysstat` 等）。这是安装阶段的一次性动作，和运行时「默认不自动装包」是两回事。

升级：

```bash
cd ~/iperf3 && git pull --ff-only && sudo ./install.sh && hash -r
```

---

## 3. 依赖管理

运行时依赖：`jq iperf3 ethtool ip awk sed grep sort tee`（用密码认证时还需 `sshpass`）。

**v2.7.0 起，运行时默认不自动安装依赖。** 缺依赖时只打印手动安装命令并退出：

```bash
# Debian/Ubuntu
sudo apt-get install -y jq iperf3 ethtool iproute2 sysstat
# RHEL/CentOS
sudo yum install -y jq iperf3 ethtool iproute sysstat
# Arch
sudo pacman -S jq iperf3 ethtool iproute2 sysstat
# Alpine
sudo apk add jq iperf3 ethtool iproute2 sysstat
```

如果你确实希望脚本自动装（例如临时测试机），显式开启：

```bash
sudo iperf3-tune optimize --server <SERVER_IP> --auto-install ...
```

`--auto-install` 的选择会同步传递给远端（远端也会按同样策略装/不装）。

---

## 4. 命令总览

```bash
iperf3-tune <COMMAND> [OPTIONS]
```

| 命令 | 用途 |
|---|---|
| `detect` | 只检测瓶颈，不改系统 |
| `tune` | 只应用本机调优 |
| `bench` | 只测速，不改系统 |
| `optimize` | 完整流程：检测 → 本机调优 → 远端调优 → 测速 |
| `rollback` | 回退本机与远端调优 |
| `status` | 查看状态与最近结果 |
| `watch` / `tail` / `stop` | 后台任务进度 / 日志 / 停止 |

常用全局选项：

| 选项 | 说明 |
|---|---|
| `--dry-run` | 预演，只打印将修改的内容，不动系统 |
| `-y, --yes` | 跳过确认（无 tty 改系统时必须加） |
| `--auto-install` | 允许自动安装缺失依赖（默认关闭） |
| `--no-stop-irqbalance` | 调优时不停止 irqbalance |
| `--no-nic-tune` | 只调 sysctl，完全不动网卡硬件（offload/ring/RPS/XPS/IRQ） |
| `--enable-lro` | 额外开启 LRO（默认不开；转发/桥接/虚拟化/抓包场景不友好） |
| `--profile NAME` | `balanced` / `aggressive` / `extreme` |
| `-v, --verbose` / `--json` | 详细日志 / JSON 输出 |

---

## 5. 远端 SSH 与密码安全

`optimize` 在 reverse（下行）方向下，**远端 server 才是发送端**，所以同步调优远端往往是关键。需要能 SSH 登录远端。

认证方式按**推荐程度从高到低**：

### 5.1 SSH 私钥（最推荐）

```bash
sudo iperf3-tune optimize \
  --server <SERVER_IP> --ssh-host <SERVER_IP> \
  --ssh-user <SSH_USER> --ssh-key ~/.ssh/id_rsa \
  --profile aggressive --yes
```

### 5.2 交互输入密码（推荐，不留痕）

`--ssh-ask-pass` 会在终端隐式读取密码，写入一个权限 600 的临时文件，**不进入 shell history、不出现在 `ps` / argv**，用完自动删除：

```bash
sudo iperf3-tune optimize \
  --server <SERVER_IP> --ssh-host <SERVER_IP> \
  --ssh-user <SSH_USER> --ssh-ask-pass \
  --profile aggressive --yes
```

### 5.3 密码文件

```bash
sudo install -m 600 /dev/null /root/.iperf3_remote.pw
sudo nano /root/.iperf3_remote.pw      # 写入密码

sudo iperf3-tune optimize \
  --server <SERVER_IP> --ssh-host <SERVER_IP> \
  --ssh-user <SSH_USER> --ssh-pass-file /root/.iperf3_remote.pw \
  --profile aggressive --yes
```

### 5.4 命令行明文密码（不推荐）

```bash
# 会被 shell history / ps / 审计系统记录，工具会对此告警
--ssh-pass '<SSH_PASSWORD>'
```

> **关于 `--detach` + 密码**：后台模式下，工具会自动把命令行/交互密码转存为权限 600 的文件，后台进程改用 `--ssh-pass-file`，因此**不会在 `ps` 里暴露明文**；任务结束或 `stop` 时该文件被清理。

非 22 端口加 `--ssh-port <SSH_PORT>`。

---

## 6. optimize 完整优化

`optimize` 执行：`detect → tune → remote_tune → bench`。

```bash
sudo iperf3-tune optimize \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> --ssh-user <SSH_USER> --ssh-key ~/.ssh/id_rsa \
  --profile aggressive --time 30 --repeats 3 --yes
```

执行前会列出本次会修改的所有项并请你确认（除非 `--yes`）。reverse 方向若未提供 `--ssh-host`，工具会提醒你「只能调本机接收端，发挥有限」。

---

## 7. dry-run 预演

任何 `tune` / `optimize` 加 `--dry-run`，只打印不执行：

```bash
sudo iperf3-tune optimize --dry-run \
  --server <SERVER_IP> --ssh-host <SERVER_IP> --ssh-key ~/.ssh/id_rsa \
  --profile aggressive
```

它会展示：将写入的 sysctl 内容预览、将对网卡做的 offload/ring/MTU/IRQ 改动、将在远端执行的命令。**不会**连远端、不会改本机、不会跑测试。生产上线前先看这个。

---

## 8. scan 自动寻优 / single 单流

```bash
# 单流自动寻优：扫拥塞算法(server端) + TCP 窗口 + CPU 绑核，选最优组合
sudo iperf3-tune optimize --scan \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> --ssh-user <SSH_USER> --ssh-key ~/.ssh/id_rsa \
  --profile aggressive --yes

# 仅测单流：自动绑核(NUMA 对齐) + 按 BDP 算窗口 + 零拷贝
sudo iperf3-tune optimize --single \
  --server <SERVER_IP> --ssh-host <SERVER_IP> --ssh-key ~/.ssh/id_rsa --yes
```

寻优相关参数（`--scan-window` / `--scan-congestion` / `--scan-cpu` / `--window-list` / `--congestion-list` / `--scan-time` / `--scan-repeats` 等）见 `iperf3-tune --help`。SSH 不可达时，需要远端的扫描项会自动跳过，本地扫描照常进行。

---

## 9. 后台运行

高速链路测试时间长、容易因 SSH 断开而中断，建议 `--detach` 放后台：

```bash
sudo iperf3-tune optimize --detach --yes \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> --ssh-user <SSH_USER> --ssh-key ~/.ssh/id_rsa \
  --profile aggressive

sudo iperf3-tune watch    # 实时进度
sudo iperf3-tune tail     # 跟随日志
sudo iperf3-tune stop     # 停止
```

---

## 10. 查看结果与回退

```bash
sudo iperf3-tune status
sudo jq . /var/lib/iperf3-tune/state.json
```

回退（本机）：

```bash
sudo iperf3-tune rollback --yes
```

回退会：还原备份的 sysctl、删除 `/etc/sysctl.d/99-iperf3-tune.conf`、还原 MTU，并从 `nic.before.json` 精确还原 offload（含 LRO）/ring buffer/RPS/XPS/IRQ 亲和，按原始状态恢复 `irqbalance`。v2.9.0 起网卡改动可完整自动回退。

连远端一起回退：

```bash
sudo iperf3-tune rollback \
  --ssh-host <SERVER_IP> --ssh-user <SSH_USER> --ssh-key ~/.ssh/id_rsa --yes
```

---

## 11. profile 三档

| profile | 缓冲区 | 适用 | 业务影响 |
|---|---|---|---|
| `balanced` | 64MB | 1G / 2.5G 链路 | 小 |
| `aggressive` | 256MB | 10G 链路（推荐） | 中 |
| `extreme` | 1GB | 25G+ / 长肥管道 | **显著**（含关闭 rp_filter 等，生产慎用） |

`extreme` 会关闭反向路径过滤（`rp_filter=0`）等较激进项，确认时会单独提示。

---

## 12. 优雅降级行为

v2.7.0 重点改进了「环境不理想时不崩溃」：

- **OS 不是 Linux / bash 太老**：启动即给出一行明确报错。
- **缺 root**：需要 root 的命令直接提示 `sudo`，不会执行一半失败。
- **缺依赖**：打印手动安装命令并退出（除非 `--auto-install`）。
- **探测不到主网卡**（无默认路由 / 容器 / 策略路由）：不再 `die`；网卡相关步骤跳过并提示用 `PRIMARY_IFACE=eth0 iperf3-tune ...` 显式指定，sysctl 调优仍生效。
- **SSH 不可达 / 认证失败**：远端枚举、远端调优、远端拥塞算法/CPU 寻优全部跳过，只 `warn` 并继续本地，不会因为一条远端命令非零而整体退出。
- **容器 `/proc/sys` 不可写**：警告并跳过无法生效的 sysctl/网卡项。

---

## 13. 常见问题

### 13.1 为什么不再自动安装依赖了？

出于生产安全。脚本自动 `apt/yum` 装包在生产上不可控（源不可用、内网无公网、包管理器被锁），还可能引入意外变更。默认改为「告诉你装什么」，需要时用 `--auto-install` 显式开启。

### 13.2 提示「无法探测主网卡」怎么办？

常见于容器、多网卡策略路由、无默认路由的测试机。显式指定网卡即可：

```bash
sudo PRIMARY_IFACE=eth0 iperf3-tune optimize --server <SERVER_IP> ...
```

### 13.3 SSH 连不上会怎样？

工具会打印 SSH 报错原因并跳过所有远端步骤，本地调优与测速继续。先手动确认能登录：

```bash
ssh -p <SSH_PORT> <SSH_USER>@<SERVER_IP>
```

### 13.4 reverse 下速度不理想？

默认方向 `--direction reverse`（即 `iperf3 -c <IP> -R`），此时**本机是接收端、远端 server 是发送端**。要提升下行，必须提供 `--ssh-host` 让工具同步调优远端发送端。

### 13.5 提示 TCP 窗口算太大 / iperf3 因 `-w` 跑不起来？（v2.8.0 已修复）

旧版按 `2.5×BDP` 算窗口，且带宽默认取**网卡标称速率**（`/sys/class/net/*/speed`）。如果你实际宽带只有 1G，但网卡是 10G/25G/40G，窗口会被按 10G/25G 算成几百 MB，再加上没和内核 `net.core.wmem_max/rmem_max` 上限对比，`iperf3 -w` 就会超上限被静默裁剪（吞吐崩）甚至直接报错。

v2.8.0 的处理：

- 自动窗口改为 `2.0×BDP`，并新增**绝对上限** `WINDOW_MAX`（默认 `64M`，1G 宽带绰绰有余）。
- 设 `-w` 前一律夹到 `min(算出值, wmem_max, rmem_max)`，保证请求值不超内核上限。
- 系统缓冲仍是默认小值（< 2MiB，即没跑过 `tune`）时**不再硬塞 `-w`**，改为不带 `-w` 交给内核自动扩张（autotune 比钉死一个小窗口更稳、吞吐更好）。
- 手动 `--window` 会校验格式并按内核上限夹取（超上限自动夹小并告警，不会再把 iperf3 跑挂）。

如果你的网卡标称速率和实际宽带不符，建议显式告诉它真实带宽：

```bash
# 实际 1G 宽带，避免用网卡标称 25G 算窗口
iperf3-tune bench --server <IP> --bandwidth 1000

# 或直接限定窗口绝对上限
iperf3-tune optimize --server <IP> --window-max 32M
```

### 13.6 改了之后业务受影响 / 想完全恢复？

先 `rollback`；若仍有残留（不可逆 offload），移除 `/etc/sysctl.d/99-iperf3-tune.conf` 后重启最干净。`extreme` 档影响最大，生产建议从 `aggressive` 起步并先 `--dry-run`。

### 13.7 远端 iperf3 端口连不上？

```bash
# 远端启动 server
iperf3 -s -p 5201 -D
ss -lntp | grep 5201
```

检查云安全组、防火墙（ufw/iptables/nftables）、端口是否写错。

### 13.8 没有 sshpass？

```bash
sudo apt-get install -y sshpass     # 或改用更安全的 --ssh-key
```

### 13.9 测试全失败，但脚本退出码是 0？（v2.9.0 已修复）

旧版即使所有 iperf3 测试都失败，仍会打印「最优: null 流, null Mbps」并以退出码 0 结束，自动化系统据此会误判调优成功。

v2.9.0 起：单流与多流若无任何成功样本，会写入 `status:"failed"` 的状态 JSON（含失败原因），并以**非零退出码**结束，不再打印误导性的 null 结果。`status` 命令读到失败状态时也会明确显示「失败」而非 null。守护进程（iperf3-tuned）遇到失败不会用失败结果覆盖已有的良好 baseline。

### 13.10 我担心网卡 offload / IRQ 改动回不去？（v2.9.0 已加固）

v2.9.0 在调优前会把要改的 offload 特性（含 LRO）、ring buffer、RPS/RFS/XPS、IRQ 亲和的**当前值**完整备份到 `nic.before.json`，`rollback` 时精确还原，并按原始状态决定要不要重启 `irqbalance`。

如果你的机器承担转发、桥接、虚拟化或抓包等业务，建议：

```bash
# 完全不动网卡硬件，只调内核 sysctl
sudo iperf3-tune optimize --server <IP> --no-nic-tune

# 或保留网卡调优但不开 LRO（默认就不开）
sudo iperf3-tune optimize --server <IP>
```

### 13.11 64 核 / 128 核机器上 RPS/XPS 配置不对？（v2.9.0 已修复）

旧版用 bash 整数位移生成 CPU mask，在 64 核及以上会溢出/回绕，导致 RPS/XPS/IRQ 亲和配错。v2.9.0 改用逗号分组的 32bit cpumask 生成器（如 64 核全置位为 `ffffffff,ffffffff`），符合内核要求，不再溢出。

---

## 安全提醒

请不要把真实服务器 IP、SSH 用户名/密码/私钥、密码文件、云厂商 token、带公网 IP 的测试日志提交到公开仓库。文档统一用 `<SERVER_IP>` `<SSH_USER>` `<SSH_PASSWORD>` `<SSH_PORT>` 占位。

---

## 一句话推荐命令（生产）

```bash
# 私钥 + 先预演，确认后去掉 --dry-run 再加 --yes 执行
sudo iperf3-tune optimize --dry-run \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> --ssh-user <SSH_USER> --ssh-key ~/.ssh/id_rsa \
  --profile aggressive
```
