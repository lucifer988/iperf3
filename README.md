# iperf3-tune

`iperf3-tune` 是一个面向 Linux 的 iperf3 网络调优与测速辅助工具，目标是提升 iperf3 实测吞吐，尤其适合单流、反向测试 `-R`、跨地域高 RTT、VPS/云服务器下行测速等场景。

当前源码版本：`2.9.5`

## 功能概览

`iperf3-tune` 可以做这些事：

* 检测当前系统网络瓶颈；
* 应用 TCP/sysctl 调优；
* 调整网卡 offload、ring buffer、RPS/XPS、IRQ 亲和；
* 自动选择 TCP 拥塞控制算法；
* 自动估算或扫描 TCP 窗口；
* 单流测速时自动绑核；
* 支持 iperf3 零拷贝发送；
* 支持本机和远端双端调优；
* 支持 SSH 私钥、SSH 密码、交互式密码输入；
* 支持 `--scan` 自动寻优；
* 支持 `--dry-run` 预演；
* 支持 `rollback` 回退；
* 支持 systemd timer 定时重新优化；
* 支持金丝雀测速监控。

## 支持系统

安装脚本支持常见 Linux 发行版：

* Debian / Ubuntu / Mint / Kali / Pop / Deepin
* RHEL / CentOS / Rocky / AlmaLinux / Fedora / Amazon Linux / Oracle Linux / openEuler
* Arch / Manjaro / EndeavourOS / Garuda
* Alpine
* openSUSE / SLES

脚本依赖 Linux 的 `sysctl`、`procfs`、`sysfs`、`ethtool`，不支持 macOS 或 Windows 原生环境。

## 安装

推荐使用 `bash install.sh`，不要直接依赖脚本可执行位。

```bash
git clone --depth=1 --branch main https://github.com/lucifer988/iperf3.git
cd iperf3
sudo bash install.sh
```

安装完成后会安装：

```text
/usr/local/sbin/iperf3-tune
/usr/local/sbin/iperf3-tuned
/usr/local/sbin/iperf3-tune.sh -> /usr/local/sbin/iperf3-tune
/etc/iperf3-tune/
/var/lib/iperf3-tune/
/var/log/iperf3-tune/
```

验证安装：

```bash
/usr/local/sbin/iperf3-tune --version
/usr/local/sbin/iperf3-tune selftest
/usr/local/sbin/iperf3-tune --help
```

当前版本应输出：

```text
2.9.5
```

确认当前 shell 调用的是新版：

```bash
type -a iperf3-tune
which -a iperf3-tune
```

如果 PATH 里有旧版本，建议直接使用全路径：

```bash
/usr/local/sbin/iperf3-tune --version
```

## 升级 / 干净重装

```bash
cd ~

rm -rf ~/iperf3
sudo rm -f /usr/local/sbin/iperf3-tune \
           /usr/local/sbin/iperf3-tune.sh \
           /usr/local/sbin/iperf3-tuned

git clone --depth=1 --branch main https://github.com/lucifer988/iperf3.git
cd ~/iperf3

sudo bash install.sh

hash -r

/usr/local/sbin/iperf3-tune --version
/usr/local/sbin/iperf3-tune selftest
type -a iperf3-tune
```

## 快速开始

### 1. 仅检测，不修改系统

```bash
sudo iperf3-tune detect
```

### 2. 仅本机调优，不测速

```bash
sudo iperf3-tune tune --profile aggressive
```

### 3. 完整流程：检测 + 本机调优 + 远端调优 + 测速

使用 SSH 私钥：

```bash
sudo iperf3-tune optimize --server 1.2.3.4 --port 5201 --ssh-host 1.2.3.4 --ssh-user root --ssh-port 22 --ssh-key ~/.ssh/id_rsa --profile aggressive --time 30 --repeats 3 --yes
```

使用 SSH 密码交互输入：

```bash
sudo iperf3-tune optimize --server 1.2.3.4 --port 5201 --ssh-host 1.2.3.4 --ssh-user root --ssh-port 22 --ssh-ask-pass --profile aggressive --time 30 --repeats 3 --yes
```

运行后会提示输入 SSH 密码。输入时终端通常不会显示字符或星号，输完回车即可。

## 重要说明：reverse 和 forward

默认方向是：

```text
--direction reverse
```

也就是 iperf3 的 `-R` 模式。

在 `reverse` 模式下：

```text
远端 server 是发送端
本机 client 是接收端
```

所以做下行测速时，远端 server 的调优非常重要。建议同时提供：

