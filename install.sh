#!/bin/bash

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# 检查是否为 Root 用户
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

echo -e "${GREEN}============================================${PLAIN}"
echo -e "${GREEN}  Xray (VLESS+Vision+Reality) 终极一键脚本  ${PLAIN}"
echo -e "${GREEN}  Environment: Debian 12 / Ubuntu           ${PLAIN}"
echo -e "${GREEN}============================================${PLAIN}"

# 1. 安装基础工具与依赖 (包含 openssl 用于生成随机数，iproute2 用于端口检测)
echo -e "${YELLOW}[1/8] 安装基础依赖环境...${PLAIN}"
apt-get update -y > /dev/null 2>&1
apt-get install -y curl wget tar unzip openssl iproute2 iptables ufw > /dev/null 2>&1

# 2. 开启 BBR
echo -e "${YELLOW}[2/8] 检查并开启 BBR...${PLAIN}"
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p > /dev/null 2>&1
    echo -e "${GREEN}BBR 已开启${PLAIN}"
else
    echo -e "${GREEN}BBR 之前已开启，跳过${PLAIN}"
fi

# 3. 获取并严格校验用户输入
echo -e "${YELLOW}[3/8] 配置参数...${PLAIN}"

# 端口输入与查占循环
while true; do
    read -p "请输入端口号 [默认: 34567]: " PORT
    PORT=${PORT:-34567}
    
    # 检查合法性
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        echo -e "${RED}警告：请输入 1-65535 之间的有效数字！${PLAIN}"
        continue
    fi
    
    # 拦截 80 和 443
    if [[ "$PORT" == "80" || "$PORT" == "443" ]]; then
        echo -e "${RED}警告：端口 80 和 443 建议留给建站环境 (Nginx)，请更换！${PLAIN}"
        continue
    fi
    
    # 检查端口是否被占用 (核心优化)
    if ss -lntp | grep -q ":$PORT "; then
        echo -e "${RED}错误：端口 $PORT 已被其他程序占用，请更换！${PLAIN}"
        continue
    fi
    
    break
done

# SNI 域名输入与联通性测试
while true; do
    read -p "请输入伪装域名 (SNI) [默认: www.bing.com]: " SNI
    SNI=${SNI:-www.bing.com}
    SNI=$(echo "${SNI}" | xargs) # 去除两端空格
    
    echo -e "正在测试目标域名的 443 端口联通性..."
    if ! timeout 5 bash -c "</dev/tcp/${SNI}/443" 2>/dev/null; then
        echo -e "${RED}警告：域名 ${SNI} 无法连接或禁用了 443 端口，不适合作为 Reality 伪装目标，请更换！${PLAIN}"
        continue
    fi
    break
done

read -p "请输入链接备注名称 [默认: zdaben]: " LINK_NAME
LINK_NAME=${LINK_NAME:-zdaben}
LINK_NAME=$(echo "${LINK_NAME}" | xargs)

# 4. 安装 Xray 官方内核
echo -e "${YELLOW}[4/8] 安装 Xray 最新内核...${PLAIN}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED}Xray 安装失败，请检查网络连接！${PLAIN}"
    exit 1
fi

# 5. 生成凭证并写入配置
echo -e "${YELLOW}[5/8] 生成安全凭证...${PLAIN}"

# 生成基础参数
UUID=$(xray uuid)
SHORT_ID=$(openssl rand -hex 4) # 生成 8 位随机 ShortId (核心优化)

# 健壮解析密钥对
KEYS=$(xray x25519)
PRIVATE_KEY=$(echo "$KEYS" | grep -i "Private" | awk '{print $NF}')
PUBLIC_KEY=$(echo "$KEYS" | grep -i -E "Public|Password" | awk '{print $NF}')

if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" || "$PRIVATE_KEY" == *"("* || "$PUBLIC_KEY" == *"("* ]]; then
    echo -e "${RED}严重错误：密钥生成或解析失败！${PLAIN}"
    exit 1
fi

# 备份旧配置 (如果存在)
if [ -f /usr/local/etc/xray/config.json ]; then
    cp /usr/local/etc/xray/config.json /usr/local/etc/xray/config.json.bak
    echo -e "${GREEN}已备份旧配置文件到 config.json.bak${PLAIN}"
fi

# 写入新配置文件
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${SNI}:443",
          "serverNames": [
            "$SNI"
          ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [
            "$SHORT_ID"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ]
}
EOF

# 6. 配置系统级防火墙放行
echo -e "${YELLOW}[6/8] 配置本机防火墙规则...${PLAIN}"
if command -v ufw >/dev/null 2>&1; then
    ufw allow $PORT/tcp >/dev/null 2>&1
fi
if command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport $PORT -j ACCEPT >/dev/null 2>&1
    # 尝试保存 iptables 规则避免重启失效
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1
fi

# 7. 重启服务与异常捕获
echo -e "${YELLOW}[7/8] 启动 Xray 服务...${PLAIN}"
systemctl enable xray > /dev/null 2>&1

# 带有日志输出的启动检查 (核心优化)
if ! systemctl restart xray; then
    echo -e "${RED}致命错误：Xray 服务启动失败！以下是最近的报错日志：${PLAIN}"
    journalctl -u xray -n 20 --no-pager
    exit 1
fi

# 8. 输出结果
echo -e "${YELLOW}[8/8] 正在生成连接信息...${PLAIN}"

# 多渠道获取本机 IP (核心优化)
IP=$(curl -s4m8 ifconfig.me || curl -s4m8 ip.sb || curl -s4m8 api.ipify.org)

# 拼接 VLESS 链接 (加入了 sid 参数和 fp 显示)
LINK="vless://${UUID}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${LINK_NAME}"

echo -e "${GREEN}============================================${PLAIN}"
echo -e "${GREEN}            安装成功！节点配置如下：        ${PLAIN}"
echo -e "${GREEN}============================================${PLAIN}"
echo -e "服务器IP (Address) : ${CYAN}${IP}${PLAIN}"
echo -e "连接端口 (Port)    : ${CYAN}${PORT}${PLAIN}"
echo -e "用户ID (UUID)      : ${CYAN}${UUID}${PLAIN}"
echo -e "流控算法 (Flow)    : ${CYAN}xtls-rprx-vision${PLAIN}"
echo -e "加密方式 (TLS)     : ${CYAN}reality${PLAIN}"
echo -e "伪装域名 (SNI)     : ${CYAN}${SNI}${PLAIN}"
echo -e "公钥参数 (Pbk)     : ${CYAN}${PUBLIC_KEY}${PLAIN}"
echo -e "短身份码 (ShortId) : ${CYAN}${SHORT_ID}${PLAIN}"
echo -e "指纹特征 (Fp)      : ${CYAN}chrome${PLAIN}"
echo -e "${GREEN}============================================${PLAIN}"
echo -e "🚀 分享链接 (直接复制到 Hiddify/v2rayN 中导入):"
echo -e "${YELLOW}${LINK}${PLAIN}"
echo -e "${GREEN}============================================${PLAIN}"
echo -e "${RED}⚠️ 重要提示：${PLAIN}如果您的服务器在阿里云、腾讯云、AWS 等云平台，请务必去网页端控制台的【安全组/防火墙】中放行 TCP 端口 ${PORT}，否则无法连接！"
echo -e "${GREEN}============================================${PLAIN}"
