#!/bin/bash

# 检查权限
if [ "$EUID" -ne 0 ]; then 
  echo "❌ 请使用 root 权限运行"
  exit 1
fi

# --- 1. 静态参数（根据你的环境固定） ---
IFACE="eth0"
PUB_GW="199.15.78.1"
INT_IP="172.16.15.12"
INT_GW="172.16.15.1"
TARGET_PORT="11111"
TABLE_ID="11"

echo "🛠️ 正在初始化 Debian 13 端口分流配置..."

# --- 2. 写入持久化脚本 ---
# 我们直接使用数字 ID 11，不再依赖 /etc/iproute2/rt_tables 里的别名
cat <<EOF > /usr/local/bin/set-port-routing.sh
#!/bin/bash

# A. 清理旧规则（防止重复堆叠）
ip rule del fwmark $TABLE_ID table $TABLE_ID 2>/dev/null
ip route flush table $TABLE_ID

# B. 配置内网路由表 (直接使用 ID $TABLE_ID)
ip route add default via $INT_GW dev $IFACE src $INT_IP table $TABLE_ID

# C. 添加策略路由：带标签的流量查 ID 为 $TABLE_ID 的表
ip rule add fwmark $TABLE_ID table $TABLE_ID

# D. 配置防火墙标签 (iptables-nft)
# 先清除可能存在的旧规则
iptables -t mangle -D OUTPUT -p tcp --dport $TARGET_PORT -j MARK --set-mark $TABLE_ID 2>/dev/null
iptables -t mangle -D OUTPUT -p udp --dport $TARGET_PORT -j MARK --set-mark $TABLE_ID 2>/dev/null
iptables -t nat -D POSTROUTING -m mark --mark $TABLE_ID -j SNAT --to-source $INT_IP 2>/dev/null

# 重新注入
iptables -t mangle -A OUTPUT -p tcp --dport $TARGET_PORT -j MARK --set-mark $TABLE_ID
iptables -t mangle -A OUTPUT -p udp --dport $TARGET_PORT -j MARK --set-mark $TABLE_ID
iptables -t nat -A POSTROUTING -m mark --mark $TABLE_ID -j SNAT --to-source $INT_IP

# E. 调整内核参数（防止丢包）
sysctl -w net.ipv4.conf.$IFACE.rp_filter=2 >/dev/null
sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null

echo "✅ 路由规则已刷新！"
EOF

chmod +x /usr/local/bin/set-port-routing.sh

# --- 3. 配置 Systemd 服务 ---
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

# --- 4. 激活并验证 ---
systemctl daemon-reload
systemctl enable port-routing.service
systemctl restart port-routing.service

echo "------------------------------------------------"
echo "✨ 配置完成！"
echo "检查 ip rule:"
ip rule show | grep "fwmark"
echo "检查路由表 $TABLE_ID:"
ip route show table $TABLE_ID
echo "------------------------------------------------"
