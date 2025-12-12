#!/usr/bin/env bash
set -euo pipefail

# metadata / instance-specific names
INSTANCE="aes256"
METHOD="2022-blake3-aes-256-gcm"
SERVICE_NAME="ss2022_${INSTANCE}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
CONF="/etc/${SERVICE_NAME}.json"
ENVFILE="/etc/${SERVICE_NAME}.env"
HOSTNAME_DISPLAY="$(hostname)-SS2022-${INSTANCE}"
PLUGIN="obfs-server"

# ---------------- helpers ----------------
need_root(){ [ "$(id -u)" = 0 ] || { echo "请用 root 运行"; exit 1; }; }
has(){ command -v "$1" >/dev/null 2>&1; }
pubip(){ curl -4s ifconfig.me || curl -4s ipinfo.io/ip || hostname -I | awk '{print $1}'; }

# detect package manager
detect_pm(){
  if has apt; then PM="apt"
  elif has yum; then PM="yum"
  else
    echo "未检测到 apt/yum 包管理器"; exit 1
  fi
}

pm_install(){
  if [ "${PM:-}" = "apt" ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt update -y
    apt install -y "$@"
  else
    yum install -y epel-release >/dev/null 2>&1 || true
    yum install -y "$@"
  fi
}

b64_inline(){
  if base64 --help 2>&1 | grep -q -- "-w"; then
    base64 -w0
  else
    base64 | tr -d '\n'
  fi
}

ssrust_url_by_arch(){
  ARCH="$(uname -m)"
  VERSION=$(curl -s https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest | grep -oP '"tag_name": "\K(.*)(?=\")') || true
  if [ -z "${VERSION}" ]; then
    echo "无法获取最新版本" >&2
    exit 1
  fi
  case "${ARCH}" in
    x86_64|amd64)
      echo "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${VERSION}/shadowsocks-${VERSION}.x86_64-unknown-linux-musl.tar.xz"
      ;;
    aarch64|arm64)
      echo "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${VERSION}/shadowsocks-${VERSION}.aarch64-unknown-linux-musl.tar.xz"
      ;;
    *)
      echo "不支持的架构: ${ARCH}"; exit 1
      ;;
  esac
}

# time sync
sync_time(){
  echo "==> 配置系统时间同步..."
  if has timedatectl; then
    timedatectl set-ntp true || true
    if ! systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
      if [ "${PM}" = "apt" ]; then
        pm_install systemd-timesyncd || true
        systemctl enable --now systemd-timesyncd || true
      fi
    fi
  else
    pm_install chrony || true
    systemctl enable --now chronyd || true
  fi
}

random_host(){
  HOSTS=( "cn.download.nvidia.com" "cvws.icloud-content.com" "live-source-play.xhscdn.com" "pull-flv-l1.douyincdn.com" )
  echo "${HOSTS[$((RANDOM % ${#HOSTS[@]}))]}"
}

