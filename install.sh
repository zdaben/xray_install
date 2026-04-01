#!/bin/bash

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 检查是否为 Root 用户
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

echo -e "${GREEN}============================================${PLAIN}"
echo -e "${GREEN}  Xray (VLESS+Vision+Reality) 一键安装脚本  ${PLAIN}"
echo -e "${GREEN}  Environment: Debian 12 / Ubuntu           ${PLAIN}"
echo -e "${GREEN}============================================${PLAIN}"

# 1. 安装基础工具
echo -e "${YELLOW}[1/6] 安装基础工具...${PLAIN}"
apt update -y > /dev/null 2>&1
apt install -y curl wget tar > /dev/null 2>&1

# 2. 开启 BBR
echo -e "${YELLOW}[2/6] 检查并开启 BBR...${PLAIN}"
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p > /dev/null 2>&1
    echo -e "${GREEN}BBR 已开启${PLAIN}"
else
    echo -e "${GREEN}BBR 之前已开启，跳过${PLAIN}"
fi

# 3. 获取用户输入
echo -e "${YELLOW}[3/6] 配置参数...${PLAIN}"

# 设置端口
read -p "请输入端口号 [默认: 34567]: " PORT
[[ -z "${PORT}" ]] && PORT="34567"

# 设置伪装域名
read -p "请输入伪装域名 (SNI) [默认: www.bing.com]: " SNI
[[ -z "${SNI}" ]] && SNI="www.bing.com"

# 设置链接名称
read -p "请输入链接备注名称 [默认: zdaben]: " LINK_NAME
[[ -z "${LINK_NAME}" ]] && LINK_NAME="zdaben"

# 4. 安装 Xray 官方内核
echo -e "${YELLOW}[4/6] 安装 Xray 最新内核...${PLAIN}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null 2>&1

if [ $? -ne 0 ]; then
    echo -e "${RED}Xray 安装失败，请检查网络连接！${PLAIN}"
    exit 1
fi

# 5. 生成凭证并写入配置
echo -e "${YELLOW}[5/6] 生成配置...${PLAIN}"

# 生成 UUID
UUID=$(xray uuid)

# 核心修复：更健壮的密钥解析逻辑
# 无论输出是 "PrivateKey: xxxx" 还是 "Private key: xxxx"，$NF 都会提取最后一列真正的密钥
KEYS=$(xray x25519)
PRIVATE_KEY=$(echo "$KEYS" | grep -i "Private" | awk '{print $NF}')
PUBLIC_KEY=$(echo "$KEYS" | grep -i -E "Public|Password" | awk '{print $NF}')

# 密钥安全校验
if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" || "$PRIVATE_KEY" == *"("* || "$PUBLIC_KEY" == *"("* ]]; then
    echo -e "${RED}严重错误：密钥生成或解析失败，请检查 Xray 版本或手动排查！${PLAIN}"
    exit 1
fi

# 写入配置文件
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
            ""
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

# 重启服务
systemctl restart xray
systemctl enable xray > /dev/null 2>&1

# 检查服务是否成功启动
if ! systemctl is-active --quiet xray; then
    echo -e "${RED}Xray 启动失败！可能是端口 ${PORT} 被占用（例如 LNMP 的 Nginx）。请使用 journalctl -u xray -e 查看报错日志。${PLAIN}"
    exit 1
fi

# 6. 输出结果
echo -e "${YELLOW}[6/6] 生成连接信息...${PLAIN}"

# 获取本机 IP
IP=$(curl -s4m8 ifconfig.me)

# 拼接 VLESS 链接
LINK="vless://${UUID}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&type=tcp&headerType=none#${LINK_NAME}"

echo -e "${GREEN}============================================${PLAIN}"
echo -e "${GREEN}            安装成功！配置如下：            ${PLAIN}"
echo -e "${GREEN}============================================${PLAIN}"
echo -e "地址 (Address): ${RED}${IP}${PLAIN}"
echo -e "端口 (Port)   : ${RED}${PORT}${PLAIN}"
echo -e "用户ID (UUID) : ${RED}${UUID}${PLAIN}"
echo -e "流控 (Flow)   : ${RED}xtls-rprx-vision${PLAIN}"
echo -e "加密 (TLS)    : ${RED}reality${PLAIN}"
echo -e "伪装域名 (SNI): ${RED}${SNI}${PLAIN}"
echo -e "公钥 (Pbk)    : ${RED}${PUBLIC_KEY}${PLAIN}"
echo -e "${GREEN}============================================${PLAIN}"
echo -e "🚀 分享链接 (直接复制导入):"
echo -e "${YELLOW}${LINK}${PLAIN}"
echo -e "${GREEN}============================================${PLAIN}"