```bash
--ssh-host 1.2.3.4
```

这样脚本可以登录远端进行同步调优、启动 iperf3 server、扫描远端拥塞算法和 CPU 绑核。

如果要测上行，使用：

```bash
--direction forward
```

## 自动扫描寻优

### 一键扫描

```bash
sudo iperf3-tune optimize --scan --server 1.2.3.4 --port 5201 --ssh-host 1.2.3.4 --ssh-user root --ssh-port 22 --ssh-ask-pass --profile aggressive --time 30 --repeats 3 --yes
```

`--scan` 会组合启用：

```text
--scan-congestion
--scan-window
--scan-cpu
```

扫描逻辑大致是：

```text
拥塞算法 -> TCP 窗口 -> CPU 绑核
```

并按带宽和重传表现选择最优组合。

### 只扫描拥塞算法

```bash
sudo iperf3-tune optimize --scan-congestion --server 1.2.3.4 --ssh-host 1.2.3.4 --ssh-user root --ssh-ask-pass --yes
```

自定义拥塞算法列表：

```bash
--congestion-list bbr,cubic,bbr2
```

### 只扫描 TCP 窗口

```bash
sudo iperf3-tune optimize --scan-window --server 1.2.3.4 --ssh-host 1.2.3.4 --ssh-user root --ssh-ask-pass --yes
```

自定义窗口列表：

```bash
--window-list 16M,32M,64M,96M
```

### 只扫描 CPU

```bash
sudo iperf3-tune optimize --scan-cpu --server 1.2.3.4 --ssh-host 1.2.3.4 --ssh-user root --ssh-ask-pass --yes
```

在 `reverse` 模式下，server 是发送端，CPU 扫描会优先关注远端发送端。

### 调整扫描时长

扫描阶段默认比正式测试短。可以手动指定：

```bash
--scan-time 10
--scan-repeats 1
```

例如：

```bash
sudo iperf3-tune optimize --scan --scan-time 15 --scan-repeats 2 --server 1.2.3.4 --ssh-host 1.2.3.4 --ssh-user root --ssh-ask-pass --yes
```

## SSH 认证方式

### 推荐：SSH 私钥

```bash
--ssh-key ~/.ssh/id_rsa
```

完整示例：

```bash
sudo iperf3-tune optimize --server 1.2.3.4 --ssh-host 1.2.3.4 --ssh-user root --ssh-key ~/.ssh/id_rsa --yes
```

### 推荐：交互式密码

```bash
--ssh-ask-pass
--sudo-ask-pass
```

示例：

```bash
sudo iperf3-tune optimize --server 1.2.3.4 --ssh-host 1.2.3.4 --ssh-user root --ssh-port 22 --ssh-ask-pass --sudo-ask-pass --yes
```

这种方式不会把 SSH 密码直接写进 shell history。

### sudo 密码单独指定

如果远端 SSH 密码和 sudo 密码不同，优先显式提供 sudo 密码：

```bash
--sudo-pass 'your_sudo_password'
```

或：

```bash
--sudo-pass-file /root/.ssh/iperf3-sudo-pass
```

也可以交互输入：

```bash
--sudo-ask-pass
```

示例：

```bash
sudo iperf3-tune optimize --server 1.2.3.4 --ssh-host 1.2.3.4 --ssh-user admin --ssh-ask-pass --sudo-ask-pass --yes
```

### 不推荐：命令行明文密码

```bash
--ssh-pass 'your_password'
```

示例：

```bash
sudo iperf3-tune optimize --server 1.2.3.4 --ssh-host 1.2.3.4 --ssh-user root --ssh-pass 'your_password' --yes
```

注意：命令行明文密码可能出现在 shell history、进程参数或审计日志中，不建议生产使用。

### 密码文件

```bash
--ssh-pass-file /root/.ssh/iperf3-pass
```

建议权限：

```bash
chmod 600 /root/.ssh/iperf3-pass
```

## 依赖安装

从当前版本起，脚本在本机仍保持保守策略：默认不自动安装本机缺失依赖，缺依赖时会提示手动安装命令；如需允许本机自动安装，可显式加：

```bash
--auto-install
```

但在 `optimize` 的远端流程里，只要你提供了可登录且可提权的 SSH 凭据，脚本会默认自动完成这些动作：

```text
1. SSH 登录远端
2. 自动判断 root / sudo 免密 / sudo 密码提权
3. 自动安装远端缺失依赖（至少包括 iperf3 / jq / ethtool / iproute2 / sysstat / sshpass）
4. 自动执行远端 tune
5. 自动启动并校验远端 iperf3 -s
```

