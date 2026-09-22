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
