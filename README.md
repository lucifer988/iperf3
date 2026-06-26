# iperf3-tune 使用说明

`iperf3-tune` 是一个面向 Linux 的 iperf3 高速链路调优与测试脚本，目标是提升 iperf3 测得带宽，尤其适合单流、`iperf3 -R` 下行、长肥管道、10G/25G+ 链路等场景。

当前脚本版本：`2.6.0`

核心能力：

- 本机瓶颈检测
- 本机 sysctl / 网卡调优
- 远端 server 通过 SSH 同步调优
- iperf3 基准测试
- 单流优化
- TCP 窗口自动计算
- CPU 绑核
- zerocopy
- 拥塞算法 / 窗口 / CPU 自动扫描
- 后台运行、查看进度、查看日志、停止任务
- 回退调优
- systemd 定时任务与 canary 检查

---

## 🔴 你当前机器适用的命令

下面这条命令就是你这次环境适用的命令：

- 本机：`root@debian12-2`
- 远端 server：`23.144.12.228`
- SSH 用户：`root`
- SSH 密码方式：`--ssh-pass`
- 调优配置：`aggressive`
- 后台运行：`--detach`
- 自动扫描：`--scan`

### 红色标记版

> 支持 HTML 样式的 Markdown 渲染器会把下面命令显示为红色。  
> 如果 GitHub 或你的编辑器没有显示红色，请看下一段“可复制版”。

<p>
<strong>
<span style="color:red;">
sudo /usr/local/sbin/iperf3-tune optimize --scan --server 23.144.12.228 --ssh-host 23.144.12.228 --ssh-user root --ssh-pass 'xxxxx' --profile aggressive --detach --yes
</span>
</strong>
</p>

### 可复制版

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --scan \
  --server 23.144.12.228 \
  --ssh-host 23.144.12.228 \
  --ssh-user root \
  --ssh-pass 'xxxxx' \
  --profile aggressive \
  --detach \
  --yes
```

> 注意：`xxxxx` 请替换为你的真实 SSH 密码。  
> 不建议把真实密码提交到 GitHub README、公开仓库或聊天记录里。

---

## 1. 先解决 `未知选项: --scan`

如果你运行：

```bash
sudo iperf3-tune optimize --scan ...
```

出现：

```text
✗ 未知选项: --scan
```

通常说明你当前执行的是旧版 `iperf3-tune`，不是当前仓库里的新版脚本。

新版脚本已经支持：

```text
--scan
--scan-window
--scan-congestion
--scan-cpu
```

请先检查当前系统实际调用的是哪个命令：

```bash
which -a iperf3-tune
iperf3-tune --version
iperf3-tune --help | grep -E -- '--scan|--scan-window|--scan-congestion|--scan-cpu'
```

如果看不到 `--scan`，请重新安装新版：

```bash
cd ~/iperf3
git pull --ff-only
sudo ./install.sh
hash -r
```

然后确认新版已经安装成功：

```bash
sudo /usr/local/sbin/iperf3-tune --version
sudo /usr/local/sbin/iperf3-tune --help | grep -E -- '--scan|--scan-window|--scan-congestion|--scan-cpu'
```

如果上面能看到 `--scan`，再运行你的正式命令：

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --scan \
  --server 23.144.12.228 \
  --ssh-host 23.144.12.228 \
  --ssh-user root \
  --ssh-pass 'xxxxx' \
  --profile aggressive \
  --detach \
  --yes
```

---

## 2. 安装和升级

### 2.1 首次安装

```bash
git clone https://github.com/lucifer988/iperf3.git
cd iperf3
sudo ./install.sh
```

安装后脚本会放到：

```text
/usr/local/sbin/iperf3-tune
/usr/local/sbin/iperf3-tuned
```

验证：

```bash
which -a iperf3-tune
iperf3-tune --version
iperf3-tune --help
```

---

### 2.2 已经 clone 过仓库，更新到最新版