也就是说，生产使用时远端通常不需要你提前手工装 `iperf3` 或其它依赖。你只需要保证：

```text
- SSH 能登录
- 登录用户是 root，或具备 sudo 权限
- 如果不是免密 sudo，可以直接额外提供 --sudo-pass / --sudo-pass-file / --sudo-ask-pass
- 如果没有单独提供 sudo 密码，脚本默认回退为“sudo 密码与 SSH 密码相同”
```

如果你只想让本机也自动安装缺失依赖，再额外加：

```bash
--auto-install
```

禁用本机自动安装：

```bash
--no-auto-install
```

密码 SSH 模式依赖 `sshpass`。如果使用：

```text
--ssh-pass
--ssh-pass-file
--ssh-ask-pass
```

但系统没有 `sshpass`，可以手动安装：

Debian / Ubuntu：

```bash
sudo apt-get install -y sshpass
```

或者让脚本安装：

```bash
--auto-install
```

## 常用命令

### detect

仅检测系统瓶颈，不修改系统：

```bash
sudo iperf3-tune detect
```

### tune

只应用本机调优，不跑 iperf3 测试：

```bash
sudo iperf3-tune tune --profile aggressive
```

### bench

只跑 iperf3 测试，不做系统调优：

```bash
sudo iperf3-tune bench --server 1.2.3.4 --port 5201 --direction reverse --time 30 --repeats 3
```

### optimize

完整流程：

```bash
sudo iperf3-tune optimize --server 1.2.3.4 --port 5201 --direction reverse --ssh-host 1.2.3.4 --ssh-user root --ssh-ask-pass --profile aggressive --time 30 --repeats 3 --yes
```

### rollback

回退本机调优：

```bash
sudo iperf3-tune rollback
```

带远端回退：

```bash
sudo iperf3-tune rollback --ssh-host 1.2.3.4 --ssh-user root --ssh-ask-pass --yes
```

### status

查看状态：

```bash
sudo iperf3-tune status
```

### selftest

检查当前安装的脚本关键修复是否生效：

```bash
iperf3-tune selftest
```

## profile 档位

支持三档：

```text
balanced
aggressive
extreme
```

推荐选择：

| profile    | 适合场景            | 说明          |
| ---------- | --------------- | ----------- |
| balanced   | 1G / 2.5G 普通链路  | 比较稳妥，影响较小   |
| aggressive | 10G 或希望尽量跑满单流   | 默认推荐        |
| extreme    | 25G+、高 RTT、长肥管道 | 更激进，对业务影响更大 |

使用示例：

```bash
sudo iperf3-tune tune --profile balanced
sudo iperf3-tune tune --profile aggressive
sudo iperf3-tune tune --profile extreme
```

生产环境建议先用：

```bash
sudo iperf3-tune tune --profile aggressive --dry-run
```

确认影响项后再执行正式调优。

## dry-run 预演

`--dry-run` 只打印将要修改的内容，不实际修改系统。

```bash
sudo iperf3-tune tune --profile aggressive --dry-run
```

完整流程预演：

```bash
sudo iperf3-tune optimize --server 1.2.3.4 --ssh-host 1.2.3.4 --ssh-user root --ssh-ask-pass --profile aggressive --dry-run
```

## 非交互执行

修改系统的命令会列出影响项并要求确认。

非交互环境中必须加：

```bash
--yes
```

例如：

```bash
sudo iperf3-tune optimize --server 1.2.3.4 --ssh-host 1.2.3.4 --ssh-user root --ssh-ask-pass --profile aggressive --yes
```

## 单流优化

仅测试单流：

```bash
sudo iperf3-tune optimize --single --server 1.2.3.4 --ssh-host 1.2.3.4 --ssh-user root --ssh-ask-pass --yes
```

`--single` 等价于只关注单流测试，适合排查单线程跑不满的问题。

手动指定最大并发流：

```bash
--max-parallel 8
```

例如：

```bash
sudo iperf3-tune bench --server 1.2.3.4 --max-parallel 8
```

## TCP 窗口相关

手动指定 TCP 窗口：

```bash
--window 64M
```

示例：

```bash
sudo iperf3-tune bench --server 1.2.3.4 --window 64M
```

指定窗口上限：

```bash
--window-max 96M
```

手动指定链路带宽，用于 BDP 估算：

```bash
--bandwidth 2000
```

单位是 Mbit/s。例如 2Gbps：

