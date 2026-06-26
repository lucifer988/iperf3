# iperf3-tune 使用说明

## 1. 环境要求

- 仅支持 Linux
- 本机需要 root
- 远端 server 如需同步调优 / 扫描远端参数，需要 SSH 登录权限
- 远端需能运行 `iperf3`

---

## 2. 下载并安装

先下载源码并进入目录：

```bash
git clone https://github.com/lucifer988/iperf3.git
cd iperf3
```

再执行安装：

```bash
sudo ./install.sh
```

安装完成后验证：

```bash
iperf3-tune --version
iperf3-tune --help
```

如未安装到 PATH，也可以直接用当前目录脚本：

```bash
./iperf3-tune.sh --help
```

---

## 3. 先准备远端 iperf3 server

在远端机器执行：

```bash
iperf3 -s -p 5201
```

如果要后台运行：

```bash
iperf3 -s -p 5201 -D
```

如果你不手动启动，脚本在 `optimize` 的远端同步阶段会尝试自动启动远端 `iperf3 -s`。

---

## 4. 命令结构

```bash
iperf3-tune <命令> [选项]
```

可用命令：

- `detect`：只检测，不改系统
- `tune`：只调本机，不测速
- `bench`：只测速，不改系统
- `optimize`：检测 + 本机调优 + 远端调优 + 测试
- `rollback`：回退本机和远端调优
- `status`：看最近结果
- `watch`：看后台进度
- `tail`：看后台日志
- `stop`：停止后台任务

---

## 5. 最常用的 9 种用法

### 5.1 只检测本机瓶颈

```bash
sudo iperf3-tune detect
```

### 5.2 只做本机调优，不测速

```bash
sudo iperf3-tune tune --profile aggressive
```

### 5.3 只测速，不改系统

```bash
sudo iperf3-tune bench --server 1.2.3.4 --time 30 --repeats 3
```

### 5.4 完整流程：检测 + 调优 + 测试

```bash
sudo iperf3-tune optimize \
    --server 1.2.3.4 \
    --ssh-host 1.2.3.4 --ssh-user root --ssh-key ~/.ssh/id_rsa \
    --profile aggressive --time 30 --repeats 3
```

### 5.5 单流模式：专门追求单线程高带宽低重传

```bash
sudo iperf3-tune optimize --single \
    --server 1.2.3.4 \
    --ssh-host 1.2.3.4 --ssh-user root --ssh-key ~/.ssh/id_rsa \
    --profile aggressive --time 30 --repeats 3
```

### 5.6 单流自动寻优：自动扫描拥塞算法 + 窗口 + CPU

```bash
sudo iperf3-tune optimize --scan \
    --server 1.2.3.4 \
    --ssh-host 1.2.3.4 --ssh-user root --ssh-key ~/.ssh/id_rsa \
    --profile aggressive
```

### 5.7 后台运行

```bash
sudo iperf3-tune optimize --detach \
    --server 1.2.3.4 \
    --ssh-host 1.2.3.4 --ssh-user root --ssh-key ~/.ssh/id_rsa \
    --profile aggressive
```

查看后台进度：

```bash
sudo iperf3-tune watch
sudo iperf3-tune tail
sudo iperf3-tune status
```

### 5.8 回退所有调优

```bash
sudo iperf3-tune rollback \
    --ssh-host 1.2.3.4 --ssh-user root --ssh-key ~/.ssh/id_rsa
```

### 5.9 最强版本：有远端 SSH 账号密码时直接用这条

```bash
sudo iperf3-tune optimize --scan \
    --server 1.2.3.4 \
    --ssh-host 1.2.3.4 --ssh-user root --ssh-pass 'YourPassword' \
    --profile aggressive --detach
```

#### 这条命令会做什么

- 自动检测本机瓶颈
- 自动调优本机
- 自动通过 SSH 调优远端 server
- 自动扫描单流最优拥塞算法、窗口、CPU
- reverse 默认场景下优先处理远端 server 发送端
- 后台运行，适合扫描时间较长的场景

#### 跑完后怎么查看结果

