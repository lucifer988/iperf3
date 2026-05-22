# iperf3-tune 使用教程

## 1. 一行安装

在要运行测试的机器上执行：

```bash
git clone https://github.com/lucifer988/iperf3.git iperf3-tune && \
cd iperf3-tune && \
sudo bash install.sh
```

安装完成后检查：

```bash
iperf3-tune --version
iperf3-tune --help
iperf3-tuned --help
```

更新到最新版：

```bash
cd iperf3-tune
git pull
sudo bash install.sh
```

卸载：

```bash
cd iperf3-tune
sudo bash uninstall.sh
```

彻底删除配置、日志、历史结果：

```bash
sudo rm -rf /etc/iperf3-tune /var/lib/iperf3-tune /var/log/iperf3-tune
```

---

## 2. 先搞清楚两台机器的角色

假设你有两台机器：

```text
本机 / client：运行 iperf3-tune 命令的机器
远端 / server：跑 iperf3 server 的机器，IP 假设为 1.2.3.4
```

下面所有命令里的 `1.2.3.4` 都改成你的远端 IP。

```bash
SERVER_IP="1.2.3.4"
```

参数对应关系：

```text
--server      iperf3 测试目标，也就是远端 iperf3 server 地址
--ssh-host    通过 SSH 登录并调优的远端地址，通常和 --server 一样
--ssh-user    远端 SSH 用户，做远端调优时建议用 root
--ssh-key     SSH 私钥路径
--ssh-pass    SSH 密码，不推荐直接写在命令里
--ssh-pass-file  从文件读取 SSH 密码，推荐
```

默认测试方向是 `reverse`，等价于普通 iperf3 的 `-R`：

```text
reverse：远端 server 发送，本机 client 接收，用来测本机下行
forward：本机 client 发送，远端 server 接收，用来测本机上行
```

---

## 3. 最省事的一键完整优化

本机已经能用 SSH key 登录远端 root 时，直接执行：

```bash
SERVER_IP="1.2.3.4"

sudo iperf3-tune optimize --detach \
  --server "$SERVER_IP" \
  --ssh-host "$SERVER_IP" \
  --ssh-user root \
  --ssh-key ~/.ssh/id_rsa \
  --profile aggressive \
  --time 30 \
  --repeats 3 \
  --yes
```

查看进度：

```bash
sudo iperf3-tune watch
```

查看实时日志：

```bash
sudo iperf3-tune tail
```

查看最近一次结果：

```bash
sudo iperf3-tune status
```

停止后台任务：

```bash
sudo iperf3-tune stop
```

这条完整命令会做这些事：

```text
1. 检测本机 CPU、内存、网卡、TCP 状态
2. 调优本机 sysctl 和网卡参数
3. 通过 SSH 把脚本同步到远端
4. 在远端执行 tune
5. 尝试在远端启动 iperf3 -s
6. 执行单流测试
7. 执行多流寻优测试
8. 保存结果到 /var/lib/iperf3-tune/state.json
9. 写日志到 /var/log/iperf3-tune/
```

---

## 4. 使用 SSH 密码的一键完整优化

不要把密码直接写在命令历史里。先把密码写入 root 只读文件：

```bash
sudo install -m 600 /dev/null /root/iperf3-ssh-pass
sudo bash -c 'read -rsp "SSH password: " p; echo "$p" > /root/iperf3-ssh-pass; echo'
```

然后运行：

```bash
SERVER_IP="1.2.3.4"

sudo iperf3-tune optimize --detach \
  --server "$SERVER_IP" \
  --ssh-host "$SERVER_IP" \
  --ssh-user root \
  --ssh-pass-file /root/iperf3-ssh-pass \
  --profile aggressive \
  --time 30 \
  --repeats 3 \
  --yes
```

如果 SSH 端口不是 22：

```bash
sudo iperf3-tune optimize --detach \
  --server "$SERVER_IP" \
  --ssh-host "$SERVER_IP" \
  --ssh-user root \
  --ssh-port 2222 \
  --ssh-pass-file /root/iperf3-ssh-pass \
  --profile aggressive \
  --time 30 \
  --repeats 3 \
  --yes
```

---

## 5. 不想远端调优，只跑本机调优 + 测试

这种方式不会 SSH 到远端。远端必须已经启动 iperf3 server。

远端执行：

```bash
sudo iperf3 -s -p 5201 -D
```

本机执行：

