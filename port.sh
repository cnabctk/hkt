#!/bin/bash
# 一键脚本：使本机发出的指定端口流量走内网网关，其余流量走公网网关
# 自动检测网络配置，支持交互式端口选择

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 全局变量
INTERFACE=""
PUBLIC_GW=""
PUBLIC_IP=""
PRIVATE_GW=""
PRIVATE_IP=""
MARK_VALUE="1"
TABLE_ID="100"
TABLE_NAME="inner"
TARGET_PORTS=""
PORT_TYPE=""
SUPPORT_UDP="n"

# 自动检测网络配置函数
detect_network_config() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}自动检测网络配置${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    
    # 1. 检测网卡（排除虚拟网卡和回环接口）
    echo -e "${YELLOW}>>> 检测可用网卡...${NC}"
    INTERFACES=$(ip -o link show | grep -v lo | grep -v docker | grep -v veth | grep -v br- | awk -F': ' '{print $2}' | grep -v '@' | sed 's/@.*//')
    
    if [ -z "$INTERFACES" ]; then
        echo -e "${RED}错误：未检测到有效的网卡${NC}"
        exit 1
    fi
    
    # 如果有多个网卡，让用户选择
    INTERFACE_COUNT=$(echo "$INTERFACES" | wc -l)
    if [ $INTERFACE_COUNT -eq 1 ]; then
        INTERFACE="$INTERFACES"
        echo -e "${GREEN}✓ 检测到网卡: $INTERFACE${NC}"
    else
        echo -e "${YELLOW}检测到多个网卡：${NC}"
        echo "$INTERFACES" | nl -w2 -s') '
        echo ""
        read -p "请选择要使用的网卡 [1-$INTERFACE_COUNT]: " choice
        INTERFACE=$(echo "$INTERFACES" | sed -n "${choice}p")
        if [ -z "$INTERFACE" ]; then
            echo -e "${RED}错误：无效的选择${NC}"
            exit 1
        fi
        echo -e "${GREEN}✓ 已选择网卡: $INTERFACE${NC}"
    fi
    
    # 2. 获取该网卡上的所有IP地址
    echo -e "${YELLOW}>>> 检测IP地址...${NC}"
    IP_ADDRESSES=$(ip addr show dev $INTERFACE | grep -oP 'inet \K[\d.]+' | grep -v '^127\.')
    
    if [ -z "$IP_ADDRESSES" ]; then
        echo -e "${RED}错误：网卡 $INTERFACE 上没有检测到IP地址${NC}"
        exit 1
    fi
    
    # 显示检测到的IP地址
    echo -e "${CYAN}检测到的IP地址：${NC}"
    echo "$IP_ADDRESSES" | nl -w2 -s') '
    
    # 判断公网IP和内网IP
    echo -e "${YELLOW}>>> 识别公网IP和内网IP...${NC}"
    
    # 内网IP段
    PRIVATE_RANGES=(
        "10\."
        "172\.1[6-9]\."
        "172\.2[0-9]\."
        "172\.3[0-1]\."
        "192\.168\."
    )
    
    for ip in $IP_ADDRESSES; do
        is_private=false
        for range in "${PRIVATE_RANGES[@]}"; do
            if [[ $ip =~ ^$range ]]; then
                is_private=true
                break
            fi
        done
        
        if [ "$is_private" = true ]; then
            if [ -z "$PRIVATE_IP" ]; then
                PRIVATE_IP="$ip"
            fi
        else
            if [ -z "$PUBLIC_IP" ]; then
                PUBLIC_IP="$ip"
            fi
        fi
    done
    
    # 如果只有一个IP，询问用户是公网还是内网
    if [ -n "$PUBLIC_IP" ] && [ -z "$PRIVATE_IP" ]; then
        echo -e "${YELLOW}警告：只检测到一个IP地址 ($PUBLIC_IP)${NC}"
        read -p "这个IP是公网IP还是内网IP？[1)公网 2)内网]: " ip_type
        if [ "$ip_type" = "2" ]; then
            PRIVATE_IP="$PUBLIC_IP"
            PUBLIC_IP=""
        fi
    elif [ -z "$PUBLIC_IP" ] && [ -n "$PRIVATE_IP" ]; then
        echo -e "${YELLOW}警告：只检测到一个IP地址 ($PRIVATE_IP)${NC}"
        read -p "这个IP是公网IP还是内网IP？[1)公网 2)内网]: " ip_type
        if [ "$ip_type" = "1" ]; then
            PUBLIC_IP="$PRIVATE_IP"
            PRIVATE_IP=""
        fi
    fi
    
    # 如果没有检测到公网IP或内网IP，让用户手动输入
    if [ -z "$PUBLIC_IP" ]; then
        echo -e "${YELLOW}未检测到公网IP${NC}"
        read -p "请输入公网IP地址: " PUBLIC_IP
        if [ -z "$PUBLIC_IP" ]; then
            echo -e "${RED}错误：公网IP不能为空${NC}"
            exit 1
        fi
    fi
    
    if [ -z "$PRIVATE_IP" ]; then
        echo -e "${YELLOW}未检测到内网IP${NC}"
        read -p "请输入内网IP地址: " PRIVATE_IP
        if [ -z "$PRIVATE_IP" ]; then
            echo -e "${RED}错误：内网IP不能为空${NC}"
            exit 1
        fi
    fi
    
    echo -e "${GREEN}✓ 公网IP: $PUBLIC_IP${NC}"
    echo -e "${GREEN}✓ 内网IP: $PRIVATE_IP${NC}"
    
    # 3. 检测网关
    echo -e "${YELLOW}>>> 检测网关...${NC}"
    
    # 获取默认网关
    DEFAULT_GW=$(ip route show default | grep -v 'table' | grep -oP 'via \K[\d.]+' | head -1)
    
    if [ -n "$DEFAULT_GW" ]; then
        echo -e "${CYAN}检测到默认网关: $DEFAULT_GW${NC}"
        
        # 判断默认网关是公网还是内网
        is_private_gw=false
        for range in "${PRIVATE_RANGES[@]}"; do
            if [[ $DEFAULT_GW =~ ^$range ]]; then
                is_private_gw=true
                break
            fi
        done
        
        if [ "$is_private_gw" = true ]; then
            echo -e "${YELLOW}默认网关为内网网关${NC}"
            read -p "是否将 $DEFAULT_GW 作为内网网关？[y/N]: " use_as_private
            if [[ "$use_as_private" =~ ^[Yy]$ ]]; then
                PRIVATE_GW="$DEFAULT_GW"
                read -p "请输入公网网关地址: " PUBLIC_GW
            else
                read -p "请输入内网网关地址: " PRIVATE_GW
                read -p "请输入公网网关地址: " PUBLIC_GW
            fi
        else
            echo -e "${YELLOW}默认网关为公网网关${NC}"
            read -p "是否将 $DEFAULT_GW 作为公网网关？[Y/n]: " use_as_public
            if [[ "$use_as_public" =~ ^[Nn]$ ]]; then
                read -p "请输入公网网关地址: " PUBLIC_GW
            else
                PUBLIC_GW="$DEFAULT_GW"
            fi
            read -p "请输入内网网关地址: " PRIVATE_GW
        fi
    else
        echo -e "${YELLOW}未检测到默认网关${NC}"
        read -p "请输入公网网关地址: " PUBLIC_GW
        read -p "请输入内网网关地址: " PRIVATE_GW
    fi
    
    # 验证网关格式
    if [[ ! "$PUBLIC_GW" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "$PRIVATE_GW" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${RED}错误：网关地址格式不正确${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ 公网网关: $PUBLIC_GW${NC}"
    echo -e "${GREEN}✓ 内网网关: $PRIVATE_GW${NC}"
    
    echo ""
}

# 交互式端口选择函数
select_port() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}端口分流配置向导${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo -e "${YELLOW}请选择要配置的端口：${NC}"
    echo "1) 输入单个端口（例如：11111）"
    echo "2) 输入多个端口（逗号分隔，例如：11111,22222,33333）"
    echo "3) 输入端口范围（例如：10000-20000）"
    echo "4) 取消配置"
    echo ""
    read -p "请选择 [1-4]: " choice

    case $choice in
        1)
            read -p "请输入要分流的端口号 (1-65535): " port
            if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
                TARGET_PORTS="$port"
                PORT_TYPE="single"
                echo -e "${GREEN}✓ 已选择端口: $port${NC}"
            else
                echo -e "${RED}错误：无效的端口号${NC}"
                exit 1
            fi
            ;;
        2)
            read -p "请输入要分流的端口号（用逗号分隔，如：11111,22222,33333）: " ports
            # 验证端口格式
            if [[ "$ports" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
                TARGET_PORTS="$ports"
                PORT_TYPE="multi"
                echo -e "${GREEN}✓ 已选择端口: $ports${NC}"
            else
                echo -e "${RED}错误：无效的端口格式${NC}"
                exit 1
            fi
            ;;
        3)
            read -p "请输入端口范围（格式：起始端口-结束端口，如：10000-20000）: " port_range
            if [[ "$port_range" =~ ^[0-9]+-[0-9]+$ ]]; then
                TARGET_PORTS="$port_range"
                PORT_TYPE="range"
                echo -e "${GREEN}✓ 已选择端口范围: $port_range${NC}"
            else
                echo -e "${RED}错误：无效的端口范围格式${NC}"
                exit 1
            fi
            ;;
        4)
            echo -e "${YELLOW}已取消配置${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}错误：无效的选择${NC}"
            exit 1
            ;;
    esac
    
    # 询问是否需要UDP支持
    read -p "是否需要同时支持UDP协议？[y/N]: " SUPPORT_UDP
    if [[ "$SUPPORT_UDP" =~ ^[Yy]$ ]]; then
        SUPPORT_UDP="y"
    else
        SUPPORT_UDP="n"
    fi
    
    echo ""
    echo -e "${YELLOW}确认配置：${NC}"
    echo -e "  端口: ${GREEN}$TARGET_PORTS${NC}"
    echo -e "  协议: ${GREEN}TCP${SUPPORT_UDP:+, UDP}${NC}"
    echo -e "  将走内网网关: ${GREEN}$PRIVATE_GW${NC} (源IP: $PRIVATE_IP)"
    echo -e "  其他端口走公网网关: ${GREEN}$PUBLIC_GW${NC} (源IP: $PUBLIC_IP)"
    echo ""
    read -p "是否继续配置？[y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}已取消配置${NC}"
        exit 0
    fi
}

