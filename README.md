# iperf3-tune 一键使用

所有命令都是一行。把 `<SERVER_IP>` 换成远端 iperf3 server 的 IP 后直接复制执行。

## 1. 安装

```bash
unzip iperf3-tune-v2.9.1.zip && cd iperf3-main && sudo ./install.sh && iperf3-tune --version
```

```bash
git clone https://github.com/lucifer988/iperf3.git && cd iperf3 && sudo ./install.sh && iperf3-tune --version
```

## 2. 最推荐：SSH 密码全面调优

```bash
SERVER_IP=<SERVER_IP>; sudo iperf3-tune optimize --scan --direction reverse --server "$SERVER_IP" --port 5201 --ssh-host "$SERVER_IP" --ssh-user root --ssh-port 22 --ssh-ask-pass --profile aggressive --time 30 --repeats 3 --yes
```

这一行会自动完成：本机调优、SSH 远端调优、远端 iperf3 server 检查/启动、拥塞算法扫描、TCP 窗口扫描、两端 CPU 绑核扫描、最终测速。

## 3. 生产先预演，不改系统

```bash
SERVER_IP=<SERVER_IP>; sudo iperf3-tune optimize --scan --dry-run --direction reverse --server "$SERVER_IP" --port 5201 --ssh-host "$SERVER_IP" --ssh-user root --ssh-port 22 --ssh-ask-pass --profile aggressive --time 30 --repeats 3
```

## 4. 后台执行 SSH 密码全面调优

```bash
SERVER_IP=<SERVER_IP>; sudo iperf3-tune optimize --scan --detach --yes --direction reverse --server "$SERVER_IP" --port 5201 --ssh-host "$SERVER_IP" --ssh-user root --ssh-port 22 --ssh-ask-pass --profile aggressive --time 30 --repeats 3
```

## 5. 查看后台任务

```bash
sudo iperf3-tune watch
```

```bash
sudo iperf3-tune tail
```

```bash
sudo iperf3-tune stop
```

## 6. SSH 密码文件方式

```bash
SERVER_IP=<SERVER_IP>; sudo bash -c "read -rsp 'SSH password: ' P; echo; install -m 600 /dev/null /root/.iperf3-ssh.pass; printf '%s\n' \"\$P\" > /root/.iperf3-ssh.pass; iperf3-tune optimize --scan --direction reverse --server '$SERVER_IP' --port 5201 --ssh-host '$SERVER_IP' --ssh-user root --ssh-port 22 --ssh-pass-file /root/.iperf3-ssh.pass --profile aggressive --time 30 --repeats 3 --yes"
```

## 7. SSH 密钥全面调优

```bash
SERVER_IP=<SERVER_IP>; sudo iperf3-tune optimize --scan --direction reverse --server "$SERVER_IP" --port 5201 --ssh-host "$SERVER_IP" --ssh-user root --ssh-port 22 --ssh-key ~/.ssh/id_rsa --profile aggressive --time 30 --repeats 3 --yes
```

## 8. 自动安装缺失依赖后全面调优

```bash
SERVER_IP=<SERVER_IP>; sudo iperf3-tune optimize --scan --auto-install --direction reverse --server "$SERVER_IP" --port 5201 --ssh-host "$SERVER_IP" --ssh-user root --ssh-port 22 --ssh-ask-pass --profile aggressive --time 30 --repeats 3 --yes
```

## 9. 不碰网卡，只调 sysctl

```bash
SERVER_IP=<SERVER_IP>; sudo iperf3-tune optimize --scan --no-nic-tune --direction reverse --server "$SERVER_IP" --port 5201 --ssh-host "$SERVER_IP" --ssh-user root --ssh-port 22 --ssh-ask-pass --profile aggressive --time 30 --repeats 3 --yes
```

## 10. 指定真实带宽

```bash
SERVER_IP=<SERVER_IP>; sudo iperf3-tune optimize --scan --bandwidth 1000 --direction reverse --server "$SERVER_IP" --port 5201 --ssh-host "$SERVER_IP" --ssh-user root --ssh-port 22 --ssh-ask-pass --profile aggressive --time 30 --repeats 3 --yes
```

## 11. 限制 TCP 窗口上限

```bash
SERVER_IP=<SERVER_IP>; sudo iperf3-tune optimize --scan --window-max 32M --direction reverse --server "$SERVER_IP" --port 5201 --ssh-host "$SERVER_IP" --ssh-user root --ssh-port 22 --ssh-ask-pass --profile aggressive --time 30 --repeats 3 --yes
```

## 12. MTU 9000 全面调优

```bash
SERVER_IP=<SERVER_IP>; sudo iperf3-tune optimize --scan --mtu 9000 --direction reverse --server "$SERVER_IP" --port 5201 --ssh-host "$SERVER_IP" --ssh-user root --ssh-port 22 --ssh-ask-pass --profile aggressive --time 30 --repeats 3 --yes
```

## 13. 上行全面调优

```bash
SERVER_IP=<SERVER_IP>; sudo iperf3-tune optimize --scan --direction forward --server "$SERVER_IP" --port 5201 --ssh-host "$SERVER_IP" --ssh-user root --ssh-port 22 --ssh-ask-pass --profile aggressive --time 30 --repeats 3 --yes
```

## 14. 只检测

```bash
sudo iperf3-tune detect
```

## 15. 只调优本机

```bash
sudo iperf3-tune tune --profile aggressive --yes
```

## 16. 只测速，不调优

```bash
SERVER_IP=<SERVER_IP>; iperf3-tune bench --direction reverse --server "$SERVER_IP" --port 5201 --time 30 --repeats 3
```

## 17. 查看结果

```bash
sudo iperf3-tune status
```

```bash
sudo jq . /var/lib/iperf3-tune/state.json
```

## 18. 回退本机

```bash
sudo iperf3-tune rollback --yes
```

## 19. 回退本机 + 远端

```bash
SERVER_IP=<SERVER_IP>; sudo iperf3-tune rollback --ssh-host "$SERVER_IP" --ssh-user root --ssh-port 22 --ssh-ask-pass --yes
```

## 20. 启用定时调优

```bash
sudo iperf3-tuned init && sudo iperf3-tuned install
```

## 21. 查看定时调优

```bash
systemctl status iperf3-tuned.timer && systemctl status iperf3-tuned-canary.timer
```

## 22. 关闭定时调优

```bash
sudo iperf3-tuned uninstall
```

## 23. 卸载

```bash
sudo ./uninstall.sh
```

## 24. 常用 profile

```bash
SERVER_IP=<SERVER_IP>; sudo iperf3-tune optimize --scan --direction reverse --server "$SERVER_IP" --ssh-host "$SERVER_IP" --ssh-user root --ssh-ask-pass --profile balanced --yes
```

```bash
SERVER_IP=<SERVER_IP>; sudo iperf3-tune optimize --scan --direction reverse --server "$SERVER_IP" --ssh-host "$SERVER_IP" --ssh-user root --ssh-ask-pass --profile aggressive --yes
```

```bash
SERVER_IP=<SERVER_IP>; sudo iperf3-tune optimize --scan --direction reverse --server "$SERVER_IP" --ssh-host "$SERVER_IP" --ssh-user root --ssh-ask-pass --profile extreme --yes
```

## 25. 最终只记这一条

```bash
SERVER_IP=<SERVER_IP>; sudo iperf3-tune optimize --scan --direction reverse --server "$SERVER_IP" --port 5201 --ssh-host "$SERVER_IP" --ssh-user root --ssh-port 22 --ssh-ask-pass --profile aggressive --time 30 --repeats 3 --yes
```
