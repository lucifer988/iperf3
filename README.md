# iperf3 单文件一键自动调优

这个仓库现在的目标很简单：

- **一个入口脚本**：`iperf3-easy.sh`
- **你不用去服务端手动执行任何命令**
- 你只需要提供：**服务端 IP、SSH 信息、目标网速**
- 脚本会自动：连 SSH、装依赖、启动服务端、调参、测速、清理
- 优化目标：**速度尽量高，重传尽量低**

---

## 适合谁

适合这种场景：

- 你本地没有公网 IP
- 但你本地可以 `SSH` 到服务端
- 服务端是 Linux
- 你想测 `iperf3 -R`，也就是 **服务端发，本地收**
- 你不想在服务端手动安装、手动启动、手动调 sysctl、手动回滚

如果这就是你的场景，那你直接用下面命令就行。

---

## 一键使用

```bash
git clone https://github.com/lucifer988/iperf3.git
cd iperf3
chmod +x iperf3-easy.sh iperf3.sh
sudo ./iperf3-easy.sh --interactive
```

运行后，脚本会问你：

- 服务端 IP / 域名
- SSH 用户名（默认 `root`）
- SSH 地址
- SSH 密码
- SSH 端口
- 目标单流 Mbps
- iperf3 端口
- 可选 RTT
- 可选本地公网 IP

你填完以后，后面的事都由脚本自己做。

---

## 它会自动帮你做什么

### 本地自动处理

- 检查本地依赖
- 必要时自动安装：
  - `iperf3`
  - `openssh-client`
  - `sshpass`
  - `python3`
  - `iproute2`
  - `iputils-ping`

### 服务端自动处理

脚本会通过 SSH 自动在服务端做这些事：

- 检查并安装缺失依赖
- 自动准备 `iperf3 server`
- 自动调 `sysctl`
- 自动切换远端发送侧 profile
- 自动启动 / 停止 `iperf3`
- 默认测完自动清理现场

**你不需要登录服务端手动跑命令。**

---

## 最推荐的用法

```bash
sudo ./iperf3-easy.sh --interactive
```

这是最适合你的模式。

因为它会：

- 自动问你需要的信息
- 自动选择更合适的调优强度
- 默认适配“本地无公网 IP”的情况
- 自动做双端联调

---

## 非交互用法

如果你之后想写成自己的快捷命令，也可以直接这样：

```bash
sudo ./iperf3-easy.sh \
  --server 1.2.3.4 \
  --server-ssh root@1.2.3.4 \
  --server-ssh-pass '你的SSH密码' \
  --server-ssh-port 22 \
  --target-mbps 1000 \
  --yes
```

如果你知道 RTT，可以这样：

```bash
sudo ./iperf3-easy.sh \
  --server 1.2.3.4 \
  --server-ssh root@1.2.3.4 \
  --server-ssh-pass '你的SSH密码' \
  --server-ssh-port 22 \
  --target-mbps 1000 \
  --remote-rtt-ms 180 \
  --yes
```

---

## 脚本会怎么调

脚本会自动在这些方向上做搜索和选择：

- 本地接收侧窗口/缓冲参数
- 服务端发送侧 profile
- 在 `bbr-fq` / `cubic-fq` / `cubic-fq_codel` 之间比较
- 根据吞吐和重传综合挑选结果

默认不是单纯追求跑分最大，目标是：

- **高吞吐**
- **低重传**
- **更适合真实链路**

---

## 输出结果看哪里

跑完后重点看这些：

- `summary.csv`
- `final-summary.json`
- `run_best.sh`
- `remote-auto-report_*/summary.tsv`
- `remote-auto-report_*/summary.json`

如果用了 `auto-all`，你还能看到不同远端 profile 的对比结果。

---

## 默认行为

默认情况下：

- 本地会调优并测试
- 服务端会自动启动和调优
- 跑完后会自动清理服务端临时状态
- 不需要你再去服务端手动回滚

---

## 什么时候需要你自己管

基本只需要管两件事：

1. 你能从本地 SSH 到服务端
2. 你给的 SSH 账号在服务端有足够权限（最好 root）

如果不是 root，也最好确保它能执行需要的系统命令。

---

## 最短复制版

你可以直接复制这段：

```bash
git clone https://github.com/lucifer988/iperf3.git
cd iperf3
chmod +x iperf3-easy.sh iperf3.sh
sudo ./iperf3-easy.sh --interactive
```

---

## 注意事项

- `-R` 模式下，真正发送数据的是服务端，所以服务端 profile 很重要
- 如果你不知道 RTT，可以不填，脚本会用保守值
- 如果你知道 RTT，填上通常更准
- 如果线路、机房、运营商、目标带宽变了，建议重新跑一次
- `--server-ssh-pass` 会出现在 shell 历史里，所以长期建议优先用交互模式
