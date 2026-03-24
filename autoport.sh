#!/bin/bash

# ====================================================
# Debian 13 多 IP 按端口分流策略路由 一键持久化脚本 (终极修复版)
# 针对云服务器环境进行了底层兼容性优化
# ====================================================

if [ "$EUID" -ne 0 ]; then 
    echo "❌ 错误: 请使用 root 权限运行此脚本 (sudo ./route_persist_setup.sh)"
    exit 1
fi

echo "===================================================="
echo "🔍 正在自动检测网络环境..."
echo "===================================================="

# 自动获取默认网卡和网关
DEFAULT_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n 1)
DEFAULT_GW=$(ip route show default | awk '/default/ {print $3}' | head -n 1)

if [ -z "$DEFAULT_IFACE" ] || [ -z "$DEFAULT_GW" ]; then
    echo "❌ 错误: 无法自动检测到默认网卡或网关，请检查网络配置。"
    exit 1
fi

echo "✅ 默认网卡: $DEFAULT_IFACE"
echo "✅ 默认网关: $DEFAULT_GW"
echo "----------------------------------------------------"

# 自动获取当前绑定的所有 IP
IP_LIST=($(ip -4 addr show dev $DEFAULT_IFACE | grep -oP '(?<=inet\s)\d+(\.\d+){3}'))
echo "🌐 网卡 [$DEFAULT_IFACE] 上可用的 IP 地址有："
for i in "${!IP_LIST[@]}"; do
    echo "  [$i] ${IP_LIST[$i]}"
done
echo "----------------------------------------------------"

read -p "✍️  请输入你想作为【出口】的 IP 地址: " OUT_IP
read -p "✍️  请输入你想分流的【目标端口】(如 199): " TARGET_PORT

if ! [[ "$TARGET_PORT" =~ ^[0-9]+$ ]]; then
    echo "❌ 错误: 端口必须是纯数字！"
    exit 1
fi

echo "===================================================="
echo "⚙️ 正在应用并持久化路由和防火墙规则..."
echo "===================================================="

# 核心变量设定（直接使用纯数字 ID）
TABLE_ID=$((200 + TARGET_PORT % 50)) 
MARK_ID=$TARGET_PORT
SERVICE_NAME="custom-route-${TARGET_PORT}.service"
SCRIPT_PATH="/usr/local/bin/custom-route-${TARGET_PORT}.sh"

# 1. 检查并安装 iptables-persistent
if ! dpkg -l | grep -q iptables-persistent; then
    echo "📦 正在安装 iptables-persistent..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y iptables-persistent netfilter-persistent
fi

# 2. 清理并应用当前 iptables 规则 (SNAT 解决源 IP 伪装)
iptables -t mangle -D OUTPUT -p tcp --dport $TARGET_PORT -j MARK --set-mark $MARK_ID 2>/dev/null
iptables -t mangle -D OUTPUT -p udp --dport $TARGET_PORT -j MARK --set-mark $MARK_ID 2>/dev/null
iptables -t nat -D POSTROUTING -m mark --mark $MARK_ID -j SNAT --to-source $OUT_IP 2>/dev/null

iptables -t mangle -A OUTPUT -p tcp --dport $TARGET_PORT -j MARK --set-mark $MARK_ID
iptables -t mangle -A OUTPUT -p udp --dport $TARGET_PORT -j MARK --set-mark $MARK_ID
iptables -t nat -A POSTROUTING -m mark --mark $MARK_ID -j SNAT --to-source $OUT_IP

# 保存 iptables 规则使其持久化
netfilter-persistent save >/dev/null 2>&1

# 3. 创建专用的路由恢复脚本 (去除名称映射和 src 参数)
cat > $SCRIPT_PATH << EOF
#!/bin/bash
# 注入环境变量，防止 systemd 找不到 ip 命令
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 清理旧的路由规则 (使用纯数字 TABLE_ID: $TABLE_ID)
ip rule del fwmark $MARK_ID table $TABLE_ID 2>/dev/null || true
ip route flush table $TABLE_ID 2>/dev/null || true

# 添加新的路由规则 (已去除 src 参数，避开云厂商网关校验限制)
ip route add default via $DEFAULT_GW dev $DEFAULT_IFACE table $TABLE_ID
ip rule add fwmark $MARK_ID table $TABLE_ID
EOF
chmod +x $SCRIPT_PATH

# 4. 创建 systemd 服务
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

# 5. 启用并启动系统服务
systemctl daemon-reload
systemctl enable $SERVICE_NAME >/dev/null 2>&1
systemctl restart $SERVICE_NAME

# 检查服务最终状态
if systemctl is-active --quiet $SERVICE_NAME; then
    echo "🎉 配置与持久化成功！"
    echo "👉 端口 [ $TARGET_PORT ] 的流量现在通过 IP [ $OUT_IP ] 发出。"
    echo "🛡️  已通过 systemd ($SERVICE_NAME) 实现开机自启。"
else
    echo "⚠️ 警告: 服务虽然创建，但启动状态异常。请运行以下命令查看详细信息："
    echo "systemctl status $SERVICE_NAME"
fi
echo "===================================================="