```bash
cd ~/iperf3
git pull --ff-only
sudo ./install.sh
hash -r
```

验证：

```bash
sudo /usr/local/sbin/iperf3-tune --version
sudo /usr/local/sbin/iperf3-tune --help | grep -E -- '--scan|--single|--cpu-remote'
```

---

### 2.3 不安装，直接运行当前目录脚本

如果怀疑系统里装的是旧版，可以直接运行当前仓库里的脚本：

```bash
cd ~/iperf3
sudo bash ./iperf3-tune.sh --version
sudo bash ./iperf3-tune.sh --help
```

直接用当前目录脚本执行你的命令：

```bash
sudo bash ./iperf3-tune.sh optimize \
  --scan \
  --server 23.144.12.228 \
  --ssh-host 23.144.12.228 \
  --ssh-user root \
  --ssh-pass 'xxxxx' \
  --profile aggressive \
  --detach \
  --yes
```

---

## 3. 远端 iperf3 server 准备

远端机器可以手动启动 iperf3 server：

```bash
iperf3 -s -p 5201
```

后台启动：

```bash
iperf3 -s -p 5201 -D
```

如果远端没有手动启动，`optimize` 远端同步阶段会尝试通过 SSH 自动启动：

```bash
iperf3 -s -p 5201 -D
```

---

## 4. 命令结构

```bash
iperf3-tune <命令> [选项]
```

可用命令：

```text
detect      只检测系统瓶颈，不修改配置
tune        只应用本机调优，不测速
bench       只运行 iperf3 测试，不改系统
optimize    完整流程：detect → tune → remote_tune → bench
rollback    回退本机和远端调优
status      查看当前优化状态和最近测试结果
watch       实时查看后台任务进度
tail        跟随后台任务日志
stop        停止后台任务
```

---

## 5. 推荐使用方式

### 5.1 有远端 root 密码，后台全自动扫描

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --scan \
  --server 23.144.12.228 \
  --ssh-host 23.144.12.228 \
  --ssh-user root \
  --ssh-pass 'xxxxx' \
  --profile aggressive \
  --detach \
  --yes
```

### 5.2 更安全：使用密码文件

避免密码出现在 shell history：

```bash
umask 077
printf '%s' '你的真实密码' > /root/.iperf3_remote.pw
chmod 600 /root/.iperf3_remote.pw
```

运行：

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --scan \
  --server 23.144.12.228 \
  --ssh-host 23.144.12.228 \
  --ssh-user root \
  --ssh-pass-file /root/.iperf3_remote.pw \
  --profile aggressive \
  --detach \
  --yes
```

### 5.3 使用 SSH 私钥

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --scan \
  --server 23.144.12.228 \
  --ssh-host 23.144.12.228 \
  --ssh-user root \
  --ssh-key ~/.ssh/id_rsa \
  --profile aggressive \
  --detach \
  --yes
```

---

## 6. 常用用法

### 6.1 只检测本机瓶颈

```bash
sudo /usr/local/sbin/iperf3-tune detect
```

### 6.2 只做本机调优，不测速

```bash
sudo /usr/local/sbin/iperf3-tune tune --profile aggressive --yes
```

### 6.3 只测速，不改系统

```bash
sudo /usr/local/sbin/iperf3-tune bench \
  --server 23.144.12.228 \
  --time 30 \
  --repeats 3
```

### 6.4 完整流程：检测 + 本机调优 + 远端调优 + 测试

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --server 23.144.12.228 \
  --ssh-host 23.144.12.228 \
  --ssh-user root \
  --ssh-pass 'xxxxx' \
  --profile aggressive \
  --time 30 \
  --repeats 3 \
  --yes
```

### 6.5 单流模式

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --single \
  --server 23.144.12.228 \
  --ssh-host 23.144.12.228 \
  --ssh-user root \
  --ssh-pass 'xxxxx' \
  --profile aggressive \
  --time 30 \
  --repeats 3 \
  --yes
