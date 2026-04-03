#!/bin/bash

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# 核心缓存路径
CACHE_FILE="/usr/local/etc/xray/.xray_info"
SCRIPT_PATH="/usr/local/bin/xmgr"

# 检查是否为 Root 用户
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：必须使用 root 用户运行此脚本。${PLAIN}" && exit 1

# 安装系统级命令
if [ "$0" != "$SCRIPT_PATH" ]; then
    cp "$0" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    if [ -z "$1" ]; then
        echo -e "${GREEN}脚本已安装为系统命令。${PLAIN}"
        echo -e "请使用 ${CYAN}xmgr${PLAIN} 或 ${CYAN}xmgr help${PLAIN} 查看可用命令。"
        exit 0
    fi
fi

# ================= 核心功能函数 =================

# 1. 安装与配置
install_xray() {
    echo -e "${GREEN}开始安装/配置 Xray (VLESS+Reality)...${PLAIN}"

    apt-get update -y > /dev/null 2>&1
    apt-get install -y curl wget tar unzip openssl iproute2 iptables ufw > /dev/null 2>&1

    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p > /dev/null 2>&1
    fi

    # 读取旧配置作为默认项
    DEF_PORT=34567
    DEF_SNI="www.bing.com"
    DEF_NAME="zdaben"
    if [ -f "$CACHE_FILE" ]; then
        source "$CACHE_FILE"
        DEF_PORT=${XRAY_PORT:-$DEF_PORT}
        DEF_SNI=${XRAY_SNI:-$DEF_SNI}
        DEF_NAME=${XRAY_NAME:-$DEF_NAME}
        echo -e "${CYAN}提示：检测到已有配置，直接回车可保持当前设置。${PLAIN}"
    fi

    # 端口配置
    while true; do
        read -p "请输入端口号 [默认: $DEF_PORT]: " PORT
        PORT=${PORT:-$DEF_PORT}
        if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
            echo -e "${RED}输入错误：请输入 1-65535 之间的数字。${PLAIN}"
            continue
        fi
        if [[ "$PORT" == "80" || "$PORT" == "443" ]]; then
            echo -e "${RED}输入错误：80 和 443 端口需预留给 Web 服务。${PLAIN}"
            continue
        fi
        if [ "$PORT" != "$DEF_PORT" ] && ss -lntp | grep -q ":$PORT "; then
            echo -e "${RED}输入错误：端口 $PORT 已被占用。${PLAIN}"
            continue
        fi
        break
    done

    # SNI 配置
    while true; do
        read -p "请输入伪装域名(SNI) [默认: $DEF_SNI]: " SNI
        SNI=${SNI:-$DEF_SNI}
        SNI=$(echo "${SNI}" | xargs)
        if [ "$SNI" != "$DEF_SNI" ]; then
            if ! timeout 5 bash -c "</dev/tcp/${SNI}/443" 2>/dev/null; then
                echo -e "${RED}验证失败：域名 ${SNI} 的 443 端口无法连接。${PLAIN}"
                continue
            fi
        fi
        break
    done

    # 备注配置
    read -p "请输入备注名称 [默认: $DEF_NAME]: " LINK_NAME
    LINK_NAME=${LINK_NAME:-$DEF_NAME}
    LINK_NAME=$(echo "${LINK_NAME}" | xargs)

    echo "正在安装 Xray..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null 2>&1

    echo "正在生成配置..."
    UUID=$(xray uuid)
    SHORT_ID=$(openssl rand -hex 4)
    KEYS=$(xray x25519)
    PRIVATE_KEY=$(echo "$KEYS" | grep -i "Private" | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$KEYS" | grep -i -E "Public|Password" | awk '{print $NF}')

    if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
        echo -e "${RED}错误：密钥生成失败。${PLAIN}" && exit 1
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

    echo "正在配置防火墙..."
    command -v ufw >/dev/null 2>&1 && ufw allow $PORT/tcp >/dev/null 2>&1
    if command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -p tcp --dport $PORT -j ACCEPT >/dev/null 2>&1
        command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1
    fi

    systemctl enable xray > /dev/null 2>&1
    if ! systemctl restart xray; then
        echo -e "${RED}错误：Xray 启动失败，请检查日志。${PLAIN}"
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

    echo -e "${GREEN}安装与配置完成。${PLAIN}"
    show_link
}

# 2. 查看链接
show_link() {
    if [ ! -f "$CACHE_FILE" ]; then
        echo -e "${RED}错误：未找到配置信息，请先运行 xmgr install。${PLAIN}"
        exit 1
    fi
    
    source "$CACHE_FILE"
    LINK="vless://${XRAY_UUID}@${XRAY_IP}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${XRAY_SNI}&fp=chrome&pbk=${XRAY_PBK}&sid=${XRAY_SID}&type=tcp&headerType=none#${XRAY_NAME}"

    echo ""
    echo -e "${CYAN}--- Xray 节点信息 ---${PLAIN}"
    echo -e "IP 地址  : ${XRAY_IP}"
    echo -e "端口     : ${XRAY_PORT}"
    echo -e "伪装域名 : ${XRAY_SNI}"
    echo -e "UUID     : ${XRAY_UUID}"
    echo -e "ShortId  : ${XRAY_SID}"
    echo ""
    echo -e "${CYAN}订阅链接 (VLESS):${PLAIN}"
    echo -e "${LINK}"
    echo ""
}

# 3. 查看状态
show_status() {
    echo -e "${CYAN}--- 服务状态 ---${PLAIN}"
    systemctl status xray --no-pager | head -n 10
    echo ""
    echo -e "${CYAN}--- 最近日志 ---${PLAIN}"
    journalctl -u xray -n 10 --no-pager
}

# 4. 卸载
uninstall_xray() {
    read -p "确定要卸载 Xray 吗？(y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        systemctl stop xray > /dev/null 2>&1
        systemctl disable xray > /dev/null 2>&1
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove > /dev/null 2>&1
        rm -rf /usr/local/etc/xray
        rm -f "$SCRIPT_PATH"
        echo -e "${GREEN}Xray 已完全卸载。${PLAIN}"
        exit 0
    else
        echo "已取消卸载。"
    fi
}

# ================= 命令解析 =================
show_help() {
    echo -e "${CYAN}Xray 管理脚本 (VLESS+Reality)${PLAIN}"
    echo -e "用法: xmgr [命令]"
    echo ""
    echo -e "可用命令:"
    echo -e "  ${GREEN}install${PLAIN}   安装或修改配置 (端口/域名)"
    echo -e "  ${GREEN}link${PLAIN}      查看当前节点信息与订阅链接"
    echo -e "  ${GREEN}restart${PLAIN}   重启 Xray 服务"
    echo -e "  ${GREEN}status${PLAIN}    查看运行状态与系统日志"
    echo -e "  ${GREEN}uninstall${PLAIN} 彻底卸载 Xray 及所有配置"
    echo -e "  ${GREEN}help${PLAIN}      显示此帮助信息"
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
        echo -e "${GREEN}Xray 服务已重启。${PLAIN}"
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
