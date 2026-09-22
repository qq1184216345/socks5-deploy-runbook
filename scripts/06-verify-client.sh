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