# 清理现有配置函数
cleanup_existing_config() {
    echo -e "${YELLOW}>>> 清理现有配置...${NC}"
    
    # 清理 iptables 规则
    if [ -n "$TARGET_PORTS" ]; then
        # 清理 TCP 规则
        if [ "$PORT_TYPE" = "single" ]; then
            iptables -t mangle -D OUTPUT -p tcp --dport $TARGET_PORTS -j MARK --set-mark $MARK_VALUE 2>/dev/null || true
            iptables -t mangle -D OUTPUT -p tcp --dport $TARGET_PORTS -j CONNMARK --save-mark 2>/dev/null || true
            if [ "$SUPPORT_UDP" = "y" ]; then
                iptables -t mangle -D OUTPUT -p udp --dport $TARGET_PORTS -j MARK --set-mark $MARK_VALUE 2>/dev/null || true
                iptables -t mangle -D OUTPUT -p udp --dport $TARGET_PORTS -j CONNMARK --save-mark 2>/dev/null || true
            fi
        elif [ "$PORT_TYPE" = "multi" ]; then
            IFS=',' read -ra PORT_ARRAY <<< "$TARGET_PORTS"
            for port in "${PORT_ARRAY[@]}"; do
                iptables -t mangle -D OUTPUT -p tcp --dport $port -j MARK --set-mark $MARK_VALUE 2>/dev/null || true
                iptables -t mangle -D OUTPUT -p tcp --dport $port -j CONNMARK --save-mark 2>/dev/null || true
                if [ "$SUPPORT_UDP" = "y" ]; then
                    iptables -t mangle -D OUTPUT -p udp --dport $port -j MARK --set-mark $MARK_VALUE 2>/dev/null || true
                    iptables -t mangle -D OUTPUT -p udp --dport $port -j CONNMARK --save-mark 2>/dev/null || true
                fi
            done
        elif [ "$PORT_TYPE" = "range" ]; then
            iptables -t mangle -D OUTPUT -p tcp -m multiport --dports $TARGET_PORTS -j MARK --set-mark $MARK_VALUE 2>/dev/null || true
            iptables -t mangle -D OUTPUT -p tcp -m multiport --dports $TARGET_PORTS -j CONNMARK --save-mark 2>/dev/null || true
            if [ "$SUPPORT_UDP" = "y" ]; then
                iptables -t mangle -D OUTPUT -p udp -m multiport --dports $TARGET_PORTS -j MARK --set-mark $MARK_VALUE 2>/dev/null || true
                iptables -t mangle -D OUTPUT -p udp -m multiport --dports $TARGET_PORTS -j CONNMARK --save-mark 2>/dev/null || true
            fi
        fi
    fi
    
    # 清理连接标记恢复规则
    iptables -t mangle -D PREROUTING -i $INTERFACE -m connmark --mark $MARK_VALUE -j CONNMARK --restore-mark 2>/dev/null || true
    
    # 清理策略路由规则
    ip rule del fwmark $MARK_VALUE table $TABLE_NAME 2>/dev/null || true
    
    # 清理自定义路由表中的路由
    ip route flush table $TABLE_NAME 2>/dev/null || true
    
    echo -e "${GREEN}✓ 清理完成${NC}"
}

