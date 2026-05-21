# iperf3

一套自动化的 iperf3 网络性能调优工具。

---

## 这是干嘛的

简单说,这工具帮你做三件事:

1. **检测**你的 Linux 服务器在哪里卡(CPU、内存、网卡、TCP 缓冲)
2. **自动调优**内核参数和网卡设置,把带宽拉到链路上限
3. **测试验证**调完之后两台机器之间能跑多少带宽、重传率多少,并告诉你"还能不能更高"或者"已经到顶了"

适合场景:

- 内网两台服务器之间的 iperf3 跑不满千兆/万兆,想知道哪里卡
- 跨地域/跨境的服务器互联,带宽达不到预期
- 部署新机器后,想一次性把 TCP 参数调到位

不适合场景:

- 想优化 Web 服务器的请求延迟(这工具调的是 TCP 吞吐,不是延迟)
- 业务流量的优化(这工具是激进调优,**会牺牲一部分稳定性换吞吐**)

---

## 你需要准备什么

| 项目 | 要求 |
|---|---|
| **客户端**(发起测试的机器) | Linux,root 权限 |
| **服务端**(对端机器) | Linux,root 权限,跑着 `iperf3 -s -p 5201`,SSH 可登录 |
| **网络** | 客户端能 ping 通服务端,能 SSH 上去 |
| **内核版本** | ≥ 4.9(为了支持 BBR 拥塞控制,看 `uname -r`) |
| **物理内存** | 至少 1GB(< 2GB 会自动用保守档位) |

服务端要先这样跑起来:

```bash
# 在服务端执行(让它一直跑,或者用 systemd/screen)
sudo iperf3 -s -p 5201
```

如果服务端有防火墙,记得放行 5201 端口。

---

## 安装

把这个目录传到客户端机器上(比如用 `scp` 或者解压压缩包),然后:

```bash
cd iperf3-tune
sudo ./install.sh
```

安装脚本会自动:

- 识别系统是 Debian/Ubuntu/CentOS/RHEL/Rocky/AlmaLinux/Fedora 中的哪个
- 装齐依赖:`jq iperf3 ethtool iproute2 sysstat bc sshpass`
- 检查 BBR 内核模块是否可用
- 把脚本装到 `/usr/local/sbin/iperf3-tune` 和 `/usr/local/sbin/iperf3-tuned`
- 创建配置目录 `/etc/iperf3-tune/`、状态目录 `/var/lib/iperf3-tune/`、日志目录 `/var/log/iperf3-tune/`

**注意**:安装本身**不会改任何系统设置**。改系统的只有 `tune` 和 `optimize` 命令。

服务端机器也要装一份(scp 这个目录过去,再跑一次 `install.sh`),或者让 `optimize` 命令通过 SSH 自动同步过去(见下文)。

---

## 用法概览

工具有 5 个常用命令,从只读到改系统排序:

| 命令 | 改系统吗 | 用途 |
|---|---|---|
| `iperf3-tune detect` | ❌ 只读 | 看看你的机器哪里有瓶颈 |
| `iperf3-tune bench` | ❌ 只读 | 跑一次测试,看现在能跑多少带宽 |
| `iperf3-tune tune` | ✅ 改 sysctl + 网卡 | 只调优,不测试 |
| `iperf3-tune optimize` | ✅ 改 sysctl + 网卡 + 远端 + 测试 | **推荐**,一把梭 |
| `iperf3-tune rollback` | ✅ 恢复原状 | 后悔了,撤销所有改动 |

辅助命令(后台运行场景):

| 命令 | 用途 |
|---|---|
| `iperf3-tune watch` | 看正在后台跑的任务进度(实时刷新) |
| `iperf3-tune tail` | `tail -f` 后台任务的日志 |
| `iperf3-tune stop` | 终止后台任务 |
| `iperf3-tune status` | 看当前的优化状态 |

---

## 具体怎么用

### 场景 1:第一次用,完全没头绪

**第一步**:先看看自己机器的情况,**不修改任何东西**:

```bash
sudo iperf3-tune detect
```

你会看到这样的报告:

