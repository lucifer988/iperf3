# iperf3 真单文件一键自动调优

现在这个仓库只保留 **一个主脚本**：

- `iperf3-easy.sh`

你的使用目标也很简单：

- **你不用去服务端手动跑任何命令**
- 你只提供：**服务端 IP、SSH 用户、SSH 密码、SSH 端口、目标网速**
- 脚本自动完成：
  - 本地依赖检查/安装
  - SSH 登录服务端
  - 服务端依赖检查/安装
  - 服务端启动 `iperf3 server`
  - 服务端发送侧调优
  - 本地接收侧调优
  - 联合测速
  - 默认自动清理服务端现场

优化目标：

- **速度高**
- **重传低**

---

## 适合的场景

如果你满足下面几点，这个脚本就是给你写的：

- 本地没有公网 IP
- 本地可以 SSH 到服务端
- 服务端是 Linux
- 你要测的是 `iperf3 -R`
- 你不想上服务端手动安装、手动启动、手动调参数、手动清理

---

## 最短使用方法

直接复制：

```bash
git clone https://github.com/lucifer988/iperf3.git
cd iperf3
chmod +x iperf3-easy.sh
sudo ./iperf3-easy.sh --interactive
```

就这一条主命令：

```bash
sudo ./iperf3-easy.sh --interactive
```

如果你已经知道参数，也可以直接非交互运行。

---

## 运行时会问你什么

脚本会交互询问：

- 服务端 IP / 域名
- SSH 用户名（默认 `root`）
- SSH 地址
- SSH 密码
- SSH 端口
- 目标单流 Mbps
- iperf3 端口
- 可选 RTT
- 可选本地公网 IP

你填完后，后面都不用管。

---

## 它会自动帮你做什么

### 本地自动处理

如果本地缺依赖，脚本会尝试自动安装：

- `iperf3`
- `openssh-client`
- `sshpass`
- `python3`
- `iproute2`
- `iputils-ping`

### 服务端自动处理

脚本会通过 SSH 自动在服务端：

- 检查依赖
- 安装缺失依赖
- 调整发送侧参数
- 启动 `iperf3 server`
- 做远端 profile 切换
- 结束后自动清理临时状态

**你不用登录服务端手动执行任何命令。**

---

## 推荐用法

### 1）最推荐：交互模式

```bash
sudo ./iperf3-easy.sh --interactive
```

这个模式最适合你，因为只需要回答提示问题。

### 2）非交互模式

如果你以后想自己封装快捷命令，也可以这样：

```bash
sudo ./iperf3-easy.sh \
  --server 1.2.3.4 \
  --server-ssh root@1.2.3.4 \
  --server-ssh-pass '你的SSH密码' \
  --server-ssh-port 22 \
  --target-mbps 1000 \
  --yes
```

如果你知道 RTT：

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

如果你只想在本机做接收侧调优，不碰远端：

```bash
sudo ./iperf3-easy.sh \
  --server 1.2.3.4 \
  --target-mbps 1000 \
  --local-only \
  --yes
```

如果你想更慢一点但测得更稳，可以加：

```bash
  --profile balanced
```

或手动指定：

- `--coarse-seconds N`
- `--fine-seconds N`
- `--omit N`
- `--bind IP`
- `--skip-rx-copy`
- `--keep` / `--persist` / `--rollback`

---

## 它怎么决定参数

脚本会自动综合这些维度：

- 本地接收窗口/缓冲
- 服务端发送侧 profile
- `bbr-fq`
- `cubic-fq`
- `cubic-fq_codel`
- 吞吐结果
- 重传情况

最终不是只追求跑分最大，而是尽量做到：

- 吞吐更高
- 重传更低
- 更适合真实线路

---

## 结果看哪里

跑完后主要看：

- `summary.csv`
- `final-summary.json`
- `run_best.sh`
- `remote-auto-report_*/summary.tsv`
- `remote-auto-report_*/summary.json`

如果启用了 `auto-all`，还能看到不同远端 profile 的对比。

---

## 默认行为

默认情况下脚本会：

- 自动处理本地调优
- 自动处理服务端调优
- 自动启动服务端 iperf3
- 自动执行测速
- 默认结束后自动清理服务端临时状态

所以你不需要再上服务端回滚。

---

## 你只需要保证两件事

1. 你的本地能 SSH 到服务端
2. 你提供的 SSH 账号在服务端有足够权限，最好是 `root`

---

## 注意事项

- `-R` 模式下，真正发流量的是服务端，所以服务端 profile 很关键
- 不知道 RTT 可以不填，脚本会用保守值
- 知道 RTT 的话，填上通常更准
- 换线路、换机房、换运营商、换目标带宽之后，建议重新跑一次
- 如果你用 `--server-ssh-pass`，密码会出现在 shell 历史里，所以长期建议优先用交互模式

## 这次继续优化了什么

这版继续把单文件模式收干净了：

- 修正单文件脚本内部残留的旧入口引用
- 修正本地调优引擎参数解析入口
- 文档统一为 `iperf3-easy.sh`，避免再出现 `iperf3.sh` 的旧说法
- README 补充 `--local-only` 和常用高级参数说明

也就是说，现在仓库语义上和实现上都更接近真正的**单文件工作流**。
