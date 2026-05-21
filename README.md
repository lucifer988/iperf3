# iperf3

<p align="center">
  <strong>面向高带宽链路的 iperf3 自动调优与基准测试工具</strong>
</p>

<p align="center">
  <a href="https://github.com/lucifer988/iperf3"><img alt="Shell" src="https://img.shields.io/badge/language-Shell-89e051?style=flat-square"></a>
  <img alt="Version" src="https://img.shields.io/badge/version-v2.1.0-blue?style=flat-square">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-green?style=flat-square">
  <img alt="Linux" src="https://img.shields.io/badge/platform-Linux-orange?style=flat-square">
</p>

`iperf3-tune` 是一个用于 **检测瓶颈、应用 TCP/网卡调优、运行 iperf3 多流寻优、后台监控与回退** 的 Linux 工具。它的核心目标很明确：

> 在 iperf3 场景下尽可能提升带宽，并尽可能降低 TCP 重传率。

相比保守型系统优化工具，本项目会主动调整 sysctl、网卡 offload、ring buffer、RPS/RFS/XPS、IRQ 亲和性等参数。因此它更适合裸金属、高速 VPS、跨机房链路、长肥管道、10G/25G+ 链路等场景。

---

## 目录

* [特性](#特性)
* [适用场景](#适用场景)
* [安装](#安装)
* [快速开始](#快速开始)
* [命令总览](#命令总览)
* [参数详解](#参数详解)
* [典型用法](#典型用法)
* [profile 调优档位](#profile-调优档位)
* [寻优算法](#寻优算法)
* [后台运行与断线恢复](#后台运行与断线恢复)
* [定时优化与金丝雀监控](#定时优化与金丝雀监控)
* [文件路径](#文件路径)
* [安全建议](#安全建议)
* [回退与卸载](#回退与卸载)
* [常见问题](#常见问题)
* [更新日志](#更新日志)
* [License](#license)

---

## 特性

* **一键瓶颈检测**：自动检查 CPU、内存、网卡、offload、ring buffer、RPS 等状态。
* **三档调优策略**：`balanced`、`aggressive`、`extreme`，覆盖 1G 到 25G+ 场景。
* **多流自动寻优**：自动测试 `1 / 2 / 4 / 8 / 16 / 32` 并发流，找出最优并发数。
* **带宽与重传联合评分**：不是简单选择最高带宽，而是按带宽和重传率综合评分。
* **重复测试取中位数**：每个并发档位默认跑 3 次，降低单次抖动影响。
* **后台运行**：`--detach` 可脱离 SSH 终端，即使连接断开测试也会继续。
* **实时进度**：`watch` 查看测试进度，`tail` 跟踪日志，`stop` 停止后台任务。
* **远端同步调优**：可通过 SSH 对 iperf3 服务端同步应用同等优化。
* **精确回退**：应用前备份 sysctl 和网卡状态，支持 `rollback` 回退。
* **daemon 定时任务**：支持每周自动重新优化，并每 6 小时执行金丝雀检查。
* **JSON 输出**：便于自动化系统、面板、CI 或日志系统接入。

---

## 适用场景

推荐用于：

* 10G、25G 或更高速率的服务器链路测试；
* 跨区域、跨机房、跨运营商长距离链路；
* BBR / CUBIC / fq 等 TCP 栈调优验证；
* iperf3 单流、多流带宽压测；
* 高速 VPS、裸金属服务器、专线网络验收；
* 想快速判断瓶颈来自 CPU、内存、网卡还是 TCP 缓冲区的场景。

不建议直接用于：

* 对稳定性极度敏感的生产业务机器；
* 多租户共享环境；
* 不允许修改 sysctl 或网卡 offload 的系统；
* 对安全策略有严格要求的公网机器，尤其是 `extreme` profile。

> `iperf3-tune` 的优化目标偏向压测结果，不保证真实业务流量获得同比例收益。

---

## 安装

### 1. 克隆项目

```bash
git clone https://github.com/lucifer988/iperf3.git iperf3-tune
cd iperf3-tune
```

### 2. 执行安装

```bash
sudo ./install.sh
```

安装脚本会自动完成：

| 动作     | 说明                                                                 |
| ------ | ------------------------------------------------------------------ |
| 检测系统   | 识别发行版、内核、CPU、内存等信息                                                 |
| 安装依赖   | Debian/Ubuntu 使用 `apt`，RHEL/CentOS/Fedora 等使用 `yum`/`dnf`          |
| 检查 BBR | 尝试加载 `tcp_bbr` 并检查拥塞控制可用性                                          |
| 安装脚本   | 安装到 `/usr/local/sbin/iperf3-tune` 和 `/usr/local/sbin/iperf3-tuned` |
| 创建目录   | 创建配置、状态、日志目录                                                       |

依赖项包括：

```text
jq iperf3 ethtool iproute2/iproute sysstat bc tar
```

安装完成后验证：

```bash
iperf3-tune --help
iperf3-tuned --help
```

---

## 快速开始

### 第一步：准备 iperf3 服务端

在远端服务器上启动 iperf3 server：

```bash
iperf3 -s -p 5201
```

如果使用防火墙，请放行 TCP 5201：

```bash
# firewalld
sudo firewall-cmd --add-port=5201/tcp --permanent
sudo firewall-cmd --reload

# ufw
sudo ufw allow 5201/tcp
```

### 第二步：在本机检测系统瓶颈

```bash
sudo iperf3-tune detect
```

这一步只读系统信息，不会修改 sysctl 或网卡配置。

### 第三步：后台运行完整优化流程

```bash
sudo iperf3-tune optimize --detach \
  --server 1.2.3.4 \
  --ssh-host 1.2.3.4 --ssh-user root --ssh-key ~/.ssh/id_rsa \
  --profile aggressive \
  --time 30 \
  --repeats 3
```

这条命令会执行：

```text
detect → tune → remote tune → bench
```

也就是：

1. 检测本机瓶颈；
2. 应用本机优化；
3. 通过 SSH 同步调优远端；
4. 运行 iperf3 单流基准和多流寻优。

### 第四步：查看进度

```bash
sudo iperf3-tune watch
```

查看日志：

```bash
sudo iperf3-tune tail
```

中途停止：

```bash
sudo iperf3-tune stop
```

---

## 命令总览

### `iperf3-tune` 主命令

| 命令         | 是否修改系统 | 用途                       |
| ---------- | -----: | ------------------------ |
| `detect`   |      否 | 检测 CPU、内存、网卡瓶颈           |
| `tune`     |      是 | 仅应用本机 sysctl + 网卡优化      |
| `bench`    |      否 | 仅运行 iperf3 测试，不改系统参数     |
| `optimize` |      是 | 完整流程：检测、调优、远端同步、测试       |
| `rollback` |      是 | 回退优化前的 sysctl 配置，并尝试远端回退 |
| `status`   |      否 | 查看当前优化状态和最近测试结果          |
| `watch`    |      否 | 实时查看后台任务进度               |
| `tail`     |      否 | 跟踪后台任务日志                 |
| `stop`     |      是 | 停止后台任务及相关 iperf3 进程      |

### `iperf3-tuned` daemon 命令

| 命令          | 用途                                              |
| ----------- | ----------------------------------------------- |
| `init`      | 初始化 daemon 配置，写入 `/etc/iperf3-tune/config.json` |
| `install`   | 安装 systemd timer：每周优化 + 每 6 小时金丝雀检查             |
| `uninstall` | 卸载 systemd timer                                |
| `run`       | 立即执行一次完整 optimize 流程                            |
| `canary`    | 手动执行一次金丝雀检查                                     |
| `rollback`  | 回退本机和远端优化                                       |
| `status`    | 查看 daemon、timer、baseline、canary 状态              |

---

## 参数详解

### 测试参数

| 参数                             |       默认值 | 说明                                   |
| ------------------------------ | --------: | ------------------------------------ |
| `--server IP`                  |         无 | iperf3 服务端地址，`bench` 和 `optimize` 必填 |
| `--port N`                     |    `5201` | iperf3 服务端端口                         |
| `--time SECS`                  |      `30` | 每次 iperf3 测试时长，最低 5 秒                |
| `--repeats N`                  |       `3` | 每个并发档位重复测试次数，结果取中位数                  |
| `--max-parallel N`             |      `32` | 最大并发流数量                              |
| `--direction reverse\|forward` | `reverse` | `reverse` 为下行测试，`forward` 为上行测试      |
| `--mss N`                      |    `1448` | 估算 TCP 重传率时使用的 MSS                   |

`--direction` 说明：

```text
reverse：客户端接收，服务端发送，常用于测试下行
forward：客户端发送，服务端接收，常用于测试上行
```

`--mss` 建议值：

|  MTU |          建议 MSS | 说明                     |
| ---: | --------------: | ---------------------- |
| 1500 |          `1448` | 默认值，适用于常见以太网环境         |
| 9000 | `8948` 或 `8960` | jumbo frame 场景，按实际链路调整 |

> TCP 模式下 iperf3 不直接输出包数，因此工具通过 `bytes / MSS` 估算总段数，再计算重传率。

### 调优参数

| 参数                        |          默认值 | 说明                                         |
| ------------------------- | -----------: | ------------------------------------------ |
| `--profile NAME`          | `aggressive` | 调优档位：`balanced` / `aggressive` / `extreme` |
| `--congestion ALGO`       |        `bbr` | TCP 拥塞控制算法，如 `bbr`、`cubic`                 |
| `--retrans-threshold PCT` |        `1.0` | 重传率超过该阈值时提前停止寻优                            |
| `--retrans-penalty K`     |       `10.0` | 评分函数中的重传惩罚系数                               |

### 后台参数

| 参数               | 说明                                      |
| ---------------- | --------------------------------------- |
| `-d`, `--detach` | 将 `bench` 或 `optimize` 放到后台运行，脱离 SSH 终端 |
| `watch`          | 查看后台任务实时进度                              |
| `tail`           | 查看最新后台日志                                |
| `stop`           | 停止后台任务                                  |

### SSH 参数

| 参数                     |    默认值 | 说明                              |
| ---------------------- | -----: | ------------------------------- |
| `--ssh-host HOST`      |      无 | 远端 iperf3 服务器，用于远端同步调优          |
| `--ssh-user USER`      | `root` | SSH 用户                          |
| `--ssh-port N`         |   `22` | SSH 端口                          |
| `--ssh-key PATH`       |      无 | SSH 私钥路径                        |
| `--ssh-pass PASS`      |      无 | SSH 密码，通过 `SSHPASS` 环境变量传递      |
| `--ssh-pass-file PATH` |      无 | 从文件读取 SSH 密码，推荐方式，文件权限必须为 `600` |

### 通用参数

| 参数                | 说明                            |
| ----------------- | ----------------------------- |
| `-y`, `--yes`     | 非交互模式，跳过确认                    |
| `-v`, `--verbose` | 输出详细日志，并保留每次 iperf3 JSON 原始结果 |
| `--json`          | 输出 JSON，方便自动化处理               |
| `-h`, `--help`    | 查看帮助                          |
| `-V`, `--version` | 查看版本                          |

---

## 典型用法

### 1. 只检测，不修改任何配置

```bash
sudo iperf3-tune detect
```

输出内容包括：

* 主网卡；
* CPU 核心数与中断队列数；
* 软中断速率；
* CPU 使用率；
* 内存容量与可用内存；
* TCP buffer 当前值；
* GRO / TSO / GSO / LRO 状态；
* RX/TX ring buffer 当前值和最大值；
* 主要瓶颈与建议。

输出 JSON：

```bash
sudo iperf3-tune detect --json
```

---

### 2. 只应用本机调优，不跑测试

```bash
sudo iperf3-tune tune --profile aggressive
```

适合你只想快速应用 sysctl 和网卡优化，而不希望马上跑满带宽测试的场景。

使用更保守档位：

```bash
sudo iperf3-tune tune --profile balanced
```

使用极限档位：

```bash
sudo iperf3-tune tune --profile extreme
```

---

### 3. 只跑基准测试，不修改系统参数

```bash
iperf3-tune bench \
  --server 1.2.3.4 \
  --port 5201 \
  --time 30 \
  --repeats 3 \
  --max-parallel 32
```

该命令会：

1. 先跑单流基准；
2. 再依次测试多流并发；
3. 每档重复 N 次并取中位数；
4. 计算带宽、重传次数、估算重传率和评分；
5. 保存结果到 `/var/lib/iperf3-tune/state.json`。

---

### 4. 完整优化：本机 + 远端 + 测试

使用 SSH key：

```bash
sudo iperf3-tune optimize --detach \
  --server 1.2.3.4 \
  --ssh-host 1.2.3.4 \
  --ssh-user root \
  --ssh-key ~/.ssh/id_rsa \
  --profile aggressive \
  --time 30 \
  --repeats 3
```

使用 SSH 密码：

```bash
sudo iperf3-tune optimize --detach \
  --server 1.2.3.4 \
  --ssh-host 1.2.3.4 \
  --ssh-user root \
  --ssh-pass 'YOUR_PASSWORD' \
  --profile aggressive \
  --time 30 \
  --repeats 3
```

更安全的密码文件方式：

```bash
echo -n 'YOUR_PASSWORD' | sudo tee /root/.iperf3-ssh.pass >/dev/null
sudo chmod 600 /root/.iperf3-ssh.pass

sudo iperf3-tune optimize --detach \
  --server 1.2.3.4 \
  --ssh-host 1.2.3.4 \
  --ssh-user root \
  --ssh-pass-file /root/.iperf3-ssh.pass \
  --profile aggressive
```

---

### 5. 测试下行与上行

测试下行，默认 `reverse`：

```bash
sudo iperf3-tune bench \
  --server 1.2.3.4 \
  --direction reverse
```

测试上行：

```bash
sudo iperf3-tune bench \
  --server 1.2.3.4 \
  --direction forward
```

---

### 6. Jumbo Frame 场景

如果链路 MTU 为 9000，建议显式指定 MSS：

```bash
sudo iperf3-tune bench \
  --server 1.2.3.4 \
  --mss 8948 \
  --time 30 \
  --repeats 3
```

---

### 7. 更看重低重传

默认评分中，1% 重传率会扣掉约 10% 评分。若你更重视低重传，可以提高惩罚系数：

```bash
sudo iperf3-tune bench \
  --server 1.2.3.4 \
  --retrans-penalty 20
```

如果你只看带宽，不在乎重传：

```bash
sudo iperf3-tune bench \
  --server 1.2.3.4 \
  --retrans-penalty 0
```

---

### 8. 调整提前停止阈值

默认重传率超过 `1.0%` 会提前停止后续更高并发测试。

更严格：

```bash
sudo iperf3-tune bench \
  --server 1.2.3.4 \
  --retrans-threshold 0.3
```

更宽松：

```bash
sudo iperf3-tune bench \
  --server 1.2.3.4 \
  --retrans-threshold 3.0
```

---

### 9. 输出 JSON 供自动化系统使用

```bash
sudo iperf3-tune bench \
  --server 1.2.3.4 \
  --json > result.json
```

查看最优并发：

```bash
jq '.best' result.json
```

查看所有测试档位：

```bash
jq '.all[]' result.json
```

---

### 10. 查看当前状态

```bash
sudo iperf3-tune status
```

状态信息包括：

* sysctl 配置是否已应用；
* 当前 profile；
* 最近一次测试结果；
* 当前拥塞控制算法；
* 当前 qdisc；
* 后台任务 PID 状态。

---

## profile 调优档位

`iperf3-tune` 内置三档 profile。越往后越激进，对系统和其他业务影响越大。

| Profile      | 缓冲区规模 | 适合链路        | 风险等级 | 推荐用途          |
| ------------ | ----: | ----------- | ---: | ------------- |
| `balanced`   |  64MB | 1G / 2.5G   |    低 | VPS、共享机器、保守测试 |
| `aggressive` | 256MB | 10G         |    中 | 默认推荐，高速链路常用   |
| `extreme`    |   1GB | 25G+ / 长肥管道 |    高 | 极限压测、受控网络、裸金属 |

### balanced

适合 1G/2.5G 链路，重点提高 TCP buffer，并启用 BBR + fq。

```text
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
```

### aggressive

默认档位，适合 10G 链路。在 balanced 基础上提高 buffer、backlog、RPS flow entries，并调整 TCP 输出行为。

```text
net.core.rmem_max = 268435456
net.core.wmem_max = 268435456
net.core.netdev_budget = 600
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_limit_output_bytes = 1048576
net.core.rps_sock_flow_entries = 32768
```

### extreme

适合 25G+ 或长肥管道。它更偏向压测性能，会关闭部分安全/保守策略。

```text
net.core.rmem_max = 1073741824
net.core.wmem_max = 1073741824
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_limit_output_bytes = 4194304
net.ipv4.conf.all.rp_filter = 0
```

> 公网生产环境不建议直接使用 `extreme`。它可能影响安全策略和其他业务流量。

---

## 寻优算法

### 候选并发数

默认会测试以下并发流：

```text
1, 2, 4, 8, 16, 32
```

如果指定 `--max-parallel 8`，则只测试：

```text
1, 2, 4, 8
```

### 重复测试

每个并发数默认测试 3 次：

```bash
--repeats 3
```

最终取中位数，降低单次抖动的影响。

### 评分公式

每个并发档位都会计算一个 score：

```text
score = bandwidth_mbps × max(0, 1 - k × retrans_rate_pct / 100)
```

其中：

* `bandwidth_mbps`：该档位测试得到的中位带宽；
* `retrans_rate_pct`：根据重传次数和估算 TCP 段数计算出的重传率；
* `k`：重传惩罚系数，即 `--retrans-penalty`，默认 `10`。

### 早停条件

出现以下情况时会提前停止后续并发档位：

1. 当前重传率超过 `--retrans-threshold`；
2. 当前评分相比前一档下降超过 5%。

### 结果保存

结果会写入：

```text
/var/lib/iperf3-tune/state.json
/var/lib/iperf3-tune/progress.json
```

`--verbose` 模式下会额外保留每次 iperf3 原始 JSON：

```text
/var/log/iperf3-tune/last-iperf3-<streams>-<run>.json
```

---

## 后台运行与断线恢复

高速压测时，SSH 连接很容易因为带宽打满而卡顿甚至断开。建议使用：

```bash
--detach
```

示例：

```bash
sudo iperf3-tune optimize --detach \
  --server 1.2.3.4 \
  --ssh-host 1.2.3.4 \
  --ssh-user root \
  --ssh-pass-file /root/.iperf3-ssh.pass
```

后台模式会：

* 使用 `setsid` 脱离 SSH controlling terminal；
* 将 PID 写入 `/var/lib/iperf3-tune/iperf3-tune.pid`；
* 将日志写入 `/var/log/iperf3-tune/run-YYYYMMDD-HHMMSS.log`；
* 每完成一档测试就更新 `/var/lib/iperf3-tune/progress.json`。

查看实时进度：

```bash
sudo iperf3-tune watch
```

跟随日志：

```bash
sudo iperf3-tune tail
```

停止后台任务：

```bash
sudo iperf3-tune stop
```

### SSH 客户端心跳建议

如果 SSH 经常断，可以在客户端 `~/.ssh/config` 加：

```sshconfig
Host *
    ServerAliveInterval 15
    ServerAliveCountMax 6
    TCPKeepAlive yes
```

---

## 定时优化与金丝雀监控

`iperf3-tuned` 用于长期运行场景，可以自动执行周期性优化和质量检查。

### 初始化配置

交互式初始化：

```bash
sudo iperf3-tuned init
```

参数式初始化：

```bash
sudo iperf3-tuned init \
  --server 1.2.3.4 \
  --port 5201 \
  --profile aggressive \
  --time 30 \
  --repeats 3 \
  --ssh-host 1.2.3.4 \
  --ssh-user root \
  --ssh-key ~/.ssh/id_rsa \
  --yes
```

配置会写入：

```text
/etc/iperf3-tune/config.json
```

### 安装 systemd timer

```bash
sudo iperf3-tuned install
```

安装后会启用：

| Timer                       | 频率                  | 用途      |
| --------------------------- | ------------------- | ------- |
| `iperf3-tuned.timer`        | 每周日 22:00           | 执行完整优化  |
| `iperf3-tuned-canary.timer` | 开机 1 小时后开始，每 6 小时一次 | 执行金丝雀检查 |

查看状态：

```bash
sudo iperf3-tuned status
systemctl list-timers | grep iperf3
```

手动执行一次完整优化：

```bash
sudo iperf3-tuned run
```

手动执行一次金丝雀检查：

```bash
sudo iperf3-tuned canary
```

卸载 timer：

```bash
sudo iperf3-tuned uninstall
```

---

## 文件路径

| 路径                                       | 说明              |
| ---------------------------------------- | --------------- |
| `/usr/local/sbin/iperf3-tune`            | 主脚本             |
| `/usr/local/sbin/iperf3-tuned`           | daemon 脚本       |
| `/usr/local/sbin/iperf3-tune.sh`         | 主脚本兼容符号链接       |
| `/etc/iperf3-tune/`                      | 配置目录            |
| `/etc/iperf3-tune/config.json`           | daemon 配置       |
| `/etc/sysctl.d/99-iperf3-tune.conf`      | 当前应用的 sysctl 配置 |
| `/var/lib/iperf3-tune/`                  | 状态目录            |
| `/var/lib/iperf3-tune/sysctl.before.txt` | sysctl 回退快照     |
| `/var/lib/iperf3-tune/nic.before.json`   | 网卡设置快照          |
| `/var/lib/iperf3-tune/state.json`        | 最近一次 bench 结果   |
| `/var/lib/iperf3-tune/progress.json`     | 后台任务进度          |
| `/var/lib/iperf3-tune/baseline.json`     | daemon 基准结果     |
| `/var/lib/iperf3-tune/canary.json`       | 金丝雀检查历史         |
| `/var/lib/iperf3-tune/iperf3-tune.pid`   | 后台任务 PID        |
| `/var/log/iperf3-tune/`                  | 日志目录            |
| `/var/log/iperf3-tune/daemon.log`        | daemon 日志       |
| `/var/log/iperf3-tune/run-*.log`         | 后台任务日志          |

---

## 安全建议

### SSH 密码

更推荐使用 SSH key：

```bash
--ssh-key ~/.ssh/id_rsa
```

如果必须使用密码，优先使用密码文件：

```bash
echo -n 'YOUR_PASSWORD' | sudo tee /root/.iperf3-ssh.pass >/dev/null
sudo chmod 600 /root/.iperf3-ssh.pass
```

然后：

```bash
--ssh-pass-file /root/.iperf3-ssh.pass
```

不推荐长期使用：

```bash
--ssh-pass 'YOUR_PASSWORD'
```

虽然工具会通过 `SSHPASS` 环境变量传递密码，避免在 `ps`/`top` 中直接暴露，但命令本身仍可能进入 shell history。

### profile 风险

| profile      | 风险说明                         |
| ------------ | ---------------------------- |
| `balanced`   | 相对保守，一般适合多数测试环境              |
| `aggressive` | 默认推荐，但可能影响同机其他网络业务           |
| `extreme`    | 会关闭 ECN 和反向路径校验，更适合受控网络或短时压测 |

### 生产环境建议

1. 先执行 `detect`；
2. 再使用 `balanced` 或 `aggressive` 小规模测试；
3. 业务低峰期运行 `bench` 或 `optimize`；
4. 保留一个 SSH 备用会话；
5. 确认 `rollback` 可正常执行；
6. 不要在业务高峰期开启 `extreme`。

---

## 回退与卸载

### 回退本机优化

```bash
sudo iperf3-tune rollback
```

### 回退本机 + 远端

```bash
sudo iperf3-tune rollback \
  --ssh-host 1.2.3.4 \
  --ssh-user root \
  --ssh-key ~/.ssh/id_rsa
```

或密码文件：

```bash
sudo iperf3-tune rollback \
  --ssh-host 1.2.3.4 \
  --ssh-user root \
  --ssh-pass-file /root/.iperf3-ssh.pass
```

### 卸载

```bash
sudo ./uninstall.sh
```

卸载脚本会：

1. 停止并移除 systemd timer；
2. 执行 `rollback` 回退 sysctl；
3. 删除已安装脚本。

配置、日志和历史数据默认保留。如需彻底清理：

```bash
sudo rm -rf \
  /etc/iperf3-tune \
  /var/lib/iperf3-tune \
  /var/log/iperf3-tune
```

---

## 常见问题

### 1. 为什么建议使用 `--detach`？

因为 iperf3 压测可能打满链路，SSH 会卡顿甚至断开。`--detach` 会将任务放入新的 session，SSH 断开后任务仍会继续运行。

### 2. `bench` 和 `optimize` 有什么区别？

| 命令         | 是否修改系统 | 是否测试带宽 | 适用场景        |
| ---------- | -----: | -----: | ----------- |
| `bench`    |      否 |      是 | 只想测带宽，不想改系统 |
| `optimize` |      是 |      是 | 想自动调优并验证效果  |

### 3. 为什么重传率是估算值？

iperf3 TCP 模式不输出总 packets 字段，因此工具使用：

```text
estimated_segments = bytes_sent / MSS
retrans_rate = retransmits / estimated_segments × 100%
```

MSS 默认 `1448`，可以通过 `--mss` 修改。

### 4. 远端一定要提供 SSH 吗？

不一定。`--ssh-host` 只用于远端同步调优。如果不提供，工具会跳过远端调优，只对本机进行优化和测试。

但 `--server` 仍然是必须的，因为 iperf3 客户端需要连接服务端。

### 5. `--ssh-host` 和 `--server` 可以不同吗？

可以。一般情况下它们相同：

```bash
--server 1.2.3.4 --ssh-host 1.2.3.4
```

如果 iperf3 服务地址和 SSH 管理地址不同，也可以分别指定。

### 6. 找不到主网卡怎么办？

工具会按以下顺序探测：

1. IPv4 默认路由网卡；
2. IPv6 默认路由网卡；
3. `/sys/class/net` 下第一个 `up` 的物理网卡。

如果仍失败，可显式指定：

```bash
sudo PRIMARY_IFACE=eth0 iperf3-tune detect
```

### 7. BBR 不可用怎么办？

BBR 通常需要较新的 Linux 内核。如果 `tcp_bbr` 不可用，可以改用 cubic：

```bash
sudo iperf3-tune tune \
  --profile aggressive \
  --congestion cubic
```

### 8. 如何查看原始 iperf3 JSON？

使用 `--verbose`：

```bash
sudo iperf3-tune bench \
  --server 1.2.3.4 \
  --verbose
```

原始 JSON 会保存在：

```text
/var/log/iperf3-tune/last-iperf3-*.json
```

---

## 更新日志

### v2.1.0

* 修复 TCP 重传率始终显示 `0.000%` 的问题。
* TCP 模式下改用 `bytes / MSS` 估算总 TCP 段数。
* 输出原始重传次数，例如 `重传 1234 次 (0.123%)`。
* 新增 `--mss N` 参数，适配不同 MTU / jumbo frame 场景。
* `--verbose` 模式保留 iperf3 原始 JSON。
* `state.json` / `progress.json` 新增 `retransmits`、`est_segments`、`bytes_sent` 字段。

### v2.0

* 新增 `--detach` 后台运行。
* 新增 `watch`、`tail`、`stop` 子命令。
* 支持进度增量保存。
* SSH 密码改用 `SSHPASS` 环境变量传递。
* ethtool 解析改为段头定位，避免固定行偏移。
* 引入多档中位数寻优。
* 引入评分函数 `bandwidth × (1 - k × retrans_rate)`。
* sysctl 支持精确备份和回退。

---

## License

MIT
