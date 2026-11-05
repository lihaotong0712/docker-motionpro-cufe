#!/usr/bin/env bash
# =============================================================
#  CUFE VPN 管理 TUI(gum / whiptail / 纯文本 三级自适应)
#
#  功能:
#    1) 新建/修改配置(无配置=新建;有配置=先展示现有账号密码再询问修改)
#    2) 启动 VPN 服务容器
#    3) 停止 VPN 服务容器
#    4) 查看容器日志
#    5) 校园网资源连通性测试
#    6) 生成 Clash 全局扩展脚本(存文件 + 尽力复制剪贴板)
#
#  用法:
#    ./cufe-tui.sh           交互式 TUI
#    ./cufe-tui.sh config    新建/修改配置
#    ./cufe-tui.sh start     启动
#    ./cufe-tui.sh stop      停止
#    ./cufe-tui.sh logs      日志
#    ./cufe-tui.sh test      连通性测试
#    ./cufe-tui.sh gen       生成脚本(存文件+尝试剪贴板)
#    ./cufe-tui.sh gen-preview  仅打印生成的脚本,不写盘
# =============================================================

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR" || exit 1

CONTAINER="motionpro"
PROXY_PORT="10801"
ENV_FILE=".env"
DEFAULT_VPN_HOST="vpn6.cufe.edu.cn"

VERGE_DIR="${HOME}/.local/share/io.github.clash-verge-rev.clash-verge-rev"
SCRIPT_JS="${VERGE_DIR}/profiles/Script.js"
MIHOMO_SOCK="$(ls /run/clash-verge-service/users/*/verge-mihomo.sock 2>/dev/null | head -1)"
[ -z "${MIHOMO_SOCK}" ] && MIHOMO_SOCK="${VERGE_DIR}/verge-mihomo.sock"

# ---------- UI 框架探测:gum 优先,whiptail 兜底,最后纯文本 ----------
GUM_BIN="$(command -v gum 2>/dev/null || true)"
[ -z "$GUM_BIN" ] && [ -x "$HOME/.local/bin/gum" ] && GUM_BIN="$HOME/.local/bin/gum"

UI="plain"
if [ -n "$GUM_BIN" ] && [ -t 1 ]; then
  UI="gum"
elif command -v whiptail >/dev/null 2>&1 && [ -t 1 ]; then
  UI="whiptail"
fi

C_G=$'\033[32m'; C_R=$'\033[31m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_N=$'\033[0m'
[ -t 1 ] || { C_G=""; C_R=""; C_Y=""; C_B=""; C_N=""; }
ok()   { echo "${C_G}[✓]${C_N} $*"; }
bad()  { echo "${C_R}[✗]${C_N} $*"; }
warn() { echo "${C_Y}[!]${C_N} $*"; }
info() { echo "${C_B}[i]${C_N} $*"; }

ANSI_RE=$'\x1b\[[0-9;]*m'
strip_ansi() { sed "s|${ANSI_RE}||g"; }

# ---------- UI 基元 ----------
api() {
  [ -S "${MIHOMO_SOCK}" ] || return 0
  curl -s --max-time 4 --unix-socket "${MIHOMO_SOCK}" "http://localhost$1" 2>/dev/null || true
}

# ui_menu <标题> <选项...>:结果存入 MENU_IDX(1 基,0=取消)
MENU_IDX=0
ui_menu() {
  local title="$1"; shift
  local labels=("$@") i sel
  MENU_IDX=0
  case "$UI" in
    gum)
      clear
      "$GUM_BIN" style --foreground 212 --bold "$title"
      # gum v2: 界面渲染到 stderr,选择结果输出到 stdout —— 不可压制 stderr
      sel=$("$GUM_BIN" choose "${labels[@]}") || return 0
      for i in "${!labels[@]}"; do
        [ "${labels[$i]}" = "$sel" ] && MENU_IDX=$((i + 1))
      done
      ;;
    whiptail)
      local args=()
      for i in "${!labels[@]}"; do args+=("$((i + 1))" "${labels[$i]}"); done
      sel=$(whiptail --title "$title" --menu "选择操作" 20 70 10 "${args[@]}" 3>&1 1>&2 2>&3) || return 0
      MENU_IDX="$sel"
      ;;
    *)
      echo "── $title ──"
      for i in "${!labels[@]}"; do echo "  $((i + 1))) ${labels[$i]}"; done
      read -r -p "请选择: " sel
      [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#labels[@]}" ] && MENU_IDX="$sel"
      ;;
  esac
}