```bash
sudo iperf3-tune optimize --server 1.2.3.4 --bandwidth 2000 --profile aggressive --yes
```

## CPU 绑核

手动指定本机 CPU 核：

```bash
--cpu 2
```

手动指定远端 server CPU 核：

```bash
--cpu-remote 3
```

示例：

```bash
sudo iperf3-tune optimize --server 1.2.3.4 --ssh-host 1.2.3.4 --ssh-user root --ssh-ask-pass --cpu 2 --cpu-remote 3 --yes
```

自动扫描 CPU：

```bash
--scan-cpu
```

## 零拷贝

默认启用 iperf3 零拷贝发送。

禁用零拷贝：

```bash
--no-zerocopy
```

示例：

```bash
sudo iperf3-tune bench --server 1.2.3.4 --no-zerocopy
```

## MTU / Jumbo Frame

设置 MTU：

```bash
--mtu 9000
```

示例：

```bash
sudo iperf3-tune optimize --server 1.2.3.4 --ssh-host 1.2.3.4 --ssh-user root --ssh-ask-pass --mtu 9000 --yes
```

注意：MTU 9000 需要本机、远端和中间链路都支持。否则可能导致丢包或连接异常。

## 网卡硬件调优开关

默认会尝试做网卡相关优化，包括：

```text
offload
ring buffer
RPS/RFS/XPS
IRQ affinity
```

只调 sysctl，不动网卡硬件：

```bash
--no-nic-tune
```

示例：

```bash
sudo iperf3-tune tune --profile aggressive --no-nic-tune
```

默认不启用 LRO，因为 LRO 对转发、桥接、虚拟化、抓包等场景不友好。

显式启用 LRO：

```bash
--enable-lro
```

不停止 irqbalance：

```bash
--no-stop-irqbalance
```

## 指定主网卡

脚本会自动探测主网卡。如果探测失败，可以通过环境变量指定：

```bash
PRIMARY_IFACE=eth0 sudo iperf3-tune tune --profile aggressive
```

完整示例：

```bash
PRIMARY_IFACE=ens3 sudo iperf3-tune optimize --server 1.2.3.4 --ssh-host 1.2.3.4 --ssh-user root --ssh-ask-pass --yes
```

## JSON 输出

需要机器可读输出时：

```bash
--json
```

示例：

```bash
sudo iperf3-tune detect --json
```

## 后台运行

`bench` 和 `optimize` 支持后台运行：

```bash
--detach
```

示例：

```bash
sudo iperf3-tune optimize --detach --server 1.2.3.4 --ssh-host 1.2.3.4 --ssh-user root --ssh-key ~/.ssh/id_rsa --yes
```

查看日志：

```bash
sudo iperf3-tune tail
```

停止任务：

```bash
sudo iperf3-tune stop
```

## systemd 定时任务 / 金丝雀监控

安装脚本会安装 `iperf3-tuned`，但不会自动启用 systemd timer。

初始化配置：

```bash
sudo iperf3-tuned init
```

也可以非交互初始化：

```bash
sudo iperf3-tuned init --server 1.2.3.4 --port 5201 --direction reverse --ssh-host 1.2.3.4 --ssh-user root --ssh-key ~/.ssh/id_rsa --profile aggressive --time 30 --repeats 3 --yes
```

安装定时任务：

```bash
sudo iperf3-tuned install
```

默认 timer：

```text
主优化任务：每周日 22:00
金丝雀检查：每 6 小时一次
```

立即跑一次完整流程：

```bash
sudo iperf3-tuned run
```

手动触发一次金丝雀检查：

```bash
sudo iperf3-tuned canary
```

查看 daemon 状态：

```bash
sudo iperf3-tuned status
```

卸载 timer：

```bash
sudo iperf3-tuned uninstall
```

回退本机和远端：

```bash
sudo iperf3-tuned rollback
```

## 常用完整示例

### 远端 root + SSH 密码 + 反向下行 + 自动扫描

```bash
sudo iperf3-tune optimize --scan --auto-install --direction reverse --server 1.2.3.4 --port 5201 --ssh-host 1.2.3.4 --ssh-user root --ssh-port 22 --ssh-ask-pass --profile aggressive --time 30 --repeats 3 --yes
```

### 远端 root + SSH 私钥 + 反向下行 + 自动扫描

```bash
sudo iperf3-tune optimize --scan --auto-install --direction reverse --server 1.2.3.4 --port 5201 --ssh-host 1.2.3.4 --ssh-user root --ssh-port 22 --ssh-key ~/.ssh/id_rsa --profile aggressive --time 30 --repeats 3 --yes
```