```
========== 系统瓶颈报告 ==========
主网卡:        ens192 (10000 Mbps, MTU 1500)
CPU 核心:      4  中断队列: 5  RPS: true
软中断速率:    7608/s   CPU 使用率: 5%
内存:          16.0GB (可用 8.2GB)
TCP 缓冲区:    rmem_max=212992  wmem_max=212992
网卡 offload:  gro=on  tso=on  gso=on  lro=on
Ring buffer:   rx=512/4096  tx=512/4096
主要瓶颈:      nic_ring_small (severity 1/4)

建议:
  - nic_ring_small: RX ring 当前 512 < 最大 4096
```

**读懂**:

- `主要瓶颈` 行告诉你最该优化什么(severity 越大越严重,1=轻 / 4=危险)
- `TCP 缓冲区` 太小(默认才 212992 = 200KB)是 99% 的人的问题
- `Ring buffer` 没拉满也是常见问题
- 网卡 offload 全 on 是好事

**第二步**:跑一把完整流程,让脚本帮你调:

```bash
sudo iperf3-tune optimize \
    --server 1.2.3.4 \
    --ssh-host 1.2.3.4 --ssh-user root --ssh-pass 'YOUR_PASSWORD' \
    --profile aggressive --time 30 --repeats 3
```

**参数说明**:

| 参数 | 说明 |
|---|---|
| `--server 1.2.3.4` | iperf3 服务端的 IP 地址 |
| `--ssh-host 1.2.3.4` | 通过 SSH 连过去同步调优远端,通常和 server 是同一个 IP |
| `--ssh-user root` | SSH 用户名(默认就是 root,可以不写) |
| `--ssh-pass 'PASSWORD'` | SSH 密码,**一定要用单引号**包起来防止 `$`/`!` 被 bash 解析 |
| `--profile aggressive` | 调优档位,见下面表格 |
| `--time 30` | 每次 iperf3 测试跑 30 秒 |
| `--repeats 3` | 每个并发数测 3 次取中位数(防抖动) |

**三个 profile 怎么选**:

| Profile | 适合场景 | TCP 缓冲区 |
|---|---|---|
| `balanced` | 千兆链路、内存 < 2GB | 64MB |
| `aggressive`(默认) | 万兆链路、内存 ≥ 4GB | 256MB |
| `extreme` | 25G+ 链路、长肥管道(跨境/跨洋) | 1GB,**关 ECN,关反向路径过滤** |

⚠ 注意 `extreme` 会**关闭 ECN 和反向路径过滤**,公网环境会降低安全性,**只在内网或受控网络用**。

整个流程大概 5-10 分钟,跑完会有这样的最终报告:

```
========== 链路分析 ==========
  链路类型:   跨境/长距离 (RTT 200 ms, ping 丢包 1%)
  带宽利用率: 92.5% (925 Mbps / NIC 标称 1000 Mbps)
  多流提升:   3.4% (单流 894 → 4 流 925 Mbps)
  重传率评级: 正常 (0.42%)
              → BBR 设计内, 不影响吞吐

结论与建议:
  ✓ 已接近 NIC 标称速率, 两端 sysctl 已不是瓶颈
  最优配置 4 流, 推荐应用层用相同的并发数

  ✓ 本次调优已生效
     sysctl 持久化在 /etc/sysctl.d/99-iperf3-tune.conf (重启保留)
```

### 场景 2:测试时间会很长(> 5 分钟),怕 SSH 断

跨境/万兆链路、并发流测试到 32 流,整个流程可能要 10-15 分钟。SSH 在这种高负载下经常会断。

**加 `--detach` 让脚本到后台跑**:

```bash
sudo iperf3-tune optimize --detach \
    --server 1.2.3.4 \
    --ssh-host 1.2.3.4 --ssh-pass 'YOUR_PASSWORD' \
    --profile aggressive --time 30 --repeats 3
```

立即返回,你可以放心关 SSH 窗口。重新连上 SSH 后,**在任何一个 SSH 会话里**都可以查看进度:

```bash
# 滚动看每档结果(每 3 秒刷新)
sudo iperf3-tune watch

# 或者 tail 完整日志
sudo iperf3-tune tail

# 中途想停掉
sudo iperf3-tune stop
```

`watch` 输出类似:

