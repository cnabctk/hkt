#!/bin/bash

# ====================================================
# Debian 13 多 IP 按端口分流策略路由 一键持久化脚本
# ====================================================

if [ "$EUID" -ne 0 ]; then 
    echo "❌ 错误: 请使用 root 权限运行此脚本 (sudo ./route_persist_setup.sh)"
    exit 1
fi

echo "===================================================="
echo "🔍 正在自动检测网络环境..."
echo "===================================================="

DEFAULT_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n 1)
DEFAULT_GW=$(ip route show default | awk '/default/ {print $3}' | head -n 1)

if [ -z "$DEFAULT_IFACE" ] || [ -z "$DEFAULT_GW" ]; then
    echo "❌ 错误: 无法自动检测到默认网卡或网关，请检查网络配置。"
    exit 1
fi

echo "✅ 默认网卡: $DEFAULT_IFACE"
echo "✅ 默认网关: $DEFAULT_GW"
echo "----------------------------------------------------"

IP_LIST=($(ip -4 addr show dev $DEFAULT_IFACE | grep -oP '(?<=inet\s)\d+(\.\d+){3}'))
echo "🌐 网卡 [$DEFAULT_IFACE] 上可用的 IP 地址有："
for i in "${!IP_LIST[@]}"; do
    echo "  [$i] ${IP_LIST[$i]}"
done
echo "----------------------------------------------------"

read -p "✍️  请输入你想作为【出口】的 IP 地址: " OUT_IP
read -p "✍️  请输入你想分流的【目标端口】: " TARGET_PORT

if ! [[ "$TARGET_PORT" =~ ^[0-9]+$ ]]; then
    echo "❌ 错误: 端口必须是纯数字！"
    exit 1
fi

echo "===================================================="
echo "⚙️ 正在应用并持久化路由和防火墙规则..."
echo "===================================================="

TABLE_ID=$((200 + TARGET_PORT % 50))
TABLE_NAME="custom_rt_$TARGET_PORT"
MARK_ID=$TARGET_PORT
SERVICE_NAME="custom-route-${TARGET_PORT}.service"
SCRIPT_PATH="/usr/local/bin/custom-route-${TARGET_PORT}.sh"

# 1. 检查并安装 iptables-persistent (Debian 系列标准持久化工具)
if ! dpkg -l | grep -q iptables-persistent; then
    echo "📦 正在安装 iptables-persistent..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y iptables-persistent netfilter-persistent
fi

# 2. 写入路由表名称
if ! grep -q "$TABLE_NAME" /etc/iproute2/rt_tables; then
    echo "$TABLE_ID $TABLE_NAME" >> /etc/iproute2/rt_tables
fi

# 3. 清理并应用当前 iptables 规则
iptables -t mangle -D OUTPUT -p tcp --dport $TARGET_PORT -j MARK --set-mark $MARK_ID 2>/dev/null
iptables -t mangle -D OUTPUT -p udp --dport $TARGET_PORT -j MARK --set-mark $MARK_ID 2>/dev/null
iptables -t nat -D POSTROUTING -m mark --mark $MARK_ID -j SNAT --to-source $OUT_IP 2>/dev/null

iptables -t mangle -A OUTPUT -p tcp --dport $TARGET_PORT -j MARK --set-mark $MARK_ID
iptables -t mangle -A OUTPUT -p udp --dport $TARGET_PORT -j MARK --set-mark $MARK_ID
iptables -t nat -A POSTROUTING -m mark --mark $MARK_ID -j SNAT --to-source $OUT_IP

# 保存 iptables 规则使其持久化
netfilter-persistent save

# 4. 创建专用的路由恢复脚本
cat > $SCRIPT_PATH << EOF
#!/bin/bash
# 清理旧的路由规则，防止重启网络服务时重复添加
ip rule del fwmark $MARK_ID table $TABLE_NAME 2>/dev/null
ip route flush table $TABLE_NAME 2>/dev/null

# 添加新的路由规则
ip route add default via $DEFAULT_GW dev $DEFAULT_IFACE src $OUT_IP table $TABLE_NAME
ip rule add fwmark $MARK_ID table $TABLE_NAME
EOF
chmod +x $SCRIPT_PATH

# 执行一次该脚本以应用当前路由
$SCRIPT_PATH

# 5. 创建 systemd 服务以在开机/网络重启时自动执行路由脚本
cat > /etc/systemd/system/$SERVICE_NAME << EOF
[Unit]
Description=Custom Policy Routing for Port $TARGET_PORT
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# 启用并启动 systemd 服务
systemctl daemon-reload
systemctl enable $SERVICE_NAME
systemctl start $SERVICE_NAME

echo "🎉 配置与持久化完成！"
echo "👉 端口 [ $TARGET_PORT ] 的流量现在通过 IP [ $OUT_IP ] 发出。"
echo "🛡️  已通过 iptables-persistent 和 systemd ($SERVICE_NAME) 实现开机自启。"
echo "===================================================="
