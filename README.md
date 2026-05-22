# iperf3-tune 使用说明

面向高带宽链路的 iperf3 自动调优与基准测试工具。在 root 下修改本机 sysctl / 网卡 offload / ring / RPS, 并可通过 SSH 把同一套调优同步到远端 iperf3 服务端。

---

## 1. 安装

```bash
git clone https://github.com/lucifer988/iperf3.git iperf3-tune
cd iperf3-tune
sudo ./install.sh
```

`install.sh` 会:

- 检测发行版, 自动安装 `jq iperf3 ethtool iproute2 sysstat bc tar iputils`
  - 支持 Debian/Ubuntu (apt), RHEL/CentOS/Rocky/Alma/Fedora/Amazon (dnf/yum), Arch/Manjaro (pacman), Alpine (apk), openSUSE/SLES (zypper)
- 加载 `tcp_bbr` 内核模块
- 把 `iperf3-tune` 和 `iperf3-tuned` 安装到 `/usr/local/sbin/`
- 创建 `/etc/iperf3-tune/` `/var/lib/iperf3-tune/` `/var/log/iperf3-tune/`

安装完只支持 Linux, macOS / WSL 上 `install.sh` 会直接报错并退出。

验证:

```bash
iperf3-tune --version    # 应输出 2.3.0
iperf3-tune --help
```

> `sshpass` 不在安装清单里, 属按需依赖。当你**首次**使用 `--ssh-pass` / `--ssh-pass-file` 时, root 下会自动装上; 非 root 或加了 `--no-auto-install` 则会报"使用 SSH 密码认证需要 sshpass, 但未安装"。

---

## 2. 命令一览

### `iperf3-tune` 主命令

| 命令 | 是否改本机 | 说明 |
|---|---|---|
| `detect` | 否 | 只检测 CPU / 内存 / 网卡瓶颈 |
| `tune` | 是 | 仅应用本机 sysctl + 网卡优化 |
| `bench` | 否 | 仅跑 iperf3 测试 (需 `--server`) |
| `optimize` | 是 | 完整流程: detect → 本机 tune → 远端 tune → bench |
| `rollback` | 是 | 回退本机 sysctl, 如有 `--ssh-host` 也回退远端 |
| `status` | 否 | 当前状态与最近一次结果 |
| `watch` | 否 | 后台任务实时进度 |
| `tail` | 否 | 跟随后台任务日志 |
| `stop` | 是 | 停止后台任务及其 iperf3 子进程 |

`bench`、`optimize` 支持 `-d` / `--detach` 入后台, 适合 SSH 远程操作时避免会话断开。

### `iperf3-tuned` daemon

`iperf3-tuned` 用 systemd timer 周期性重做 optimize, 配置只填一次。

| 子命令 | 说明 |
|---|---|
| `init` | 交互式生成 `/etc/iperf3-tune/config.json` (含 SSH 凭据) |
| `install` | 装 systemd timer: 每周日 22:00 跑一次 + 每 6h canary |
| `uninstall` | 卸载 timer |
| `run` | 立刻按 config 跑一次完整 optimize |
| `canary` | 手动金丝雀检查 |
| `rollback` | 按 config 回退本机 + 远端 |
| `status` | daemon / baseline / canary 状态 |

---

## 3. 第一次跑: 最小可用流程

远端先起 iperf3 服务端:

```bash
# 在 1.2.3.4 上执行 (端口任选, 默认 5201)
iperf3 -s -p 5201
# 防火墙放行 TCP 5201
```

本机先做一次只读检测, 不改任何东西:

```bash
sudo iperf3-tune detect
```

只想测速、不改系统:

```bash
sudo iperf3-tune bench --server 1.2.3.4 --time 30 --repeats 3
```

完整流程 (检测 + 本机调优 + 远端调优 + 测试):

```bash
sudo iperf3-tune optimize --detach \
    --server 1.2.3.4 \
    --ssh-host 1.2.3.4 --ssh-user root --ssh-key ~/.ssh/id_rsa \
    --profile aggressive --time 30 --repeats 3
```

加 `--detach` 入后台, 用 `sudo iperf3-tune watch` 看进度, `sudo iperf3-tune status` 看最终结果。

---

## 4. SSH 密码登录 (重点)

远端调优需要 SSH。脚本支持三种鉴权方式, **互斥**, 同时配多个时**私钥优先**(因为脚本会强制 `PreferredAuthentications=publickey`, 密码会被 ssh 拒绝)。

