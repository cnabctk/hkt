#!/bin/bash
# 一键脚本：使本机发出的 11111 端口流量走内网网关，其余流量走公网网关
# 适用场景：单网卡（eth0）同时拥有公网 IP 和内网 IP，需根据目标端口分流

set -e

# ====== 配置参数（请根据实际情况修改） ======
INTERFACE="eth0"                     # 网卡名称
PUBLIC_GW="199.15.78.1"              # 公网网关
PUBLIC_IP="199.15.78.13"             # 公网 IP
PRIVATE_GW="172.16.15.1"             # 内网网关
PRIVATE_IP="172.16.15.12"            # 内网 IP
TARGET_PORT="11111"                  # 需要走内网的端口
MARK_VALUE="1"                       # 标记值（可自定义）
TABLE_ID="100"                       # 自定义路由表 ID
TABLE_NAME="inner"                   # 自定义路由表名称
# =========================================

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
    echo "请使用 root 权限运行此脚本"
    exit 1
fi

echo ">>> 开始配置..."

# 1. 设置 sysctl：关闭反向路径过滤（允许非对称路由）
echo ">>> 配置 sysctl..."
sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
sysctl -w net.ipv4.conf.$INTERFACE.rp_filter=2 >/dev/null
# 持久化
if ! grep -q "net.ipv4.conf.all.rp_filter" /etc/sysctl.conf; then
    echo "net.ipv4.conf.all.rp_filter = 2" >> /etc/sysctl.conf
fi
if ! grep -q "net.ipv4.conf.$INTERFACE.rp_filter" /etc/sysctl.conf; then
    echo "net.ipv4.conf.$INTERFACE.rp_filter = 2" >> /etc/sysctl.conf
fi

# 2. 设置主路由表（公网）的默认网关，并指定源 IP
echo ">>> 设置主路由表公网默认路由..."
ip route replace default via $PUBLIC_GW dev $INTERFACE src $PUBLIC_IP

# 3. 创建自定义路由表（内网）
echo ">>> 创建自定义路由表..."
# 在 rt_tables 中添加表名（如果尚未添加）
if ! grep -q "^$TABLE_ID $TABLE_NAME" /etc/iproute2/rt_tables; then
    echo "$TABLE_ID $TABLE_NAME" >> /etc/iproute2/rt_tables
fi
# 添加内网默认路由，指定源 IP 为内网 IP
ip route add default via $PRIVATE_GW dev $INTERFACE src $PRIVATE_IP table $TABLE_NAME || true

# 4. 配置 iptables 标记
echo ">>> 配置 iptables 标记..."
# 清除可能已存在的相关规则（避免重复）
iptables -t mangle -D OUTPUT -p tcp --dport $TARGET_PORT -j MARK --set-mark $MARK_VALUE 2>/dev/null || true
iptables -t mangle -D OUTPUT -p tcp --dport $TARGET_PORT -j CONNMARK --save-mark 2>/dev/null || true
# 添加新规则
iptables -t mangle -A OUTPUT -p tcp --dport $TARGET_PORT -j MARK --set-mark $MARK_VALUE
iptables -t mangle -A OUTPUT -p tcp --dport $TARGET_PORT -j CONNMARK --save-mark
# 可选：为响应包恢复标记（确保连接对称）
iptables -t mangle -D PREROUTING -i $INTERFACE -m connmark --mark $MARK_VALUE -j CONNMARK --restore-mark 2>/dev/null || true
iptables -t mangle -A PREROUTING -i $INTERFACE -m connmark --mark $MARK_VALUE -j CONNMARK --restore-mark

# 5. 添加策略路由规则
echo ">>> 添加策略路由规则..."
# 删除可能已存在的相同规则
ip rule del fwmark $MARK_VALUE table $TABLE_NAME 2>/dev/null || true
# 添加新规则
ip rule add fwmark $MARK_VALUE table $TABLE_NAME

