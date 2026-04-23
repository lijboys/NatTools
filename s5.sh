cat > /usr/local/bin/s5 <<'EOF'
#!/bin/bash

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
BLUE="\033[34m"
RESET="\033[0m"

SCRIPT_VERSION="v1.3.0"
CONF_FILE="/etc/danted.conf"
INFO_FILE="/etc/s5_info.txt"
SERVICE_NAME="danted"
LOG_FILE="/var/log/danted.log"
SCRIPT_URL="https://raw.githubusercontent.com/lijboys/SSHTools/main/s5.sh"

pause() { read -p "按回车键返回主菜单..." ; }

is_valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

is_valid_ipv4() {
  local ip=$1
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
  for o in "$o1" "$o2" "$o3" "$o4"; do
    [[ "$o" =~ ^[0-9]+$ ]] && [ "$o" -ge 0 ] && [ "$o" -le 255 ] || return 1
  done
  return 0
}

is_valid_ipv6() {
  local ip=$1
  [[ "$ip" =~ : ]] || return 1
  [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]] || return 1
  return 0
}

is_port_in_use() {
  ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1$"
}

get_public_ip() {
  local ip_type="${1:-4}"
  local ip=""
  if [ "$ip_type" = "6" ]; then
    ip=$(curl -s6m3 --connect-timeout 3 ipv6.icanhazip.com 2>/dev/null)
    [ -z "$ip" ] && ip=$(curl -s6m3 --connect-timeout 3 api6.ipify.org 2>/dev/null)
    [ -z "$ip" ] && ip=$(curl -s6m3 --connect-timeout 3 ifconfig.co 2>/dev/null)
    is_valid_ipv6 "$ip" && echo "$ip" || echo ""
  else
    ip=$(curl -s4m3 --connect-timeout 3 ipv4.icanhazip.com 2>/dev/null)
    [ -z "$ip" ] && ip=$(curl -s4m3 --connect-timeout 3 api.ipify.org 2>/dev/null)
    [ -z "$ip" ] && ip=$(curl -s4m3 --connect-timeout 3 ifconfig.me 2>/dev/null)
    is_valid_ipv4 "$ip" && echo "$ip" || echo ""
  fi
}

detect_iface() {
  ip route | awk '/default/ {print $5; exit}'
}

get_status() {
  if command -v rc-service >/dev/null 2>&1; then
    rc-service ${SERVICE_NAME} status >/dev/null 2>&1 && echo -e "${GREEN}运行中${RESET}" || echo -e "${RED}已停止${RESET}"
  else
    systemctl is-active --quiet ${SERVICE_NAME} && echo -e "${GREEN}运行中${RESET}" || echo -e "${RED}已停止${RESET}"
  fi
}

detect_pkg_manager() {
  if command -v apk >/dev/null 2>&1; then
    echo "apk"
  elif command -v apt >/dev/null 2>&1; then
    echo "apt"
  elif command -v dnf >/dev/null 2>&1; then
    echo "dnf"
  elif command -v yum >/dev/null 2>&1; then
    echo "yum"
  else
    echo "unknown"
  fi
}

install_deps() {
  local pkg_mgr=$(detect_pkg_manager)
  case "$pkg_mgr" in
    apk)
      apk add --no-cache dante-server curl >/dev/null 2>&1
      ;;
    apt)
      apt update -y >/dev/null 2>&1
      apt install -y dante-server >/dev/null 2>&1
      ;;
    dnf)
      dnf install -y dante-server >/dev/null 2>&1
      ;;
    yum)
      yum install -y dante-server >/dev/null 2>&1
      ;;
    *)
      echo -e "${RED}❌ 不支持的系统包管理器${RESET}"
      return 1
      ;;
  esac
}

format_host_for_url() {
  local ip="$1"
  local ip_type="$2"
  if [ "$ip_type" = "6" ]; then
    echo "[${ip}]"
  else
    echo "$ip"
  fi
}