### 只测试，不修改系统

```bash
sudo iperf3-tune bench --direction reverse --server 1.2.3.4 --port 5201 --time 30 --repeats 3
```

### 低内存 VPS 更稳的写法

```bash
sudo iperf3-tune optimize --direction reverse --server 1.2.3.4 --ssh-host 1.2.3.4 --ssh-user root --ssh-ask-pass --profile aggressive --window-max 32M --time 30 --repeats 3 --yes
```

### 2Gbps 目标链路

```bash
sudo iperf3-tune optimize --scan --direction reverse --server 1.2.3.4 --ssh-host 1.2.3.4 --ssh-user root --ssh-ask-pass --bandwidth 2000 --profile aggressive --time 30 --repeats 3 --yes
```

### 容器或受限环境只调 sysctl

```bash
sudo iperf3-tune tune --profile aggressive --no-nic-tune --yes
```

## 参数速查

### 基础参数

| 参数                   | 说明               | 默认       |           |              |
| -------------------- | ---------------- | -------- | --------- | ------------ |
| `--server IP`        | iperf3 server 地址 | 空        |           |              |
| `--port N`           | iperf3 端口        | `5201`   |           |              |
| `--direction reverse | forward`         | 测试方向     | `reverse` |              |
| `--time S`           | 每次测试时长           | `30`     |           |              |
| `--repeats N`        | 重复次数             | `3`      |           |              |
| `--max-parallel N`   | 最大并发流            | `32`     |           |              |
| `--profile balanced  | aggressive       | extreme` | 调优档位      | `aggressive` |
| `--congestion ALG`   | TCP 拥塞算法         | `bbr`    |           |              |
| `--mss N`            | MSS              | `1448`   |           |              |

### 单流 / 窗口 / CPU

| 参数                   | 说明                         |
| -------------------- | -------------------------- |
| `--single`           | 仅测试单流                      |
| `--window SIZE`      | 手动指定 iperf3 TCP 窗口，如 `64M` |
| `--window-max SIZE`  | 自动窗口上限，如 `96M`             |
| `--window-list LIST` | 扫描窗口列表，如 `16M,32M,64M`     |
| `--bandwidth MBPS`   | 链路带宽提示，单位 Mbit/s           |
| `--cpu N`            | 本机 CPU 绑核                  |
| `--cpu-remote N`     | 远端 server CPU 绑核           |
| `--no-zerocopy`      | 禁用 iperf3 `-Z` 零拷贝         |

### 扫描参数

| 参数                       | 说明         |
| ------------------------ | ---------- |
| `--scan`                 | 启用完整扫描     |
| `--scan-window`          | 扫描 TCP 窗口  |
| `--scan-congestion`      | 扫描拥塞算法     |
| `--scan-cpu`             | 扫描 CPU 绑核  |
| `--congestion-list LIST` | 自定义拥塞算法列表  |
| `--scan-time S`          | 扫描阶段每点测试时长 |
| `--scan-repeats N`       | 扫描阶段每点重复次数 |

### SSH 参数

| 参数                     | 说明                  |
| ---------------------- | ------------------- |
| `--ssh-host HOST`      | 远端 SSH 主机           |
| `--ssh-user USER`      | 远端 SSH 用户，默认 `root` |
| `--ssh-port PORT`      | SSH 端口，默认 `22`      |
| `--ssh-key PATH`       | SSH 私钥路径            |
| `--ssh-ask-pass`       | 交互式输入 SSH 密码        |
| `--ssh-pass PASS`      | 命令行明文 SSH 密码，不推荐    |
| `--ssh-pass-file FILE` | 从文件读取 SSH 密码        |

### 安全 / 运维参数

| 参数                     | 说明                    |
| ---------------------- | --------------------- |
| `--dry-run`            | 预演，不实际修改系统            |
| `--yes`                | 自动确认修改                |
| `--auto-install`       | 允许自动安装缺失依赖            |
| `--no-auto-install`    | 禁止自动安装缺失依赖            |
| `--no-nic-tune`        | 不修改网卡硬件，只调 sysctl     |
| `--enable-lro`         | 显式启用 LRO              |
| `--no-stop-irqbalance` | 不停止 irqbalance        |
| `--json`               | 输出 JSON               |
| `--verbose`            | 输出更多日志                |
| `--detach`             | 后台运行 bench / optimize |

## 文件位置

