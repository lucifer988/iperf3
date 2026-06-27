# iperf3-tune 使用说明

`iperf3-tune` 用来在 Linux 服务器上自动调优网络参数，并用 `iperf3` 测试带宽与重传率。

这份 README 只讲怎么用。

---

## 1. 安装

如果你拿到的是压缩包：

```bash
unzip iperf3-tune-v2.9.1.zip
cd iperf3-main
sudo ./install.sh
```

安装完成后验证：

```bash
iperf3-tune --version
iperf3-tune --help
```

安装后的命令：

```text
/usr/local/sbin/iperf3-tune
/usr/local/sbin/iperf3-tuned
```

---

## 2. 使用前准备

### 本机要求

必须是 Linux，并且需要 root 权限执行调优命令：

```bash
sudo iperf3-tune detect
```

### 远端要求

如果你要调优远端 server，需要保证：

```text
1. 本机可以 SSH 登录远端
2. 远端 SSH 用户最好是 root
3. 远端允许密码登录或密钥登录
4. 防火墙 / 安全组放行 iperf3 端口，默认 TCP 5201
```

如果远端还没有启动 `iperf3 server`，不用太担心：`optimize` 在 SSH 成功后会尝试自动启动：

```bash
iperf3 -s -p 5201 -D
```

如果密码方式提示缺少 `sshpass`，按系统安装即可，例如：

```bash
# Debian / Ubuntu
sudo apt-get install -y sshpass

# RHEL / CentOS / Rocky / Alma
sudo yum install -y sshpass
```

---

## 3. 最推荐：SSH 密码全面调优

这是最重要的用法。

适合场景：

```text
你在本机测远端服务器下行速度。
也就是 iperf3 -R 场景。
此时远端 server 才是发送端，所以必须通过 SSH 调优远端，效果才完整。
```

### 推荐命令：交互输入 SSH 密码

```bash
sudo iperf3-tune optimize --scan \
  --direction reverse \
  --server <SERVER_IP> \
  --port 5201 \
  --ssh-host <SERVER_IP> \
  --ssh-user root \
  --ssh-port 22 \
  --ssh-ask-pass \
  --profile aggressive \
  --time 30 \
  --repeats 3 \
  --yes
```

运行后会提示你输入远端 SSH 密码。密码不会出现在命令行、shell history 或 `ps` 进程列表里。

这条命令会做完整调优：

```text
1. 检测本机网络环境
2. 调优本机 sysctl
3. 调优本机网卡参数
4. SSH 登录远端
5. 上传调优脚本到远端临时目录
6. 调优远端 sysctl
7. 调优远端网卡参数
8. 检查或启动远端 iperf3 -s
9. 扫描拥塞算法
10. 扫描 TCP 窗口
11. 扫描本机和远端 CPU 绑核
12. 运行 iperf3 测试
13. 写入最终结果
```

`--scan` 是全面自动寻优开关，会扫描：

```text
拥塞算法 → TCP 窗口 → CPU 绑核
```

默认重点优化单流 `iperf3 -R` 下行表现。

---

## 4. 先预演，不真正修改系统

生产环境建议先跑 `--dry-run`：

```bash
sudo iperf3-tune optimize --scan --dry-run \
  --direction reverse \
  --server <SERVER_IP> \
  --port 5201 \
  --ssh-host <SERVER_IP> \
  --ssh-user root \
  --ssh-port 22 \
  --ssh-ask-pass \
  --profile aggressive
```

`--dry-run` 只打印将要做什么，不会修改本机、不会修改远端、不会跑测试。

确认没问题后，再去掉 `--dry-run`，加上 `--yes` 正式执行：

```bash
sudo iperf3-tune optimize --scan \
  --direction reverse \
  --server <SERVER_IP> \
  --port 5201 \
  --ssh-host <SERVER_IP> \
  --ssh-user root \
  --ssh-port 22 \
  --ssh-ask-pass \
  --profile aggressive \
  --time 30 \
  --repeats 3 \
  --yes
```

---

## 5. SSH 密码的三种写法

### 方式一：`--ssh-ask-pass`，推荐

```bash
sudo iperf3-tune optimize --scan \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user root \
  --ssh-ask-pass \
  --profile aggressive \
  --yes
```

推荐日常手动执行使用这种方式。

### 方式二：`--ssh-pass-file`，适合脚本和后台任务

