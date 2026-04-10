# iperf3 双端 Sysctl 自动调优与持久化

> 目标很明确：**自动调优客户端与服务端的 sysctl.conf / sysctl.d 配置，提升 `iperf3 -R` 吞吐，尽量降低重传。**

这个仓库现在的核心不是“花里胡哨地跑测试”，而是：

- 自动通过 SSH 接管服务端
- 自动调优 **服务端发送侧** sysctl
- 自动调优 **客户端接收侧** sysctl
- 自动比较不同远端 profile（可选）
- 找出更适合当前链路的组合
- **把双端最佳 sysctl 配置持久化落地**
- 最后再补上 `iperf3` 命令层建议（例如 `-w 4M`）

---

## 这工具适合谁

适合下面这种场景：

- 你测的是 `iperf3 -R`
- 客户端没有公网 IP，或者不想在服务端手工操作
- 你希望脚本帮你：
  - 登录服务端
  - 调整双端 sysctl
  - 做一轮自动搜索
  - 最后决定 **回滚 / 保留 / 持久化**

如果你的核心诉求是：

> **通过调整客户端和服务端 sysctl.conf，增大 iperf3 吞吐、降低重传，并且持久化生效**

那这个脚本就是围绕这个目标写的。

---

## 仓库里只有一个主脚本

```bash
iperf3-easy.sh
```

---

## 最快开始

```bash
git clone https://github.com/lucifer988/iperf3.git
cd iperf3
chmod +x iperf3-easy.sh
sudo ./iperf3-easy.sh --interactive
```

最推荐直接用：

```bash
sudo ./iperf3-easy.sh --interactive
```

---

## 它实际会做什么

### 客户端（本地）

脚本会围绕接收侧自动调整这些内核参数：

- `net.core.rmem_max`
- `net.core.wmem_max`
- `net.ipv4.tcp_rmem`
- `net.ipv4.tcp_wmem`
- `net.ipv4.tcp_moderate_rcvbuf`
- `net.ipv4.tcp_mtu_probing`
- `net.ipv4.tcp_no_metrics_save`
- 在需要时，也会调整：
  - `net.ipv4.tcp_congestion_control`
  - `net.core.default_qdisc`

### 服务端（远端）

脚本会围绕发送侧自动调整这些参数：

- `net.core.rmem_max`
- `net.core.wmem_max`
- `net.ipv4.tcp_wmem`
- `net.ipv4.tcp_congestion_control`
- `net.core.default_qdisc`

并自动做：

- SSH 登录服务端
- 安装缺失依赖
- 启动 / 清理 `iperf3 server`
- 切换远端 profile：
  - `bbr-fq`
  - `cubic-fq`
  - `cubic-fq_codel`

---

## 你需要明白的一件事

### Sysctl 能持久化，但 `iperf3 -w` 不是 sysctl

脚本会帮你找到：

- 双端更合适的 sysctl 配置
- 更合适的远端 profile
- 更合适的 `iperf3` 运行参数

但像这种参数：

```bash
-w 4M
```

是 **iperf3 命令行参数**，不是 sysctl。  
所以即使双端 sysctl 已经持久化，之后跑 iperf3 时，你仍然应该按脚本给出的推荐命令显式带上 `-w`。

---

## 最推荐的工作流

### 方案 1：交互模式（最适合）

```bash
sudo ./iperf3-easy.sh --interactive
```

运行时会问你：

- 服务端 IP / 域名
- SSH 用户
- SSH 地址
- SSH 密码
- SSH 端口
- 目标单流 Mbps
- iperf3 端口
- 可选 RTT
- 可选客户端公网 IP

跑完后会**明确再问你一次最终动作**：

1. 仅查看结果并回滚  
2. 保留最佳运行态（本地 + 远端）  
3. **持久化最佳配置（本地 + 远端，推荐）**

这才是这个仓库现在最推荐的使用方式。

### 方案 2：非交互模式

```bash
sudo ./iperf3-easy.sh \
  --server 1.2.3.4 \
  --server-ssh root@1.2.3.4 \
  --server-ssh-pass '你的SSH密码' \
  --server-ssh-port 22 \
  --target-mbps 1000 \
  --persist \
  --yes
```

如果你已经知道 RTT，可以补：

```bash
  --remote-rtt-ms 180
```

如果你只想先调客户端，不碰远端：

```bash
sudo ./iperf3-easy.sh \
  --server 1.2.3.4 \
  --target-mbps 1000 \
  --local-only \
  --persist \
  --yes
```

---

## 结果怎么看

跑完后主要会产出这些文件：

- `summary.csv`
- `final-summary.json`
- `run_best.sh`
- `remote-auto-report_*/summary.tsv`
- `remote-auto-report_*/summary.json`

如果启用了 `auto-all`：

- 会比较不同远端 profile
- 会按 **综合评分优先、吞吐次级** 选最佳远端 profile
- 会显示每个 profile 的：
  - 吞吐
  - score
  - 重传
  - 本地最佳参数
- 会额外给出一条 **下次直接复用** 的推荐命令

---

## 持久化后到底写到了哪

### 客户端

脚本会把本地最佳 sysctl 持久化到：

```bash
/etc/sysctl.d/99-iperf3-client-tune.conf
```

如果本地 sender 侧也参与了优化，还会额外写：

```bash
/etc/systemd/system/iperf3-qdisc.service
```

用于系统启动后恢复 qdisc。

### 服务端

服务端目前会把远端最佳 sysctl / profile 相关配置写到：

```bash
/etc/sysctl.d/99-iperf3-server-tune.conf
```

也就是说：

- 发送缓冲、拥塞控制、qdisc 等服务端关键参数会合并持久化到同一个文件

---

## 脚本优化目标是什么

不是只追求跑分最大，而是尽量同时做到：

- 吞吐更高
- 重传更低
- 对当前线路更稳
- 持久化后可复用

所以脚本内部会综合考虑：

- `mbps`
- `sender_retrans`
- 本地 `TcpRetransSegs` 增量
- RTT / BDP
- 本地接收缓冲
- 远端发送 profile

---

## auto-all 现在有什么意义

`auto-all` 不是噱头，而是：

- 帮你比较多种远端发送侧策略
- 自动选出当前链路更合适的服务端 profile
- 让最终持久化更有依据

而且现在：

- 单个 profile 失败不会拖垮整轮
- 失败项会写进汇总
- 结果提取优先读取结构化 `final-summary.json`
- 降低对终端文本格式的依赖

---

## 注意事项

- `iperf3 -R` 下，真正发流的是服务端，所以**服务端 sysctl 往往更关键**
- 即使 sysctl 已持久化，`-w 4M` 这类 `iperf3` 参数也建议继续显式带上
- 如果你使用 `--server-ssh-pass`，密码会出现在 shell 历史里；更推荐交互模式
- 更换线路、机房、运营商、目标带宽后，建议重新跑一次

---

## 这个仓库现在的主线

一句话总结：

> **自动搜索更优的双端网络内核参数，并把最佳 sysctl 持久化落地，再辅以最佳 iperf3 参数。**

如果你需要的就是这件事，那就直接：

```bash
sudo ./iperf3-easy.sh --interactive
```

跑完后选：

```text
3) 持久化最佳配置（本地 + 远端；推荐）
```