write_conf() {
  local iface="$1"
  local port="$2"
  local ip_type="$3"

  if [ "$ip_type" = "6" ]; then
    cat > "$CONF_FILE" <<EOT
logoutput: /var/log/danted.log
internal: :: port = ${port}
external: ${iface}

socksmethod: username
user.privileged: root
user.unprivileged: nobody

client pass {
  from: ::/0 to: ::/0
  log: connect error
}

client block {
  from: ::/0 to: ::/0
  log: error
}

socks pass {
  from: ::/0 to: ::/0
  command: bind connect udpassociate
  socksmethod: username
  log: connect error
}

socks block {
  from: ::/0 to: ::/0
  log: error
}
EOT
  else
    cat > "$CONF_FILE" <<EOT
logoutput: /var/log/danted.log
internal: 0.0.0.0 port = ${port}
external: ${iface}

socksmethod: username
user.privileged: root
user.unprivileged: nobody

client pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  log: connect error
}

client block {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  log: error
}

socks pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  command: bind connect udpassociate
  socksmethod: username
  log: connect error
}

socks block {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  log: error
}
EOT
  fi
}

save_info() {
  local ip="$1"
  local port="$2"
  local user="$3"
  local pass="$4"
  local ip_type="$5"

  local host
  host=$(format_host_for_url "$ip" "$ip_type")

  local socks5_link="socks5://${user}:${pass}@${host}:${port}"
  local tg_link="tg://socks?server=${host}&port=${port}&user=${user}&pass=${pass}"

  cat > "$INFO_FILE" <<EOT
IP="${ip}"
PORT="${port}"
USER="${user}"
PASS="${pass}"
IP_TYPE="${ip_type}"
SOCKS5_LINK="${socks5_link}"
TG_LINK="${tg_link}"
EOT
}

read_info() {
  grep "^$1=" "$INFO_FILE" 2>/dev/null | head -n1 | cut -d'"' -f2
}

stop_service() {
  if command -v rc-service >/dev/null 2>&1; then
    rc-service ${SERVICE_NAME} stop >/dev/null 2>&1
  else
    systemctl stop ${SERVICE_NAME} >/dev/null 2>&1
  fi
  sleep 1
  if [ -f "$CONF_FILE" ]; then
    local port
    port=$(grep -o 'port = [0-9]*' "$CONF_FILE" | awk '{print $3}' | head -n1)
    for i in {1..5}; do
      if ! is_port_in_use "$port"; then
        break
      fi
      sleep 1
    done
  fi
}

start_service() {
  if command -v rc-service >/dev/null 2>&1; then
    rc-update add ${SERVICE_NAME} >/dev/null 2>&1
    rc-service ${SERVICE_NAME} restart >/dev/null 2>&1
  else
    systemctl enable ${SERVICE_NAME} >/dev/null 2>&1
    systemctl restart ${SERVICE_NAME} >/dev/null 2>&1
  fi
  sleep 1
  if command -v rc-service >/dev/null 2>&1; then
    rc-service ${SERVICE_NAME} status >/dev/null 2>&1
  else
    systemctl is-active --quiet ${SERVICE_NAME}
  fi
}