# 生成 iptables 规则函数
generate_iptables_rules() {
    local port_config="$1"
    local port_type="$2"
    local mark_value="$3"
    local support_udp="$4"
    
    local rules=""
    
    case $port_type in
        single)
            rules="iptables -t mangle -A OUTPUT -p tcp --dport $port_config -j MARK --set-mark $mark_value
iptables -t mangle -A OUTPUT -p tcp --dport $port_config -j CONNMARK --save-mark"
            if [ "$support_udp" = "y" ]; then
                rules="$rules
iptables -t mangle -A OUTPUT -p udp --dport $port_config -j MARK --set-mark $mark_value
iptables -t mangle -A OUTPUT -p udp --dport $port_config -j CONNMARK --save-mark"
            fi
            ;;
        multi)
            IFS=',' read -ra PORT_ARRAY <<< "$port_config"
            for port in "${PORT_ARRAY[@]}"; do
                rules="$rules
iptables -t mangle -A OUTPUT -p tcp --dport $port -j MARK --set-mark $mark_value
iptables -t mangle -A OUTPUT -p tcp --dport $port -j CONNMARK --save-mark"
            done
            if [ "$support_udp" = "y" ]; then
                for port in "${PORT_ARRAY[@]}"; do
                    rules="$rules
iptables -t mangle -A OUTPUT -p udp --dport $port -j MARK --set-mark $mark_value
iptables -t mangle -A OUTPUT -p udp --dport $port -j CONNMARK --save-mark"
                done
            fi
            ;;
        range)
            rules="iptables -t mangle -A OUTPUT -p tcp -m multiport --dports $port_config -j MARK --set-mark $mark_value
