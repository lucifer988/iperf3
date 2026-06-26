# iperf3-tune

`iperf3-tune` 是一个面向 Debian / Ubuntu 服务器的 iperf3 网络性能调优与测速工具。

它主要用于：

- 检测本机网络瓶颈
- 自动安装 Debian / Ubuntu 依赖
- 调整 Linux 网络参数
- 调整网卡队列、MTU、offload 等配置
- 通过 SSH 同步调优远端 iperf3 server
- 运行 iperf3 基准测试
- 优化单流 `iperf3 -R` 下行测速
- 自动扫描 TCP 拥塞算法、TCP 窗口和 CPU 绑核
- 后台运行测速任务
- 查看进度、日志和最终结果
- 回退本机和远端调优

> 适用系统：Debian 11 / Debian 12 / Ubuntu 20.04 / Ubuntu 22.04 / Ubuntu 24.04  
> 推荐权限：root  
> 推荐场景：VPS、独立服务器、10G/25G/40G 网络测试、跨境链路测试、iperf3 单流调优

---

## 目录

- [1. 快速开始](#1-快速开始)
- [2. Debian / Ubuntu 环境准备](#2-debian--ubuntu-环境准备)
- [3. 安装 iperf3-tune](#3-安装-iperf3-tune)
- [4. 升级 iperf3-tune](#4-升级-iperf3-tune)
- [5. 基础命令说明](#5-基础命令说明)
- [6. 最常用命令](#6-最常用命令)
- [7. 远端服务器 SSH 配置](#7-远端服务器-ssh-配置)
- [8. iperf3 server 准备](#8-iperf3-server-准备)
- [9. optimize 完整优化](#9-optimize-完整优化)
- [10. scan 自动扫描](#10-scan-自动扫描)
- [11. single 单流模式](#11-single-单流模式)
- [12. 后台运行](#12-后台运行)
- [13. 查看结果](#13-查看结果)
- [14. 回退配置](#14-回退配置)
- [15. 常见问题](#15-常见问题)
- [16. 推荐使用流程](#16-推荐使用流程)

---

## 1. 快速开始

### 1.1 本机安装

```bash
sudo apt update
sudo apt install -y git curl ca-certificates

git clone https://github.com/lucifer988/iperf3.git
cd iperf3
sudo ./install.sh
```

验证安装：

```bash
which -a iperf3-tune
iperf3-tune --version
iperf3-tune --help
```

---

### 1.2 最推荐的完整优化命令

请把下面的占位符替换成你的远端服务器信息：

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --scan \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user <SSH_USER> \
  --ssh-pass '<SSH_PASSWORD>' \
  --profile aggressive \
  --detach \
  --yes
```

参数含义：

| 参数 | 说明 |
|---|---|
| `optimize` | 执行完整流程：检测、本机调优、远端调优、测速 |
| `--scan` | 自动扫描拥塞算法、TCP 窗口、CPU 核 |
| `--server <SERVER_IP>` | iperf3 server 地址 |
| `--ssh-host <SERVER_IP>` | 远端 SSH 地址，通常和 server IP 一样 |
| `--ssh-user <SSH_USER>` | 远端 SSH 用户，常见为 `root` |
| `--ssh-pass '<SSH_PASSWORD>'` | 远端 SSH 密码 |
| `--profile aggressive` | 使用较激进调优参数 |
| `--detach` | 后台运行 |
| `--yes` | 自动确认，不交互询问 |

---

### 1.3 更安全的密码文件方式

不建议把 SSH 密码直接写在命令行里，因为 shell history 可能记录命令。

建议使用密码文件：

```bash
sudo install -m 600 /dev/null /root/.iperf3_remote.pw
sudo nano /root/.iperf3_remote.pw
```

把远端 SSH 密码写入该文件后运行：

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --scan \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user <SSH_USER> \
  --ssh-pass-file /root/.iperf3_remote.pw \
  --profile aggressive \
  --detach \
  --yes
```

---

### 1.4 SSH 私钥方式

如果你使用 SSH key 登录远端服务器：

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --scan \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user <SSH_USER> \
  --ssh-key ~/.ssh/id_rsa \
  --profile aggressive \
  --detach \
  --yes
```

---

## 2. Debian / Ubuntu 环境准备

### 2.1 本机基础依赖

Debian / Ubuntu 推荐先安装：

```bash
sudo apt update
sudo apt install -y \
  git \
  curl \
  ca-certificates \
  jq \
  iperf3 \
  ethtool \
  iproute2 \
  sysstat \
  bc \
  tar \
  iputils-ping \
  util-linux \
  openssh-client \
  sshpass
```

说明：

| 包名 | 用途 |
|---|---|
| `git` | 拉取项目 |
| `jq` | 解析 JSON 测试结果 |
| `iperf3` | 网络测速 |
| `ethtool` | 查看和调整网卡参数 |
| `iproute2` | 提供 `ip`、`tc`、`ss` 等命令 |
| `sysstat` | 提供 `mpstat` 等 CPU 统计命令 |
| `bc` | 浮点计算 |
| `iputils-ping` | RTT 检测 |
| `openssh-client` | SSH 连接远端 |
| `sshpass` | 使用密码方式自动 SSH |

---

### 2.2 远端服务器基础依赖

远端服务器也建议安装：

```bash
sudo apt update
sudo apt install -y \
  iperf3 \
  jq \
  ethtool \
  iproute2 \
  sysstat \
  bc \
  tar \
  iputils-ping \
  util-linux \
  openssh-server
```

如果远端也需要被 SSH 登录，请确认 SSH 服务正在运行：

```bash
sudo systemctl enable --now ssh
sudo systemctl status ssh
```

Ubuntu 上服务名通常是 `ssh`。  
部分系统也可能叫 `sshd`：

```bash
sudo systemctl enable --now sshd
sudo systemctl status sshd
```

---

### 2.3 检查 iperf3

本机检查：

```bash
iperf3 --version
```

远端检查：

```bash
ssh <SSH_USER>@<SERVER_IP> 'iperf3 --version'
```

---

## 3. 安装 iperf3-tune

### 3.1 克隆项目

```bash
git clone https://github.com/lucifer988/iperf3.git
cd iperf3
```

### 3.2 执行安装

```bash
sudo ./install.sh
```

安装完成后，通常会生成：

```text
/usr/local/sbin/iperf3-tune
/usr/local/sbin/iperf3-tuned
```

### 3.3 验证安装

```bash
which -a iperf3-tune
iperf3-tune --version
iperf3-tune --help
```

建议确认实际执行路径是：

```text
/usr/local/sbin/iperf3-tune
```

如果 `which -a iperf3-tune` 输出多个路径，请优先使用完整路径：

```bash
sudo /usr/local/sbin/iperf3-tune --version
```

---

## 4. 升级 iperf3-tune

如果你已经安装过旧版，请执行：

```bash
cd ~/iperf3
git pull --ff-only
sudo ./install.sh
hash -r
```

然后确认新版参数是否存在：

```bash
sudo /usr/local/sbin/iperf3-tune --version
sudo /usr/local/sbin/iperf3-tune --help | grep -E -- '--scan|--scan-window|--scan-congestion|--scan-cpu'
```

如果能看到 `--scan`，说明当前版本支持自动扫描。

---

## 5. 基础命令说明

命令格式：

```bash
iperf3-tune <COMMAND> [OPTIONS]
```

常用命令：

| 命令 | 用途 |
|---|---|
| `detect` | 只检测系统瓶颈，不修改配置 |
| `tune` | 只应用本机调优，不测速 |
| `bench` | 只运行 iperf3 测试，不改系统 |
| `optimize` | 完整流程：检测、本机调优、远端调优、测速 |
| `rollback` | 回退本机和远端调优 |
| `status` | 查看当前优化状态和最近测试结果 |
| `watch` | 实时查看后台任务进度 |
| `tail` | 跟随后台任务日志 |
| `stop` | 停止后台任务 |

---

## 6. 最常用命令

### 6.1 只检测本机

```bash
sudo /usr/local/sbin/iperf3-tune detect
```

适合首次运行前检查系统状态。

---

### 6.2 只调优本机

```bash
sudo /usr/local/sbin/iperf3-tune tune \
  --profile aggressive \
  --yes
```

适合只想改本机网络参数，不想马上测速的情况。

---

### 6.3 只测速，不改系统

```bash
sudo /usr/local/sbin/iperf3-tune bench \
  --server <SERVER_IP> \
  --time 30 \
  --repeats 3
```

适合先确认当前链路速度。

---

### 6.4 完整优化，不自动扫描

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user <SSH_USER> \
  --ssh-key ~/.ssh/id_rsa \
  --profile aggressive \
  --time 30 \
  --repeats 3 \
  --yes
```

---

### 6.5 完整优化，自动扫描

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --scan \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user <SSH_USER> \
  --ssh-key ~/.ssh/id_rsa \
  --profile aggressive \
  --detach \
  --yes
```

---

## 7. 远端服务器 SSH 配置

`iperf3-tune` 如果要调优远端 server，需要能 SSH 登录远端。

### 7.1 测试 SSH 登录

```bash
ssh <SSH_USER>@<SERVER_IP>
```

如果使用非 22 端口：

```bash
ssh -p <SSH_PORT> <SSH_USER>@<SERVER_IP>
```

---

### 7.2 使用 SSH 密码

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user <SSH_USER> \
  --ssh-pass '<SSH_PASSWORD>' \
  --profile aggressive \
  --yes
```

如果 SSH 端口不是 22：

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user <SSH_USER> \
  --ssh-port <SSH_PORT> \
  --ssh-pass '<SSH_PASSWORD>' \
  --profile aggressive \
  --yes
```

---

### 7.3 使用密码文件

创建密码文件：

```bash
sudo install -m 600 /dev/null /root/.iperf3_remote.pw
sudo nano /root/.iperf3_remote.pw
```

运行：

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user <SSH_USER> \
  --ssh-pass-file /root/.iperf3_remote.pw \
  --profile aggressive \
  --yes
```

---

### 7.4 使用 SSH 私钥

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user <SSH_USER> \
  --ssh-key ~/.ssh/id_rsa \
  --profile aggressive \
  --yes
```

如果是 ed25519 key：

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user <SSH_USER> \
  --ssh-key ~/.ssh/id_ed25519 \
  --profile aggressive \
  --yes
```

---

## 8. iperf3 server 准备

### 8.1 远端前台启动 server

在远端服务器执行：

```bash
iperf3 -s -p 5201
```

### 8.2 远端后台启动 server

```bash
iperf3 -s -p 5201 -D
```

### 8.3 检查端口监听

远端执行：

```bash
ss -lntp | grep 5201
```

### 8.4 防火墙放行端口

如果使用 UFW：

```bash
sudo ufw allow 5201/tcp
sudo ufw reload
```

如果使用 iptables，请根据你的防火墙规则放行 TCP 5201。

---

## 9. optimize 完整优化

`optimize` 是最常用的命令。它会尽量执行完整流程：

```text
detect → tune → remote_tune → bench
```

也就是：

1. 检测本机瓶颈
2. 调整本机 Linux 网络参数
3. 通过 SSH 调整远端 server
4. 运行 iperf3 测试
5. 保存结果

推荐命令：

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user <SSH_USER> \
  --ssh-key ~/.ssh/id_rsa \
  --profile aggressive \
  --time 30 \
  --repeats 3 \
  --yes
```

如果使用密码：

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user <SSH_USER> \
  --ssh-pass '<SSH_PASSWORD>' \
  --profile aggressive \
  --time 30 \
  --repeats 3 \
  --yes
```

---

## 10. scan 自动扫描

`--scan` 会自动尝试寻找更好的组合。

它相当于同时开启：

```text
--scan-congestion
--scan-window
--scan-cpu
```

扫描内容：

| 参数 | 作用 |
|---|---|
| `--scan-congestion` | 扫描 TCP 拥塞算法 |
| `--scan-window` | 扫描 TCP 窗口 |
| `--scan-cpu` | 扫描本机和远端 CPU 绑核 |
| `--scan-time` | 设置扫描阶段单次测试时长 |
| `--scan-repeats` | 设置扫描阶段每个点重复次数 |
| `--window-list` | 自定义 TCP 窗口候选 |
| `--congestion-list` | 自定义拥塞算法候选 |

---

### 10.1 推荐自动扫描命令

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --scan \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user <SSH_USER> \
  --ssh-key ~/.ssh/id_rsa \
  --profile aggressive \
  --detach \
  --yes
```

---

### 10.2 使用密码自动扫描

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --scan \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user <SSH_USER> \
  --ssh-pass '<SSH_PASSWORD>' \
  --profile aggressive \
  --detach \
  --yes
```

---

### 10.3 缩短扫描时间

如果你想更快完成：

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --scan \
  --scan-time 8 \
  --scan-repeats 1 \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user <SSH_USER> \
  --ssh-key ~/.ssh/id_rsa \
  --profile aggressive \
  --detach \
  --yes
```

---

### 10.4 自定义窗口扫描

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --scan-window \
  --window-list 32M,64M,96M,128M,192M,256M \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user <SSH_USER> \
  --ssh-key ~/.ssh/id_rsa \
  --profile aggressive \
  --yes
```

---

### 10.5 自定义拥塞算法扫描

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --scan-congestion \
  --congestion-list bbr,cubic,bbr2 \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user <SSH_USER> \
  --ssh-key ~/.ssh/id_rsa \
  --profile aggressive \
  --yes
```

> 注意：并不是所有内核都支持 `bbr2`。如果系统不支持，脚本会跳过不可用项。

---

## 11. single 单流模式

`--single` 适合测试单条 TCP 流的极限速度。

常见场景：

- 单连接下载速度不够
- `iperf3 -R` 下行单流速度低
- 多流速度很高，但单流速度很低
- 跨境链路单连接速度瓶颈明显

---

### 11.1 单流测试

```bash
sudo /usr/local/sbin/iperf3-tune bench \
  --single \
  --server <SERVER_IP> \
  --time 30 \
  --repeats 3
```

---

### 11.2 单流完整优化

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --single \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user <SSH_USER> \
  --ssh-key ~/.ssh/id_rsa \
  --profile aggressive \
  --time 30 \
  --repeats 3 \
  --yes
```

---

### 11.3 单流 + 自动扫描

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --single \
  --scan \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user <SSH_USER> \
  --ssh-key ~/.ssh/id_rsa \
  --profile aggressive \
  --detach \
  --yes
```

---

### 11.4 指定链路带宽

如果你知道链路大概是 10G：

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --single \
  --bandwidth 10000 \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user <SSH_USER> \
  --ssh-key ~/.ssh/id_rsa \
  --profile aggressive \
  --yes
```

单位是 Mbit/s：

| 链路 | `--bandwidth` |
|---|---|
| 1G | `1000` |
| 2.5G | `2500` |
| 5G | `5000` |
| 10G | `10000` |
| 25G | `25000` |
| 40G | `40000` |
| 100G | `100000` |

---

### 11.5 指定 TCP 窗口

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --single \
  --window 128M \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user <SSH_USER> \
  --ssh-key ~/.ssh/id_rsa \
  --profile aggressive \
  --yes
```

---

### 11.6 指定 CPU 核

本机 CPU：

```bash
--cpu 2
```

远端 server CPU：

```bash
--cpu-remote 6
```

完整示例：

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --single \
  --cpu 2 \
  --cpu-remote 6 \
  --window 128M \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user <SSH_USER> \
  --ssh-key ~/.ssh/id_rsa \
  --profile aggressive \
  --yes
```

---

## 12. 后台运行

### 12.1 后台启动

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --scan \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user <SSH_USER> \
  --ssh-key ~/.ssh/id_rsa \
  --profile aggressive \
  --detach \
  --yes
```

---

### 12.2 查看进度

```bash
sudo /usr/local/sbin/iperf3-tune watch
```

---

### 12.3 查看日志

```bash
sudo /usr/local/sbin/iperf3-tune tail
```

---

### 12.4 停止后台任务

```bash
sudo /usr/local/sbin/iperf3-tune stop
```

---

### 12.5 查看最终状态

```bash
sudo /usr/local/sbin/iperf3-tune status
```

---

## 13. 查看结果

测试结果默认保存在：

```text
/var/lib/iperf3-tune/state.json
```

查看完整结果：

```bash
sudo jq . /var/lib/iperf3-tune/state.json
```

查看关键信息：

```bash
sudo jq '.timestamp,.server,.direction,.profile,.single,.best' /var/lib/iperf3-tune/state.json
```

查看扫描得到的最佳组合：

```bash
sudo jq '.best_congestion,.best_window,.best_cpu_local,.best_cpu_remote,.sender' /var/lib/iperf3-tune/state.json
```

日志目录通常是：

```text
/var/log/iperf3-tune/
```

状态目录通常是：

```text
/var/lib/iperf3-tune/
```

配置目录通常是：

```text
/etc/iperf3-tune/
```

---

## 14. 回退配置

### 14.1 只回退本机

```bash
sudo /usr/local/sbin/iperf3-tune rollback --yes
```

---

### 14.2 回退本机和远端

SSH key 方式：

```bash
sudo /usr/local/sbin/iperf3-tune rollback \
  --ssh-host <SERVER_IP> \
  --ssh-user <SSH_USER> \
  --ssh-key ~/.ssh/id_rsa \
  --yes
```

密码方式：

```bash
sudo /usr/local/sbin/iperf3-tune rollback \
  --ssh-host <SERVER_IP> \
  --ssh-user <SSH_USER> \
  --ssh-pass '<SSH_PASSWORD>' \
  --yes
```

---

## 15. 常见问题

### 15.1 报错：`未知选项: --scan`

原因通常是系统里正在执行旧版本 `iperf3-tune`。

排查：

```bash
which -a iperf3-tune
iperf3-tune --version
iperf3-tune --help | grep -E -- '--scan|--scan-window|--scan-congestion|--scan-cpu'
```

重新安装最新版：

```bash
cd ~/iperf3
git pull --ff-only
sudo ./install.sh
hash -r
```

再确认：

```bash
sudo /usr/local/sbin/iperf3-tune --version
sudo /usr/local/sbin/iperf3-tune --help | grep -E -- '--scan|--scan-window|--scan-congestion|--scan-cpu'
```

建议直接使用完整路径运行：

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --scan \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user <SSH_USER> \
  --ssh-key ~/.ssh/id_rsa \
  --profile aggressive \
  --detach \
  --yes
```

---

### 15.2 报错：`--server IP 必填`

`bench` 和 `optimize` 必须指定远端 iperf3 server：

```bash
--server <SERVER_IP>
```

示例：

```bash
sudo /usr/local/sbin/iperf3-tune bench --server <SERVER_IP>
```

---

### 15.3 SSH 连接失败

先手动测试：

```bash
ssh <SSH_USER>@<SERVER_IP>
```

如果端口不是 22：

```bash
ssh -p <SSH_PORT> <SSH_USER>@<SERVER_IP>
```

确认能登录后再运行 `iperf3-tune`。

---

### 15.4 远端 iperf3 端口连不上

远端启动 server：

```bash
iperf3 -s -p 5201 -D
```

远端检查监听：

```bash
ss -lntp | grep 5201
```

本机测试连接：

```bash
iperf3 -c <SERVER_IP> -p 5201 -t 10
```

如果连接失败，请检查：

- 云服务商安全组
- Debian / Ubuntu 防火墙
- iptables / nftables
- 远端 iperf3 是否运行
- 端口是否写错

---

### 15.5 reverse 下速度不理想

默认方向是：

```bash
--direction reverse
```

也就是：

```bash
iperf3 -c <SERVER_IP> -R
```

reverse 模式下：

```text
本机 = 接收端
远端 server = 发送端
```

所以如果你想优化下行速度，远端 server 才是关键发送端。

建议一定提供 SSH 参数：

```bash
--ssh-host <SERVER_IP> --ssh-user <SSH_USER>
```

这样脚本才能同步调优远端发送端。

---

### 15.6 密码包含特殊字符

请用单引号包住密码：

```bash
--ssh-pass '<SSH_PASSWORD>'
```

如果密码里本身有单引号，建议使用密码文件：

```bash
--ssh-pass-file /root/.iperf3_remote.pw
```

---

### 15.7 没有 `sshpass`

Debian / Ubuntu 安装：

```bash
sudo apt update
sudo apt install -y sshpass
```

或者改用 SSH key：

```bash
--ssh-key ~/.ssh/id_rsa
```

---

### 15.8 后台任务不知道是否还在运行

查看进度：

```bash
sudo /usr/local/sbin/iperf3-tune watch
```

查看日志：

```bash
sudo /usr/local/sbin/iperf3-tune tail
```

查看状态：

```bash
sudo /usr/local/sbin/iperf3-tune status
```

停止任务：

```bash
sudo /usr/local/sbin/iperf3-tune stop
```

---

## 16. 推荐使用流程

### 第一步：安装

```bash
sudo apt update
sudo apt install -y git curl ca-certificates

git clone https://github.com/lucifer988/iperf3.git
cd iperf3
sudo ./install.sh
```

---

### 第二步：检查版本和参数

```bash
which -a iperf3-tune
sudo /usr/local/sbin/iperf3-tune --version
sudo /usr/local/sbin/iperf3-tune --help | grep -E -- '--scan|--single|--cpu-remote'
```

---

### 第三步：先检测本机

```bash
sudo /usr/local/sbin/iperf3-tune detect
```

---

### 第四步：先只测速

```bash
sudo /usr/local/sbin/iperf3-tune bench \
  --server <SERVER_IP> \
  --time 30 \
  --repeats 3
```

---

### 第五步：确认 SSH 能登录远端

```bash
ssh <SSH_USER>@<SERVER_IP>
```

---

### 第六步：完整优化

SSH key 方式：

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --scan \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user <SSH_USER> \
  --ssh-key ~/.ssh/id_rsa \
  --profile aggressive \
  --detach \
  --yes
```

密码文件方式：

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --scan \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user <SSH_USER> \
  --ssh-pass-file /root/.iperf3_remote.pw \
  --profile aggressive \
  --detach \
  --yes
```

---

### 第七步：查看进度和结果

```bash
sudo /usr/local/sbin/iperf3-tune watch
sudo /usr/local/sbin/iperf3-tune status
sudo jq . /var/lib/iperf3-tune/state.json
```

---

### 第八步：需要恢复时回退

```bash
sudo /usr/local/sbin/iperf3-tune rollback --yes
```

远端也一起回退：

```bash
sudo /usr/local/sbin/iperf3-tune rollback \
  --ssh-host <SERVER_IP> \
  --ssh-user <SSH_USER> \
  --ssh-key ~/.ssh/id_rsa \
  --yes
```

---

## 安全提醒

请不要把以下内容提交到公开仓库：

- 真实服务器 IP
- SSH 用户名
- SSH 密码
- SSH 私钥
- 密码文件
- 云厂商 token
- 防火墙后台截图
- 带有公网 IP 的测试日志

README 中建议统一使用：

```text
<SERVER_IP>
<SSH_USER>
<SSH_PASSWORD>
<SSH_PORT>
```

---

## 一句话推荐命令

如果你只是想跑完整自动优化，优先用这条：

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --scan \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user <SSH_USER> \
  --ssh-key ~/.ssh/id_rsa \
  --profile aggressive \
  --detach \
  --yes
```

如果你使用密码，不想暴露在命令历史里，优先用这条：

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --scan \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user <SSH_USER> \
  --ssh-pass-file /root/.iperf3_remote.pw \
  --profile aggressive \
  --detach \
  --yes
```
