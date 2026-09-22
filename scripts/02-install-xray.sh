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