```bash
SERVER_IP="1.2.3.4"

sudo iperf3-tune optimize --detach \
  --server "$SERVER_IP" \
  --profile aggressive \
  --time 30 \
  --repeats 3 \
  --yes
```

查看结果：

```bash
sudo iperf3-tune status
```

---

## 6. 完全不改系统，只跑测速

远端启动 iperf3 server：

```bash
sudo iperf3 -s -p 5201 -D
```

本机只跑测试：

```bash
SERVER_IP="1.2.3.4"

sudo iperf3-tune bench \
  --server "$SERVER_IP" \
  --port 5201 \
  --time 30 \
  --repeats 3 \
  --max-parallel 32
```

放到后台跑：

```bash
sudo iperf3-tune bench --detach \
  --server "$SERVER_IP" \
  --port 5201 \
  --time 30 \
  --repeats 3 \
  --max-parallel 32
```

查看：

```bash
sudo iperf3-tune watch
sudo iperf3-tune tail
sudo iperf3-tune status
```

---

## 7. 只检测瓶颈，不改系统

```bash
sudo iperf3-tune detect
```

输出里重点看：

```text
CPU 是否打满
内存是否太小
默认网卡是哪张
网卡速率
当前拥塞控制
当前 qdisc
是否支持 BBR
```

如果只想拿 JSON：

```bash
sudo iperf3-tune detect --json
```

---

## 8. 只调优本机，不跑测速

```bash
sudo iperf3-tune tune \
  --profile aggressive \
  --congestion bbr \
  --yes
```

调完查看当前状态：

```bash
sudo iperf3-tune status
```

回退本机调优：

```bash
sudo iperf3-tune rollback
```

---

## 9. 打开远端 5201 端口

远端如果启用了防火墙，需要放行 TCP 5201。

Ubuntu / Debian 使用 ufw：

```bash
sudo ufw allow 5201/tcp
sudo ufw reload
```

CentOS / Rocky / Alma / Fedora 使用 firewalld：

```bash
sudo firewall-cmd --permanent --add-port=5201/tcp
sudo firewall-cmd --reload
```

临时 iptables：

```bash
sudo iptables -I INPUT -p tcp --dport 5201 -j ACCEPT
```

远端检查 iperf3 server 是否启动：

```bash
pgrep -a iperf3
ss -lntp | grep 5201
```

手动启动：

```bash
sudo iperf3 -s -p 5201 -D
```

手动停止：

```bash
sudo pkill -f "iperf3 -s"
```

---

## 10. 测下行、上行、不同端口

默认是下行测试：

```bash
sudo iperf3-tune bench \
  --server "$SERVER_IP" \
  --direction reverse
```

上行测试：

```bash
sudo iperf3-tune bench \
  --server "$SERVER_IP" \
  --direction forward
```

使用 5202 端口：

```bash
sudo iperf3-tune bench \
  --server "$SERVER_IP" \
  --port 5202
```

对应远端也要用同一个端口：

```bash
sudo iperf3 -s -p 5202 -D
```

---

## 11. profile 怎么选

### balanced

适合普通 1G / 2.5G 机器、共享 VPS、小内存机器：

```bash
sudo iperf3-tune optimize --detach \
  --server "$SERVER_IP" \
  --ssh-host "$SERVER_IP" \
  --ssh-user root \
  --ssh-key ~/.ssh/id_rsa \
  --profile balanced \
  --time 30 \
  --repeats 3 \
  --yes
```

### aggressive

默认推荐。适合 10G、跨机房、高速 VPS、单流下行 `-R` 速度上不去的场景：

```bash
sudo iperf3-tune optimize --detach \
  --server "$SERVER_IP" \
  --ssh-host "$SERVER_IP" \
  --ssh-user root \
  --ssh-key ~/.ssh/id_rsa \
  --profile aggressive \
  --time 30 \
  --repeats 3 \
  --yes
```

### extreme

适合 25G+、RTT 高、长肥管道、机器内存足够的场景：

```bash
sudo iperf3-tune optimize --detach \
  --server "$SERVER_IP" \
  --ssh-host "$SERVER_IP" \
  --ssh-user root \
  --ssh-key ~/.ssh/id_rsa \
  --profile extreme \
  --time 30 \
  --repeats 3 \
  --yes
```

如果机器内存小，不要直接用 `extreme`。

---

## 12. 多流寻优怎么调

默认最多测试到 32 流：

```bash
--max-parallel 32
```

只想测到 8 流：