# ui_msg <标题> <文本>:展示长文本(gum 用 pager,whiptail 剥离 ANSI 后弹窗)
ui_msg() {
  local title="$1" text="$2"
  case "$UI" in
    gum)      printf '%s' "$text" | "$GUM_BIN" pager ;;
    whiptail) whiptail --scrolltext --title "$title" --msgbox "$(printf '%s' "$text" | strip_ansi)" 28 88 2>/dev/null || true ;;
    *)        printf '%s\n' "$text" ;;
  esac
}

ui_confirm() {
  local text="$1"
  case "$UI" in
    gum)      "$GUM_BIN" confirm "$text" ;;
    whiptail) whiptail --yesno "$text" 10 54 3>&1 1>&2 2>&3 ;;
    *)        local a; read -r -p "$text [y/N]: " a; [ "$a" = y ] || [ "$a" = Y ] ;;
  esac
}

press_enter() {
  read -r -p "按回车返回菜单..." _
  [ "$UI" != plain ] && clear
}

menu_header() {
  local vs s
  vs=$(vpn_status)
  case "$vs" in
    "VPN Status: connected") s="VPN 已连接" ;;
    *) s="${vs:-VPN 未运行}" ;;
  esac
  echo "CUFE VPN 管理台 [$s]"
}

# ---------- 基础探测 ----------
container_state() {
  local s
  s=$(docker ps -a --filter "name=^/${CONTAINER}$" --format '{{.Status}}' 2>/dev/null)
  [ -n "$s" ] && echo "$s" || echo "(不存在)"
}

vpn_status() {
  docker exec "$CONTAINER" MotionPro -a 2>/dev/null || echo "(容器未运行)"
}

env_get() {
  [ -f "$ENV_FILE" ] || return 0
  grep -E "^$1=" "$ENV_FILE" | tail -n1 | cut -d= -f2- | tr -d "'" | tr -d '"'
}

env_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

kernel_nodes() {
  api /proxies | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)["proxies"]
    print(",".join(sorted(k for k in d if "CUFE" in k)))
except Exception:
    print("")'
}

