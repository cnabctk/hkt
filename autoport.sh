#!/bin/bash

# 检查是否为 root 用户
if [ "$EUID" -ne 0 ]; then 
  echo "❌ 请使用 sudo 或 root 权限运行此脚本"
  exit 1
fi

echo "🔎 正在自动分析网络环境..."

# 1. 自动获取网络参数
IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
PUB_GW=$(ip route | grep default | awk '{print $3}' | head -n1)
INT_IP=$(ip -4 addr show $IFACE | grep -oP '(?<=inet\s)172\.(1[6-9]|2[0-9]|3[0-1])\.[0-9.]+' | head -n1)
# 如果自动获取失败，请手动修正下方两行，或者脚本会报错停止
[ -z "$INT_IP" ] && INT_IP="172.16.15.12" 
INT_GW=$(echo $INT_IP | cut -d. -f1-3).1

echo "---------------------------------------"
echo "网卡设备: $IFACE"
echo "默认公网: $PUB_GW"
echo "检测内网: $INT_IP"
echo "内网网关: $INT_GW"
echo "---------------------------------------"

read -p "请输入要走内网的端口号 (默认 11111): " TARGET_PORT
TARGET_PORT=${TARGET_PORT:-11111}

# 2. 写入持久化执行脚本
cat <<EOF > /usr/local/bin/set-port-routing.sh
#!/bin/bash
# 确保路由表存在
if ! grep -q "intranet" /etc/iproute2/rt_tables; then
    echo "11 intranet" >> /etc/iproute2/rt_tables
fi

# 清理旧规则
ip rule del fwmark 11 table intranet 2>/dev/null
ip route flush table intranet

# 配置路由逻辑
ip route add default via $INT_GW dev $IFACE src $INT_IP table intranet
ip rule add fwmark 11 table intranet

# 配置 iptables (Debian 13)
iptables -t mangle -A OUTPUT -p tcp --dport $TARGET_PORT -j MARK --set-mark 11
iptables -t mangle -A OUTPUT -p udp --dport $TARGET_PORT -j MARK --set-mark 11
iptables -t nat -A POSTROUTING -m mark --mark 11 -j SNAT --to-source $INT_IP

# 内核参数优化
sysctl -w net.ipv4.conf.$IFACE.rp_filter=2
sysctl -w net.ipv4.conf.all.rp_filter=2
EOF

chmod +x /usr/local/bin/set-port-routing.sh

# 3. 写入 Systemd 服务文件
cat <<EOF > /etc/systemd/system/port-routing.service
[Unit]
Description=Port $TARGET_PORT Routing via Intranet
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/set-port-routing.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# 4. 激活服务
systemctl daemon-reload
systemctl enable port-routing.service
systemctl restart port-routing.service

echo "---------------------------------------"
echo "✅ 配置已完成并已设为开机自启！"
echo "当前策略：端口 $TARGET_PORT 走内网 ($INT_GW)，其余走公网。"
echo "查看状态：systemctl status port-routing.service"
echo "---------------------------------------"