```

`--single` 会：

- 强制只测 1 条 TCP 流
- 自动按 RTT / BDP 估算窗口
- 自动选择本机 CPU 核
- reverse 模式下配合 SSH 自动选择远端 server 核
- 默认启用 zerocopy

### 6.6 单流全自动寻优

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --scan \
  --server 23.144.12.228 \
  --ssh-host 23.144.12.228 \
  --ssh-user root \
  --ssh-pass 'xxxxx' \
  --profile aggressive \
  --detach \
  --yes
```

`--scan` 等价于同时开启：

```text
--scan-congestion
--scan-window
--scan-cpu
```

扫描顺序：

```text
拥塞算法 → TCP 窗口 → CPU 核
```

---

## 7. 后台运行

后台启动：

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --scan \
  --server 23.144.12.228 \
  --ssh-host 23.144.12.228 \
  --ssh-user root \
  --ssh-pass 'xxxxx' \
  --profile aggressive \
  --detach \
  --yes
```

查看进度：

```bash
sudo /usr/local/sbin/iperf3-tune watch
```

查看日志：

```bash
sudo /usr/local/sbin/iperf3-tune tail
```

查看最终结果：

```bash
sudo /usr/local/sbin/iperf3-tune status
```

停止后台任务：

```bash
sudo /usr/local/sbin/iperf3-tune stop
```

---

## 8. 参数说明

### 8.1 基本测试参数

指定远端 server：

```bash
--server 23.144.12.228
```

指定端口：

```bash
--port 5201
```

指定单次测试时长：

```bash
--time 30
```

指定重复次数：

```bash
--repeats 3
```

指定最大并发流：

```bash
--max-parallel 32
```

指定方向：

```bash
--direction reverse
```

或者：

```bash
--direction forward
```

说明：

```text
reverse = iperf3 -R，下行，默认
forward = 普通上行
```

---

### 8.2 profile 选择

balanced：

```bash
--profile balanced
```

适合 1G / 2.5G 或者不想太激进的机器。

aggressive：

```bash
--profile aggressive
```

默认推荐，适合 10G 左右链路。

extreme：

```bash
--profile extreme
```

适合 25G+、长肥管道、可接受更激进参数的机器。

---

### 8.3 TCP 拥塞算法

默认：

```bash
--congestion bbr
```

也可以指定：

```bash
--congestion cubic
```

如果开启扫描：

```bash
--scan-congestion
```

脚本会在发送端扫描可用拥塞算法。

注意：

- reverse 模式下，发送端是远端 server
- 所以 reverse 下扫描拥塞算法建议提供 `--ssh-host`
- 否则脚本无法在真正发送端切换拥塞算法

---

### 8.4 单流参数

开启单流：

```bash
--single
```

手动指定窗口：

```bash
--window 128M
```

告诉脚本链路容量，用于自动计算窗口：

```bash
--bandwidth 10000
```

手动指定本机 CPU 核：

```bash
--cpu 2
```

手动指定远端 server CPU 核：

```bash
--cpu-remote 6
```

关闭 zerocopy：

```bash
--no-zerocopy
```

设置 MTU：

```bash
--mtu 9000
```

MTU 9000 需要本机、远端、中间网络都支持，否则不要开启。

---

### 8.5 自动扫描参数

全扫：

```bash
--scan
```

只扫窗口：

```bash
--scan-window
```

只扫拥塞算法：

```bash
--scan-congestion
```

只扫 CPU：

```bash
--scan-cpu
```

自定义窗口候选：

```bash
--window-list 32M,64M,96M,128M,192M,256M
```

自定义拥塞算法候选：

```bash
--congestion-list bbr,cubic,bbr2
```

缩短扫描时间：

```bash
--scan-time 8 --scan-repeats 1
```

完整示例：

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --scan \
  --scan-time 8 \
  --scan-repeats 1 \
  --server 23.144.12.228 \
  --ssh-host 23.144.12.228 \
  --ssh-user root \
  --ssh-pass 'xxxxx' \
  --profile aggressive \
  --detach \
  --yes
```

