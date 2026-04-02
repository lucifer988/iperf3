# iperf3 自动调优脚本

包含三个脚本：
- `iperf3-easy.sh`：一键入口，优先推荐
- `iperf3.sh`：本地 client 侧自动调优与测速
- `iperf3-remote.sh`：远端 server + 本地 client 双端联调包装脚本

适合场景：
- `iperf3 -R` 反向单流测试
- 海外 server → 大陆 client
- 高 RTT、高 BDP 场景
- 想要“一条命令自动调优、自动测速、自动汇总”

---

## 一键入口（最省事）

### 双端自动联调（推荐）

```bash
cd /root/.openclaw/workspace-lite/iperf3-work
chmod +x iperf3-easy.sh iperf3.sh iperf3-remote.sh
sudo ./iperf3-easy.sh   --server 你的服务端IP   --server-ssh root@你的服务端IP   --client-ip 你的本机公网IP   --target-mbps 1000   --yes
```

### 仅本地调优

```bash
cd /root/.openclaw/workspace-lite/iperf3-work
sudo ./iperf3-easy.sh   --server 你的服务端IP   --target-mbps 1000   --yes
```

`iperf3-easy.sh` 的逻辑很简单：
- 提供了 `--server-ssh`：自动走双端联调
- 没提供 `--server-ssh`：自动走本地调优

---

## 现在已经能做什么

### `iperf3-easy.sh`
- 给出更少参数的一键入口
- 自动在“本地模式 / 双端模式”之间切换
- 支持常见参数透传：
  - `--server`
  - `--server-ssh`
  - `--client-ip`
  - `--target-mbps`
  - `--port`
  - `--profile`
  - `--remote-profile`
  - `--rollback | --keep | --persist`
  - `--yes`

### `iperf3.sh`
- 自动测 RTT、估算 BDP
- 自动生成 `-w` 候选
- 两阶段搜索：粗筛 + 精测
- 自动调优本地接收侧 sysctl
- 可选扫描本地 sender 因子（`cc/qdisc`）
- 记录每轮结果到：
  - `summary.csv`
  - 单轮 JSON / stderr 日志
- 输出最终结构化汇总：
  - `final-summary.json`
- 生成推荐复跑脚本：
  - `run_best.sh`
- 选择最优解时不只看吞吐，还会参考重传：
  - `score = Mbps - sender_retrans 惩罚 - 本地 retrans 惩罚`

### `iperf3-remote.sh`
- 远程 SSH 到 server 自动调优发送侧
- 自动启动 / 清理远端 iperf3 server
- 自动轮询远端 profile：
  - `bbr-fq`
  - `cubic-fq`
  - `cubic-fq_codel`
  - `auto`
  - `auto-all`
- 调用本地 `iperf3.sh` 完成本地搜索
- 自动汇总输出：
  - `summary.tsv`
  - `summary.json`
- 支持透传本地参数：
  - `--profile`
  - `--coarse-seconds`
  - `--fine-seconds`
  - `--omit`
  - `--bind`
  - `--skip-rx-copy`

---

## 常见用法

### 1）一键双端联调

```bash
sudo ./iperf3-easy.sh   --server 1.2.3.4   --server-ssh root@1.2.3.4   --client-ip 5.6.7.8   --target-mbps 1000   --yes
```

### 2）一键本地调优

```bash
sudo ./iperf3-easy.sh   --server 1.2.3.4   --target-mbps 1000   --yes
```

### 3）只调用底层本地脚本

```bash
sudo ./iperf3.sh   --server 1.2.3.4   --port 5201   --target-mbps 1000   --max-mbps 1000   --profile balanced   --rollback   --yes
```

### 4）只调用底层双端脚本

```bash
sudo ./iperf3-remote.sh   --server-ssh root@1.2.3.4   --server 1.2.3.4   --client-ip 5.6.7.8   --target-mbps 1000   --remote-profile auto-all   --profile balanced   --yes
```

---

## 输出文件

### 本地结果目录
`iperf3.sh` 跑完后会生成：
- `summary.csv`
- 单轮 `*.json`
- 单轮 `*.err`
- `final-summary.json`
- `run_best.sh`

### 远端汇总目录
`iperf3-remote.sh` 跑完后会生成：
- `summary.tsv`
- `summary.json`

---

## 结果怎么看

### `summary.csv`
字段：
- `phase`
- `run_id`
- `cc`
- `qdisc`
- `window`
- `mbps`
- `sender_retrans`
- `local_retrans_delta`
- `score`
- `rc`
- `json_file`
- `err_file`

说明：
- `mbps`：该轮吞吐
- `sender_retrans`：服务端发送重传
- `local_retrans_delta`：本地侧 `TcpRetransSegs` 增量
- `score`：综合评分，越高越好

### `final-summary.json`
会包含：
- 最佳 phase
- 最佳 `cc/qdisc/window`
- 最佳中位数吞吐
- 中位数 sender 重传
- 中位数本地重传增量
- 综合评分
- 全部运行记录

### `summary.tsv` / `summary.json`
会汇总不同远端 profile 的最佳表现，帮助判断：
- 哪个远端拥塞控制更优
- 哪个 qdisc 更优
- 本地窗口与本地最佳组合是什么

---

## 常用参数

### `iperf3-easy.sh`
- `--server IP/HOST`
- `--server-ssh USER@HOST`
- `--client-ip IP`
- `--target-mbps N`
- `--port N`
- `--profile fast|balanced|exhaustive`
- `--remote-profile auto|auto-all|bbr-fq|cubic-fq|cubic-fq_codel`
- `--rollback | --keep | --persist`
- `--local-only`
- `--yes`

### `iperf3.sh`
- `--server HOST`
- `--port PORT`
- `--target-mbps N`
- `--max-mbps N`
- `--profile fast|balanced|exhaustive`
- `--coarse-seconds N`
- `--fine-seconds N`
- `--omit N`
- `--bind IP`
- `--skip-rx-copy`
- `--sweep-local-sender`
- `--rollback | --keep | --persist`
- `--yes`

### `iperf3-remote.sh`
- `--server-ssh USER@HOST`
- `--server IP`
- `--client-ip IP`
- `--target-mbps N`
- `--remote-profile auto|auto-all|bbr-fq|cubic-fq|cubic-fq_codel`
- `--profile NAME`
- `--coarse-seconds N`
- `--fine-seconds N`
- `--omit N`
- `--bind IP`
- `--skip-rx-copy`
- `--remote-keep`
- `--remote-persist`
- `--local-keep`
- `--local-persist`
- `--yes`

---

## 当前建议

如果你的目标是：
> 自动把单流回程速度尽量做高，同时尽量压低重传

优先使用：

```bash
sudo ./iperf3-easy.sh   --server SERVER   --server-ssh root@SERVER   --client-ip CLIENT_PUBLIC_IP   --target-mbps 目标速率   --yes
```

如果只是本机先试：

```bash
sudo ./iperf3-easy.sh --server SERVER --target-mbps 目标速率 --yes
```

---

## 注意事项

- `-R` 模式下真正发送数据的是 server，所以远端调优通常比本地 `cc/qdisc` 更关键。
- `-w` 不会被 sysctl 永久替代，复跑 iperf3 时仍建议显式带上。
- `--persist` / `--remote-persist` 会写系统配置，生产机使用前先确认。
- 如果链路本身抖动很大，结果会有波动，建议增加 `--fine-seconds` 后再测。