iptables -t mangle -A OUTPUT -p tcp -m multiport --dports $port_config -j CONNMARK --save-mark"
            if [ "$support_udp" = "y" ]; then
                rules="$rules
iptables -t mangle -A OUTPUT -p udp -m multiport --dports $port_config -j MARK --set-mark $mark_value
iptables -t mangle -A OUTPUT -p udp -m multiport --dports $port_config -j CONNMARK --save-mark"
            fi
            ;;
    esac
    
    echo "$rules"
}

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误：请使用 root 权限运行此脚本${NC}"
    exit 1
fi

# 自动检测网络配置
detect_network_config

# 交互式端口选择
select_port

# 清理现有配置
cleanup_existing_config

# 开始配置
echo ""
echo -e "${GREEN}>>> 开始配置端口分流...${NC}"
echo ""

# 1. 设置 sysctl：关闭反向路径过滤
echo ">>> 配置 sysctl..."
sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.$INTERFACE.rp_filter=2 >/dev/null 2>&1 || true

# 持久化 sysctl 配置
if ! grep -q "net.ipv4.conf.all.rp_filter" /etc/sysctl.conf 2>/dev/null; then
    echo "net.ipv4.conf.all.rp_filter = 2" >> /etc/sysctl.conf
fi
if ! grep -q "net.ipv4.conf.$INTERFACE.rp_filter" /etc/sysctl.conf 2>/dev/null; then
    echo "net.ipv4.conf.$INTERFACE.rp_filter = 2" >> /etc/sysctl.conf