# 6. 持久化配置：创建 systemd 服务，确保重启后自动生效
echo ">>> 创建 systemd 服务以实现持久化..."
SERVICE_FILE="/etc/systemd/system/route-port${TARGET_PORT}.service"
SCRIPT_FILE="/usr/local/bin/route-port${TARGET_PORT}.sh"

# 生成应用规则的脚本
cat > $SCRIPT_FILE <<EOF
#!/bin/bash
# 自动应用端口分流规则（由一键脚本生成）
INTERFACE="$INTERFACE"
PUBLIC_GW="$PUBLIC_GW"
PUBLIC_IP="$PUBLIC_IP"
PRIVATE_GW="$PRIVATE_GW"
PRIVATE_IP="$PRIVATE_IP"
TARGET_PORT="$TARGET_PORT"
MARK_VALUE="$MARK_VALUE"
TABLE_NAME="$TABLE_NAME"

# 设置 sysctl（确保反向路径过滤宽松）
sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
sysctl -w net.ipv4.conf.\$INTERFACE.rp_filter=2 >/dev/null

# 设置主路由表公网默认路由
ip route replace default via \$PUBLIC_GW dev \$INTERFACE src \$PUBLIC_IP

# 设置内网路由表（表可能已存在，添加路由）
ip route add default via \$PRIVATE_GW dev \$INTERFACE src \$PRIVATE_IP table \$TABLE_NAME 2>/dev/null || true

# 添加 iptables 标记
iptables -t mangle -A OUTPUT -p tcp --dport \$TARGET_PORT -j MARK --set-mark \$MARK_VALUE
iptables -t mangle -A OUTPUT -p tcp --dport \$TARGET_PORT -j CONNMARK --save-mark
iptables -t mangle -A PREROUTING -i \$INTERFACE -m connmark --mark \$MARK_VALUE -j CONNMARK --restore-mark

# 添加策略路由规则
ip rule add fwmark \$MARK_VALUE table \$TABLE_NAME 2>/dev/null || true

exit 0
EOF

chmod +x $SCRIPT_FILE

# 创建 systemd 服务单元
cat > $SERVICE_FILE <<EOF
[Unit]
Description=Route Port $TARGET_PORT via Private Gateway
After=network.target
Wants=network.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_FILE
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# 启用并启动服务
systemctl daemon-reload
systemctl enable route-port${TARGET_PORT}.service
systemctl start route-port${TARGET_PORT}.service

echo ">>> 配置完成！"
echo "当前路由规则如下："
ip route show table main
ip route show table $TABLE_NAME
ip rule show
echo
echo "验证方法："
echo "1. 从本机访问目标端口 $TARGET_PORT 的服务，抓包确认源 IP 为 $PRIVATE_IP："
echo "   tcpdump -i $INTERFACE -n host $PRIVATE_GW and port $TARGET_PORT"
echo "2. 访问其他端口，抓包应看到源 IP 为 $PUBLIC_IP"
echo
echo "重启后配置将自动生效。如需回滚，可执行以下命令："
echo "   systemctl disable route-port${TARGET_PORT}.service && rm $SERVICE_FILE $SCRIPT_FILE"
echo "   iptables -t mangle -D OUTPUT -p tcp --dport $TARGET_PORT -j MARK --set-mark $MARK_VALUE"
echo "   iptables -t mangle -D OUTPUT -p tcp --dport $TARGET_PORT -j CONNMARK --save-mark"
echo "   iptables -t mangle -D PREROUTING -i $INTERFACE -m connmark --mark $MARK_VALUE -j CONNMARK --restore-mark"
echo "   ip rule del fwmark $MARK_VALUE table $TABLE_NAME"
echo "   ip route del default via $PUBLIC_GW dev $INTERFACE"
echo "   ip route del default via $PRIVATE_GW dev $INTERFACE table $TABLE_NAME"