```bash
sudo iperf3-tune watch
sudo iperf3-tune tail
sudo iperf3-tune status
sudo jq '.best_congestion,.best_window,.best_cpu_local,.best_cpu_remote,.sender' /var/lib/iperf3-tune/state.json
```

---

## 6. 参数怎么用

### 6.1 基本测试参数

#### 指定远端 server

```bash
--server 1.2.3.4
```

`bench` 和 `optimize` 必填。

#### 指定端口

```bash
--port 5201
```

远端 `iperf3 -s -p 5201` 的端口必须一致。

#### 指定单次测试时长

```bash
--time 30
```

表示每次测试跑 30 秒。

#### 指定重复次数

```bash
--repeats 3
```

同一档参数重复测 3 次，脚本取中位结果。

#### 指定方向

```bash
--direction reverse
```

或：

```bash
--direction forward
```

- `reverse`：等价 `iperf3 -R`，默认值
- `forward`：普通上行

如果你要调 `iperf3 -c -R` 的单线程高带宽低重传，默认就用 `reverse`，不用额外写。

---

### 6.2 profile 怎么选

#### balanced

```bash
--profile balanced
```

适合：
- 1G / 2.5G
- 内存不大
- 不想调太激进

#### aggressive

```bash
--profile aggressive
```

适合：
- 10G 左右链路
- 默认推荐

#### extreme

```bash
--profile extreme
```

适合：
- 25G+
- 长肥管道
- 接受更激进的系统参数

---

### 6.3 单流模式怎么用

#### 开启单流

```bash
--single
```

作用：
- 强制只测 1 条 TCP 流
- 自动按 RTT/BDP 算窗口
- 自动绑核
- 默认开 zerocopy

完整示例：

```bash
sudo iperf3-tune bench --single --server 1.2.3.4
```

或：

```bash
sudo iperf3-tune optimize --single \
    --server 1.2.3.4 \
    --ssh-host 1.2.3.4 --ssh-key ~/.ssh/id_rsa
```

---

### 6.4 窗口怎么调

#### 自动窗口

什么都不写时：

```bash
sudo iperf3-tune bench --single --server 1.2.3.4
```

脚本会按 RTT × 带宽自动估算窗口。

#### 手动指定窗口

```bash
--window 128M
```

示例：

```bash
sudo iperf3-tune bench --single --window 128M --server 1.2.3.4
```

#### 手动告诉脚本链路带宽

```bash
--bandwidth 10000
```

如果已知是 10Gbps：

```bash
sudo iperf3-tune bench --single --bandwidth 10000 --server 1.2.3.4
```

如果自动识别网卡速率不准，优先用 `--bandwidth`。

---

### 6.5 CPU 绑核怎么用

#### 指定本机核

```bash
--cpu 2
```

示例：

```bash
sudo iperf3-tune bench --single --cpu 2 --server 1.2.3.4
```

#### 指定远端 server 核

```bash
--cpu-remote 6
```

示例：

```bash
sudo iperf3-tune bench --single \
    --cpu 2 --cpu-remote 6 \
    --server 1.2.3.4 \
    --ssh-host 1.2.3.4 --ssh-key ~/.ssh/id_rsa
```

#### 不手动指定

什么都不写时：
- 本机会自动选核
- reverse + `--ssh-host` 时，远端 server 也会自动选核

---

### 6.6 zerocopy 怎么用

#### 默认开启

什么都不写就是开：

```bash
sudo iperf3-tune bench --single --server 1.2.3.4
```

#### 手动关闭

```bash
--no-zerocopy
```

示例：

```bash
sudo iperf3-tune bench --single --no-zerocopy --server 1.2.3.4
```

如果你想对比开关差异，就跑两次分别比较结果。

---

### 6.7 MTU / jumbo frame 怎么用

#### 开 MTU 9000

```bash
--mtu 9000
```

示例：

```bash
sudo iperf3-tune optimize --single --mtu 9000 \
    --server 1.2.3.4 \
    --ssh-host 1.2.3.4 --ssh-key ~/.ssh/id_rsa
```

前提：
- 本机支持
- 远端支持
- 中间交换链路支持