先创建密码文件：

```bash
sudo install -m 600 /dev/null /root/.iperf3-ssh.pass
sudo nano /root/.iperf3-ssh.pass
```

写入远端 SSH 密码后执行：

```bash
sudo iperf3-tune optimize --scan \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user root \
  --ssh-pass-file /root/.iperf3-ssh.pass \
  --profile aggressive \
  --yes
```

密码文件权限建议是 `600` 或 `400`。

### 方式三：`--ssh-pass`，能用但不推荐

```bash
sudo iperf3-tune optimize --scan \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user root \
  --ssh-pass '<SSH_PASSWORD>' \
  --profile aggressive \
  --yes
```

不推荐这种方式，因为密码可能进入 shell history、`ps`、审计日志。

---

## 6. 后台执行 SSH 密码全面调优

高速链路测试可能比较久，建议后台运行：

```bash
sudo iperf3-tune optimize --scan --detach --yes \
  --direction reverse \
  --server <SERVER_IP> \
  --port 5201 \
  --ssh-host <SERVER_IP> \
  --ssh-user root \
  --ssh-ask-pass \
  --profile aggressive \
  --time 30 \
  --repeats 3
```

查看进度：

```bash
sudo iperf3-tune watch
```

查看日志：

```bash
sudo iperf3-tune tail
```

停止后台任务：

```bash
sudo iperf3-tune stop
```

后台模式下，即使你用了密码，脚本也会把密码转存为权限 `600` 的临时文件，不会把明文密码暴露在 `ps` 里。

---

## 7. 只用 SSH 密钥调优

如果你有私钥，优先使用私钥：

```bash
sudo iperf3-tune optimize --scan \
  --direction reverse \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user root \
  --ssh-key ~/.ssh/id_rsa \
  --profile aggressive \
  --time 30 \
  --repeats 3 \
  --yes
```

---

## 8. 常用命令

### 只检测，不修改系统

```bash
sudo iperf3-tune detect
```

### 只调优本机，不测试

```bash
sudo iperf3-tune tune --profile aggressive --yes
```

### 只跑测试，不修改系统

```bash
iperf3-tune bench \
  --server <SERVER_IP> \
  --port 5201 \
  --time 30 \
  --repeats 3
```

### 完整流程，不做扫描

```bash
sudo iperf3-tune optimize \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user root \
  --ssh-ask-pass \
  --profile aggressive \
  --time 30 \
  --repeats 3 \
  --yes
```

这个会执行完整流程，但不会额外扫描拥塞算法、窗口和 CPU。  
如果你要更充分地自动寻优，用 `--scan`。

---

## 9. 下行、上行怎么选

默认是下行测试：

```bash
--direction reverse
```

等价于：

```bash
iperf3 -c <SERVER_IP> -R
```

下行场景中：

```text
本机 = 接收端
远端 server = 发送端
```

所以要想下行速度好，建议一定加：

```bash
--ssh-host <SERVER_IP>
```

如果你要测上行：

```bash
sudo iperf3-tune optimize \
  --direction forward \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user root \
  --ssh-ask-pass \
  --profile aggressive \
  --yes
```

---

## 10. profile 怎么选

| profile | 适合场景 | 建议 |
|---|---|---|
| `balanced` | 1G / 2.5G 链路 | 更稳妥 |
| `aggressive` | 10G 链路 | 默认推荐 |
| `extreme` | 25G+ / 长肥管道 | 更激进，生产慎用 |

推荐从这里开始：

```bash
--profile aggressive
```

---

## 11. 网卡调优开关

默认会调优 sysctl 和网卡参数。

如果你只想调 sysctl，完全不碰网卡硬件参数：

```bash
sudo iperf3-tune optimize --scan \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user root \
  --ssh-ask-pass \
  --profile aggressive \
  --no-nic-tune \
  --yes
```

如果你的机器承担转发、桥接、虚拟化或抓包业务，建议优先加：

```bash
--no-nic-tune
```

LRO 默认不开。确实需要开启时再加：

```bash
--enable-lro
```

---

## 12. Jumbo Frame / MTU 9000

如果两端网络都支持 MTU 9000，可以这样：

```bash
sudo iperf3-tune optimize --scan \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user root \
  --ssh-ask-pass \
  --profile aggressive \
  --mtu 9000 \
  --yes
```

