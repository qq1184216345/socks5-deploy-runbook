# SOCKS5 代理部署文档（多 IP 通用）

> 基于 2026-09-22 在阿里云香港 3-IP 实例（Ubuntu 24.04 / 407MB）上的完整实施与踩坑整理。
> 文档内所有脚本均在该机器上实测通过，可自适应 **任意数量的 IP**（1 个到 N 个）。
>
> **技术选型**：官方 [Xray-core](https://github.com/XTLS/Xray-core)，非网上流传的一键脚本。
> 原因见文末〈附录 B：为什么不用网上的一键脚本〉。

---

## 1. 交付方式（给 AI 助手的启动指令）

仓库： **https://github.com/qq1184216345/socks5-deploy-runbook**

买到新服务器后，把下面这段发给我即可，我会照本文档从头配到底：

```
按 https://github.com/qq1184216345/socks5-deploy-runbook 配置 socks5

服务器: <公网IP>
账号: root
密码: <密码>
起始端口: 55620        # 可选，不填默认 55620
```

我会自动完成：探测机器上有几个 IP、每个 IP 的公网出口是哪个、逐路生成独立凭证、
部署服务、然后从服务器侧和你本机侧双向验证，最后把凭证表交给你。

**唯一需要你手动做的事**：在云控制台安全组放通端口（见第 5 节）。这一步 API 权限不在我手上。

### 给 AI 助手的注意事项

1. **本文档中所有公网 IP 均为 RFC 5737 文档示例段占位符**（`203.0.113.0/24`），
   不是真实服务器地址。实际部署时由 `03-gen-config.py` 自动探测，无需手填。

2. **不要把任何真实凭证或真实服务器 IP 提交回本仓库。** 仓库是公开的。
   `.gitignore` 已拦掉 `credentials.txt` 与 `config.json`，但提交前仍应自查。

3. 克隆方式：

   ```bash
   git clone https://github.com/qq1184216345/socks5-deploy-runbook /tmp/sk5doc
   cd /tmp/sk5doc
   ```

---

## 2. 服务器配置推荐

### 2.1 硬件

| 项目 | 最低 | 推荐 | 实测说明 |
|---|---|---|---|
| 内存 | 512MB | **1GB 以上** | Xray 本体只占 **35MB**，但 407MB 的机器跑任何 `apt` 操作都会被拖死（见附录 A 事故）|
| CPU | 1 核 | 1-2 核 | 代理转发本身不吃 CPU；**慎选突发性能实例**（阿里云 t5/t6、腾讯云 S/SA 突发型），CPU 积分耗尽会被限流到 ~10%，表现为 SSH 连得上但迟迟不返回 banner |
| 磁盘 | 20GB | 20GB | Xray 本体 36MB + geoip/geosite 数据 30MB，总占用 < 100MB |
| swap | — | **必须有** | 零 swap 的小内存机器一遇内存压力就全盘卡死（进程集体进 D 状态、load 飙到 20+）。`01-preflight.sh` 会自动加 |
| 带宽 | 按需 | 按需 | 这是代理的实际瓶颈，按并发和流量估算 |

> **结论**：不要为了省钱买 512MB 以下的机型。1GB 内存的机器多花的钱，远少于机器卡死排查一次的时间成本。

### 2.2 系统

- **推荐 Ubuntu 22.04 / 24.04 LTS**，或 Debian 12。本文档脚本在 **Ubuntu 24.04.2** 实测通过。
- CentOS 7 已 EOL，不建议。
- 架构支持 x86_64 与 arm64，`02-install-xray.sh` 自动识别。

### 2.3 多 IP 机器的关键前提

想让每个端口走**不同的公网出口 IP**，必须满足：

1. 机器上有多个**辅助私网 IP**（阿里云：弹性网卡辅助私网 IP；其他云类似）
2. **每个私网 IP 各自绑定一个独立的公网 IP / EIP**

若多个私网 IP 共用同一个 EIP，那么无论开多少端口，出口 IP 都是同一个——这是云平台的网络配置问题，不是代理配置能解决的。

`03-gen-config.py` 会逐个 IP 实测出口地址并打印出来，一眼就能看出映射是否正确。本次实测结果：

```
[1] 172.18.63.192    -> 公网出口 203.0.113.10
[2] 172.18.63.193    -> 公网出口 203.0.113.11
[3] 172.18.63.194    -> 公网出口 203.0.113.12
```

---

## 3. 部署流程总览

六个脚本，按序执行。全部位于本文档同级的 `scripts/` 目录。

| 脚本 | 作用 | 在哪运行 |
|---|---|---|
| `01-preflight.sh` | 体检 + 加 swap + 关掉会压垮小机器的服务 | 服务器 |
| `02-install-xray.sh` | 下载官方 Xray，**校验 SHA256** 后安装 | 服务器 |
| `03-gen-config.py` | **自动探测 N 个 IP**，生成 N 路配置与随机凭证 | 服务器 |
| `04-deploy-service.sh` | 装 systemd 服务并启动 | 服务器 |
| `05-verify-server.sh` | 服务器本机验证（绕过安全组）| 服务器 |
| `06-verify-client.sh` | 经公网验证 | 本机 Mac |

### 3.1 一键上传并执行（在本机 Mac 运行）

```bash
SRV=<服务器公网IP>
PW='<root密码>'
DOC=$(pwd)      # 在克隆下来的仓库根目录执行

# 上传脚本
sshpass -p "$PW" scp -o StrictHostKeyChecking=no -r "$DOC/scripts" root@$SRV:/root/sk5/

# 依次执行（每步看完输出再走下一步，不要盲目串起来跑）
sshpass -p "$PW" ssh -o StrictHostKeyChecking=no root@$SRV 'bash /root/sk5/01-preflight.sh'
sshpass -p "$PW" ssh -o StrictHostKeyChecking=no root@$SRV 'bash /root/sk5/02-install-xray.sh'
sshpass -p "$PW" ssh -o StrictHostKeyChecking=no root@$SRV 'BASE_PORT=55620 python3 /root/sk5/03-gen-config.py'
sshpass -p "$PW" ssh -o StrictHostKeyChecking=no root@$SRV 'bash /root/sk5/04-deploy-service.sh'
sshpass -p "$PW" ssh -o StrictHostKeyChecking=no root@$SRV 'bash /root/sk5/05-verify-server.sh'

# 拉回凭证，从本机验证
sshpass -p "$PW" scp -o StrictHostKeyChecking=no \
  root@$SRV:/usr/local/etc/xray/credentials.txt ./credentials.txt
chmod 600 ./credentials.txt
bash "$DOC/scripts/06-verify-client.sh" ./credentials.txt
```

> **`01` 必须最先跑**。它会先 mask 掉 apt 自动升级，再做后续操作——顺序颠倒就可能复现附录 A 的事故。

---

## 4. 各步骤详解与脚本全文

### 步骤 1：体检 + swap + 关资源杀手

做三件事：打印机器实况；内存 < 2GB 且 swap < 512MB 时自动建 swap 并写入 `fstab`；**mask 掉 apt 全套自动升级定时器**。内存 < 1GB 时额外停用云主机上无用的守护进程（`multipathd` 约 26MB、`tuned` 约 16MB 等，合计可回收约 60MB）。

刻意**不碰**云厂商的管理代理（`AliYunDun`、`aliyun-service` 等）——关掉会影响控制台改密码、监控等功能，该不该关是机器主人的决定。


```bash
#!/bin/bash
# 步骤1: 体检 + 加 swap + 关掉会压垮小内存机器的服务
# 必须在任何 apt 操作之前运行
set -u

echo "########## 系统信息 ##########"
grep PRETTY_NAME /etc/os-release
echo "架构: $(uname -m)   内核: $(uname -r)   CPU核数: $(nproc)"
echo
echo "########## 网卡 IP ##########"
ip -4 -o addr show scope global | awk '{print "  " $2 "  " $4}'
echo
echo "########## 内存 / 磁盘 ##########"
free -m | head -3
df -h / | tail -1
echo

# --- 加 swap（内存 < 2G 时强烈建议；零 swap 的小机器必加）---
MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
SWAP_MB=$(free -m | awk '/^Swap:/{print $2}')
if [ "$SWAP_MB" -lt 512 ] && [ "$MEM_MB" -lt 2048 ]; then
  SIZE=1G; [ "$MEM_MB" -ge 1024 ] && SIZE=2G
  echo ">>> 内存 ${MEM_MB}MB、swap ${SWAP_MB}MB —— 创建 $SIZE swap"
  fallocate -l $SIZE /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
  chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl -w vm.swappiness=30 >/dev/null
  grep -q vm.swappiness /etc/sysctl.conf || echo 'vm.swappiness=30' >> /etc/sysctl.conf
  echo ">>> swap 已启用并写入 fstab（重启保持）"
else
  echo ">>> swap 无需调整 (内存 ${MEM_MB}MB / swap ${SWAP_MB}MB)"
fi
echo

# --- 掐掉 apt 自动升级：小内存机器的头号杀手 ---
echo ">>> mask apt 自动升级（apt-check 单进程可吃 47MB，407MB 机器会被拖死）"
systemctl mask --now apt-daily.timer apt-daily-upgrade.timer \
  apt-daily.service apt-daily-upgrade.service unattended-upgrades.service 2>&1 | grep -c Created | xargs -I{} echo "  已 mask {} 项"
pkill -9 -f unattended-upgr 2>/dev/null
pkill -9 -f apt-check 2>/dev/null
echo

# --- 关掉云主机上无用的守护进程（内存 < 1G 时执行）---
if [ "$MEM_MB" -lt 1024 ]; then
  echo ">>> 内存 < 1G，停用云主机上无用的守护进程"
  for s in multipathd.service multipathd.socket tuned.service \
           networkd-dispatcher.service udisksd.service; do
    systemctl disable --now "$s" >/dev/null 2>&1 && echo "  已停用 $s"
  done
  echo "  注意: 未触碰 AliYunDun / aliyun-service 等云厂商管理代理（关掉会影响控制台功能）"
fi
echo
echo "########## 体检后状态 ##########"
free -m | head -3
echo "负载: $(cat /proc/loadavg)"
echo ">>> 步骤1 完成"
```

### 步骤 2：安装官方 Xray-core

要点：

- 版本号从 GitHub API 取最新 release，不写死
- **下载后用官方 `.dgst` 文件校验 SHA256，不一致立即终止**
- **用 `python3` 的 `zipfile` 解压，全程不调用 `apt`**。这是从附录 A 事故学来的：`apt-get update` 会刷新软件源并触发 `unattended-upgrades`，在小内存机器上足以致命。Ubuntu/Debian 自带 python3，无需额外装包。
- 注意：`zipfile.extractall()` **不保留可执行权限位**，解压出来的 `xray` 是 `-rw-r--r--`。脚本用 `install -m 755` 显式设权限，已实测正确。
- 建一个 `nologin` 的 `xray` 专用用户，服务不以 root 运行。


```bash
#!/bin/bash
# 步骤2: 安装官方 Xray-core（校验 SHA256）
# 刻意不使用 apt —— 用 python3 解压，避免触发软件源刷新与自动升级
set -eu

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)  PKG=Xray-linux-64.zip ;;
  aarch64|arm64) PKG=Xray-linux-arm64-v8a.zip ;;
  *) echo "不支持的架构: $ARCH"; exit 1 ;;
esac

VER=$(curl -s --max-time 25 https://api.github.com/repos/XTLS/Xray-core/releases/latest \
      | grep -m1 '"tag_name"' | cut -d'"' -f4)
[ -n "$VER" ] || { echo "获取版本号失败"; exit 1; }
echo ">>> 目标版本 $VER  架构包 $PKG"

WORK=/root/xray-dl
rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"
BASE="https://github.com/XTLS/Xray-core/releases/download/$VER"
curl -sL --max-time 180 -o "$PKG"       "$BASE/$PKG"
curl -sL --max-time 60  -o "$PKG.dgst"  "$BASE/$PKG.dgst"

WANT=$(grep -i 'SHA2-256' "$PKG.dgst" | head -1 | awk '{print $NF}')
GOT=$(sha256sum "$PKG" | awk '{print $1}')
echo ">>> 官方 SHA256: $WANT"
echo ">>> 实际 SHA256: $GOT"
[ "$WANT" = "$GOT" ] || { echo "!!! 校验失败，终止安装 !!!"; exit 1; }
echo ">>> 校验通过"

# 用 python3 解压（Ubuntu/Debian 自带），不调用 apt 装 unzip
python3 - "$PKG" <<'PY'
import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extractall('.')
print(">>> 解压完成")
PY

install -m 755 xray /usr/local/bin/xray
mkdir -p /usr/local/etc/xray /var/log/xray /usr/local/share/xray
for f in geoip.dat geosite.dat; do
  [ -f "$f" ] && install -m 644 "$f" /usr/local/share/xray/
done
id xray >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin -M xray
chown -R xray:xray /var/log/xray

echo ">>> 已安装: $(/usr/local/bin/xray version | head -1)"
echo ">>> 步骤2 完成"
```

### 步骤 3：生成配置（自适应任意 IP 数量）

这是整套方案能"不管几个 IP 都能配"的核心。脚本自动：

1. `ip -4 -o addr show scope global` 列出本机全部全局 IPv4
2. 对每个 IP 用 `curl --interface <ip>` 实测其公网出口地址（三个查询源依次兜底）
3. 第 N 个 IP 分配端口 `BASE_PORT + N - 1`
4. 每路生成独立的 8 位用户名 + 16 位强随机密码（设 `SAME_CRED=1` 可改为全部共用一组）
5. 写出配置与 `credentials.txt`（权限 600）

#### 三个必须理解的配置要点

**(1) `settings.ip` 必须填公网 IP —— 网上脚本在这里有 bug**

```json
"settings": {
  "ip": "203.0.113.10",      // ✅ 公网 IP
  "udp": true
}
```

这个字段是 socks5 **UDP ASSOCIATE** 阶段告知客户端"往哪发 UDP 包"的中继地址。
网上流传的脚本填的是内网 IP（`172.18.63.192`），公网客户端根本发不到那个地址，
结果 **TCP 正常但 UDP 静默失效**。本次实施中我也先踩了这个坑，实测定位后修正。

**(2) `listen` 填内网 IP，`sendThrough` 填内网 IP**

云厂商的 EIP 是 DNAT 到私网 IP 的，所以监听私网 IP 即可接到对应 EIP 的流量；
`sendThrough` 指定出站源地址，这是实现"不同端口走不同公网出口"的关键。
若机器是公网 IP 直接配在网卡上（部分海外 VPS），脚本探测到出口 == 本地 IP，配置依然正确。

**(3) 拦截内网段 + 云元数据，且必须用 `IPIfNonMatch`**

```json
"routing": { "domainStrategy": "IPIfNonMatch", "rules": [ ... ] }
```

代理不加限制的话，任何人拿到凭证就能用它访问你的**内网**和**云元数据接口**
（阿里云 `100.100.100.200`、标准 `169.254.169.254`），后者可能泄露实例临时凭证。
脚本拦掉 16 个网段（`100.64.0.0/10` 覆盖阿里云元数据，`169.254.0.0/16` 覆盖标准地址）。

`domainStrategy` 必须是 `IPIfNonMatch`：默认的 `AsIs` 只按域名匹配规则，
攻击者可以用一个解析到 `169.254.169.254` 的域名绕过 IP 拦截规则。


```python
#!/usr/bin/env python3
"""
步骤3: 生成 Xray socks5 配置 —— 自动适配任意数量的 IP

自动完成:
  1. 探测本机所有全局 IPv4
  2. 逐个测出该 IP 的公网出口地址（curl --interface）
  3. 为每个 IP 生成一条 socks5 入站 + 独占出站 + 路由规则
  4. 随机生成每路的用户名/密码
  5. 拦截内网段与云元数据接口

环境变量:
  BASE_PORT   起始端口, 默认 55620（第 N 个 IP 用 BASE_PORT+N-1）
  XRAY_CONF   配置输出路径, 默认 /usr/local/etc/xray/config.json
  XRAY_CRED   凭证输出路径, 默认 /usr/local/etc/xray/credentials.txt
  SAME_CRED   设为 1 则所有端口共用同一组用户名密码, 默认每路独立
"""
import json, os, re, secrets, string, subprocess, sys

BASE_PORT = int(os.environ.get("BASE_PORT", "55620"))
CONF      = os.environ.get("XRAY_CONF", "/usr/local/etc/xray/config.json")
CRED      = os.environ.get("XRAY_CRED", "/usr/local/etc/xray/credentials.txt")
SAME_CRED = os.environ.get("SAME_CRED", "") == "1"

# 内网 + 链路本地 + 云元数据，全部拦掉。
# 100.64.0.0/10 覆盖阿里云元数据 100.100.100.200；169.254.0.0/16 覆盖标准元数据地址。
PRIVATE = ["0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
           "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24", "192.168.0.0/16",
           "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24",
           "224.0.0.0/4", "240.0.0.0/4", "::1/128", "fc00::/7", "fe80::/10"]

UA = string.ascii_lowercase + string.digits
PA = string.ascii_letters + string.digits
IPV4 = re.compile(r"^\d{1,3}(\.\d{1,3}){3}$")


def sh(cmd: str) -> str:
    return subprocess.run(cmd, shell=True, capture_output=True,
                          text=True).stdout.strip()


def local_ips():
    """本机全局 IPv4，保序去重"""
    out = sh("ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1")
    seen, res = set(), []
    for line in out.splitlines():
        ip = line.strip()
        if ip and ip not in seen:
            seen.add(ip)
            res.append(ip)
    return res


def egress_ip(ip: str):
    """该内网 IP 出公网时的源地址；探测失败返回 None"""
    for url in ("https://api.ipify.org", "https://ifconfig.me/ip",
                "https://ipv4.icanhazip.com"):
        out = sh(f"curl --interface {ip} -s --max-time 10 {url}")
        if IPV4.match(out or ""):
            return out
    return None


def main():
    ips = local_ips()
    if not ips:
        sys.exit("未探测到任何全局 IPv4，请检查 `ip -4 addr`")
    print(f">>> 探测到 {len(ips)} 个 IP: {', '.join(ips)}")

    shared_user = "".join(secrets.choice(UA) for _ in range(8))
    shared_pass = "".join(secrets.choice(PA) for _ in range(16))

    inbounds, outbounds, rules, creds = [], [], [], []
    rules.append({"type": "field", "ip": PRIVATE, "outboundTag": "block"})

    for i, lan_ip in enumerate(ips):
        n, port = i + 1, BASE_PORT + i
        pub = egress_ip(lan_ip)
        if pub is None:
            pub = lan_ip
            print(f"  [{n}] {lan_ip:<16} 出口探测失败，按直连公网 IP 处理")
        else:
            print(f"  [{n}] {lan_ip:<16} -> 公网出口 {pub}")

        user = shared_user if SAME_CRED else "".join(secrets.choice(UA) for _ in range(8))
        pw   = shared_pass if SAME_CRED else "".join(secrets.choice(PA) for _ in range(16))
        creds.append((lan_ip, port, user, pw, pub))

        inbounds.append({
            "tag": f"in{n}",
            "listen": lan_ip,        # 监听内网 IP：云厂商 EIP 会 DNAT 到这里
            "port": port,
            "protocol": "socks",
            "settings": {
                "auth": "password",
                "udp": True,
                # 关键: 这是告知客户端的 UDP 中继地址，必须填【公网】IP。
                # 填内网 IP 会导致公网客户端的 UDP 包发不到——这是原版脚本的 bug。
                "ip": pub,
                "accounts": [{"user": user, "pass": pw}],
            },
        })
        outbounds.append({"tag": f"out{n}", "protocol": "freedom",
                          "sendThrough": lan_ip})
        rules.append({"type": "field", "inboundTag": [f"in{n}"],
                      "outboundTag": f"out{n}"})

    outbounds.append({"tag": "block", "protocol": "blackhole"})

    cfg = {
        "log": {"loglevel": "warning"},
        "inbounds": inbounds,
        "outbounds": outbounds,
        # IPIfNonMatch: 先把域名解析成 IP 再匹配路由，
        # 否则可以用解析到 169.254.169.254 的域名绕过上面的拦截规则。
        "routing": {"domainStrategy": "IPIfNonMatch", "rules": rules},
    }

    os.makedirs(os.path.dirname(CONF), exist_ok=True)
    with open(CONF, "w") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)

    with open(CRED, "w") as f:
        f.write("# 内网IP 端口 用户名 密码 公网出口IP\n")
        for c in creds:
            f.write(" ".join(map(str, c)) + "\n")
    os.chmod(CRED, 0o600)

    print(f"\n>>> 配置已写入 {CONF}（{len(ips)} 路）")
    print(f">>> 凭证已写入 {CRED}（权限 600）\n")
    print("=" * 62)
    print(f"{'公网出口IP':<18}{'端口':<8}{'用户名':<12}密码")
    print("=" * 62)
    for lan, port, user, pw, pub in creds:
        print(f"{pub:<18}{port:<8}{user:<12}{pw}")
    print("=" * 62)


if __name__ == "__main__":
    main()
```

### 步骤 4：部署 systemd 服务

systemd 单元的安全加固项：`User=xray`（不以 root 运行）、`ProtectSystem=strict`、
`ProtectHome`、`NoNewPrivileges`、`CapabilityBoundingSet` 只留 `CAP_NET_BIND_SERVICE`。
`MemoryMax` 按 IP 数量自动放宽（基础 128M，每多一路 +32M），防止异常情况下把小机器吃垮。


```bash
#!/bin/bash
# 步骤4: 安装 systemd 服务并启动
set -eu

# MemoryMax 按 IP 数量放宽：基础 128M，每多一路 +32M
N=$(grep -vc '^#' /usr/local/etc/xray/credentials.txt 2>/dev/null || echo 1)
MEMMAX=$((128 + (N - 1) * 32))

cat > /etc/systemd/system/xray.service <<UNIT
[Unit]
Description=Xray SOCKS5 Proxy (multi-IP egress)
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=xray
Group=xray
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65535
MemoryMax=${MEMMAX}M
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true
ReadWritePaths=/var/log/xray
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
UNIT

chown root:xray /usr/local/etc/xray/config.json
chmod 640 /usr/local/etc/xray/config.json

echo ">>> 配置语法检查"
/usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json 2>&1 | tail -1

systemctl daemon-reload
systemctl enable xray >/dev/null 2>&1
systemctl restart xray
sleep 2

echo ">>> 服务状态: $(systemctl is-active xray)  自启: $(systemctl is-enabled xray)"
echo ">>> MemoryMax=${MEMMAX}M ($N 路)"
echo ">>> 监听端口:"
ss -tlnp | grep xray | awk '{print "  " $4}'
echo ">>> 步骤4 完成"
```

### 步骤 5：服务器本机验证

**这一步的价值在于区分"配置问题"和"安全组问题"。** 本机测试绕过安全组：
本机通了但公网不通 → 安全组；本机也不通 → 配置。

本次实施中，我曾一度把 `55621/55622` 不通误判为安全组规则问题，实际是机器资源耗尽。
先跑这个脚本就能避免这种误判。

检查 8 项：N 路 TCP 出口分流、错误密码拒绝、匿名访问拒绝、三类内网/元数据拦截、UDP 转发。


```bash
#!/bin/bash
# 步骤5: 服务器本机验证（绕过安全组，用于区分「配置问题」与「安全组问题」）
CRED=/usr/local/etc/xray/credentials.txt
pass_n=0; fail_n=0

echo "########## TCP 出口分流 ##########"
while read -r ip port user pw pub; do
  [ "${ip:0:1}" = "#" ] && continue
  out=$(curl -s --max-time 15 --socks5-hostname "$user:$pw@$ip:$port" https://api.ipify.org 2>&1)
  if [ "$out" = "$pub" ]; then
    echo "  端口 $port  ✅ 出口 $out"; pass_n=$((pass_n+1))
  else
    echo "  端口 $port  ❌ 期望 $pub 实得 '$out'"; fail_n=$((fail_n+1))
  fi
done < "$CRED"

echo
echo "########## 认证强制 ##########"
read -r ip port user pw pub < <(grep -v '^#' "$CRED" | head -1)
out=$(curl -s --max-time 10 --socks5-hostname "$user:WrongPass000@$ip:$port" https://api.ipify.org 2>&1)
[ -z "$out" ] && { echo "  错误密码  ✅ 已拒绝"; pass_n=$((pass_n+1)); } \
              || { echo "  错误密码  ❌ 竟然通过: $out"; fail_n=$((fail_n+1)); }
out=$(curl -s --max-time 10 --socks5-hostname "$ip:$port" https://api.ipify.org 2>&1)
[ -z "$out" ] && { echo "  匿名访问  ✅ 已拒绝"; pass_n=$((pass_n+1)); } \
              || { echo "  匿名访问  ❌ 竟然通过: $out"; fail_n=$((fail_n+1)); }

echo
echo "########## 内网/元数据拦截 ##########"
for target in 100.100.100.200 169.254.169.254 10.0.0.1; do
  out=$(curl -s --max-time 8 --socks5-hostname "$user:$pw@$ip:$port" "http://$target/" 2>&1)
  [ -z "$out" ] && { echo "  $target  ✅ 已拦截"; pass_n=$((pass_n+1)); } \
                || { echo "  $target  ❌ 泄露: ${out:0:60}"; fail_n=$((fail_n+1)); }
done

echo
echo "########## UDP 转发（强制发到内网地址，绕过安全组）##########"
python3 - "$ip" "$port" "$user" "$pw" <<'PY'
import socket, struct, sys
host, port, user, pw = sys.argv[1], int(sys.argv[2]), sys.argv[3].encode(), sys.argv[4].encode()
try:
    s = socket.create_connection((host, port), timeout=10)
    s.sendall(b"\x05\x01\x02")
    if s.recv(2) != b"\x05\x02": sys.exit("  ❌ 认证方法协商失败")
    s.sendall(b"\x01" + bytes([len(user)]) + user + bytes([len(pw)]) + pw)
    if s.recv(2)[1] != 0: sys.exit("  ❌ 认证被拒")
    s.sendall(b"\x05\x03\x00\x01\x00\x00\x00\x00" + struct.pack("!H", 0))
    r = s.recv(10)
    if r[1] != 0: sys.exit(f"  ❌ UDP ASSOCIATE 拒绝 REP={r[1]}")
    relay_port = struct.unpack("!H", r[8:10])[0]
    print(f"  上报中继地址 = {socket.inet_ntoa(r[4:8])}:{relay_port}  (应为公网IP)")
    dns = (b"\xab\xcd\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"
           b"\x07example\x03com\x00\x00\x01\x00\x01")
    pkt = b"\x00\x00\x00\x01" + socket.inet_aton("8.8.8.8") + struct.pack("!H", 53) + dns
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); u.settimeout(10)
    u.sendto(pkt, (host, relay_port))
    data, _ = u.recvfrom(4096)
    print(f"  ✅ UDP 转发正常，DNS answer 数={struct.unpack('!H', data[16:18])[0]}")
except socket.timeout:
    print("  ❌ 本机 UDP 也不通 —— 问题在 Xray 配置，不是安全组")
except Exception as e:
    print(f"  ❌ {type(e).__name__}: {e}")
PY

echo
echo "########## 资源占用 ##########"
v=$(systemctl show xray -p MemoryCurrent --value)
echo "  xray 驻留内存: $((v/1024/1024)) MB"
echo "  负载: $(cat /proc/loadavg | cut -d' ' -f1-3)"
free -m | head -3 | sed 's/^/  /'
echo
echo "########## 汇总: 通过 $pass_n 项, 失败 $fail_n 项 ##########"
```

### 步骤 6：本机（客户端）验证

> **必须用 `bash` 运行，不要用 `zsh`。** macOS 默认 shell 是 zsh，而 zsh 不对无引号变量做分词，
> `set -- $line` 会把整行塞进 `$1`，导致代理串损坏、`curl` 报 `rc=5`（无法解析代理）。
> 这个坑在本次实施中连踩两次。


```bash
#!/bin/bash
# 步骤6: 从本机（Mac/任意客户端）经公网验证
#
# 用法: bash 06-verify-client.sh <credentials.txt>
#   credentials.txt 即服务器 /usr/local/etc/xray/credentials.txt
#   格式: 内网IP 端口 用户名 密码 公网出口IP
#
# 拉取方式:
#   sshpass -p '密码' scp -o StrictHostKeyChecking=no \
#     root@<服务器IP>:/usr/local/etc/xray/credentials.txt ./credentials.txt
#
# 【必须用 bash 运行，不能用 zsh】zsh 默认不对无引号变量做分词，
# 会把整行塞进 $1，导致 proxy 串损坏、curl 报 rc=5 (无法解析代理)。

set -u
CRED="${1:-credentials.txt}"
[ -f "$CRED" ] || { echo "找不到凭证文件: $CRED"; exit 1; }

tcp_ok=0; tcp_fail=0; udp_ok=0; udp_fail=0

echo "########## TCP: 经公网逐路验证出口 IP ##########"
while read -r lan port user pw pub; do
  [ "${lan:0:1}" = "#" ] && continue
  printf "  %-16s:%-6s " "$pub" "$port"
  out=$(curl -s --max-time 15 --socks5-hostname "$user:$pw@$pub:$port" https://api.ipify.org 2>&1)
  rc=$?
  if [ "$out" = "$pub" ]; then
    echo "✅ 出口 $out"; tcp_ok=$((tcp_ok+1))
  elif [ -n "$out" ]; then
    echo "⚠️  连通但出口是 $out（期望 $pub）"; tcp_fail=$((tcp_fail+1))
  else
    echo "❌ 不通 (curl rc=$rc)"; tcp_fail=$((tcp_fail+1))
  fi
done < "$CRED"

echo
echo "########## UDP: 经公网逐路验证 ##########"
while read -r lan port user pw pub; do
  [ "${lan:0:1}" = "#" ] && continue
  printf "  %-16s:%-6s " "$pub" "$port"
  python3 - "$pub" "$port" "$user" "$pw" <<'PY'
import socket, struct, sys
host, port = sys.argv[1], int(sys.argv[2])
user, pw = sys.argv[3].encode(), sys.argv[4].encode()
DNS = (b"\xab\xcd\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"
       b"\x07example\x03com\x00\x00\x01\x00\x01")
try:
    s = socket.create_connection((host, port), timeout=10)
    s.sendall(b"\x05\x01\x02")
    if s.recv(2) != b"\x05\x02":
        print("❌ 认证方法协商失败"); sys.exit(2)
    s.sendall(b"\x01" + bytes([len(user)]) + user + bytes([len(pw)]) + pw)
    if s.recv(2)[1] != 0:
        print("❌ 认证被拒"); sys.exit(2)
    s.sendall(b"\x05\x03\x00\x01\x00\x00\x00\x00" + struct.pack("!H", 0))
    r = s.recv(10)
    if r[1] != 0:
        print(f"❌ UDP ASSOCIATE 拒绝 REP={r[1]}"); sys.exit(2)
    rip, rport = socket.inet_ntoa(r[4:8]), struct.unpack("!H", r[8:10])[0]
    if rip in ("0.0.0.0", "127.0.0.1"):
        rip = host
    pkt = b"\x00\x00\x00\x01" + socket.inet_aton("8.8.8.8") + struct.pack("!H", 53) + DNS
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); u.settimeout(10)
    u.sendto(pkt, (rip, rport))
    data, _ = u.recvfrom(4096)
    print(f"✅ UDP 通 (中继 {rip}:{rport}, answer={struct.unpack('!H', data[16:18])[0]})")
except socket.timeout:
    print("❌ UDP 超时 —— 安全组未放通 UDP（先用 05 脚本确认本机 UDP 正常）")
    sys.exit(2)
except Exception as e:
    print(f"❌ {type(e).__name__}: {e}"); sys.exit(2)
PY
  [ $? -eq 0 ] && udp_ok=$((udp_ok+1)) || udp_fail=$((udp_fail+1))
done < "$CRED"

echo
echo "########## 安全策略（取第一路抽检）##########"
read -r lan port user pw pub < <(grep -v '^#' "$CRED" | head -1)
out=$(curl -s --max-time 10 --socks5-hostname "$user:WrongPass000@$pub:$port" https://api.ipify.org 2>&1)
[ -z "$out" ] && echo "  错误密码         ✅ 已拒绝" || echo "  错误密码         ❌ 通过了: $out"
out=$(curl -s --max-time 10 --socks5-hostname "$pub:$port" https://api.ipify.org 2>&1)
[ -z "$out" ] && echo "  匿名访问         ✅ 已拒绝" || echo "  匿名访问         ❌ 通过了: $out"
for t in 100.100.100.200 169.254.169.254; do
  out=$(curl -s --max-time 8 --socks5-hostname "$user:$pw@$pub:$port" "http://$t/" 2>&1)
  [ -z "$out" ] && echo "  $t  ✅ 已拦截" || echo "  $t  ❌ 泄露"
done
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
       --socks5-hostname "$user:$pw@$pub:$port" https://www.cloudflare.com/cdn-cgi/trace)
[ "$code" = "200" ] && echo "  正常站点可用     ✅ HTTP 200" || echo "  正常站点         ⚠️  HTTP $code"

echo
echo "########## 汇总 ##########"
echo "  TCP: 通 $tcp_ok / 失败 $tcp_fail"
echo "  UDP: 通 $udp_ok / 失败 $udp_fail"
[ "$udp_fail" -gt 0 ] && echo "  提示: UDP 全失败但 TCP 正常 → 安全组补 UDP 规则即可"
```

---

## 5. 安全组配置（必须手动做）

在云控制台给实例的安全组添加**入方向**规则：

| 协议 | 端口范围 | 授权对象 | 说明 |
|---|---|---|---|
| TCP | `55620/55622` | 你的客户端出口 IP/32 | 端口数 = IP 数量，起始端口 `BASE_PORT` |
| UDP | `55620/55622` | 同上 | **不加这条，UDP 代理静默失效** |

### 两个容易出错的点

1. **UDP 必须单独加。** TCP 和 UDP 是两条独立规则，只放 TCP 的话 `06` 脚本会报
   "UDP 超时"。本次实施最后就卡在这里：TCP 三路全通，UDP 三路全超时。
2. **多 IP 机器要确认规则覆盖全部 IP。** 阿里云安全组是实例级的，通常自动覆盖所有网卡；
   但若用了多安全组或网卡级 ACL，需逐个确认。

### 授权对象怎么填

- **强烈建议填你的固定出口 IP/32**。公网暴露的 socks5 会在上线几分钟内被扫描器发现。
- 出口 IP 不固定（家宽拨号）才用 `0.0.0.0/0`，此时依赖 16 位随机密码作为唯一防线。
- 查自己的出口 IP：`curl https://api.ipify.org`

### 不要"全部放通"

那篇参考文章建议安全组设为"全部放通"图省事。这等于把机器上每个端口都暴露到公网——
包括 SSH 22 和将来你可能临时起的任何服务。按上表只开需要的端口。

---

## 6. 运维速查

```bash
# 服务状态 / 重启 / 日志
systemctl status xray
systemctl restart xray
journalctl -u xray -n 50 --no-pager

# 查看凭证
cat /usr/local/etc/xray/credentials.txt

# 改端口或重新随机所有凭证（会换掉全部密码）
BASE_PORT=56000 python3 /root/sk5/03-gen-config.py && bash /root/sk5/04-deploy-service.sh

# 只改某一路的密码：直接编辑 config.json 里对应 inbound 的 accounts，然后
/usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json   # 先验语法
systemctl restart xray
# 记得同步更新 credentials.txt

# 机器新增了 IP（加了辅助私网IP + EIP）后，重新生成即可自动纳入
python3 /root/sk5/03-gen-config.py && bash /root/sk5/04-deploy-service.sh

# 升级 Xray 到最新版
bash /root/sk5/02-install-xray.sh && systemctl restart xray

# 资源占用
systemctl show xray -p MemoryCurrent --value | awk '{print $1/1024/1024 " MB"}'
cat /proc/loadavg
```

### 客户端使用

```bash
# curl
curl --socks5-hostname '用户名:密码@公网IP:端口' https://api.ipify.org

# 注意用 --socks5-hostname（域名交给代理解析），而非 --socks5（本地解析后再发）
```

浏览器 / 各类工具填 SOCKS5，地址 = 公网 IP，端口 = 对应端口，勾选"需要认证"填用户名密码。

---

## 7. 卸载与回滚

```bash
# 卸载 Xray
systemctl disable --now xray
rm -f /etc/systemd/system/xray.service /usr/local/bin/xray
rm -rf /usr/local/etc/xray /usr/local/share/xray /var/log/xray
systemctl daemon-reload
userdel xray 2>/dev/null

# 恢复 apt 自动安全更新（升配后建议恢复）
systemctl unmask apt-daily.timer apt-daily-upgrade.timer \
  apt-daily.service apt-daily-upgrade.service unattended-upgrades.service
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer

# 恢复被停用的守护进程
systemctl enable --now multipathd.service tuned.service networkd-dispatcher.service

# 移除 swap
swapoff /swapfile && rm -f /swapfile
sed -i '/^\/swapfile/d' /etc/fstab
```

> 注意：`01-preflight.sh` **不会**像网上那些脚本一样清空 iptables。
> 若你的机器原本有 iptables 规则，本方案完全不触碰。

---

## 附录 A：2026-09-22 实施事故复盘

首次实施中把服务器搞到 SSH 连不上，值得记录以免重犯。

### 现象

配置完成、三路验证全部通过之后，机器突然全面无响应：
TCP 22 端口能完成握手，但 SSH banner 交换超时；socks5 端口同样 TCP 通但不返回协商响应。
`load average` 一路飙到 **29.71**，几乎所有进程卡在 **D 状态**（不可中断的 I/O 等待）。

### 排查路径

1. 先怀疑是刚改的安全组规则 → **错**。安全组不会导致 TCP 握手成功但应用层无响应。
2. 再怀疑突发性能实例 CPU 积分耗尽 → 症状吻合，但不是本次主因。
3. 关键线索：PID 计数器 10 分钟内从 ~12000 涨到 26586，**每秒约 23 个新进程**。
4. `ps --sort=-pcpu` 抓到真凶：

```
16.8 %CPU  33988 KB  unattended-upgr    17:09:25 启动
 1.1 %CPU  47212 KB  apt-check
 2.0 %CPU   5196 KB  xray               ← 代理本身很清白
```

### 根因

`unattended-upgrades` 及其拉起的 `apt-check`，在 407MB 内存的机器上光 RSS 就占掉约 80MB，
触发 `kswapd0` 疯狂换页，进而全系统 I/O 饥饿。

**触发点是我自己**：为装 `unzip` 跑了一次 `apt-get update`，刷新软件源后
`unattended-upgrades` 就去处理待升级包了。机器本身底子也薄——零 swap，
我登录之前 `dmesg` 在 16:46 已经在刷 `Under memory pressure, flushing caches`。

### 处置与结果

加 1GB swap、mask 掉 apt 全套定时器、停用 `multipathd`/`tuned`/`networkd-dispatcher`。

```
load:  26.35 → 17.36 → 14.69 → 9.74 → 6.97 → 4.99 → 3.58 → 2.56 → 0.03
可用内存: 90MB → 225MB
```

机器恢复后三路 socks5 立即全部正常，证实与代理配置无关。

### 写进本文档的三条改进

1. **`01-preflight.sh` 必须最先跑**，先 mask apt 自动升级再做别的
2. **`02-install-xray.sh` 全程不用 apt**，改用 python3 解压
3. **先跑 `05-verify-server.sh`（本机验证）再判断安全组**，避免误判

---

## 附录 B：为什么不用网上的一键脚本

参考文章（CSDN `YUNZHUJI4613/article/details/147579676`）的全部内容就是一条命令：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/yanpengcloud/scoks/refs/heads/main/test1.sh)
```

审计该脚本后发现四个问题，因此没有采用：

| 问题 | 具体内容 |
|---|---|
| 自删除 | 脚本首行 `rm -f $0`，执行后自我删除，不留审计痕迹 |
| 匿名闭源二进制 | 从 `github.com/yanpeng997995/prxoy/raw/main/sk5` 下载（仓库名拼写为 `prxoy`），以 root + `Restart=always` 常驻，内容完全不可审计，无任何校验 |
| 清空防火墙 | 安装和卸载都执行 `iptables -F` / `-X` 并把三条链策略置为 `ACCEPT`，会抹掉机器上原有的全部防火墙规则 |
| 回传信息 | "Bug 反馈"功能把服务器公网 IP、系统信息 POST 到硬编码的 `43.163.94.138:8000` |

从它生成的配置格式（`inbounds` / `outbounds` / `sendThrough` / `routing`）可以判断，
那个 `sk5` 二进制基本就是改名的 Xray-core。所以本方案直接用官方 Xray-core，
功能完全等价，但二进制来自 XTLS 官方仓库、带 SHA256 校验、可审计，
并额外补上了原脚本缺失的内网/元数据拦截，同时修正了它 `settings.ip` 填内网 IP 的 UDP bug。

---

## 附录 C：本次实施的验收记录（2026-09-22，阿里云香港 3-IP）

> 下列公网 IP 已替换为 RFC 5737 文档示例段（`203.0.113.x`），非真实地址；
> 端口、内网 IP、版本号、SHA256 与实测一致。

服务器侧 `05-verify-server.sh`：**8 项通过 / 0 失败**

```
TCP 出口分流:  55620 → 203.0.113.10     ✅
               55621 → 203.0.113.11   ✅
               55622 → 203.0.113.12    ✅
认证强制:      错误密码 ✅ 拒绝   匿名访问 ✅ 拒绝
内网/元数据:   100.100.100.200 ✅  169.254.169.254 ✅  10.0.0.1 ✅
UDP 转发:      ✅ 正常（中继地址上报为公网 IP，DNS answer=2）
资源占用:      xray 35MB   load 0.03   可用内存 223MB
```

本机侧 `06-verify-client.sh`：TCP 3/3 通，安全策略全过，UDP 0/3（安全组未放通 UDP）

```
环境: Ubuntu 24.04.2 / x86_64 / 407MB / Xray-core v26.3.27
SHA256: 23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae（与官方 .dgst 一致）
```