fi

# 2. 确保 rt_tables 文件存在
echo ">>> 创建自定义路由表..."
if [ -f /etc/iproute2/rt_tables ]; then
    RT_TABLES="/etc/iproute2/rt_tables"
elif [ -f /usr/lib/iproute2/rt_tables ]; then
    RT_TABLES="/usr/lib/iproute2/rt_tables"
else
    mkdir -p /etc/iproute2
    RT_TABLES="/etc/iproute2/rt_tables"
    cat > $RT_TABLES <<EOF
#
# reserved values
#
255     local
254     main
253     default
0       unspec
#
# local
#
#1      inr.ruhep
EOF
fi

# 添加自定义路由表
if ! grep -q "^$TABLE_ID $TABLE_NAME" $RT_TABLES 2>/dev/null; then
    echo "$TABLE_ID $TABLE_NAME" >> $RT_TABLES
    echo ">>> 已在 $RT_TABLES 中添加路由表定义"
fi

# 3. 设置主路由表（先删除可能存在的默认路由）
echo ">>> 设置主路由表公网默认路由..."
# 删除所有默认路由
ip route del default 2>/dev/null || true
# 删除指定接口的默认路由
ip route del default dev $INTERFACE 2>/dev/null || true
# 添加新的默认路由
ip route add default via $PUBLIC_GW dev $INTERFACE src $PUBLIC_IP

# 4. 创建内网路由表
echo ">>> 配置内网路由表..."
# 先删除表100中的默认路由
ip route del default via $PRIVATE_GW dev $INTERFACE table $TABLE_NAME 2>/dev/null || true
# 添加新的内网路由
ip route add default via $PRIVATE_GW dev $INTERFACE src $PRIVATE_IP table $TABLE_NAME

# 5. 配置 iptables 标记
echo ">>> 配置 iptables 标记..."
# 生成并应用 iptables 规则
IPTABLES_RULES=$(generate_iptables_rules "$TARGET_PORTS" "$PORT_TYPE" "$MARK_VALUE" "$SUPPORT_UDP")
eval "$IPTABLES_RULES"

# 添加连接标记恢复规则
iptables -t mangle -A PREROUTING -i $INTERFACE -m connmark --mark $MARK_VALUE -j CONNMARK --restore-mark

# 6. 添加策略路由规则
echo ">>> 添加策略路由规则..."
# 删除可能已存在的相同规则
ip rule del fwmark $MARK_VALUE table $TABLE_NAME 2>/dev/null || true
# 添加新规则
ip rule add fwmark $MARK_VALUE table $TABLE_NAME

# 7. 持久化配置
echo ">>> 创建 systemd 服务..."
PORT_FILENAME=$(echo "$TARGET_PORTS" | tr ',' '_' | tr '-' '_')
SERVICE_FILE="/etc/systemd/system/route-port-${PORT_FILENAME}.service"
SCRIPT_FILE="/usr/local/bin/route-port-${PORT_FILENAME}.sh"

