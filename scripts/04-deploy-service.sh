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
