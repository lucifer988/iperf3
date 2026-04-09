# iperf3 自动调优脚本

目标很直接：

- 尽量把 `iperf3 -R` 单流速度拉高
- 同时把重传压低
- 优先适配“本地没有公网 IP，但本地能 SSH 到服务端”的场景

仓库里有 3 个脚本，但日常只需要记住 1 个入口：

- `iperf3-easy.sh`：主入口，推荐直接用
- `iperf3-remote.sh`：双端联调包装层
- `iperf3.sh`：本地调优底层脚本

## 适用场景

- 海外 server -> 大陆 client
- 高 RTT / 高 BDP 链路
- 你想根据目标带宽自动扫参数，而不是手工猜 `-w`
- 你本地没有公网 IP，但可以 `ssh` 到服务端

## 一条命令先跑起来

```bash
git clone https://github.com/lucifer988/iperf3.git
cd iperf3
chmod +x iperf3-easy.sh iperf3.sh iperf3-remote.sh
sudo ./iperf3-easy.sh \
  --server 1.2.3.4 \
  --server-ssh root@1.2.3.4 \
  --target-mbps 1000 \
  --yes
```

这就是推荐主路径。

它的含义是：

- 本地通过 SSH 登录服务端
- 服务端自动切换发送侧 profile
- 本地自动搜索 `cc/qdisc/window`
- 最终按“速度高、重传低”的综合分数选最优组合

## 没有公网 IP 也能用

现在双端模式默认不再要求 `--client-ip`。

如果你满足下面这个条件，就可以直接用上面的主命令：

- 本地能 SSH 到服务端
- 服务端不需要主动回连你的本地

### 可选增强

如果你知道链路 RTT，可以手动给一个估值，让远端初始参数更贴近实际：

```bash
sudo ./iperf3-easy.sh \
  --server 1.2.3.4 \
  --server-ssh root@1.2.3.4 \
  --target-mbps 1000 \
  --remote-rtt-ms 180 \
  --yes
```

如果你本地真的有可达公网 IP，也可以补 `--client-ip`，让服务端直接测 RTT：

```bash
sudo ./iperf3-easy.sh \
  --server 1.2.3.4 \
  --server-ssh root@1.2.3.4 \
  --client-ip 5.6.7.8 \
  --target-mbps 1000 \
  --yes
```

## 只做本地调优

如果你暂时不想 SSH 控远端：

```bash
sudo ./iperf3-easy.sh \
  --server 1.2.3.4 \
  --local-only \
  --target-mbps 1000 \
  --yes
```

或者干脆不传 `--server-ssh`，也会自动落到本地模式。

## 脚本会做什么

`iperf3-easy.sh` 会根据你有没有提供 `--server-ssh` 自动切模式：

- 有 `--server-ssh`：走双端联调
- 没有 `--server-ssh`：只做本地调优

双端联调时会做这些事：

1. 远端准备 iperf3 server，并切换发送侧 profile
2. 本地自动跑粗筛 + 精测
3. 对 `bbr-fq` / `cubic-fq` / `cubic-fq_codel` 做对比
4. 按吞吐和重传综合选出最佳结果

## 输出结果

本地调优结果目录里主要看：

- `summary.csv`
- `final-summary.json`
- `run_best.sh`

双端联调额外会产出：

- `summary.tsv`
- `summary.json`

综合评分不是只看速度，还会惩罚重传，所以更接近“速度高、重传低”的目标。

## 常用参数

主入口 `iperf3-easy.sh`：

- `--server IP/HOST`
- `--server-ssh USER@HOST`
- `--target-mbps N`
- `--remote-rtt-ms N`
- `--client-ip IP`
- `--port N`
- `--profile fast|balanced|exhaustive`
- `--remote-profile auto|auto-all|bbr-fq|cubic-fq|cubic-fq_codel`
- `--rollback | --keep | --persist`
- `--local-only`
- `--yes`

高级参数如果你需要细调，也可以继续透传到底层双端脚本：

- `--coarse-seconds N`
- `--fine-seconds N`
- `--omit N`
- `--bind IP`
- `--skip-rx-copy`

## 前提条件

- 本地和服务端都安装了 `iperf3`
- 双端模式下，本地能 `ssh` 到服务端
- 需要 `sudo`，因为脚本会调 `sysctl` / `tc`

## 注意事项

- `-R` 模式下真正发数据的是服务端，所以远端 profile 往往比本地 sender 参数更关键。
- `--persist` 和 `--remote-persist` 会写系统配置，生产机使用前先确认。
- 链路波动大时，建议适当增加 `--fine-seconds` 再复测。
- `run_best.sh` 适合复跑最佳参数，不等于永久系统最优，换线路后最好重新测。
