# iperf3-tune

iperf3 高速低重传优化工具（v2）。

目标很直接：
- **让 iperf3 测得带宽更高**
- **让重传率更低**

这套脚本偏激进优化，优先照顾压测结果，不强调“业务无感”。

## 仓库内容

- `install.sh`：安装脚本
- `uninstall.sh`：卸载脚本
- `iperf3-tune.sh`：主调优脚本
- `iperf3-tuned.sh`：定时优化/守护脚本
- `iperf3-tune.tar.gz`：打包文件

## 一键安装

直接整仓下载并安装：

```bash
TMP_DIR=$(mktemp -d) && \
cd "$TMP_DIR" && \
curl -fsSL https://github.com/lucifer988/iperf3/archive/refs/heads/main.tar.gz -o iperf3.tar.gz && \
tar -xzf iperf3.tar.gz --strip-components=1 && \
sudo bash install.sh
```

## 一键卸载

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lucifer988/iperf3/main/uninstall.sh)
```

## 常用命令

### 1）仅检测，不修改系统

```bash
sudo iperf3-tune detect
```

### 2）仅本机调优

```bash
sudo iperf3-tune tune --profile aggressive
```

### 3）完整优化 + 测试

```bash
sudo iperf3-tune optimize \
  --server 1.2.3.4 \
  --ssh-host 1.2.3.4 \
  --ssh-key ~/.ssh/id_rsa \
  --profile aggressive \
  --time 30 \
  --repeats 3
```

### 4）不满意就回退

```bash
sudo iperf3-tune rollback
```

## profile 说明

- `balanced`：适合 1G / 2.5G 链路
- `aggressive`：适合 10G 链路，默认推荐
- `extreme`：适合 25G+ 或长肥管道，更激进，业务影响更大

## 说明

- 安装脚本会自动安装依赖：`jq iperf3 ethtool iproute2/sysstat bc tar`
- 不会在安装后自动修改 sysctl，也不会自动启用 systemd timer
- 如需长期自动优化，可安装完成后执行：

```bash
sudo iperf3-tuned init
sudo iperf3-tuned install
```

## License

MIT