| 方式 | 参数 | 备注 |
|---|---|---|
| 私钥 | `--ssh-key PATH` | 推荐, 不需要 sshpass |
| 密码 (命令行) | `--ssh-pass PASS` | 简单, 但 **明文出现在 `ps` / shell 历史** |
| 密码 (文件) | `--ssh-pass-file PATH` | 推荐的密码方式, 文件权限须 600 或 400 |

下面分别说密码登录的两种用法。

### 4.1 用 `--ssh-pass` (一次性、不推荐长期使用)

```bash
sudo iperf3-tune optimize \
    --server 1.2.3.4 \
    --ssh-host 1.2.3.4 \
    --ssh-user root \
    --ssh-pass 'YourPasswordHere' \
    --profile aggressive
```

注意点:

1. 这条命令首次跑会触发自动安装 `sshpass` (Debian: `apt install sshpass`, RHEL: `yum install sshpass`, Arch: `pacman -S sshpass`, Alpine: `apk add sshpass`, openSUSE: `zypper install sshpass`)。
2. **密码会出现在 `ps auxf` 输出和你的 shell 历史里**。建议:
   - 临时操作可以用, 但跑完立刻 `history -d <行号>` 清掉
   - 长期 / 脚本化 / 多次调用, 改用 `--ssh-pass-file`
3. 如果密码包含 `$` `!` 等 shell 特殊字符, 用 **单引号** 包住, 不要用双引号。
4. 实现层是 `SSHPASS="$密码" sshpass -e ssh ...` —— 密码不进命令行, 只通过环境变量传给 sshpass, 因此 `ps` 上看不到 *sshpass 子进程* 的密码, 但**仍能在你输入这条命令的 shell 的 ps 行里看到 `--ssh-pass`**。

### 4.2 用 `--ssh-pass-file` (推荐)

把密码写到文件里, 文件权限设成 600, 然后传文件路径:

```bash
# 1) 写密码文件 (umask 077 保证创建出来就是 600)
umask 077
printf '%s' 'YourPasswordHere' > ~/.iperf3_remote.pw
chmod 600 ~/.iperf3_remote.pw

# 2) 用文件鉴权
sudo iperf3-tune optimize \
    --server 1.2.3.4 \
    --ssh-host 1.2.3.4 \
    --ssh-user root \
    --ssh-pass-file ~/.iperf3_remote.pw \
    --profile aggressive
```

要点:

1. **密码内容不要带末尾换行**。用 `printf '%s' '密码'` 而不是 `echo '密码'`, 否则末尾的 `\n` 也会被当成密码的一部分, 鉴权失败。
2. 脚本会检查文件权限, 不是 600 或 400 时会打印警告但仍继续运行。**警告别忽略**, 你不想 `/home/<user>/.iperf3_remote.pw` 让别的用户读到。
3. `sudo` 默认 `HOME=/root`, 所以 `~/.iperf3_remote.pw` 如果在 `/home/youruser/` 下, 用 sudo 跑可能找不到。用绝对路径稳妥:

   ```bash
   sudo iperf3-tune optimize ... --ssh-pass-file /home/youruser/.iperf3_remote.pw ...
   ```

4. `--ssh-pass` 和 `--ssh-pass-file` 都给的时候, `--ssh-pass` 优先。

### 4.3 走 daemon: 密码存进 config

如果你打算长期周期性跑, 用 `iperf3-tuned init`:

```bash
sudo iperf3-tuned init
# 它会交互式问:
#   iperf3 服务端 IP:                  1.2.3.4
#   ...
#   远端 SSH 主机 IP (回车跳过):       1.2.3.4
#     SSH 用户 [root]:                 root
#     认证方式 [1=密码 2=私钥] [1]:    1
#     SSH 密码:                        (输入时不回显)
```

密码以**明文**存入 `/etc/iperf3-tune/config.json`, 文件权限自动 600。之后:

```bash
sudo iperf3-tuned install   # 装 systemd timer
sudo iperf3-tuned run       # 立即跑一次
sudo iperf3-tuned status    # 查状态
```

要修改密码, 重跑 `sudo iperf3-tuned init` 即可。

### 4.4 默认 SSH 选项 (脚本写死, 知道一下)

不管哪种鉴权, 脚本都强制下列 ssh 选项:

```
-o StrictHostKeyChecking=no       # 不交互问 host key, 自动接受
-o UserKnownHostsFile=/dev/null   # 不写 known_hosts
-o ConnectTimeout=10              # 10s 连不上就失败
-o ServerAliveInterval=15
-o ServerAliveCountMax=4          # 60s 静默就断
-o LogLevel=ERROR
```

