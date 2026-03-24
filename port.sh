#!/bin/bash

# 检查 Root 权限
if [ "$EUID" -ne 0 ]; then 
  echo "❌ 请使用 root 权限运行 (sudo ./script.sh)"
  exit 1
fi

# --- 自动检测参数 ---
IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
INT_IP="172.16.15.12"
INT_GW="172.16.15.1"
TARGET_PORT="11111"
TABLE_ID="11"  # 使用数字 ID，避开命名报错

echo "🛠️ 正在配置 Debian 13 端口分流..."
echo "网卡: $IFACE, 内网IP: $INT_IP, 端口: $TARGET_PORT"

# --- 1. 创建执行脚本 ---
cat <<EOF > /usr/local/bin/set-port-routing.sh
#!/bin/bash
# 强力清理旧规则
ip rule del fwmark $TABLE_ID table $TABLE_ID 2>/dev/null
ip route flush table $TABLE_ID 2>/dev/null

# A. 核心路由配置 (直接使用数字 ID $TABLE_ID)
ip route add default via $INT_GW dev $IFACE src $INT_IP table $TABLE_ID
ip rule add fwmark $TABLE_ID table $TABLE_ID

# B. 防火墙打标签 (Mangle 表)
# 清理旧规则防止堆叠
iptables -t mangle -D OUTPUT -p tcp --dport $TARGET_PORT -j MARK --set-mark $TABLE_ID 2>/dev/null
iptables -t mangle -D OUTPUT -p udp --dport $TARGET_PORT -j MARK --set-mark $TABLE_ID 2>/dev/null
iptables -t nat -D POSTROUTING -m mark --mark $TABLE_ID -j SNAT --to-source $INT_IP 2>/dev/null

# 注入新规则
iptables -t mangle -A OUTPUT -p tcp --dport $TARGET_PORT -j MARK --set-mark $TABLE_ID
iptables -t mangle -A OUTPUT -p udp --dport $TARGET_PORT -j MARK --set-mark $TABLE_ID
iptables -t nat -A POSTROUTING -m mark --mark $TABLE_ID -j SNAT --to-source $INT_IP

# C. 内核参数放宽 (解决同网卡双网关丢包)
sysctl -w net.ipv4.conf.$IFACE.rp_filter=2 >/dev/null
sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
EOF

chmod +x /usr/local/bin/set-port-routing.sh

# --- 2. 创建 Systemd 服务 (确保开机自启) ---
cat <<EOF > /etc/systemd/system/port-routing.service
[Unit]
Description=Port $TARGET_PORT Intranet Routing Service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/set-port-routing.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# --- 3. 激活服务 ---
systemctl daemon-reload
systemctl enable port-routing.service
systemctl restart port-routing.service

# --- 4. 最终验证 ---
echo "------------------------------------------------"
echo "🔎 正在验证配置结果..."
sleep 1
RULE_CHECK=$(ip rule show | grep "fwmark 0xb")

if [ -n "$RULE_CHECK" ]; then
    echo "✅ 成功！已发现策略路由: $RULE_CHECK"
    echo "✅ 路由表 $TABLE_ID 内容:"
    ip route show table $TABLE_ID
else
    echo "❌ 失败！ip rule 中未发现 fwmark 规则。请检查系统是否禁止修改路由。"
fi
echo "------------------------------------------------"
