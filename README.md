# iperf3-tune

`iperf3-tune` 用于一键执行 iperf3 测速、网络参数调优和结果查看。

## 安装

```bash
git clone https://github.com/lucifer988/iperf3.git
cd iperf3
sudo ./install.sh
iperf3-tune --version
```

## 开始使用

先把远端 iperf3 server 的 IP 写入变量：

```bash
SERVER_IP=<SERVER_IP>
```

一键全面调优：

```bash
sudo iperf3-tune optimize --scan --direction reverse --server "$SERVER_IP" --port 5201 --ssh-host "$SERVER_IP" --ssh-user root --ssh-port 22 --ssh-ask-pass --profile aggressive --time 30 --repeats 3 --yes
```

这条命令会自动完成本机调优、SSH 远端调优、远端 iperf3 server 检查/启动、拥塞算法扫描、TCP 窗口扫描、CPU 绑核扫描和最终测速。

## 常用命令

预演，不修改系统：

```bash
sudo iperf3-tune optimize --scan --dry-run --direction reverse --server "$SERVER_IP" --port 5201 --ssh-host "$SERVER_IP" --ssh-user root --ssh-port 22 --ssh-ask-pass --profile aggressive --time 30 --repeats 3
```

后台执行：

```bash
sudo iperf3-tune optimize --scan --detach --yes --direction reverse --server "$SERVER_IP" --port 5201 --ssh-host "$SERVER_IP" --ssh-user root --ssh-port 22 --ssh-ask-pass --profile aggressive --time 30 --repeats 3
```

查看后台任务：

```bash
sudo iperf3-tune watch
sudo iperf3-tune tail
sudo iperf3-tune stop
```

只检测环境：

```bash
sudo iperf3-tune detect
```

只调优本机：

```bash
sudo iperf3-tune tune --profile aggressive --yes
```

只测速，不调优：

```bash
iperf3-tune bench --direction reverse --server "$SERVER_IP" --port 5201 --time 30 --repeats 3
```

查看结果：

```bash
sudo iperf3-tune status
sudo jq . /var/lib/iperf3-tune/state.json
```

回退本机：

```bash
sudo iperf3-tune rollback --yes
```

回退本机和远端：

```bash
sudo iperf3-tune rollback --ssh-host "$SERVER_IP" --ssh-user root --ssh-port 22 --ssh-ask-pass --yes
```

卸载：

```bash
sudo ./uninstall.sh
```

## Profile

按需替换 `--profile`：

```bash
--profile balanced
--profile aggressive
--profile extreme
```

日常推荐使用 `aggressive`。生产环境建议先执行 `--dry-run`。