choose_ip_mode() {
  echo ""
  echo -e "${CYAN}--- 请选择对外使用的 IP 类型 ---${RESET}"
  echo -e "  ${GREEN}1.${RESET} IPv4"
  echo -e "  ${GREEN}2.${RESET} IPv6"
  read -p "请输入序号 (回车默认 2): " ip_choice

  if [ -z "$ip_choice" ] || [ "$ip_choice" = "2" ]; then
    IP_TYPE="6"
    AUTO_IP=$(get_public_ip 6)
    DISPLAY_IP=${AUTO_IP:-"获取失败，请手动输入"}
    read -p "👉 请输入公网 IPv6 地址 (识别出: $DISPLAY_IP): " PUBLIC_IP
    PUBLIC_IP=${PUBLIC_IP:-$AUTO_IP}
    is_valid_ipv6 "$PUBLIC_IP" || { echo -e "${RED}❌ 公网 IPv6 地址无效！${RESET}"; return 1; }
  elif [ "$ip_choice" = "1" ]; then
    IP_TYPE="4"
    AUTO_IP=$(get_public_ip 4)
    DISPLAY_IP=${AUTO_IP:-"获取失败，请手动输入"}
    read -p "👉 请输入公网 IPv4 地址 (识别出: $DISPLAY_IP): " PUBLIC_IP
    PUBLIC_IP=${PUBLIC_IP:-$AUTO_IP}
    is_valid_ipv4 "$PUBLIC_IP" || { echo -e "${RED}❌ 公网 IPv4 地址无效！${RESET}"; return 1; }
  else
    echo -e "${RED}❌ 输入错误！${RESET}"
    return 1
  fi
  return 0
}

ensure_user_password() {
  local user="$1"
  local pass="$2"
  if id "$user" >/dev/null 2>&1; then
    echo "$user:$pass" | chpasswd
  else
    if command -v useradd >/dev/null 2>&1; then
      useradd -M -s /usr/sbin/nologin "$user" 2>/dev/null || useradd -M -s /sbin/nologin "$user"
    else
      adduser -D -s /sbin/nologin "$user"
    fi
    echo "$user:$pass" | chpasswd
  fi
}

install_s5() {
  clear
  echo -e "${CYAN}=========================================${RESET}"
  echo -e "${CYAN}  🚀 开始部署 SOCKS5 代理 (Dante)${RESET}"
  echo -e "${CYAN}=========================================${RESET}"

  if [ -f "/usr/sbin/sockd" ] && [ -f "$INFO_FILE" ]; then
    echo -e "${YELLOW}⚠️ 检测到当前机器已经安装了 SOCKS5 代理服务！${RESET}"
    read -p "👉 是否要继续【覆盖重装】并清除原有配置？[y/N]: " confirm_reinstall
    [[ "$confirm_reinstall" != "y" && "$confirm_reinstall" != "Y" ]] && { echo -e "${GREEN}✅ 已取消安装。${RESET}"; sleep 1; return; }
  fi

  stop_service
  install_deps || { pause; return; }

  local iface port user pass
  iface=$(detect_iface)
  [ -z "$iface" ] && iface="eth0"

  echo ""
  echo -e "${YELLOW}💡 提示: SOCKS5 推荐使用 1080 或 10800 端口。${RESET}"
  read -p "👉 请输入监听端口 (回车默认 1080): " port
  port=${port:-1080}
  if ! is_valid_port "$port"; then
    echo -e "${RED}❌ 端口无效！${RESET}"; pause; return
  fi
  if is_port_in_use "$port"; then
    echo -e "${RED}❌ 端口 ${port} 已被占用！${RESET}"; pause; return
  fi

  choose_ip_mode || { pause; return; }

  read -p "👉 请输入用户名 (回车默认 s5user): " user
  user=${user:-s5user}

  read -p "👉 请输入密码 (回车默认随机8位): " pass
  [ -z "$pass" ] && pass=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8)

  ensure_user_password "$user" "$pass"
  write_conf "$iface" "$port" "$IP_TYPE"

  if start_service; then
    save_info "$PUBLIC_IP" "$port" "$user" "$pass" "$IP_TYPE"
    echo -e "\n${GREEN}✅ SOCKS5 部署成功！程序已在后台监听端口 ${port}${RESET}"
    echo -e "当前服务状态: $(get_status)"
    echo -e "当前 IP 类型: ${GREEN}IPv${IP_TYPE}${RESET}"
    echo -e "\n${CYAN}📱 TG 代理链接：${RESET}"
    echo -e "${GREEN}$(read_info TG_LINK)${RESET}"
    echo -e "\n${CYAN}🔗 SOCKS5 链接：${RESET}"
    echo -e "${YELLOW}$(read_info SOCKS5_LINK)${RESET}"
  else
    echo -e "${RED}❌ 服务启动失败！${RESET}"
    echo -e "${YELLOW}你可以检查：${RESET}"
    echo "journalctl -u ${SERVICE_NAME} -n 50 --no-pager"
    echo "cat ${CONF_FILE}"
  fi
  pause
}