注意：两端和中间链路都必须支持对应 MTU，否则可能导致网络异常。

---

## 13. 指定真实带宽，避免窗口估算过大

如果网卡标称是 10G / 25G，但你的实际带宽只有 1G，建议显式指定真实带宽：

```bash
sudo iperf3-tune optimize --scan \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user root \
  --ssh-ask-pass \
  --profile aggressive \
  --bandwidth 1000 \
  --yes
```

单位是 Mbit/s。

也可以限制自动窗口上限：

```bash
--window-max 32M
```

---

## 14. 查看结果

```bash
sudo iperf3-tune status
```

查看完整 JSON：

```bash
sudo jq . /var/lib/iperf3-tune/state.json
```

常看字段：

```text
single.bandwidth_mbps
single.retrans_rate_pct
best.bandwidth_mbps
best.retrans_rate_pct
best.streams
best_congestion
best_window
best_cpu_local
best_cpu_remote
```

---

## 15. 回退

### 回退本机

```bash
sudo iperf3-tune rollback --yes
```

### 同时回退远端

```bash
sudo iperf3-tune rollback \
  --ssh-host <SERVER_IP> \
  --ssh-user root \
  --ssh-ask-pass \
  --yes
```

回退会尽量恢复：

```text
sysctl
MTU
offload
ring buffer
RPS / XPS
IRQ 亲和
irqbalance 状态
```

---

## 16. 自动定时调优

初始化配置：

```bash
sudo iperf3-tuned init
```

安装 systemd timer：

```bash
sudo iperf3-tuned install
```

查看状态：

```bash
systemctl status iperf3-tuned.timer
systemctl status iperf3-tuned-canary.timer
```

卸载定时任务：

```bash
sudo iperf3-tuned uninstall
```

---

## 17. 一句话命令

### SSH 密码全面调优，推荐

```bash
sudo iperf3-tune optimize --scan \
  --direction reverse \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user root \
  --ssh-ask-pass \
  --profile aggressive \
  --time 30 \
  --repeats 3 \
  --yes
```

### SSH 密码全面调优，后台执行

```bash
sudo iperf3-tune optimize --scan --detach --yes \
  --direction reverse \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user root \
  --ssh-ask-pass \
  --profile aggressive \
  --time 30 \
  --repeats 3
```

### 不碰网卡，只调 sysctl

```bash
sudo iperf3-tune optimize --scan \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user root \
  --ssh-ask-pass \
  --profile aggressive \
  --no-nic-tune \
  --yes
```

### 先看会改什么

```bash
sudo iperf3-tune optimize --scan --dry-run \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user root \
  --ssh-ask-pass \
  --profile aggressive
```

---

## 18. 常见问题

### SSH 密码登录失败

先手动测试：

```bash
ssh -p 22 root@<SERVER_IP>
```

确认远端 `/etc/ssh/sshd_config` 允许密码登录：

```text
PasswordAuthentication yes
PermitRootLogin yes
```

修改后重启 sshd：

```bash
sudo systemctl restart sshd
```

### 远端调优失败

常见原因：

```text
1. SSH 用户不是 root
2. 远端缺少依赖
3. 远端包管理器不可用
4. 远端是容器，不能写 /proc/sys
5. 远端 /tmp noexec
```

如果允许脚本自动补依赖，可以加：

```bash
--auto-install
```

例如：

```bash
sudo iperf3-tune optimize --scan \
  --server <SERVER_IP> \
  --ssh-host <SERVER_IP> \
  --ssh-user root \
  --ssh-ask-pass \
  --profile aggressive \
  --auto-install \
  --yes
```

### 远端端口不通

检查远端：

```bash
ss -lntp | grep 5201
```

手动启动：

```bash
iperf3 -s -p 5201 -D
```

还要检查云安全组、防火墙、iptables / nftables。

### 调优后不满意

直接回退：

```bash
sudo iperf3-tune rollback \
  --ssh-host <SERVER_IP> \
  --ssh-user root \
  --ssh-ask-pass \
  --yes
```

---

## 19. 卸载

```bash
sudo ./uninstall.sh
```

如果已经安装到系统目录，也可以：

```bash
sudo /usr/local/sbin/iperf3-tune rollback --yes
sudo rm -f /usr/local/sbin/iperf3-tune /usr/local/sbin/iperf3-tune.sh /usr/local/sbin/iperf3-tuned
```