# =============================================================
# 功能 1:新建/修改配置(单屏表单:学号 + 密码)
# =============================================================
action_config() {
  local old_host old_user old_pass user p1 have_old=0 ans
  [ -f "$ENV_FILE" ] && have_old=1
  old_host="$(env_get VPN_HOST)"; [ -z "$old_host" ] && old_host="$DEFAULT_VPN_HOST"
  old_user="$(env_get VPN_USER)"
  old_pass="$(env_get VPN_PASSWD)"

  [ "$UI" != plain ] && clear
  if [ "$have_old" -eq 1 ]; then
    echo "── 当前配置 ──"
    echo "  网关: $old_host"
    echo "  学号: $old_user"
    echo "  密码: $old_pass"
    echo
    if ! ui_confirm "是否修改以上配置?"; then
      info "已取消,保留原配置"
      return 0
    fi
    echo "── 修改配置(网关固定: ${old_host})──"
  else
    echo "── 新建配置(网关固定: ${old_host})──"
  fi
  while :; do
    read -r -e -p "学号: " -i "${old_user}" user
    read -r -p "密码: " p1
    [ -n "$user" ] && [ -n "$p1" ] && break
    bad "学号和密码都不能为空"
  done

  {
    printf '# docker-motionpro-cufe 配置文件(请勿提交到 git)\n'
    printf 'VPN_HOST=%s\n'   "$(env_quote "$old_host")"
    printf 'VPN_USER=%s\n'   "$(env_quote "$user")"
    printf 'VPN_PASSWD=%s\n' "$(env_quote "$p1")"
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  ok "配置已写入 $ENV_FILE(网关 ${old_host},学号 ${user})"

  if [ "$have_old" -eq 1 ] && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
    if ui_confirm "配置已更新,是否重启容器使其生效?"; then
      action_start
    fi
  else
    info "可执行「启动 VPN 服务容器」开始连接"
  fi
}

# =============================================================
# 功能 2/3:启动 / 停止
# =============================================================
action_start() {
  if [ ! -f "$ENV_FILE" ]; then
    warn "尚未配置账号,请先执行「新建/修改配置」"
    return 1
  fi
  info "启动容器..."
  if [ "$UI" = gum ]; then
    # spin 界面在 stderr,compose 输出在子 shell 内静音
    "$GUM_BIN" spin --title " 拉取镜像并启动..." -- bash -c "docker compose up -d >/dev/null 2>&1" || true
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER" || { bad "启动失败"; return 1; }
  else
    if ! docker compose up -d >/dev/null 2>&1; then
      bad "启动失败,请手动执行 docker compose up -d 查看报错"
      return 1
    fi
  fi
  local waited=0 st final
  while [ "$waited" -lt 120 ]; do
    st=$(vpn_status)
    [ "$st" = "VPN Status: connected" ] && break
    printf "\r  等待 %3ds: %s    " "$waited" "${st:-容器未就绪}"
    sleep 3; waited=$((waited + 3))
  done
  echo
  final=$(vpn_status)
  if [ "$final" = "VPN Status: connected" ]; then
    ok "VPN 已连接,SOCKS5 代理: 127.0.0.1:${PROXY_PORT}"
  else
    bad "VPN 未连接($final),请用「查看容器日志」排查"
  fi
}

action_stop() {
  docker compose down && ok "VPN 服务容器已停止"
}

# =============================================================
# 功能 4:日志
# =============================================================
action_logs() {
  [ "$UI" != plain ] && clear
  echo "── 查看容器实时日志 ──"
  echo
  echo "  · 确认后日志将持续滚动跟随"
  echo "  · 按 Ctrl+C 停止日志跟随"
  echo "  · 停止后按回车键返回菜单"
  echo
  if ! ui_confirm "确认开始查看日志?"; then
    [ "$UI" != plain ] && clear
    info "已取消,返回菜单"
    return 0
  fi
  [ "$UI" != plain ] && clear
  trap '' INT
  docker compose logs -f --tail=50
  trap - INT
  echo
  read -r -p "日志已停止,按回车键返回菜单..." _
  [ "$UI" != plain ] && clear
}

# =============================================================
# 功能 5:校园网资源连通性测试
# =============================================================
action_test() {
  local out="" code u expect desc rest t nodes cs vs
  cs=$(container_state); vs=$(vpn_status)
  out+="── 基础状态 ──"$'\n'
  out+="容器: ${cs}"$'\n'"VPN : ${vs}"$'\n'
  nodes=$(kernel_nodes)
  if [ -n "$nodes" ]; then
    out+="Clash 内核: CUFE 节点已加载($nodes)"$'\n'
  else
    out+="Clash 内核: CUFE 节点未加载(需重新激活订阅)"$'\n'
  fi
  out+=$'\n'"── SOCKS5 直测(127.0.0.1:${PROXY_PORT} → danted → VPN)──"$'\n'
  code=$(curl -sk -o /dev/null -m 12 -w '%{http_code}' --socks5-hostname "127.0.0.1:${PROXY_PORT}" \
      "https://authserver.cufe.edu.cn/authserver/login" 2>/dev/null)
  if [ "$code" = "200" ]; then out+="$(ok "统一身份认证经代理: $code")"$'\n'
  else out+="$(bad "统一身份认证经代理: ${code:-超时}")"$'\n'; fi

  out+=$'\n'"── TUN 端到端(Clash 分流,模拟浏览器)──"$'\n'
  for t in \
    "http://10.13.66.23/|302|校内 Web 服务(10 网段)" \
    "https://authserver.cufe.edu.cn/authserver/login|200|统一身份认证" \
    "http://kjgllib.cufe.edu.cn/|200|脚本健康检查页"; do
    u="${t%%|*}"; rest="${t#*|}"; expect="${rest%%|*}"; desc="${rest##*|}"
    code=$(curl -sk -o /dev/null -m 12 -w '%{http_code}' "$u" 2>/dev/null)
    if [ "$code" = "$expect" ]; then
      out+="$(ok "[$desc] ${code}")"$'\n'
    else
      out+="$(bad "[$desc] ${code:-超时}(期望 $expect)")"$'\n'
    fi
  done

  out+=$'\n'"── 局域网豁免 ──"$'\n'
  if timeout 3 bash -c 'echo > /dev/tcp/192.168.0.1/80' 2>/dev/null; then
    out+="$(ok "网关 192.168.0.1 直连可达")"$'\n'
  else
    out+="$(warn "网关 192.168.0.1:80 不通(网关未开管理页则属正常)")"$'\n'
  fi

  printf '%s' "$out"
}

# =============================================================
# 功能 6:生成 Clash 全局扩展脚本
# =============================================================
env_quote_gen() { env_quote "$1"; }

build_gen_script() {
  local vpn_host login_host login_ip health_url port ip
  vpn_host="$(env_get VPN_HOST)"; [ -z "$vpn_host" ] && vpn_host="$DEFAULT_VPN_HOST"
  login_host="net.cufe.edu.cn"; login_ip="10.13.13.2"
  health_url="http://kjgllib.cufe.edu.cn/"; port="$PROXY_PORT"

  # 本机 DNS 可能被 Clash fake-ip 接管(返回 198.18.x.x),用 DoH 直查真实 A 记录
  ip=$(curl -s -m 8 "https://dns.alidns.com/resolve?name=${vpn_host}&type=A" 2>/dev/null | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
    ans=[a["data"] for a in d.get("Answer",[]) if a.get("type")==1]
    print(ans[0] if ans else "")
except Exception:
    print("")')
  if [ -z "$ip" ]; then
    ip=$(getent ahostsv4 "$vpn_host" 2>/dev/null | awk '{print $1}' | grep -v "^198\.18\." | head -1)
  fi
  if [ -z "$ip" ]; then
    ip="123.124.19.49"
    warn "网关解析失败,使用已知入口 IP ${ip}"
  fi

  GEN_SCRIPT=$(cat <<EOF
// CUFE VPN 分流脚本(由 cufe-tui.sh 生成 $(date '+%Y-%m-%d %H:%M'))
// 策略: 校园域名/10 网段优先走本机 VPN SOCKS5,VPN 掉线自动回退直连

function main(config) {
  const name = "CUFE-SOCKS5";
  const auto = "CUFE-AUTO";

  config.profile = { ...(config.profile || {}), "store-selected": true };
  config.proxies = (config.proxies || []).filter((p) => p.name !== name);
  config["proxy-providers"] = {
    ...(config["proxy-providers"] || {}),
    "CUFE-VPN-SOURCE": {
      type: "inline",
      payload: [
        { name, type: "socks5", server: "127.0.0.1", port: ${port}, udp: true },
      ],
      "health-check": {
        enable: true,
        url: "${health_url}",
        interval: 10,
        timeout: 2000,
        lazy: false,
        "expected-status": 200,
      },
    },
    "CUFE-DIRECT-SOURCE": {
      type: "inline",
      payload: [{ name: "CUFE-DIRECT", type: "direct" }],
      "health-check": { enable: false },
    },
  };
  config["proxy-groups"] = [
    {
      name: auto,
      type: "fallback",
      use: ["CUFE-VPN-SOURCE", "CUFE-DIRECT-SOURCE"],
      // 不填 url: 继承 VPN 集合的探测地址,直连集合免探测。
      timeout: 2000,
      "max-failed-times": 1,
    },
    ...(config["proxy-groups"] || []).filter((g) => g.name !== auto),
  ];

  // 校园 Wi-Fi 登录页与 VPN 入口写死 hosts,避免登录前依赖 VPN 解析。
  config.hosts = { ...(config.hosts || {}), "${login_host}": "${login_ip}" };
  const dns = config.dns || (config.dns = {});
  dns["use-hosts"] = true;
  // 校园域名使用校园 DNS,查询随自动组走 VPN 或回退直连。
  const publicDns = [
    "https://dns.alidns.com/dns-query#DIRECT",
    "https://doh.pub/dns-query#DIRECT",
  ];
  dns["nameserver-policy"] = {
    ...(dns["nameserver-policy"] || {}),
    "+.cufe.edu.cn": [
      "tcp://202.205.208.6:53#" + auto,
      "tcp://202.205.208.5:53#" + auto,
    ],
    // VPN 入口必须独立于校园 VPN 解析,避免回环。
    "${vpn_host}": publicDns,
  };
  if (!dns["proxy-server-nameserver"] || !dns["proxy-server-nameserver"].length) {
    dns["proxy-server-nameserver"] = publicDns;
  }

  const rules = [
    "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
    "IP-CIDR6,::1/128,DIRECT,no-resolve",

    // 校园 Wi-Fi 登录页、VPN 入口直连。
    "DOMAIN,${login_host},DIRECT",
    "IP-CIDR,${login_ip}/32,DIRECT,no-resolve",
    "DOMAIN,${vpn_host},DIRECT",
    "IP-CIDR,${ip}/32,DIRECT,no-resolve",

    // 校园域名和 10 网段优先 VPN,不可用时直连。
    "DOMAIN-SUFFIX,cufe.edu.cn,CUFE-AUTO",
    "IP-CIDR,10.0.0.0/8,CUFE-AUTO",

    // 私有网段直连;172 网段已包含本机 Docker 网络。
    "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
    "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
    "IP-CIDR6,fc00::/7,DIRECT,no-resolve",
  ];

  const managed = new Set(rules);
  config.rules = rules.concat(
    (config.rules || []).filter(
      (r) => !managed.has(r) && ![name, auto].includes(r.split(",")[2])
    )
  );
  return config;
}
EOF
) || return 1
  return 0
}

action_gen() {
  info "收集参数并生成脚本..."
  build_gen_script || return 1

  # 保存到固定文件
  local out_file="$REPO_DIR/generated-clash-script.js"
  printf '%s\n' "$GEN_SCRIPT" > "$out_file"

  # 自动用文本编辑器打开生成的文件
  local ed="${EDITOR:-}" c
  if [ -z "$ed" ]; then
    for c in nano vim vi; do
      command -v "$c" >/dev/null 2>&1 && { ed="$c"; break; }
    done
  fi
  if [ -n "$ed" ]; then
    [ "$UI" != plain ] && clear
    info "正在用 $ed 打开生成的脚本,编辑保存后退出编辑器继续..."
    "$ed" "$out_file" || true
    [ "$UI" != plain ] && clear
  else
    warn "未找到文本编辑器(可设置 \$EDITOR 或安装 nano),文件在: $out_file"
  fi

  # 编辑器关闭后读取最终内容进剪贴板(覆盖用户可能在编辑器中的修改)
  local content clip
  content="$(cat "$out_file")"
  clip="未安装剪贴板工具(可 sudo apt install xclip 或 wl-clipboard),请从文件复制"
  if command -v wl-copy >/dev/null 2>&1; then
    printf '%s' "$content" | wl-copy && clip="已通过 wl-copy 复制 ✓"
  elif command -v xclip >/dev/null 2>&1; then
    printf '%s' "$content" | xclip -selection clipboard && clip="已通过 xclip 复制 ✓"
  elif command -v xsel >/dev/null 2>&1; then
    printf '%s' "$content" | xsel --clipboard && clip="已通过 xsel 复制 ✓"
  fi

  ui_msg "Clash 全局扩展脚本已生成" "脚本共 $(wc -l < "$out_file") 行
文件位置: $out_file
剪贴板  : $clip

使用步骤:
1. 打开 Clash Verge → 订阅页 → 全局扩展脚本(编辑)
2. 全选粘贴脚本内容(或直接打开上方文件复制),保存
3. 重新激活订阅
4. 运行「校园网资源连通性测试」,内核出现 CUFE-AUTO 即生效"
}

# ---------- 交互菜单 ----------
menu_loop() {
  local cfg_label="新建配置"
  [ -f "$ENV_FILE" ] && cfg_label="修改配置"
  local labels=(
    "$cfg_label"
    "启动 VPN 服务容器"
    "停止 VPN 服务容器"
    "查看容器日志"
    "校园网资源连通性测试"
    "生成 Clash 全局扩展脚本"
  )
  while :; do
    ui_menu "$(menu_header)" "${labels[@]}"
    case "$MENU_IDX" in
      0) echo "再见!"; exit 0 ;;
      1) action_config;  press_enter ;;
      2) action_start;   press_enter ;;
      3) action_stop;    press_enter ;;
      4) action_logs ;;
      5) ui_msg "校园网资源连通性测试" "$(action_test)" ;;
      6) action_gen;     press_enter ;;
    esac
  done
}

# ---------- 入口 ----------
case "${1:-}" in
  "")          menu_loop ;;
  config)      action_config ;;
  start)       action_start ;;
  stop)        action_stop ;;
  logs)        action_logs ;;
  test)        action_test ;;
  gen)         action_gen ;;
  gen-preview) build_gen_script && echo "$GEN_SCRIPT" ;;
  help|-h|--help)
    grep '^#' "$0" | sed 's/^# \{0,2\}//' | tail -n +2
    ;;
  *) bad "未知命令: $1(见 ./cufe-tui.sh help)"; exit 1 ;;
esac