view_info() {
  clear
  echo -e "${CYAN}=========================================${RESET}"
  if [ ! -f "$INFO_FILE" ]; then
    echo -e "${RED}未找到配置，请先安装！${RESET}"
    echo -e "${CYAN}=========================================${RESET}"
    pause
    return
  fi
  echo -e "当前服务状态:     $(get_status)"
  echo -e "当前监听端口:     ${GREEN}$(read_info PORT)${RESET}"
  echo -e "当前对外公网地址: ${GREEN}$(read_info IP):$(read_info PORT)${RESET}"
  echo -e "当前 IP 类型:     ${GREEN}IPv$(read_info IP_TYPE)${RESET}"
  echo -e "当前账号:         ${GREEN}$(read_info USER)${RESET}"
  echo -e "当前密码:         ${GREEN}$(read_info PASS)${RESET}"
  echo -e "\n${CYAN}📱 TG 代理链接：${RESET}"
  echo -e "${GREEN}$(read_info TG_LINK)${RESET}"
  echo -e "\n${CYAN}🔗 SOCKS5 链接：${RESET}"
  echo -e "${YELLOW}$(read_info SOCKS5_LINK)${RESET}"
  echo -e "${CYAN}=========================================${RESET}"
  pause
}

modify_s5() {
  clear
  if [ ! -f "$INFO_FILE" ]; then
    echo -e "${RED}请先安装！${RESET}"
    pause
    return
  fi

  local old_port old_user old_pass old_ip old_ip_type
  local iface port user pass NEW_IP NEW_IP_TYPE

  old_port=$(read_info PORT)
  old_user=$(read_info USER)
  old_pass=$(read_info PASS)
  old_ip=$(read_info IP)
  old_ip_type=$(read_info IP_TYPE)
  [ -z "$old_ip_type" ] && old_ip_type="4"

  iface=$(detect_iface)
  [ -z "$iface" ] && iface="eth0"

  echo -e "${CYAN}--- 修改端口与账号密码 ---${RESET}"

  read -p "输入新【监听端口】 (回车保持 ${old_port}): " port
  port=${port:-$old_port}
  if ! is_valid_port "$port"; then
    echo -e "${RED}❌ 端口无效！${RESET}"
    pause
    return
  fi
  [ "$port" != "$old_port" ] && is_port_in_use "$port" && { echo -e "${RED}❌ 端口已被占用！${RESET}"; pause; return; }

  echo -e "${CYAN}当前 IP 类型: IPv${old_ip_type}${RESET}"
  echo -e "  ${GREEN}1.${RESET} IPv4"
  echo -e "  ${GREEN}2.${RESET} IPv6"
  read -p "请选择新的 IP 类型 (回车保持当前): " new_ip_choice

  case "$new_ip_choice" in
    1) NEW_IP_TYPE="4" ;;
    2) NEW_IP_TYPE="6" ;;
    *) NEW_IP_TYPE="$old_ip_type" ;;
  esac

  if [ "$NEW_IP_TYPE" = "6" ]; then
    AUTO_IP=$(get_public_ip 6)
    DISPLAY_IP=${AUTO_IP:-"获取失败"}
    echo -e "${YELLOW}当前机器识别到的 IPv6 为: ${DISPLAY_IP}${RESET}"
    read -p "输入新【公网 IPv6】 (回车保持 ${old_ip}): " NEW_IP
    NEW_IP=${NEW_IP:-$old_ip}
    is_valid_ipv6 "$NEW_IP" || { echo -e "${RED}❌ 公网 IPv6 格式无效！${RESET}"; pause; return; }
  else
    AUTO_IP=$(get_public_ip 4)
    DISPLAY_IP=${AUTO_IP:-"获取失败"}
    echo -e "${YELLOW}当前机器识别到的 IPv4 为: ${DISPLAY_IP}${RESET}"
    read -p "输入新【公网 IPv4】 (回车保持 ${old_ip}): " NEW_IP
    NEW_IP=${NEW_IP:-$old_ip}
    is_valid_ipv4 "$NEW_IP" || { echo -e "${RED}❌ 公网 IPv4 格式无效！${RESET}"; pause; return; }
  fi

  read -p "输入新【用户名】 (回车保持 ${old_user}): " user
  user=${user:-$old_user}

  read -p "输入新【密码】 (回车保持原密码): " pass
  pass=${pass:-$old_pass}

  if [ "$user" != "$old_user" ]; then
    id "$old_user" >/dev/null 2>&1 && userdel "$old_user" 2>/dev/null
  fi

  ensure_user_password "$user" "$pass"
  write_conf "$iface" "$port" "$NEW_IP_TYPE"

  if start_service; then
    save_info "$NEW_IP" "$port" "$user" "$pass" "$NEW_IP_TYPE"
    echo -e "${GREEN}✅ 配置已更新并重启成功！${RESET}"
    echo -e "\n${CYAN}📱 TG 代理链接：${RESET}"
    echo -e "${GREEN}$(read_info TG_LINK)${RESET}"
    echo -e "\n${CYAN}🔗 SOCKS5 链接：${RESET}"
    echo -e "${YELLOW}$(read_info SOCKS5_LINK)${RESET}"
  else
    echo -e "${RED}❌ 配置已写入，但服务启动失败！${RESET}"
  fi
  pause
}

