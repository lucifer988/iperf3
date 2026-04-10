# iperf3 一键自动调优

目标：

- 适合 **本地没有公网 IP** 的场景
- 只需要你提供 **服务端 IP、SSH 密码、SSH 端口、目标网速**
- 脚本自动完成双端联调
- 自动根据链路和目标速率选择更合适的调优强度
- 最终倾向：**吞吐高、重传低**

这个仓库现在保留 3 个文件：

- `iperf3-easy.sh`：唯一入口，推荐只用它
- `iperf3-remote.sh`：远端联调层
- `iperf3.sh`：本地调优引擎

---

## 1. 安装依赖

本地机器执行：

```bash
apt-get update
apt-get install -y iperf3 openssh-client sshpass python3 iproute2 iputils-ping
```

服务端至少要有：

```bash
apt-get update
apt-get install -y iperf3 iproute2 iputils-ping
```

> 脚本需要 `sudo/root`，因为会调整 `sysctl` 和 `tc`。

---

## 2. 一键使用

```bash
git clone https://github.com/lucifer988/iperf3.git
cd iperf3
chmod +x iperf3-easy.sh iperf3-remote.sh iperf3.sh
sudo ./iperf3-easy.sh --interactive
```

运行后会问你：

- 服务端 IP / 域名
- SSH 用户名（默认 `root`）
- SSH 地址
- SSH 密码
- SSH 端口
- 目标单流 Mbps
- `iperf3` 端口
- 可选 RTT
- 可选本地公网 IP

如果你什么都不懂，按默认走也可以。

---

## 3. 它会自动做什么

`iperf3-easy.sh --interactive` 会自动：

1. 根据你的目标网速和 RTT，选择 `fast / balanced / exhaustive`
2. 本地通过 SSH 登录远端
3. 远端自动准备 `iperf3 server`
4. 自动尝试不同远端发送 profile
5. 本地自动搜索更合适的窗口/接收参数
6. 根据 **速度** 和 **重传** 综合选择更优结果

默认更适合这类链路：

- 海外 server -> 国内 client
- 高 RTT
- 本地无公网 IP
- 只能主动 SSH 到服务端

---

## 4. 最常用命令

### 交互式，最推荐

```bash
sudo ./iperf3-easy.sh --interactive
```

### 非交互方式

```bash
sudo ./iperf3-easy.sh \
  --server 1.2.3.4 \
  --server-ssh root@1.2.3.4 \
  --server-ssh-pass '你的SSH密码' \
  --server-ssh-port 22 \
  --target-mbps 1000 \
  --yes
```

### 如果你知道 RTT，可以补进去

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

## 5. 输出结果看哪里

主要看：

- `summary.csv`
- `final-summary.json`
- `run_best.sh`
- 双端模式下的 `summary.tsv`
- 双端模式下的 `summary.json`

重点关注：

- 最佳中位数吞吐
- 最佳参数组合
- 重传是否明显下降

---

## 6. 保留/回滚策略

默认：测速完成后回滚。

如果你想保留本地最佳运行态：

```bash
sudo ./iperf3-easy.sh --interactive --keep
```

如果你想持久化本地运行态：

```bash
sudo ./iperf3-easy.sh --interactive --persist
```

---

## 7. 适合你的使用方式

你这种场景，直接复制：

```bash
git clone https://github.com/lucifer988/iperf3.git
cd iperf3
apt-get update
apt-get install -y iperf3 openssh-client sshpass python3 iproute2 iputils-ping
chmod +x iperf3-easy.sh iperf3-remote.sh iperf3.sh
sudo ./iperf3-easy.sh --interactive
```

---

## 8. 注意

- `-R` 模式下，真正发送数据的是服务端，所以远端 profile 很关键
- 如果你不提供公网 IP，脚本也能跑
- 如果你知道 RTT，填上通常更准
- `--server-ssh-pass` 会留在 shell 历史里，长期建议交互输入
- 换线路、换机房、换目标带宽后，建议重新跑一次