```bash
sudo iperf3-tune bench \
  --server "$SERVER_IP" \
  --max-parallel 8 \
  --time 30 \
  --repeats 3
```

想测更高并发，比如 64 流：

```bash
sudo iperf3-tune bench \
  --server "$SERVER_IP" \
  --max-parallel 64 \
  --time 30 \
  --repeats 3
```

单次测试更久：

```bash
sudo iperf3-tune bench \
  --server "$SERVER_IP" \
  --time 60 \
  --repeats 3
```

减少测试时间：

```bash
sudo iperf3-tune bench \
  --server "$SERVER_IP" \
  --time 10 \
  --repeats 1
```

---

## 13. 重传率和评分参数

默认重传率超过阈值会提前停止继续加并发：

```bash
--retrans-threshold 3.0
```

把阈值放宽到 5%：

```bash
sudo iperf3-tune bench \
  --server "$SERVER_IP" \
  --retrans-threshold 5.0
```

默认评分会惩罚重传：

```bash
--retrans-penalty 10.0
```

只看带宽，不惩罚重传：

```bash
sudo iperf3-tune bench \
  --server "$SERVER_IP" \
  --retrans-penalty 0
```

MSS 默认 1448。如果你的链路 MTU/MSS 特殊，可以改：

```bash
sudo iperf3-tune bench \
  --server "$SERVER_IP" \
  --mss 1440
```

---

## 14. 拥塞控制算法

默认使用 BBR：

```bash
sudo iperf3-tune tune \
  --profile aggressive \
  --congestion bbr \
  --yes
```

改用 cubic：

```bash
sudo iperf3-tune tune \
  --profile aggressive \
  --congestion cubic \
  --yes
```

完整优化时指定 cubic：

```bash
sudo iperf3-tune optimize --detach \
  --server "$SERVER_IP" \
  --ssh-host "$SERVER_IP" \
  --ssh-user root \
  --ssh-key ~/.ssh/id_rsa \
  --profile aggressive \
  --congestion cubic \
  --time 30 \
  --repeats 3 \
  --yes
```

查看当前拥塞控制：

```bash
sysctl net.ipv4.tcp_congestion_control
sysctl net.ipv4.tcp_available_congestion_control
```

---

## 15. 后台运行

推荐高速链路都加 `--detach`，避免 SSH 卡住或断开：

```bash
sudo iperf3-tune optimize --detach \
  --server "$SERVER_IP" \
  --ssh-host "$SERVER_IP" \
  --ssh-user root \
  --ssh-key ~/.ssh/id_rsa \
  --profile aggressive \
  --time 30 \
  --repeats 3 \
  --yes
```

查看后台进度：

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

后台文件位置：

```text
PID:      /var/lib/iperf3-tune/iperf3-tune.pid
进度:     /var/lib/iperf3-tune/progress.json
结果:     /var/lib/iperf3-tune/state.json
日志:     /var/log/iperf3-tune/run-*.log
```

---

## 16. 详细日志和 JSON 输出

显示更详细日志：

```bash
sudo iperf3-tune optimize \
  --server "$SERVER_IP" \
  --ssh-host "$SERVER_IP" \
  --ssh-user root \
  --ssh-key ~/.ssh/id_rsa \
  --profile aggressive \
  --verbose \
  --yes
```

输出 JSON：

```bash
sudo iperf3-tune bench \
  --server "$SERVER_IP" \
  --json
```

把 JSON 保存到文件：

```bash
sudo iperf3-tune bench \
  --server "$SERVER_IP" \
  --json > result.json
```

查看最近结果文件：

```bash
sudo jq . /var/lib/iperf3-tune/state.json
```

---

## 17. 回退

只回退本机：

```bash
sudo iperf3-tune rollback
```

本机 + 远端一起回退：

```bash
sudo iperf3-tune rollback \
  --ssh-host "$SERVER_IP" \
  --ssh-user root \
  --ssh-key ~/.ssh/id_rsa
```

使用密码文件回退远端：

```bash
sudo iperf3-tune rollback \
  --ssh-host "$SERVER_IP" \
  --ssh-user root \
  --ssh-pass-file /root/iperf3-ssh-pass
```

回退后建议检查：

```bash
sudo iperf3-tune status
sysctl net.ipv4.tcp_congestion_control
sysctl net.core.default_qdisc
```

如网卡 offload 某些设置没有完全恢复，直接重启机器最干净：

```bash
sudo reboot
```

