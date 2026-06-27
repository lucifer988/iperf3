# iperf3-tune 一键命令

把 `1.2.3.4` 改成远端 IP；把 `YourPassword` 改成远端 SSH 密码。

## 安装

```bash
curl -fsSL https://github.com/lucifer988/iperf3/archive/refs/heads/main.tar.gz | tar -xz && cd iperf3-main && sudo ./install.sh && iperf3-tune --version
```

```bash
git clone https://github.com/lucifer988/iperf3.git && cd iperf3 && sudo ./install.sh && iperf3-tune --version
```

```bash
unzip iperf3-tune-v2.9.1.zip && cd iperf3-main && sudo ./install.sh && iperf3-tune --version
```

## SSH 密码全面调优：推荐，安全输入密码

```bash
sudo iperf3-tune optimize --scan --auto-install --direction reverse --server 1.2.3.4 --port 5201 --ssh-host 1.2.3.4 --ssh-user root --ssh-port 22 --ssh-ask-pass --profile aggressive --time 30 --repeats 3 --yes
```

## SSH 密码全面调优：密码直接写在命令里

```bash
sudo iperf3-tune optimize --scan --auto-install --direction reverse --server 1.2.3.4 --port 5201 --ssh-host 1.2.3.4 --ssh-user root --ssh-port 22 --ssh-pass 'YourPassword' --profile aggressive --time 30 --repeats 3 --yes
```

## SSH 密码全面调优：后台运行

```bash
sudo iperf3-tune optimize --scan --auto-install --detach --direction reverse --server 1.2.3.4 --port 5201 --ssh-host 1.2.3.4 --ssh-user root --ssh-port 22 --ssh-ask-pass --profile aggressive --time 30 --repeats 3 --yes
```

## 预演，不修改系统

```bash
sudo iperf3-tune optimize --dry-run --scan --direction reverse --server 1.2.3.4 --port 5201 --ssh-host 1.2.3.4 --ssh-user root --ssh-port 22 --profile aggressive --time 30 --repeats 3
```

## SSH 私钥全面调优

```bash
sudo iperf3-tune optimize --scan --auto-install --direction reverse --server 1.2.3.4 --port 5201 --ssh-host 1.2.3.4 --ssh-user root --ssh-port 22 --ssh-key ~/.ssh/id_rsa --profile aggressive --time 30 --repeats 3 --yes
```

## 上行全面调优

```bash
sudo iperf3-tune optimize --scan --auto-install --direction forward --server 1.2.3.4 --port 5201 --ssh-host 1.2.3.4 --ssh-user root --ssh-port 22 --ssh-ask-pass --profile aggressive --time 30 --repeats 3 --yes
```

## 下行全面调优

```bash
sudo iperf3-tune optimize --scan --auto-install --direction reverse --server 1.2.3.4 --port 5201 --ssh-host 1.2.3.4 --ssh-user root --ssh-port 22 --ssh-ask-pass --profile aggressive --time 30 --repeats 3 --yes
```

## 不碰网卡，只调 sysctl

```bash
sudo iperf3-tune optimize --scan --auto-install --no-nic-tune --direction reverse --server 1.2.3.4 --port 5201 --ssh-host 1.2.3.4 --ssh-user root --ssh-port 22 --ssh-ask-pass --profile aggressive --time 30 --repeats 3 --yes
```

## MTU 9000 全面调优

```bash
sudo iperf3-tune optimize --scan --auto-install --mtu 9000 --direction reverse --server 1.2.3.4 --port 5201 --ssh-host 1.2.3.4 --ssh-user root --ssh-port 22 --ssh-ask-pass --profile aggressive --time 30 --repeats 3 --yes
```

## 指定真实带宽 1000M

```bash
sudo iperf3-tune optimize --scan --auto-install --bandwidth 1000 --direction reverse --server 1.2.3.4 --port 5201 --ssh-host 1.2.3.4 --ssh-user root --ssh-port 22 --ssh-ask-pass --profile aggressive --time 30 --repeats 3 --yes
```

## 限制窗口最大 32M

```bash
sudo iperf3-tune optimize --scan --auto-install --window-max 32M --direction reverse --server 1.2.3.4 --port 5201 --ssh-host 1.2.3.4 --ssh-user root --ssh-port 22 --ssh-ask-pass --profile aggressive --time 30 --repeats 3 --yes
```

## 自定义窗口和拥塞算法扫描

```bash
sudo iperf3-tune optimize --scan --auto-install --window-list 16M,32M,64M,128M --congestion-list bbr,cubic --scan-time 10 --scan-repeats 1 --direction reverse --server 1.2.3.4 --port 5201 --ssh-host 1.2.3.4 --ssh-user root --ssh-port 22 --ssh-ask-pass --profile aggressive --time 30 --repeats 3 --yes
```

