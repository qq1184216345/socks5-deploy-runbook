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