---

## 18. 定时任务 iperf3-tuned

初始化配置：

```bash
sudo iperf3-tuned init
```

按提示输入：

```text
iperf3 服务端 IP
iperf3 端口
单次测试时长
重复次数
profile
远端 SSH 主机
SSH 用户
SSH 密码或私钥
```

安装 systemd timer：

```bash
sudo iperf3-tuned install
```

查看状态：

```bash
sudo iperf3-tuned status
```

立即跑一次完整优化：

```bash
sudo iperf3-tuned run
```

手动跑一次 canary 检查：

```bash
sudo iperf3-tuned canary
```

回退：

```bash
sudo iperf3-tuned rollback
```

卸载定时任务：

```bash
sudo iperf3-tuned uninstall
```

配置文件位置：

```text
/etc/iperf3-tune/config.json
```

日志位置：

```text
/var/log/iperf3-tune/daemon.log
```

baseline 文件：

```text
/var/lib/iperf3-tune/baseline.json
```

canary 文件：

```text
/var/lib/iperf3-tune/canary.json
```

---

## 19. 常用命令速查

```bash
# 安装
git clone https://github.com/lucifer988/iperf3.git iperf3-tune && cd iperf3-tune && sudo bash install.sh

# 查看帮助
iperf3-tune --help
iperf3-tuned --help

# 检测，不改系统
sudo iperf3-tune detect

# 只调优本机
sudo iperf3-tune tune --profile aggressive --yes

# 只测速，不改系统
sudo iperf3-tune bench --server 1.2.3.4 --time 30 --repeats 3

# 完整优化，本机 + 远端
sudo iperf3-tune optimize --detach --server 1.2.3.4 --ssh-host 1.2.3.4 --ssh-user root --ssh-key ~/.ssh/id_rsa --profile aggressive --time 30 --repeats 3 --yes

# 查看后台进度
sudo iperf3-tune watch

# 查看后台日志
sudo iperf3-tune tail

# 查看最近结果
sudo iperf3-tune status

# 停止后台任务
sudo iperf3-tune stop

# 回退
sudo iperf3-tune rollback

# 卸载
cd iperf3-tune && sudo bash uninstall.sh
```

---

## 20. 参数速查

### 主命令

| 命令 | 是否改系统 | 用法 |
|---|---:|---|
| `detect` | 否 | 检测 CPU、内存、网卡、TCP 状态 |
| `tune` | 是 | 只调优本机 |
| `bench` | 否 | 只跑 iperf3 测试 |
| `optimize` | 是 | 检测 + 调优 + 远端同步 + 测试 |
| `rollback` | 是 | 回退本机和远端 |
| `status` | 否 | 查看当前状态和最近结果 |
| `watch` | 否 | 查看后台进度 |
| `tail` | 否 | 跟随后台日志 |
| `stop` | 是 | 停止后台任务 |

### 测试参数

| 参数 | 默认值 | 说明 |
|---|---:|---|
| `--server IP` | 无 | iperf3 服务端地址，`bench` / `optimize` 必填 |
| `--port N` | `5201` | iperf3 端口 |
| `--time SECS` | `30` | 每次测试秒数，不能小于 5 |
| `--repeats N` | `3` | 每档重复次数 |
| `--max-parallel N` | `32` | 最大并发流 |
| `--direction reverse|forward` | `reverse` | `reverse` 下行，`forward` 上行 |
| `--mss N` | `1448` | 估算重传率用的 MSS |

### 调优参数

| 参数 | 默认值 | 说明 |
|---|---:|---|
| `--profile balanced|aggressive|extreme` | `aggressive` | 调优强度 |
| `--congestion ALGO` | `bbr` | TCP 拥塞控制算法 |
| `--retrans-threshold PCT` | `3.0` | 超过该重传率提前停止寻优 |
| `--retrans-penalty K` | `10.0` | 评分时对重传率的惩罚系数 |

### SSH 参数

| 参数 | 默认值 | 说明 |
|---|---:|---|
| `--ssh-host HOST` | 无 | 远端 SSH 地址 |
| `--ssh-user USER` | `root` | 远端 SSH 用户 |
| `--ssh-port N` | `22` | 远端 SSH 端口 |
| `--ssh-key PATH` | 无 | SSH 私钥 |
| `--ssh-pass PASS` | 无 | SSH 密码，不推荐 |
| `--ssh-pass-file PATH` | 无 | 从文件读取 SSH 密码，推荐 |