---

## 9. reverse / `iperf3 -R` 场景

默认方向就是：

```bash
--direction reverse
```

也就是：

```bash
iperf3 -c SERVER -R
```

reverse 模式下：

```text
client = 本机，主要接收
server = 远端，主要发送
```

所以调下行时，远端 server 才是发送端。为了让拥塞算法、发送缓冲、CPU 绑核、zerocopy 等参数真正作用到发送端，强烈建议提供：

```bash
--ssh-host 23.144.12.228 --ssh-user root
```

推荐命令：

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --scan \
  --server 23.144.12.228 \
  --ssh-host 23.144.12.228 \
  --ssh-user root \
  --ssh-pass 'xxxxx' \
  --profile aggressive \
  --detach \
  --yes
```

---

## 10. 结果怎么看

测试结果默认写入：

```text
/var/lib/iperf3-tune/state.json
```

查看状态：

```bash
sudo /usr/local/sbin/iperf3-tune status
```

查看关键字段：

```bash
sudo jq '.timestamp,.server,.direction,.profile,.single,.best' /var/lib/iperf3-tune/state.json
```

查看单流扫描最优组合：

```bash
sudo jq '.best_congestion,.best_window,.best_cpu_local,.best_cpu_remote,.sender' /var/lib/iperf3-tune/state.json
```

查看完整 JSON：

```bash
sudo jq . /var/lib/iperf3-tune/state.json
```

---

## 11. 回退与卸载

回退本机：

```bash
sudo /usr/local/sbin/iperf3-tune rollback --yes
```

回退本机 + 远端：

```bash
sudo /usr/local/sbin/iperf3-tune rollback \
  --ssh-host 23.144.12.228 \
  --ssh-user root \
  --ssh-pass 'xxxxx' \
  --yes
```

卸载脚本：

```bash
sudo ./uninstall.sh
```

彻底删除配置、状态、日志：

```bash
sudo rm -rf /etc/iperf3-tune /var/lib/iperf3-tune /var/log/iperf3-tune
```

---

## 12. 一键排查清单

如果命令不能跑，按顺序执行：

```bash
cd ~/iperf3
git pull --ff-only
sudo ./install.sh
hash -r

which -a iperf3-tune
sudo /usr/local/sbin/iperf3-tune --version
sudo /usr/local/sbin/iperf3-tune --help | grep -E -- '--scan|--single|--cpu-remote'

ssh root@23.144.12.228 'iperf3 --version || true'
ssh root@23.144.12.228 'iperf3 -s -p 5201 -D || true'
```

然后再次执行：

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --scan \
  --server 23.144.12.228 \
  --ssh-host 23.144.12.228 \
  --ssh-user root \
  --ssh-pass 'xxxxx' \
  --profile aggressive \
  --detach \
  --yes
```

---

## 13. 建议工作流

首次使用：

```bash
sudo /usr/local/sbin/iperf3-tune detect
```

先只测：

```bash
sudo /usr/local/sbin/iperf3-tune bench --single --server 23.144.12.228
```

确认远端 SSH 可用后完整优化：

```bash
sudo /usr/local/sbin/iperf3-tune optimize \
  --scan \
  --server 23.144.12.228 \
  --ssh-host 23.144.12.228 \
  --ssh-user root \
  --ssh-pass 'xxxxx' \
  --profile aggressive \
  --detach \
  --yes
```

查看结果：

```bash
sudo /usr/local/sbin/iperf3-tune watch
sudo /usr/local/sbin/iperf3-tune status
sudo jq . /var/lib/iperf3-tune/state.json
```

不满意或要恢复：

```bash
sudo /usr/local/sbin/iperf3-tune rollback \
  --ssh-host 23.144.12.228 \
  --ssh-user root \
  --ssh-pass 'xxxxx' \
  --yes
```