# 生成应用规则的脚本
cat > $SCRIPT_FILE <<EOF
#!/bin/bash
# 自动应用端口分流规则（由一键脚本生成）
# 生成时间: $(date)

INTERFACE="$INTERFACE"
PUBLIC_GW="$PUBLIC_GW"
PUBLIC_IP="$PUBLIC_IP"
PRIVATE_GW="$PRIVATE_GW"
PRIVATE_IP="$PRIVATE_IP"
TARGET_PORTS="$TARGET_PORTS"
PORT_TYPE="$PORT_TYPE"
MARK_VALUE="$MARK_VALUE"
TABLE_ID="$TABLE_ID"
TABLE_NAME="$TABLE_NAME"
SUPPORT_UDP="$SUPPORT_UDP"

# 等待网络就绪
sleep 2

# 设置 sysctl
sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.\$INTERFACE.rp_filter=2 >/dev/null 2>&1 || true

# 设置主路由表
ip route del default 2>/dev/null || true
ip route del default dev \$INTERFACE 2>/dev/null || true
ip route add default via \$PUBLIC_GW dev \$INTERFACE src \$PUBLIC_IP

# 设置内网路由表
ip route del default via \$PRIVATE_GW dev \$INTERFACE table \$TABLE_NAME 2>/dev/null || true
ip route add default via \$PRIVATE_GW dev \$INTERFACE src \$PRIVATE_IP table \$TABLE_NAME

# 清除旧规则
iptables -t mangle -D PREROUTING -i \$INTERFACE -m connmark --mark \$MARK_VALUE -j CONNMARK --restore-mark 2>/dev/null || true

# 根据端口类型清理规则
if [ "$PORT_TYPE" = "single" ]; then
    iptables -t mangle -D OUTPUT -p tcp --dport \$TARGET_PORTS -j MARK --set-mark \$MARK_VALUE 2>/dev/null || true
    iptables -t mangle -D OUTPUT -p tcp --dport \$TARGET_PORTS -j CONNMARK --save-mark 2>/dev/null || true
    if [ "\$SUPPORT_UDP" = "y" ]; then
        iptables -t mangle -D OUTPUT -p udp --dport \$TARGET_PORTS -j MARK --set-mark \$MARK_VALUE 2>/dev/null || true
        iptables -t mangle -D OUTPUT -p udp --dport \$TARGET_PORTS -j CONNMARK --save-mark 2>/dev/null || true
    fi
elif [ "$PORT_TYPE" = "multi" ]; then
    IFS=',' read -ra PORTS <<< "\$TARGET_PORTS"
    for port in "\${PORTS[@]}"; do
        iptables -t mangle -D OUTPUT -p tcp --dport \$port -j MARK --set-mark \$MARK_VALUE 2>/dev/null || true
        iptables -t mangle -D OUTPUT -p tcp --dport \$port -j CONNMARK --save-mark 2>/dev/null || true
        if [ "\$SUPPORT_UDP" = "y" ]; then
            iptables -t mangle -D OUTPUT -p udp --dport \$port -j MARK --set-mark \$MARK_VALUE 2>/dev/null || true
            iptables -t mangle -D OUTPUT -p udp --dport \$port -j CONNMARK --save-mark 2>/dev/null || true
        fi
    done
elif [ "$PORT_TYPE" = "range" ]; then
    iptables -t mangle -D OUTPUT -p tcp -m multiport --dports \$TARGET_PORTS -j MARK --set-mark \$MARK_VALUE 2>/dev/null || true
    iptables -t mangle -D OUTPUT -p tcp -m multiport --dports \$TARGET_PORTS -j CONNMARK --save-mark 2>/dev/null || true
    if [ "\$SUPPORT_UDP" = "y" ]; then
        iptables -t mangle -D OUTPUT -p udp -m multiport --dports \$TARGET_PORTS -j MARK --set-mark \$MARK_VALUE 2>/dev/null || true
        iptables -t mangle -D OUTPUT -p udp -m multiport --dports \$TARGET_PORTS -j CONNMARK --save-mark 2>/dev/null || true
    fi