service_ctl() {
  local action="$1"
  if command -v rc-service >/dev/null 2>&1; then
    rc-service ${SERVICE_NAME} $action
  else
    systemctl ${action} ${SERVICE_NAME}
  fi
  sleep 1
  echo -e "当前状态: $(get_status)"
  pause
}

view_logs() {
  clear
  echo -e "${CYAN}=========================================${RESET}"
  echo -e "               📜 SOCKS5 运行日志"
  echo -e "${CYAN}=========================================${RESET}"
  if command -v journalctl >/dev/null 2>&1; then
    journalctl -u ${SERVICE_NAME} --no-pager -n 50 2>/dev/null || tail -n 50 "$LOG_FILE" 2>/dev/null || echo "暂无日志"
  else
    tail -n 50 "$LOG_FILE" 2>/dev/null || echo "暂无日志"
  fi
  echo -e "${CYAN}=========================================${RESET}"
  pause
}

uninstall_s5() {
  clear
  echo -e "${RED}你正在执行 SOCKS5 卸载操作！${RESET}"
  read -p "确认彻底卸载 dante + 面板吗？[y/N]: " confirm_uninstall
  [[ "$confirm_uninstall" != "y" && "$confirm_uninstall" != "Y" ]] && { echo -e "${YELLOW}已取消卸载。${RESET}"; sleep 1; return; }

  echo -e "${RED}正在卸载...${RESET}"
  stop_service

  local pkg_mgr
  pkg_mgr=$(detect_pkg_manager)
  case "$pkg_mgr" in
    apk) apk del dante-server >/dev/null 2>&1 ;;
    apt) apt remove -y dante-server >/dev/null 2>&1 ;;
    dnf) dnf remove -y dante-server >/dev/null 2>&1 ;;
    yum) yum remove -y dante-server >/dev/null 2>&1 ;;
  esac

  rm -f "$CONF_FILE" "$INFO_FILE" "$LOG_FILE" /usr/local/bin/s5
  echo -e "${GREEN}✅ 卸载完成！${RESET}"
  sleep 2
  exit 0
}

