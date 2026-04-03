#!/bin/bash

# ==========================================
# 经典终端配色定义
# ==========================================
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

# 核心缓存路径
CACHE_FILE="/usr/local/etc/xray/.xray_info"
SCRIPT_PATH="/usr/local/bin/xmgr"

# 检查是否为 Root 用户
[[ $EUID -ne 0 ]] && echo -e "${red}错误：必须使用 root 用户运行此脚本。${plain}" && exit 1

# 安装系统级命令
if [ "$0" != "$SCRIPT_PATH" ]; then
    cp "$0" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    if [ -z "$1" ]; then
        echo -e "${green}脚本已成功安装为全局系统命令。${plain}"
        echo -e "请直接输入 ${green}xmgr${plain} 或 ${green}xmgr help${plain} 查看可用命令。"
        exit 0
    fi
fi

# ================= 核心功能函数 =================

# 1. 安装与配置
install_xray() {
    clear
    echo -e "${green}=================================================${plain}"
    echo -e "${green}        Xray (VLESS+Reality) 安装与配置          ${plain}"
    echo -e "${green}=================================================${plain}"
    echo ""

    # 读取旧配置作为默认项
    DEF_PORT=34567
    DEF_SNI="www.bing.com"
    DEF_NAME="zdaben"
    if [ -f "$CACHE_FILE" ]; then
        source "$CACHE_FILE"
        DEF_PORT=${XRAY_PORT:-$DEF_PORT}
        DEF_SNI=${XRAY_SNI:-$DEF_SNI}
        DEF_NAME=${XRAY_NAME:-$DEF_NAME}
        echo -e "${yellow}检测到本地已有配置，直接回车可保持当前设置不变。${plain}"
        echo ""
    fi

    # 端口配置
    while true; do
        read -p "$(echo -e "请输入 Xray 监听端口 [默认: ${green}$DEF_PORT${plain}]: ")" PORT
        PORT=${PORT:-$DEF_PORT}
        if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
            echo -e "${red}[错误] 请输入 1-65535 之间的数字。${plain}"
            continue
        fi
        if [[ "$PORT" == "80" || "$PORT" == "443" ]]; then
            echo -e "${red}[错误] 80 和 443 端口需预留给 Web 服务，请更换。${plain}"
            continue
        fi
        if [ "$PORT" != "$DEF_PORT" ] && ss -lntp | grep -q ":$PORT "; then
            echo -e "${red}[错误] 端口 $PORT 已被系统其他程序占用，请更换。${plain}"
            continue
        fi
        break
    done

    # SNI 配置
    while true; do
        read -p "$(echo -e "请输入伪装域名(SNI) [默认: ${green}$DEF_SNI${plain}]: ")" SNI
        SNI=${SNI:-$DEF_SNI}
        SNI=$(echo "${SNI}" | xargs)
        if [ "$SNI" != "$DEF_SNI" ]; then
            echo -e "正在测试目标域名的 443 端口联通性..."
            if ! timeout 5 bash -c "</dev/tcp/${SNI}/443" 2>/dev/null; then
                echo -e "${red}[警告] 域名 ${SNI} 无法连接 443 端口，不建议使用！${plain}"
                continue
            fi
        fi
        break
    done

    # 备注配置
    read -p "$(echo -e "请输入节点备注名称 [默认: ${green}$DEF_NAME${plain}]: ")" LINK_NAME
    LINK_NAME=${LINK_NAME:-$DEF_NAME}
    LINK_NAME=$(echo "${LINK_NAME}" | xargs)

    echo ""
    echo -e "${green}配置检查完毕，开始执行部署...${plain}"
    echo "-------------------------------------------------"

    apt-get update -y > /dev/null 2>&1
    apt-get install -y curl wget tar unzip openssl iproute2 iptables ufw > /dev/null 2>&1

    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p > /dev/null 2>&1
    fi

    echo -e "状态: ${yellow}正在安装 Xray 官方内核...${plain}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null 2>&1

    echo -e "状态: ${yellow}正在生成安全凭证...${plain}"
    UUID=$(xray uuid)
    SHORT_ID=$(openssl rand -hex 4)
    KEYS=$(xray x25519)
    PRIVATE_KEY=$(echo "$KEYS" | grep -i "Private" | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$KEYS" | grep -i -E "Public|Password" | awk '{print $NF}')

    if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
        echo -e "${red}[错误] 核心密钥生成失败，部署中止。${plain}" && exit 1
    fi

    cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$UUID", "flow": "xtls-rprx-vision" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${SNI}:443",
          "serverNames": [ "$SNI" ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [ "$SHORT_ID" ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [ "http", "tls", "quic" ]
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "blocked" }
  ]
}
EOF
    chmod 644 /usr/local/etc/xray/config.json

    echo -e "状态: ${yellow}正在配置系统防火墙...${plain}"
    command -v ufw >/dev/null 2>&1 && ufw allow $PORT/tcp >/dev/null 2>&1
    if command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -p tcp --dport $PORT -j ACCEPT >/dev/null 2>&1
        command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1
    fi

    echo -e "状态: ${yellow}正在重启服务...${plain}"
    systemctl enable xray > /dev/null 2>&1
    if ! systemctl restart xray; then
        echo -e "${red}[错误] Xray 启动失败，请检查以下系统日志：${plain}"
        journalctl -u xray -n 15 --no-pager
        exit 1
    fi

    IP=$(curl -s4m8 ifconfig.me || curl -s4m8 ip.sb || curl -s4m8 api.ipify.org)

    cat > "$CACHE_FILE" <<EOF
XRAY_PORT=$PORT
XRAY_SNI=$SNI
XRAY_NAME=$LINK_NAME
XRAY_UUID=$UUID
XRAY_PBK=$PUBLIC_KEY
XRAY_SID=$SHORT_ID
XRAY_IP=$IP
EOF

    echo "-------------------------------------------------"
    echo -e "${green}Xray (VLESS+Reality) 安装与配置成功！${plain}"
    echo ""
    show_link
}