get_country_flag() {
    local country_code flag=""
    country_code=$(curl -s https://ipinfo.io/json | grep -o '"country": *"[^"]*"' | cut -d '"' -f 4) || true
    [ -z "${country_code}" ] && country_code="UN"
    for ((i=0; i<${#country_code}; i++)); do
        flag+=$(printf "\U$(printf '%x' $(( $(printf "%d" "'${country_code:$i:1}") + 127397 )))")
    done
    echo "${flag}${country_code}"
}

# ---------------- core install ----------------
do_install(){
  need_root
  detect_pm
  sync_time

  FLAG="$(get_country_flag)"
  HOSTNAME_DISPLAY="${FLAG}-${HOSTNAME_DISPLAY}"

  echo "== Shadowsocks-2022 (ss-rust) 安装器 (${SERVICE_NAME}, METHOD=${METHOD}) =="

  # generate random port
  generate_random_port() {
      while true; do
          PORT=$(( RANDOM % 50001 + 10000 ))
          if ss -tuln 2>/dev/null | grep -q ":$PORT\b"; then
              continue
          fi
          if netstat -tuln 2>/dev/null | grep -q ":$PORT\b"; then
              continue
          fi
          break
      done
  }
  generate_random_port
  DEFAULT_PORT="$PORT"
  read -rp "端口 [回车 = 随机端口 ${DEFAULT_PORT}]: " PORT_INPUT
  if [[ -z "${PORT_INPUT}" ]]; then
      PORT="${DEFAULT_PORT}"
  else
      PORT="${PORT_INPUT}"
      if ss -tuln 2>/dev/null | grep -q ":$PORT\b"; then
          echo "❌ 手动输入的端口 $PORT 已被占用，请重新运行脚本并更换端口。"; exit 1
      fi
      if netstat -tuln 2>/dev/null | grep -q ":$PORT\b"; then
          echo "❌ 手动输入的端口 $PORT 已被占用，请重新运行脚本并更换端口。"; exit 1
      fi
  fi
  echo "使用端口: ${PORT}"

  DEFAULT_PW="$(openssl rand -base64 32 2>/dev/null | tr -d '\n' || head -c32 /dev/urandom | base64 | tr -d '\n')"
  read -rp "密码 [回车 = 自动生成]: " PASSWORD_INPUT
  PASSWORD=${PASSWORD_INPUT:-$DEFAULT_PW}

  LISTEN="0.0.0.0"
  PLUGIN_HOST="$(random_host)"
  PLUGIN_OPTS="obfs=http;obfs-host=${PLUGIN_HOST}"

  echo
  echo "=== 配置确认 ==="
  echo "监听: ${LISTEN}"
  echo "端口: ${PORT}"
  echo "加密: ${METHOD}"
  echo "插件: ${PLUGIN} (参数: ${PLUGIN_OPTS})"
  echo "密码: ${PASSWORD}"
  read -rp "确认安装？[Y/n]: " OK; OK=${OK:-Y}
  [[ "${OK}" =~ ^[Yy]$ ]] || { echo "已取消"; exit 0; }

  echo "==> 安装依赖 (curl wget xz openssl qrencode simple-obfs)"
  if [ "${PM}" = "apt" ]; then
    pm_install curl wget xz-utils openssl qrencode
    pm_install simple-obfs
  else
    pm_install curl wget xz openssl qrencode
    pm_install simple-obfs || true
  fi

  echo "==> 下载并安装 shadowsocks-rust (musl static 优先) ..."
  install -d /usr/local/bin
  cd /usr/local/bin
  URL="$(ssrust_url_by_arch)"
  echo "下载： ${URL}"
  if ! wget -qO ssr.tar.xz "${URL}"; then
    echo "下载失败，尝试备用 glibc 版本..."
    ARCH="$(uname -m)"
    if [ "${ARCH}" = "x86_64" ]; then
      URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v1.22.0/shadowsocks-v1.22.0.x86_64-unknown-linux-gnu.tar.xz"
    elif [ "${ARCH}" = "aarch64" ]; then
      URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v1.22.0/shadowsocks-v1.22.0.aarch64-unknown-linux-gnu.tar.xz"
    fi
    wget -qO ssr.tar.xz "${URL}" || { echo "仍然无法下载 ss-rust 二进制，请检查网络或手动下载"; exit 1; }
  fi
  tar -xJf ssr.tar.xz
  rm -f ssr.tar.xz

  if [ -f /usr/local/bin/ssserver ]; then
    chmod +x /usr/local/bin/ssserver
  else
    EXE="$(find . -maxdepth 2 -type f -name 'ssserver' -perm /u+x 2>/dev/null | head -n1 || true)"
    if [ -n "${EXE}" ]; then
      mv -f "${EXE}" /usr/local/bin/ssserver
      chmod +x /usr/local/bin/ssserver
    else
      echo "⚠️ 未找到 ssserver 可执行，请检查解包内容。"; exit 1
    fi
  fi

  echo "==> 写入配置到 ${CONF}"
  cat >"${CONF}" <<EOF
{
  "server": "${LISTEN}",
  "server_port": ${PORT},
  "password": "${PASSWORD}",
  "method": "${METHOD}",
  "plugin": "${PLUGIN}",
  "plugin_opts": "${PLUGIN_OPTS}"
}
EOF

  echo "==> 写入 systemd 服务: ${SERVICE_FILE}"
  cat >"${SERVICE_FILE}" <<EOF
[Unit]
Description=Shadowsocks-2022 ${SERVICE_NAME}
After=network.target

[Service]
ExecStart=/usr/local/bin/ssserver -c ${CONF}
Restart=on-failure
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}"

  IP="$(pubip)"
  ENC="$(printf "%s:%s" "${METHOD}" "${PASSWORD}" | b64_inline)"
  PLUGIN_QUERY="plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3D${PLUGIN_HOST}"
  SS_PLUGIN="ss://${ENC}@${IP}:${PORT}?${PLUGIN_QUERY}#${HOSTNAME_DISPLAY}"
  SS_RAW="ss://${ENC}@${IP}:${PORT}#${HOSTNAME_DISPLAY}"

  echo
  echo "========================================"
  echo "🎉 安装完成！"
  echo "服务器: ${IP}"
  echo "端口  : ${PORT}"
  echo "加密  : ${METHOD}"
  echo "插件伪装 host: ${PLUGIN_HOST}"
  echo "配置文件：${CONF}"
  echo "systemd 服务：${SERVICE_NAME}"
  echo "========================================"
  echo
  echo "带插件节点："
  echo "${SS_PLUGIN}"
  echo
  echo "不带插件节点："
  echo "${SS_RAW}"
  echo

  if has qrencode; then
    echo "==== 二维码（终端展示 - 带插件的 ss:// 链接） ===="
    echo -n "${SS_PLUGIN}" | qrencode -t ANSIUTF8 || true
    echo "============================================"
    echo
  else
    echo "未检测到 qrencode，无法在终端展示二维码。"
  fi

  cat >"${ENVFILE}" <<EOF
SS2022_IP="${IP}"
SS2022_PORT="${PORT}"
SS2022_METHOD="${METHOD}"
SS2022_PASSWORD="${PASSWORD}"
SS2022_PLUGIN_HOST="${PLUGIN_HOST}"
SS2022_SS_PLUGIN="${SS_PLUGIN}"
SS2022_SS_RAW="${SS_RAW}"
EOF

  echo "提示：如需再次展示二维码，可运行: sudo bash $0 show-qr"
  echo "提示：查看日志: journalctl -u ${SERVICE_NAME} -f"
}

# ---------------- service helpers ----------------
do_start(){ need_root; systemctl start "${SERVICE_NAME}"; systemctl status --no-pager "${SERVICE_NAME}" || true; }
do_stop(){ need_root; systemctl stop "${SERVICE_NAME}"; systemctl status --no-pager "${SERVICE_NAME}" || true; }
do_restart(){ need_root; systemctl restart "${SERVICE_NAME}"; systemctl status --no-pager "${SERVICE_NAME}" || true; }
do_status(){ need_root; systemctl status "${SERVICE_NAME}" --no-pager || true; }
do_log(){ need_root; echo "---- 最近 200 行日志 ----"; journalctl -u "${SERVICE_NAME}" -n 200 --no-pager; }

# ---------------- show QR ----------------
load_env_if_exists(){
  if [ -f "${ENVFILE}" ]; then
    # shellcheck disable=SC1090
    source "${ENVFILE}"
    return 0
  else
    return 1
  fi
}

do_show_qr(){
  need_root
  if ! load_env_if_exists; then
    echo "未检测到安装信息 (${ENVFILE})，请先安装。"; exit 1
  fi
  echo
  echo "节点信息："
  echo " 带插件: ${SS2022_SS_PLUGIN}"
  echo " 不带插件: ${SS2022_SS_RAW}"
  echo
  if has qrencode; then
    echo "==== 二维码（终端展示 - 带插件） ===="
    echo -n "${SS2022_SS_PLUGIN}" | qrencode -t ANSIUTF8 || true
    echo "=================================="
  else
    echo "未检测到 qrencode，无法生成二维码。"
  fi
}

# ---------------- uninstall ----------------
do_uninstall(){
  need_root
  detect_pm

  echo "== 卸载 Shadowsocks-2022 (${SERVICE_NAME}) =="
  read -rp "确认卸载 Shadowsocks 服务？[y/N]: " OK
  [[ ! "${OK:-N}" =~ ^[Yy]$ ]] && { echo "已取消卸载"; exit 0; }

  echo "== 停止并删除服务 =="
  systemctl disable --now "${SERVICE_NAME}" 2>/dev/null || true
  rm -f "${SERVICE_FILE}"
  systemctl daemon-reload

  echo "== 删除 Shadowsocks 配置文件 =="
  rm -f "${CONF}"
  rm -f "${ENVFILE}"

  echo "== 删除 Shadowsocks-Rust 二进制文件 (仅当没有其他实例需要时) =="
  # only remove binary if no other ss2022_* service files exist
  if [ -z "$(ls /etc/systemd/system/ss2022_*.service 2>/dev/null || true)" ]; then
    rm -f /usr/local/bin/ssserver
  else
    echo "检测到其他 ss2022_* 实例，保留 ssserver 二进制。"
  fi

  echo
  echo "是否删除已安装依赖(simple-obfs / qrencode)？"
  echo "1) 删除依赖"
  echo "2) 保留依赖"
  read -rp "请选择 [1-2]: " CHOICE

  case "${CHOICE}" in
    1)
      echo "== 删除依赖 =="
      if [ "${PM}" = "apt" ]; then
        apt purge -y simple-obfs qrencode || true
        apt autoremove -y || true
      else
        yum remove -y simple-obfs qrencode || true
        yum autoremove -y || true
      fi
      ;;
    2)
      echo "依赖已保留。"
      ;;
    *)
      echo "无效选择，默认保留依赖。"
      ;;
  esac

  echo "== 卸载完成！ =="
}

# ---------------- interactive menu ----------------
show_menu(){
cat <<'MENU'
Shadowsocks-2022 管理面板
1) 安装
2) 启动
3) 停止
4) 重启
5) 状态
6) 查看日志
7) 展示二维码（终端）
8) 卸载
0) 退出
MENU
  read -rp "请选择 [0-8]: " CH
  case "${CH}" in
    1) do_install ;;
    2) do_start ;;
    3) do_stop ;;
    4) do_restart ;;
    5) do_status ;;
    6) do_log ;;
    7) do_show_qr ;;
    8) do_uninstall ;;
    0) exit 0 ;;
    *) echo "无效选项"; exit 1 ;;
  esac
}

# ---------------- entry ----------------
CMD="${1:-menu}"
case "${CMD}" in
  install) do_install ;;
  start) do_start ;;
  stop) do_stop ;;
  restart) do_restart ;;
  status) do_status ;;
  log) do_log ;;
  show-qr) do_show_qr ;;
  uninstall) do_uninstall ;;
  menu) show_menu ;;
  "") show_menu ;;
  *) echo "用法: sudo bash $0 [install|start|stop|restart|status|log|show-qr|uninstall|menu]"; exit 1 ;;
esac