如果你的远端做了**端口非 22**, 加 `--ssh-port N`。

### 4.5 密码登录常见错误

| 现象 | 原因 |
|---|---|
| `使用 SSH 密码认证需要 sshpass, 但未安装` | 非 root 跑, 或加了 `--no-auto-install`。手动 `apt/yum/pacman install sshpass` |
| `Permission denied (publickey)` | 同时给了 `--ssh-key` 和 `--ssh-pass`, ssh 被强制成 publickey 模式。**二选一** |
| `Permission denied (publickey,password)` 但密码确实对 | 远端 `sshd_config` 把 `PasswordAuthentication` 关了, 改 `yes` 后 `systemctl restart sshd` |
| `--ssh-pass-file` 鉴权失败但密码看起来对 | 文件末尾有换行 / BOM。用 `printf '%s'` 重写, 或 `xxd 文件名` 看末尾是不是 `0a` |
| `无法 SSH 到远端` | 网络 / 防火墙 / `--ssh-port` 不对。先 `ssh -p N user@host` 手动试一次 |

---

## 5. 常用参数速查

### 测试参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `--server IP` | — | iperf3 服务端 IP (`bench` / `optimize` 必填) |
| `--port N` | 5201 | iperf3 端口 |
| `--time SECS` | 30 | 单次测试时长, ≥5 |
| `--repeats N` | 3 | 每档重复次数, 取中位 |
| `--max-parallel N` | 32 | 最大并发流 |
| `--direction reverse\|forward` | reverse | reverse = `-R` 下行测试 |
| `--mss N` | 1448 | 估算重传率用的 MSS |

### 调优参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `--profile NAME` | aggressive | `balanced` (64 MB 缓冲, 1G/2.5G) / `aggressive` (256 MB, 10G) / `extreme` (1 GB, 25G+) |
| `--congestion ALGO` | bbr | TCP 拥塞控制算法 |
| `--retrans-threshold PCT` | 3.0 | 重传率超此值时提前停止寻优 |
| `--retrans-penalty K` | 10.0 | 评分函数对重传的惩罚系数 |

### SSH 参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `--ssh-host HOST` | — | 远端 IP |
| `--ssh-user USER` | root | SSH 用户 |
| `--ssh-port N` | 22 | SSH 端口 |
| `--ssh-key PATH` | — | SSH 私钥路径 |
| `--ssh-pass PASS` | — | SSH 密码 (走 sshpass, 见 §4.1) |
| `--ssh-pass-file PATH` | — | SSH 密码文件 (推荐, 见 §4.2) |

### 其他

| 参数 | 说明 |
|---|---|
| `-d`, `--detach` | `bench` / `optimize` 后台运行 |
| `-y`, `--yes` | 非交互, 跳过确认 |
| `-v`, `--verbose` | 详细日志 + 保留 iperf3 原始 JSON |
| `--json` | JSON 输出 |
| `--no-auto-install` | 不自动装缺失依赖 |
| `-h`, `--help` | 显示帮助 |
| `-V`, `--version` | 显示版本 |

---

## 6. 后台运行与日志

`--detach` 模式下:

- PID 写在 `/var/lib/iperf3-tune/iperf3-tune.pid`
- 日志在 `/var/log/iperf3-tune/run-<时间戳>.log`
- 进度增量写到 `/var/lib/iperf3-tune/progress.json`

操作:

```bash
sudo iperf3-tune watch    # 实时进度
sudo iperf3-tune tail     # 跟日志
sudo iperf3-tune status   # 最近结果
sudo iperf3-tune stop     # 中断 + 清子进程
```

---

## 7. 回退与卸载

回退本机调优:

```bash
sudo iperf3-tune rollback
```

同时回退远端:

```bash
sudo iperf3-tune rollback \
    --ssh-host 1.2.3.4 \
    --ssh-pass-file ~/.iperf3_remote.pw    # 或 --ssh-key / --ssh-pass
```

完整卸载:

```bash
sudo ./uninstall.sh
```

会执行 rollback、移除 systemd timer、删 `/usr/local/sbin/iperf3-tune{,d}`, 但保留配置 / 日志 / 历史数据。彻底清理:

```bash
sudo rm -rf /etc/iperf3-tune /var/lib/iperf3-tune /var/log/iperf3-tune
```