fi

# 添加新规则
$(generate_iptables_rules "$TARGET_PORTS" "$PORT_TYPE" "$MARK_VALUE" "$SUPPORT_UDP")

# 添加连接标记恢复规则
iptables -t mangle -A PREROUTING -i \$INTERFACE -m connmark --mark \$MARK_VALUE -j CONNMARK --restore-mark

# 添加策略路由规则
ip rule del fwmark \$MARK_VALUE table \$TABLE_NAME 2>/dev/null || true
ip rule add fwmark \$MARK_VALUE table \$TABLE_NAME

exit 0
EOF

chmod +x $SCRIPT_FILE

# 创建 systemd 服务单元
cat > $SERVICE_FILE <<EOF
[Unit]
Description=Route Port $TARGET_PORTS via Private Gateway
After=network.target network-online.target
Wants=network.target
Before=multi-user.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_FILE
RemainAfterExit=yes
StandardOutput=journal

[Install]
WantedBy=multi-user.target
EOF

# 启用并启动服务
systemctl daemon-reload
systemctl enable route-port-${PORT_FILENAME}.service
systemctl start route-port-${PORT_FILENAME}.service

# 显示配置结果
echo ""
echo "=========================================="
echo -e "${GREEN}>>> 配置完成！${NC}"
echo "=========================================="
echo ""
echo -e "${CYAN}配置摘要：${NC}"
echo -e "  网卡: ${GREEN}$INTERFACE${NC}"
echo -e "  公网IP: ${GREEN}$PUBLIC_IP${NC} | 网关: ${GREEN}$PUBLIC_GW${NC}"
echo -e "  内网IP: ${GREEN}$PRIVATE_IP${NC} | 网关: ${GREEN}$PRIVATE_GW${NC}"
echo -e "  分流端口: ${GREEN}$TARGET_PORTS${NC} (协议: TCP${SUPPORT_UDP:+, UDP})"
echo ""
echo -e "${YELLOW}当前路由规则：${NC}"
echo "--- 主路由表 ---"
ip route show table main
echo ""
echo "--- 内网路由表 (table $TABLE_NAME) ---"
ip route show table $TABLE_NAME 2>/dev/null || echo "路由表为空"
echo ""
echo "--- 策略路由规则 ---"
ip rule show
echo ""
echo "--- iptables mangle 规则 ---"
iptables -t mangle -L -n -v | grep -E "($(echo $TARGET_PORTS | tr ',' '|' | tr '-' '|'))|CONNMARK" | head -10
echo ""
echo -e "${YELLOW}验证命令：${NC}"
echo "1. 测试内网端口分流："
echo "   curl --interface $PRIVATE_IP -v http://目标IP:$TARGET_PORTS"
echo "   tcpdump -i $INTERFACE -n host $PRIVATE_GW and port $TARGET_PORTS"
echo ""
echo "2. 测试公网端口："
echo "   curl --interface $PUBLIC_IP -v http://目标IP:80"
echo "   tcpdump -i $INTERFACE -n host $PUBLIC_GW and not port $TARGET_PORTS"
echo ""
echo -e "${GREEN}✓ 配置已持久化，重启后自动生效${NC}"
echo ""
echo -e "${YELLOW}回滚命令：${NC}"
echo "   systemctl disable route-port-${PORT_FILENAME}.service"
echo "   systemctl stop route-port-${PORT_FILENAME}.service"
echo "   rm $SERVICE_FILE $SCRIPT_FILE"
echo "   systemctl daemon-reload"
echo "   iptables -t mangle -D PREROUTING -i $INTERFACE -m connmark --mark $MARK_VALUE -j CONNMARK --restore-mark"
echo "   ip rule del fwmark $MARK_VALUE table $TABLE_NAME"
