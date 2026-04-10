# iperf3 双端 Sysctl 自动调优

> 自动调优并持久化 **客户端 + 服务端** 的网络内核参数，提升 `iperf3 -R` 吞吐，尽量降低重传。

## 它解决什么问题

这个脚本面向 `iperf3 -R` 场景，自动完成：

- 客户端接收侧 sysctl 调优
- 服务端发送侧 sysctl 调优
- 远端 profile 比较：`bbr-fq / cubic-fq / cubic-fq_codel`
- 自动搜索更优组合
- 结果可选：**回滚 / 保留 / 持久化**

持久化后：

- 客户端写入：`/etc/sysctl.d/99-iperf3-client-tune.conf`
- 服务端写入：`/etc/sysctl.d/99-iperf3-server-tune.conf`

---

## 适合谁

适合这些场景：

- 你测的是 `iperf3 -R`
- 本地能 SSH 到服务端
- 你想自动调优双端，而不是手工改 sysctl
- 你希望脚本帮你决定是否持久化

---

## 快速开始

```bash
git clone https://github.com/lucifer988/iperf3.git
cd iperf3
chmod +x iperf3-easy.sh
sudo ./iperf3-easy.sh --interactive
```

最推荐：

```bash
sudo ./iperf3-easy.sh --interactive
```

跑完后脚本会再问你一次：

1. 仅查看结果并回滚
2. 保留最佳运行态
3. 持久化最佳配置（推荐）

---

## 非交互示例

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

只调本地：

```bash
sudo ./iperf3-easy.sh \
  --server 1.2.3.4 \
  --target-mbps 1000 \
  --local-only \
  --persist \
  --yes
```

---

## 持久化内容

### 客户端

主要写入：

- `net.core.rmem_max`
- `net.core.wmem_max`
- `net.ipv4.tcp_rmem`
- `net.ipv4.tcp_wmem`
- `net.ipv4.tcp_moderate_rcvbuf`
- `net.ipv4.tcp_mtu_probing`
- `net.ipv4.tcp_no_metrics_save`

### 服务端

主要写入：

- `net.core.rmem_max`
- `net.core.wmem_max`
- `net.ipv4.tcp_wmem`
- `net.ipv4.tcp_congestion_control`
- `net.core.default_qdisc`

---

## 结果文件

常见输出：

- `summary.csv`
- `final-summary.json`
- `run_best.sh`
- `remote-auto-report_*/summary.tsv`
- `remote-auto-report_*/summary.json`

如果启用了 `auto-all`：

- 会比较不同远端 profile
- 按 **综合评分优先** 选最佳 profile
- 输出推荐复用命令

---

## 重要说明

### 1. 这个脚本主要持久化的是 sysctl

也就是双端内核参数。

### 2. `iperf3 -w 4M` 不是 sysctl

像下面这种参数：

```bash
-w 4M
```

是 `iperf3` 命令行参数，不属于 sysctl。  
所以即使双端 sysctl 已持久化，后续跑 iperf3 时仍建议显式带上脚本推荐的 `-w`。

### 3. `iperf3 -R` 下服务端更关键

因为 `-R` 模式真正发流的是服务端，服务端的拥塞控制和 qdisc 往往更重要。

---

### 持久化后可选清理结果

交互模式下，如果你选择“持久化最佳配置”，脚本会再问一次是否清理本次本地测试结果目录。

- 只清理本地结果文件
- 不影响已经写入双端的持久化 sysctl 配置

## 一句话总结

> 这个仓库的主线不是“单纯测速”，而是：**自动搜索并持久化双端更优的 sysctl 配置，再辅以最佳 iperf3 参数。**