update_script() {
  clear
  echo -e "${YELLOW}正在从 GitHub 拉取最新脚本...${RESET}"
  local tmp_file
  tmp_file=$(mktemp)
  if curl -fsSL --connect-timeout 10 "${SCRIPT_URL}" -o "$tmp_file" 2>/dev/null; then
    sed -i 's/\r$//' "$tmp_file"
    if bash -n "$tmp_file" 2>/dev/null; then
      mv "$tmp_file" /usr/local/bin/s5
      chmod +x /usr/local/bin/s5
      echo -e "${GREEN}✅ 脚本更新完成！请重新输入 s5 启动最新版。${RESET}"
      sleep 2
      exit 0
    else
      rm -f "$tmp_file"
      echo -e "${RED}❌ 新脚本语法校验失败，已取消更新！${RESET}"
      sleep 2
    fi
  else
    rm -f "$tmp_file"
    echo -e "${RED}❌ 下载失败，请检查网络！${RESET}"
    sleep 2
  fi
  pause
}

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请使用 root 用户运行！${RESET}"
  exit 1
fi

while true; do
  clear
  if [ -f "$INFO_FILE" ]; then
    CURRENT_IP=$(read_info IP)
    CURRENT_PORT=$(read_info PORT)
    CURRENT_USER=$(read_info USER)
    CURRENT_IP_TYPE=$(read_info IP_TYPE)
    [ -z "$CURRENT_IP_TYPE" ] && CURRENT_IP_TYPE="4"
  else
    CURRENT_IP="-"
    CURRENT_PORT="-"
    CURRENT_USER="-"
    CURRENT_IP_TYPE="-"
  fi

  echo -e "${CYAN}=========================================${RESET}"
  echo -e "   🦇 SOCKS5 管理面板 ${GREEN}${SCRIPT_VERSION}${RESET}"
  echo -e "${CYAN}=========================================${RESET}"
  echo -e "当前状态: ${RESET}$(get_status)"
  echo -e "当前地址: ${YELLOW}${CURRENT_IP}:${CURRENT_PORT}${RESET}"
  echo -e "IP 类型:  ${GREEN}IPv${CURRENT_IP_TYPE}${RESET}"
  echo -e "当前账号: ${GREEN}${CURRENT_USER}${RESET}"
  echo -e "快捷指令: ${GREEN}s5${RESET}"
  echo -e "${CYAN}-----------------------------------------${RESET}"
  echo -e "  ${GREEN}1.${RESET} 安装 / 重装 SOCKS5"
  echo -e "  ${GREEN}2.${RESET} 查看当前连接信息"
  echo -e "  ${GREEN}3.${RESET} 修改端口、IP 与账号密码"
  echo -e "  ${YELLOW}4.${RESET} 启动 SOCKS5 服务"
  echo -e "  ${YELLOW}5.${RESET} 停止 SOCKS5 服务"
  echo -e "  ${CYAN}6.${RESET} 重启 SOCKS5 服务"
  echo -e "  ${CYAN}7.${RESET} 查看运行日志"
  echo -e "  ${BLUE}8.${RESET} 更新脚本代码 (从 GitHub 同步)"
  echo -e "  ${RED}9.${RESET} 彻底卸载 SOCKS5"
  echo -e "  ${GREEN}0.${RESET} 退出面板"
  echo -e "${CYAN}=========================================${RESET}"
  read -p "请输入序号选择功能: " choice

  case "$choice" in
    1) install_s5 ;;
    2) view_info ;;
    3) modify_s5 ;;
    4) service_ctl start ;;
    5) service_ctl stop ;;
    6) service_ctl restart ;;
    7) view_logs ;;
    8) update_script ;;
    9) uninstall_s5 ;;
    0) clear; exit 0 ;;
    *) echo -e "${RED}输入错误！${RESET}"; sleep 1 ;;
  esac
done
EOF

chmod +x /usr/local/bin/s5
echo -e "\033[32m✅ IPv6 版 s5 已安装完成！\033[0m"