```
========== iperf3-tune 实时进度 ==========
服务端:  1.2.3.4:5201
开始:    2026-05-21T09:33:42
更新:    2026-05-21T09:42:15
● 运行中 (PID 12345)

已测出 3 档:
  1 流: 894.5 Mbps   重传 1234 次 (0.12%)   评分 883.4
  2 流: 912.3 Mbps   重传 980 次 (0.09%)    评分 904.1
  4 流: 925.7 Mbps   重传 850 次 (0.07%)    评分 919.2
```

### 场景 3:密码不想出现在命令历史里

把密码存到文件,**文件权限必须 600**(脚本会强制检查):

```bash
echo -n 'YOUR_PASSWORD' | sudo tee /root/.iperf3-ssh.pass >/dev/null
sudo chmod 600 /root/.iperf3-ssh.pass

sudo iperf3-tune optimize --detach \
    --server 1.2.3.4 \
    --ssh-host 1.2.3.4 --ssh-user root \
    --ssh-pass-file /root/.iperf3-ssh.pass \
    --profile aggressive
```

或者用 SSH 密钥:

```bash
sudo iperf3-tune optimize --detach \
    --server 1.2.3.4 \
    --ssh-host 1.2.3.4 --ssh-user root --ssh-key ~/.ssh/id_rsa \
    --profile aggressive
```

### 场景 4:只想看现在能跑多少,不要改系统

不需要 root,**只读**:

```bash
iperf3-tune bench --server 1.2.3.4 --time 30 --repeats 3
```

会跑单流 + 多流寻优,告诉你当前网络能跑多少,但**不改任何东西**。

### 场景 5:已经调过了,想看一眼现状

```bash
sudo iperf3-tune status
```

输出:

```
========== iperf3-tune 状态 ==========
✓ sysctl 配置已应用: /etc/sysctl.d/99-iperf3-tune.conf
  当前活跃 profile: aggressive
最近测试结果:
  最优并发: 4 流, 925.7 Mbps, 重传率 0.07%
网卡 ens192 当前拥塞算法: bbr
网卡 ens192 当前 qdisc:    fq
```

### 场景 6:不满意,想恢复原状

```bash
sudo iperf3-tune rollback
```

会自动:

- 删除 `/etc/sysctl.d/99-iperf3-tune.conf`
- 把之前 backup 的每一项 sysctl 一个个恢复回去
- 加上 `--ssh-host` 参数还能同步回退远端

完全恢复成调优前的状态。

### 场景 7:让脚本每周自动重新优化

适合长期跑,网络环境可能变化的场景:

```bash
# 1) 交互式配置(会问你 IP、密码等,密码静默输入)
sudo iperf3-tuned init

# 2) 安装 systemd 定时器
sudo iperf3-tuned install
```

会装两个定时器:

- **主任务**:每周日凌晨 22:00 跑一次完整 `optimize`,刷新最优配置
- **金丝雀**:每 6 小时跑一次快速测试,如果带宽下降 > 20% 或重传率翻倍,**自动回退**

不想要了:

```bash
sudo iperf3-tuned uninstall
```

---

## 怎么看结果

最重要的就是 `optimize` 末尾的"**链路分析**"段。各字段解读:

### 链路类型(根据 RTT 自动判断)

| RTT | 类型 | 重传率多少算正常 |
|---|---|---|
| < 1ms | 本机/回环 | < 0.01% |
| 1-5ms | 同机房 LAN | < 0.1% |
| 5-50ms | 同城/同区域 | < 1% |
| 50-150ms | 跨地域 | < 3% |
| > 150ms | 跨境/长距离 | < 3-5%(BBR 能容忍) |

### 带宽利用率

`实测 Mbps / NIC 标称 Mbps × 100%`,这个数字告诉你**还有没有空间**:

- **≥ 85%**:已接近 NIC 上限,两端 sysctl 不是瓶颈
- **50-85%**:还能再调一调(比如试 `extreme` profile)
- **< 50%**:中间链路有问题(用 `mtr -rwc 50 <SERVER>` 查每跳丢包)

### 多流提升

`(多流最优带宽 - 单流带宽) / 单流带宽 × 100%`:

- **> 30%**:单流是瓶颈,应用层应该用多线程/多连接
- **< 5%**:单流已经撑满,多流没意义
- **负数**:多流反而更慢,说明 CPU 调度或者 NIC 队列分布有问题

### 重传率评级