```text
/etc/iperf3-tune/                 配置目录
/var/lib/iperf3-tune/             状态目录、备份、进度文件
/var/log/iperf3-tune/             日志目录
/etc/sysctl.d/99-iperf3-tune.conf sysctl 调优配置
/usr/local/sbin/iperf3-tune       主脚本
/usr/local/sbin/iperf3-tuned      定时任务 / 金丝雀脚本
```

## 回退说明

`rollback` 会尽量恢复脚本修改过的内容，包括：

* sysctl 备份；
* 网卡 offload；
* ring buffer；
* RPS/XPS；
* IRQ 亲和；
* MTU；
* irqbalance 状态；
* 远端调优状态。

执行：

```bash
sudo iperf3-tune rollback --yes
```

带远端：

```bash
sudo iperf3-tune rollback --ssh-host 1.2.3.4 --ssh-user root --ssh-ask-pass --yes
```

## 常见问题

### 1. `未知选项: --scan`

说明当前执行到的 `iperf3-tune` 不是新版，或者 PATH 指向旧脚本。

检查：

```bash
type -a iperf3-tune
which -a iperf3-tune
iperf3-tune --version
/usr/local/sbin/iperf3-tune --version
```

干净重装：

```bash
cd ~ && rm -rf ~/iperf3 && sudo rm -f /usr/local/sbin/iperf3-tune /usr/local/sbin/iperf3-tune.sh /usr/local/sbin/iperf3-tuned && git clone --depth=1 --branch main https://github.com/lucifer988/iperf3.git && cd ~/iperf3 && sudo bash install.sh && hash -r && /usr/local/sbin/iperf3-tune --version && /usr/local/sbin/iperf3-tune --help | grep -E -- "--scan|--ssh-ask-pass|--auto-install"
```

### 2. `--ssh-ask-pass` 密码填在哪里？

不用写在命令里。保留：

```bash
--ssh-ask-pass
```

运行后终端会提示输入 SSH 密码。

如果看到：

```text
[sudo] password for xxx:
```

这是本机 sudo 密码。

如果看到：

```text
SSH password:
```

这才是远端 SSH 密码。

### 3. SSH 密码模式失败

确认远端允许密码登录：

```bash
ssh -p 22 root@$SERVER_IP
```

确认本机安装了 `sshpass`：

```bash
command -v sshpass
```

Debian / Ubuntu 安装：

```bash
sudo apt-get install -y sshpass
```

或者运行时加：

```bash
--auto-install
```

### 4. iperf3 连接失败

检查远端端口：

```bash
ss -lntp | grep 5201
```

手动启动远端 server：

```bash
iperf3 -s -p 5201
```

检查防火墙 / 安全组是否放行 TCP 5201。

### 5. 容器里提示 sysctl 写入失败

这通常说明容器没有足够权限。建议在宿主机执行，或给容器增加相关权限，例如：

```text
--privileged
CAP_NET_ADMIN
```

### 6. 装完还是旧版本

清理旧路径并重新 hash：

```bash
sudo rm -f /usr/local/sbin/iperf3-tune /usr/local/sbin/iperf3-tune.sh /usr/local/sbin/iperf3-tuned

hash -r
type -a iperf3-tune
```

然后重新安装：

```bash
cd ~/iperf3
git pull
sudo bash install.sh
hash -r
/usr/local/sbin/iperf3-tune --version
```

## 生产环境建议

生产机器上建议先这样跑：

```bash
sudo iperf3-tune tune --profile aggressive --dry-run
```

确认影响项后，再正式执行：

```bash
sudo iperf3-tune tune --profile aggressive --yes
```

对业务敏感的机器，可以降低影响：

```bash
sudo iperf3-tune tune --profile balanced --no-nic-tune --yes
```

## 推荐排障顺序

遇到问题时按这个顺序查：

```bash
iperf3-tune --version
type -a iperf3-tune
iperf3-tune selftest
iperf3-tune --help | grep -E -- "--scan|--ssh-ask-pass|--auto-install"

sudo iperf3-tune detect
ssh -p 22 root@$SERVER_IP
iperf3 -c "$SERVER_IP" -p 5201 -R -t 5
```

确认基础连通后，再跑完整优化：

```bash
sudo iperf3-tune optimize --scan --auto-install --direction reverse --server "$SERVER_IP" --port 5201 --ssh-host "$SERVER_IP" --ssh-user root --ssh-port 22 --ssh-ask-pass --profile aggressive --time 30 --repeats 3 --yes
```
