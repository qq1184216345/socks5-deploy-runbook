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