## 指定本机 CPU 和远端 CPU

```bash
sudo iperf3-tune optimize --single --auto-install --cpu 2 --cpu-remote 6 --direction reverse --server 1.2.3.4 --port 5201 --ssh-host 1.2.3.4 --ssh-user root --ssh-port 22 --ssh-ask-pass --profile aggressive --time 30 --repeats 3 --yes
```

## balanced 档全面调优

```bash
sudo iperf3-tune optimize --scan --auto-install --direction reverse --server 1.2.3.4 --port 5201 --ssh-host 1.2.3.4 --ssh-user root --ssh-port 22 --ssh-ask-pass --profile balanced --time 30 --repeats 3 --yes
```

## aggressive 档全面调优

```bash
sudo iperf3-tune optimize --scan --auto-install --direction reverse --server 1.2.3.4 --port 5201 --ssh-host 1.2.3.4 --ssh-user root --ssh-port 22 --ssh-ask-pass --profile aggressive --time 30 --repeats 3 --yes
```

## extreme 档全面调优

```bash
sudo iperf3-tune optimize --scan --auto-install --direction reverse --server 1.2.3.4 --port 5201 --ssh-host 1.2.3.4 --ssh-user root --ssh-port 22 --ssh-ask-pass --profile extreme --time 30 --repeats 3 --yes
```

## 只检测

```bash
sudo iperf3-tune detect
```

## 只调本机

```bash
sudo iperf3-tune tune --auto-install --profile aggressive --yes
```

## 只测速

```bash
sudo iperf3-tune bench --direction reverse --server 1.2.3.4 --port 5201 --time 30 --repeats 3
```

## 只测单流

```bash
sudo iperf3-tune bench --single --direction reverse --server 1.2.3.4 --port 5201 --time 30 --repeats 3
```

## 只扫窗口

```bash
sudo iperf3-tune bench --scan-window --direction reverse --server 1.2.3.4 --port 5201 --window-list 16M,32M,64M,128M --time 30 --repeats 3
```

## 只扫拥塞算法

```bash
sudo iperf3-tune bench --scan-congestion --direction reverse --server 1.2.3.4 --port 5201 --ssh-host 1.2.3.4 --ssh-user root --ssh-port 22 --ssh-ask-pass --congestion-list bbr,cubic --time 30 --repeats 3
```

## 只扫 CPU

```bash
sudo iperf3-tune bench --scan-cpu --direction reverse --server 1.2.3.4 --port 5201 --ssh-host 1.2.3.4 --ssh-user root --ssh-port 22 --ssh-ask-pass --time 30 --repeats 3
```

## 启动远端 iperf3 server

```bash
ssh root@1.2.3.4 "sudo iperf3 -s -p 5201 -D"
```

## 查看状态

```bash
sudo iperf3-tune status
```

## 查看后台进度

```bash
sudo iperf3-tune watch
```

## 查看后台日志

```bash
sudo iperf3-tune tail
```

## 停止后台任务

```bash
sudo iperf3-tune stop
```

## 查看完整结果 JSON

```bash
sudo jq . /var/lib/iperf3-tune/state.json
```

## 回退本机

```bash
sudo iperf3-tune rollback --yes
```

## 回退本机和远端

```bash
sudo iperf3-tune rollback --ssh-host 1.2.3.4 --ssh-user root --ssh-port 22 --ssh-ask-pass --yes
```

## 自检版本修复

```bash
iperf3-tune selftest
```

## 初始化定时调优

```bash
sudo iperf3-tuned init --server 1.2.3.4 --port 5201 --profile aggressive --ssh-host 1.2.3.4 --ssh-user root --ssh-pass 'YourPassword' --yes
```

## 安装定时调优

```bash
sudo iperf3-tuned install
```

## 查看定时调优

```bash
sudo iperf3-tuned status
```

## 手动跑一次定时调优

```bash
sudo iperf3-tuned run
```

## 手动跑一次金丝雀检查

```bash
sudo iperf3-tuned canary
```

## 卸载定时调优

```bash
sudo iperf3-tuned uninstall
```

## 卸载工具

```bash
cd iperf3-main && sudo ./uninstall.sh
```

## 最终只记这一条

```bash
sudo iperf3-tune optimize --scan --auto-install --direction reverse --server 1.2.3.4 --port 5201 --ssh-host 1.2.3.4 --ssh-user root --ssh-port 22 --ssh-ask-pass --profile aggressive --time 30 --repeats 3 --yes
```