### 其他参数

| 参数 | 用法 |
|---|---|
| `--detach` / `-d` | `bench` / `optimize` 后台运行 |
| `--yes` / `-y` | 跳过确认 |
| `--verbose` / `-v` | 详细日志 |
| `--json` | JSON 输出 |
| `--no-auto-install` | 禁用自动安装依赖 |
| `--help` / `-h` | 显示帮助 |
| `--version` / `-V` | 显示版本 |

---

## 21. 常见场景直接复制

### 场景 A：我只想知道当前链路能跑多少

远端：

```bash
sudo iperf3 -s -p 5201 -D
```

本机：

```bash
SERVER_IP="1.2.3.4"

sudo iperf3-tune bench \
  --server "$SERVER_IP" \
  --time 30 \
  --repeats 3 \
  --max-parallel 32
```

### 场景 B：我要优化本机下行，不碰远端

远端：

```bash
sudo iperf3 -s -p 5201 -D
```

本机：

```bash
SERVER_IP="1.2.3.4"

sudo iperf3-tune optimize --detach \
  --server "$SERVER_IP" \
  --profile aggressive \
  --direction reverse \
  --time 30 \
  --repeats 3 \
  --yes
```

### 场景 C：我要本机和远端都优化

```bash
SERVER_IP="1.2.3.4"

sudo iperf3-tune optimize --detach \
  --server "$SERVER_IP" \
  --ssh-host "$SERVER_IP" \
  --ssh-user root \
  --ssh-key ~/.ssh/id_rsa \
  --profile aggressive \
  --direction reverse \
  --time 30 \
  --repeats 3 \
  --yes
```

### 场景 D：我要测上行

```bash
SERVER_IP="1.2.3.4"

sudo iperf3-tune bench \
  --server "$SERVER_IP" \
  --direction forward \
  --time 30 \
  --repeats 3
```

### 场景 E：我要 25G+ 链路激进测试

```bash
SERVER_IP="1.2.3.4"

sudo iperf3-tune optimize --detach \
  --server "$SERVER_IP" \
  --ssh-host "$SERVER_IP" \
  --ssh-user root \
  --ssh-key ~/.ssh/id_rsa \
  --profile extreme \
  --max-parallel 64 \
  --time 60 \
  --repeats 3 \
  --yes
```

### 场景 F：我要保守一点

```bash
SERVER_IP="1.2.3.4"

sudo iperf3-tune optimize --detach \
  --server "$SERVER_IP" \
  --ssh-host "$SERVER_IP" \
  --ssh-user root \
  --ssh-key ~/.ssh/id_rsa \
  --profile balanced \
  --max-parallel 16 \
  --time 30 \
  --repeats 3 \
  --yes
```

---

## 22. 出问题时按这个顺序查

### 1. 远端 5201 是否通

本机：

```bash
nc -vz "$SERVER_IP" 5201
```

没有 `nc` 就用：

```bash
timeout 3 bash -c "cat < /dev/null > /dev/tcp/$SERVER_IP/5201" && echo OK || echo FAIL
```

### 2. 远端 iperf3 server 是否在跑

远端：

```bash
pgrep -a iperf3
ss -lntp | grep 5201
```

没跑就启动：

```bash
sudo iperf3 -s -p 5201 -D
```

### 3. 普通 iperf3 是否能跑通

本机：

```bash
iperf3 -c "$SERVER_IP" -p 5201 -R -t 10
```

上行：

```bash
iperf3 -c "$SERVER_IP" -p 5201 -t 10
```

### 4. SSH 是否能登录远端 root

```bash
ssh -i ~/.ssh/id_rsa root@"$SERVER_IP"
```

自定义端口：

```bash
ssh -p 2222 -i ~/.ssh/id_rsa root@"$SERVER_IP"
```

### 5. 查看详细日志

```bash
sudo iperf3-tune tail
```

或者：

```bash
sudo ls -lh /var/log/iperf3-tune/
sudo tail -n 200 /var/log/iperf3-tune/run-*.log
```

### 6. 重新跑并打开详细日志

```bash
sudo iperf3-tune optimize \
  --server "$SERVER_IP" \
  --ssh-host "$SERVER_IP" \
  --ssh-user root \
  --ssh-key ~/.ssh/id_rsa \
  --profile aggressive \
  --verbose \
  --yes
```

### 7. 回退

```bash
sudo iperf3-tune rollback
sudo reboot
```