按你的链路类型分档评级(同样的 1% 重传,LAN 算异常,跨境算正常),会直接给你一个"优秀/正常/偏高/异常"的字样和建议。

---

## 常见问题排查

### 问题:NIC 标称 10 Gbps,实测只跑出 ~1 Gbps

最常见的情况,**不是你的 sysctl 没调好,是中间链路或 ISP 限速 1Gbps**。

验证方法:

```bash
mtr -rwc 100 <SERVER_IP>
```

每一跳的延迟和丢包都看清楚,找到瓶颈跳。通常你会看到某一跳的延迟突然增大,那就是限速点。

调 sysctl **没办法**突破这个限制。要突破得换线路 / 升 ISP 套餐 / 改走不同的中间路由。

### 问题:1 流就达到最高带宽,多流不提升

说明**单 TCP 连接已经撑满链路**。这通常是好事(链路稳定),应用层不需要搞多线程。

### 问题:重传率显示 0.000%,但我知道有重传

升到 v2.2 版本(用 `iperf3-tune --version` 看)。之前的版本有 bug:用 `packets` 字段做分母,但 iperf3 TCP 模式根本不输出这个字段,导致永远显示 0%。

### 问题:寻优只测了 1 流就停了

可能你用的还是老版本(< 2.2)。新版本单流不会触发早停。或者你显式用了 `--retrans-threshold 0.5` 这种很严的值,改回默认 `--retrans-threshold 3.0` 即可。

### 问题:跑 `extreme` profile 之后业务变卡

`extreme` 关了 ECN 和反向路径过滤,缓冲区 1GB,会占用大量内存做 socket buffer。如果你机器内存 < 8GB,**不推荐用 extreme**。直接回退:

```bash
sudo iperf3-tune rollback
```

然后用 `aggressive` 或 `balanced` 重试。

### 问题:SSH 远端调优失败,提示 sshpass 找不到

```bash
# Debian / Ubuntu
sudo apt-get install -y sshpass

# CentOS / RHEL (需要先开 EPEL)
sudo yum install -y epel-release
sudo yum install -y sshpass
```

`install.sh` 应该已经装过,如果没装上手动补一下。

### 问题:`extreme` profile 跑完测试结果反而下降

256MB→1GB 缓冲并不总是更好。BDP(带宽延迟积)= 带宽 × RTT 才是真正需要的缓冲量。算一下:

- 1 Gbps × 200ms = 25 MB → 64MB(balanced)已经够用
- 10 Gbps × 200ms = 250 MB → 256MB(aggressive)够用
- 10 Gbps × 800ms = 1 GB → 这才轮到 extreme

不要为了"激进"而 extreme。

---

## 文件位置

| 路径 | 内容 |
|---|---|
| `/usr/local/sbin/iperf3-tune` | 主脚本 |
| `/usr/local/sbin/iperf3-tuned` | 定时任务脚本 |
| `/etc/iperf3-tune/config.json` | 定时任务配置(含 SSH 信息,权限 600) |
| `/etc/sysctl.d/99-iperf3-tune.conf` | 应用后的 sysctl 配置 |
| `/var/lib/iperf3-tune/sysctl.before.txt` | 应用前的 sysctl 快照(回退用) |
| `/var/lib/iperf3-tune/nic.before.json` | 应用前的网卡设置快照 |
| `/var/lib/iperf3-tune/state.json` | 最近一次完整测试结果 |
| `/var/lib/iperf3-tune/progress.json` | 当前正在跑的测试的进度(增量保存) |
| `/var/lib/iperf3-tune/iperf3-tune.pid` | 后台任务 PID |
| `/var/log/iperf3-tune/run-*.log` | 后台任务日志 |

---

## 卸载

```bash
sudo ./uninstall.sh
```

会自动:

- 停掉所有 systemd 定时器
- 调一次 `rollback` 恢复 sysctl
- 删除 `/usr/local/sbin/` 下的脚本

**保留**:配置目录 `/etc/iperf3-tune/`、状态目录 `/var/lib/iperf3-tune/`、日志目录 `/var/log/iperf3-tune/`。彻底清理:

```bash
sudo rm -rf /etc/iperf3-tune /var/lib/iperf3-tune /var/log/iperf3-tune
```

---

## License

MIT