如果其中一段不支持，不要开。

---

### 6.8 自动扫描怎么用

#### 一次全扫

```bash
--scan
```

示例：

```bash
sudo iperf3-tune optimize --scan \
    --server 1.2.3.4 \
    --ssh-host 1.2.3.4 --ssh-key ~/.ssh/id_rsa
```

扫描顺序：
1. 拥塞算法
2. 窗口
3. CPU

#### 只扫窗口

```bash
sudo iperf3-tune bench --scan-window --server 1.2.3.4
```

#### 只扫拥塞算法

```bash
sudo iperf3-tune bench --scan-congestion \
    --server 1.2.3.4 \
    --ssh-host 1.2.3.4 --ssh-key ~/.ssh/id_rsa
```

#### 只扫 CPU

```bash
sudo iperf3-tune bench --scan-cpu \
    --server 1.2.3.4 \
    --ssh-host 1.2.3.4 --ssh-key ~/.ssh/id_rsa
```

#### 自定义窗口候选

```bash
sudo iperf3-tune bench --scan-window \
    --window-list 32M,64M,96M,128M,192M,256M \
    --server 1.2.3.4
```

#### 自定义拥塞算法候选

```bash
sudo iperf3-tune bench --scan-congestion \
    --congestion-list bbr,cubic,bbr2 \
    --server 1.2.3.4 \
    --ssh-host 1.2.3.4 --ssh-key ~/.ssh/id_rsa
```

#### 缩短扫描时间

```bash
--scan-time 10 --scan-repeats 1
```

示例：

```bash
sudo iperf3-tune optimize --scan \
    --scan-time 8 --scan-repeats 1 \
    --server 1.2.3.4 \
    --ssh-host 1.2.3.4 --ssh-key ~/.ssh/id_rsa
```

如果机器多、链路长、候选多，建议配 `--detach`。

---

## 7. `-R` 场景下怎么用

默认 `--direction reverse`，就是 `iperf3 -c -R` 场景。

最推荐的 4 种写法：

### 7.1 最简单单流

```bash
sudo iperf3-tune optimize --single \
    --server 1.2.3.4 \
    --ssh-host 1.2.3.4 --ssh-key ~/.ssh/id_rsa
```

### 7.2 已知 10G 链路

```bash
sudo iperf3-tune optimize --single \
    --bandwidth 10000 \
    --server 1.2.3.4 \
    --ssh-host 1.2.3.4 --ssh-key ~/.ssh/id_rsa
```

### 7.3 手动指定双端 CPU

```bash
sudo iperf3-tune bench --single \
    --cpu 2 --cpu-remote 6 \
    --server 1.2.3.4 \
    --ssh-host 1.2.3.4 --ssh-key ~/.ssh/id_rsa
```

### 7.4 直接自动扫到最优

```bash
sudo iperf3-tune optimize --scan \
    --server 1.2.3.4 \
    --ssh-host 1.2.3.4 --ssh-key ~/.ssh/id_rsa
```

如果你不给 `--ssh-host`：
- 本机仍可测速
- 但 reverse 下 server 才是发送端
- 所以远端拥塞算法、远端发送核、远端调优都做不了
- 结果会打折扣

所以调 `iperf3 -c -R` 时，**强烈建议始终提供 `--ssh-host`**。

---

## 8. SSH 怎么写

### 8.1 私钥方式

```bash
--ssh-host 1.2.3.4 --ssh-user root --ssh-key ~/.ssh/id_rsa
```

完整示例：

```bash
sudo iperf3-tune optimize \
    --server 1.2.3.4 \
    --ssh-host 1.2.3.4 --ssh-user root --ssh-key ~/.ssh/id_rsa
```

### 8.2 密码方式

```bash
--ssh-host 1.2.3.4 --ssh-user root --ssh-pass 'YourPassword'
```

完整示例：

```bash
sudo iperf3-tune optimize \
    --server 1.2.3.4 \
    --ssh-host 1.2.3.4 --ssh-user root --ssh-pass 'YourPassword'
```

### 8.3 密码文件方式

先写文件：