# 2. 查看链接
show_link() {
    if [ ! -f "$CACHE_FILE" ]; then
        echo -e "${red}[错误] 未找到配置信息，请先运行 xmgr install 进行部署。${plain}"
        exit 1
    fi
    
    source "$CACHE_FILE"
    LINK="vless://${XRAY_UUID}@${XRAY_IP}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${XRAY_SNI}&fp=chrome&pbk=${XRAY_PBK}&sid=${XRAY_SID}&type=tcp&headerType=none#${XRAY_NAME}"

    echo -e "${green}=================================================${plain}"
    echo -e "${green}                 Xray 节点配置信息               ${plain}"
    echo -e "${green}=================================================${plain}"
    echo -e " IP 地址   : ${green}${XRAY_IP}${plain}"
    echo -e " 连接端口  : ${green}${XRAY_PORT}${plain}"
    echo -e " 伪装域名  : ${green}${XRAY_SNI}${plain}"
    echo -e " 用户 UUID : ${green}${XRAY_UUID}${plain}"
    echo -e " 短身份码  : ${green}${XRAY_SID}${plain}"
    echo -e "${green}=================================================${plain}"
    echo -e " 订阅链接 (请完整复制下方内容):"
    echo -e "${yellow}${LINK}${plain}"
    echo -e "${green}=================================================${plain}"
    echo ""
}

# 3. 查看状态
show_status() {
    echo ""
    echo -e "${green}================= Xray 服务运行状态 =================${plain}"
    systemctl status xray --no-pager | head -n 10
    echo -e "${green}================= 最近 10 条运行日志 ================${plain}"
    journalctl -u xray -n 10 --no-pager
    echo -e "${green}=====================================================${plain}"
    echo ""
}

# 4. 卸载
uninstall_xray() {
    echo ""
    read -p "$(echo -e "${yellow}确定要彻底卸载 Xray 及所有配置吗？(y/n): ${plain}")" confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        systemctl stop xray > /dev/null 2>&1
        systemctl disable xray > /dev/null 2>&1
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove > /dev/null 2>&1
        rm -rf /usr/local/etc/xray
        rm -f "$SCRIPT_PATH"
        echo -e "${green}[信息] Xray 已完全卸载。${plain}"
        exit 0
    else
        echo -e "${green}[信息] 已取消卸载操作。${plain}"
    fi
}

# ================= 命令解析 =================
show_help() {
    echo ""
    echo -e " Xray (VLESS+Reality) 命令行管理脚本"
    echo -e " 使用方法: ${green}xmgr${plain} [命令]"
    echo ""
    echo -e " ${green}install${plain}   - 安装或修改配置 (更换端口/伪装域名等)"
    echo -e " ${green}link${plain}      - 查看当前节点参数与 vless 订阅链接"
    echo -e " ${green}restart${plain}   - 重启 Xray 核心服务"
    echo -e " ${green}status${plain}    - 查看服务运行状态与系统底层日志"
    echo -e " ${green}uninstall${plain} - 彻底卸载 Xray 及清理残留配置"
    echo -e " ${green}help${plain}      - 显示当前帮助信息"
    echo ""
}

case "$1" in
    install)
        install_xray
        ;;
    link)
        show_link
        ;;
    restart)
        systemctl restart xray
        echo -e "${green}[信息] Xray 服务已重启完毕。${plain}"
        ;;
    status)
        show_status
        ;;
    uninstall)
        uninstall_xray
        ;;
    *)
        show_help
        ;;
esac