```bash
umask 077
printf '%s' 'YourPassword' > ~/.iperf3_remote.pw
chmod 600 ~/.iperf3_remote.pw
```

再调用：

```bash
sudo iperf3-tune optimize \
    --server 1.2.3.4 \
    --ssh-host 1.2.3.4 --ssh-user root \
    --ssh-pass-file ~/.iperf3_remote.pw
```

如果用了 `sudo`，密码文件建议写绝对路径。

---

## 9. 状态结果怎么看

测试结果默认写到：

```bash
/var/lib/iperf3-tune/state.json
```

### 看最近结果

```bash
sudo iperf3-tune status
```

### 只看关键字段

```bash
sudo jq '.timestamp,.server,.direction,.profile,.single,.best' /var/lib/iperf3-tune/state.json
```

### 看单流扫描最优组合

```bash
sudo jq '.best_congestion,.best_window,.best_cpu_local,.best_cpu_remote,.sender' /var/lib/iperf3-tune/state.json
```

---

## 10. 后台运行怎么用

### 后台启动

```bash
sudo iperf3-tune optimize --detach \
    --server 1.2.3.4 \
    --ssh-host 1.2.3.4 --ssh-key ~/.ssh/id_rsa
```

### 看实时进度

```bash
sudo iperf3-tune watch
```

### 看日志

```bash
sudo iperf3-tune tail
```

### 看最终状态

```bash
sudo iperf3-tune status
```

### 中断后台任务

```bash
sudo iperf3-tune stop
```

---

## 11. 定时跑怎么用

### 11.1 初始化配置

```bash
sudo iperf3-tuned init
```

它会交互式询问：
- iperf3 server IP
- 端口
- 时长
- repeats
- profile
- SSH 主机
- SSH 用户
- 密码或私钥

### 11.2 安装定时任务

```bash
sudo iperf3-tuned install
```

默认：
- 每周日 22:00 跑一次 optimize
- 每 6 小时跑一次 canary

### 11.3 立即跑一次

```bash
sudo iperf3-tuned run
```

### 11.4 查看状态

```bash
sudo iperf3-tuned status
```

### 11.5 卸载定时任务

```bash
sudo iperf3-tuned uninstall
```

---

## 12. 回退与卸载

### 回退本机

```bash
sudo iperf3-tune rollback
```

### 回退本机 + 远端

```bash
sudo iperf3-tune rollback \
    --ssh-host 1.2.3.4 --ssh-user root --ssh-key ~/.ssh/id_rsa
```

### 卸载脚本

```bash
sudo ./uninstall.sh
```

### 彻底删除配置、状态、日志

```bash
sudo rm -rf /etc/iperf3-tune /var/lib/iperf3-tune /var/log/iperf3-tune
```

---

## 13. 直接照抄的命令模板

### 模板 1：10G 单流 reverse

```bash
sudo iperf3-tune optimize --single \
    --bandwidth 10000 \
    --server <SERVER_IP> \
    --ssh-host <SERVER_IP> --ssh-user root --ssh-key ~/.ssh/id_rsa \
    --profile aggressive
```

### 模板 2：25G+ 单流 reverse

```bash
sudo iperf3-tune optimize --scan \
    --server <SERVER_IP> \
    --ssh-host <SERVER_IP> --ssh-user root --ssh-key ~/.ssh/id_rsa \
    --profile extreme --detach
```

### 模板 3：只测，不改系统

```bash
sudo iperf3-tune bench --single \
    --server <SERVER_IP> \
    --ssh-host <SERVER_IP> --ssh-key ~/.ssh/id_rsa
```

### 模板 4：指定双端核 + 手动窗口

```bash
sudo iperf3-tune bench --single \
    --cpu 2 --cpu-remote 6 \
    --window 128M \
    --server <SERVER_IP> \
    --ssh-host <SERVER_IP> --ssh-key ~/.ssh/id_rsa
```

### 模板 5：开 jumbo frame

```bash
sudo iperf3-tune optimize --single --mtu 9000 \
    --server <SERVER_IP> \
    --ssh-host <SERVER_IP> --ssh-key ~/.ssh/id_rsa
```
