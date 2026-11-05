#!/usr/bin/env bash
# ============================================================
# docker-motionpro-cufe 交互式配置与管理脚本
#
# 功能:
#   - 环境自检(Docker / Compose / /dev/net/tun)
#   - 交互式生成 .env 配置(密码隐藏输入、二次确认)
#   - 启动服务并等待 VPN 连接,自动测试代理连通性
#   - 查看状态 / 日志、安全加固(仅本机监听)、启停管理
#
# 用法:
#   bash setup.sh          # 进入交互式菜单(首次自动进入配置向导)
#   bash setup.sh <命令>    # 直接执行子命令,见 setup.sh help
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE=".env"
COMPOSE_FILE="docker-compose.yaml"
CONTAINER_NAME="motionpro"
PROXY_PORT="10801"
DEFAULT_VPN_HOST="vpn6.cufe.edu.cn"
PROXY_TEST_URL="https://authserver.cufe.edu.cn/authserver/login"

# ---------- 彩色输出 ----------
if [ -t 1 ]; then
    C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_BLUE=$'\033[36m'; C_RESET=$'\033[0m'
else
    C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""; C_RESET=""
fi

info() { echo "${C_BLUE}[信息]${C_RESET} $*"; }
ok()   { echo "${C_GREEN}[成功]${C_RESET} $*"; }
warn() { echo "${C_YELLOW}[警告]${C_RESET} $*"; }
err()  { echo "${C_RED}[错误]${C_RESET} $*"; }

pause() {
    echo
    read -r -p "按回车键返回菜单..." _
}

# ---------- 环境自检 ----------
check_env() {
    local failed=0

    echo "======== 环境自检 ========"
    if command -v docker >/dev/null 2>&1; then
        ok "已安装 Docker: $(docker --version 2>/dev/null | head -n1)"
    else
        err "未安装 Docker,请先安装: https://docs.docker.com/engine/install/"
        failed=1
    fi

    if docker compose version >/dev/null 2>&1; then
        ok "已安装 Docker Compose: $(docker compose version --short 2>/dev/null || echo 'v2')"
    else
        err "未安装 Docker Compose 插件(docker compose 命令不可用)"
        failed=1
    fi

    if [ -e /dev/net/tun ]; then
        ok "检测到 /dev/net/tun"
    else
        warn "未找到 /dev/net/tun,可尝试执行: sudo modprobe tun"
        failed=1
    fi

    if [ -f "$COMPOSE_FILE" ]; then
        ok "找到 $COMPOSE_FILE"
    else
        err "当前目录缺少 $COMPOSE_FILE,请在项目根目录运行本脚本"
        failed=1
    fi

    echo
    if [ "$failed" -eq 0 ]; then
        ok "环境检查全部通过"
    else
        err "环境检查未通过,请先解决以上问题"
    fi
    return $failed
}

# ---------- .env 值转义(单引号包裹,保证特殊字符安全) ----------
env_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# ---------- 配置向导 ----------
configure() {
    local old_host="" old_user=""

    if [ -f "$ENV_FILE" ]; then
        old_host="$(grep -E '^VPN_HOST=' "$ENV_FILE" | tail -n1 | cut -d= -f2- | tr -d "'" || true)"
        old_user="$(grep -E '^VPN_USER=' "$ENV_FILE" | tail -n1 | cut -d= -f2- | tr -d "'" || true)"
        echo
        warn "已存在配置文件 $ENV_FILE"
        read -r -p "是否重新配置?[y/N] " ans
        case "$ans" in
            y|Y) ;;
            *) info "已取消,保留原配置"; return 0 ;;
        esac
    fi

    echo
    echo "======== 校园 VPN 配置向导 ========"
    info "请准备好你的校园 VPN 账号(通常与信息门户账号相同)"
    echo

    local in_host host in_user user pass1 pass2

    read -r -p "1/3 VPN 网关地址 [默认: ${DEFAULT_VPN_HOST}]: " in_host
    host="${in_host:-${old_host:-$DEFAULT_VPN_HOST}}"

    while :; do
        read -r -p "2/3 用户名/学号: " in_user
        if [ -n "$in_user" ]; then
            user="$in_user"
            break
        fi
        err "用户名不能为空,请重新输入"
    done

    while :; do
        read -r -s -p "3/3 密码(输入不会回显): " pass1
        echo
        read -r -s -p "    请再次输入密码确认: " pass2
        echo
        if [ -z "$pass1" ]; then
            err "密码不能为空,请重新输入"
        elif [ "$pass1" != "$pass2" ]; then
            err "两次输入的密码不一致,请重新输入"
        else
            break
        fi
    done

    {
        printf '# docker-motionpro-cufe 配置文件(由 setup.sh 生成,请勿提交到 git)\n'
        printf 'VPN_HOST=%s\n'   "$(env_quote "$host")"
        printf 'VPN_USER=%s\n'   "$(env_quote "$user")"
        printf 'VPN_PASSWD=%s\n' "$(env_quote "$pass1")"
    } > "$ENV_FILE"
    chmod 600 "$ENV_FILE"

    echo
    ok "配置已写入 $ENV_FILE(文件权限已设为 600,密码不回显、不入库)"
    echo "     网关: $host"
    echo "     用户: $user"
    echo "     密码: ********"

    echo
    read -r -p "是否立即启动 VPN 服务?[Y/n] " ans
    case "$ans" in
        n|N) info "可稍后运行 $0 start 启动" ;;
        *) start ;;
    esac
}

# ---------- 端口占用检查 ----------
check_port() {
    if command -v ss >/dev/null 2>&1; then
        if ss -ltn 2>/dev/null | grep -q ":${PROXY_PORT} "; then
            warn "宿主机端口 ${PROXY_PORT} 已被监听(若非本项目容器,启动后端口映射会失败)"
        fi
    fi
}

# ---------- 等待 VPN 连接 ----------
wait_vpn() {
    info "等待 VPN 建立连接(最长 120 秒)..."
    local i=0 st
    while [ "$i" -lt 120 ]; do
        st="$(docker exec "$CONTAINER_NAME" MotionPro -a 2>/dev/null || true)"
        if [ "$st" = "VPN Status: connected" ]; then
            echo
            ok "VPN 已连接!"
            test_proxy
            return 0
        fi
        printf "\r  已等待 %3d 秒,当前状态: %s    " "$i" "${st:-容器未就绪}"
        sleep 3
        i=$((i + 3))
    done
    echo
    err "等待超时,VPN 未能建立连接"
    info "常见原因: 账号或密码错误 / 网络无法访问 VPN 网关 / 在线设备数超限"
    info "请查看日志排查: $0 logs (或 docker compose logs -f)"
    return 1
}

# ---------- 启动 ----------
start() {
    if [ ! -f "$ENV_FILE" ]; then
        warn "尚未生成 $ENV_FILE,先进入配置向导"
        configure
        if [ ! -f "$ENV_FILE" ]; then
            err "未完成配置,已取消启动"
            return 1
        fi
    fi

    check_port
    info "启动容器(首次运行需要拉取镜像,可能较慢)..."
    if ! docker compose up -d; then
        err "启动失败,请检查上方错误信息(常见: 镜像拉取失败、端口被占用)"
        return 1
    fi
    wait_vpn
}

# ---------- 停止 ----------
stop() {
    info "停止并移除容器..."
    docker compose down
    ok "服务已停止"
}

# ---------- 状态 ----------
status() {
    echo "======== 容器状态 ========"
    docker compose ps
    echo
    local st
    st="$(docker exec "$CONTAINER_NAME" MotionPro -a 2>/dev/null || true)"
    if [ -n "$st" ]; then
        echo "VPN 状态: $st"
    else
        echo "VPN 状态: (容器未运行)"
    fi
}

# ---------- 代理连通性测试 ----------
test_proxy() {
    if ! command -v curl >/dev/null 2>&1; then
        warn "宿主机未安装 curl,跳过连通性测试"
        return 0
    fi
    info "通过 SOCKS5 代理(127.0.0.1:${PROXY_PORT})访问: ${PROXY_TEST_URL}"
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' \
        --socks5-hostname "127.0.0.1:${PROXY_PORT}" \
        --connect-timeout 15 "$PROXY_TEST_URL" || true)"
    if [ "$code" = "200" ]; then
        ok "代理可用!校园网认证服务返回 HTTP 200"
        info "代理地址: socks5://127.0.0.1:${PROXY_PORT}"
    else
        warn "测试未通过(HTTP 状态: ${code:-无响应})"
        info "VPN 可能仍在连接中,可稍后手动重测:"
        info "  curl --socks5-hostname 127.0.0.1:${PROXY_PORT} -I ${PROXY_TEST_URL}"
    fi
}

# ---------- 安全加固:仅本机监听 ----------
security() {
    local f="$COMPOSE_FILE"
    if grep -q "127.0.0.1:${PROXY_PORT}:1080" "$f"; then
        warn "当前代理已限制为仅本机可访问"
        read -r -p "是否恢复为所有网卡可访问(局域网内其他设备也能使用)?[y/N] " ans
        case "$ans" in
            y|Y)
                sed -i "s|- 127.0.0.1:${PROXY_PORT}:1080|- ${PROXY_PORT}:1080|" "$f"
                warn "已恢复为监听所有网卡"
                ;;
            *) return 0 ;;
        esac
    elif grep -q -- "- ${PROXY_PORT}:1080" "$f"; then
        echo
        warn "当前代理监听所有网卡,局域网内任何设备都可以使用你的 VPN 代理"
        read -r -p "是否限制为仅本机(127.0.0.1)可访问?推荐 [Y/n] " ans
        case "$ans" in
            n|N) return 0 ;;
        esac
        sed -i.bak "s|- ${PROXY_PORT}:1080|- 127.0.0.1:${PROXY_PORT}:1080|" "$f"
        ok "已限制为仅本机访问(原文件备份为 ${f}.bak)"
    else
        warn "未能在 $f 中找到端口映射配置,请手动检查"
        return 0
    fi

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
        read -r -p "容器正在运行,是否立即重建使其生效?[Y/n] " ans
        case "$ans" in
            n|N) info "可稍后运行 $0 restart 使其生效" ;;
            *) stop; start ;;
        esac
    fi
}

# ---------- 日志 ----------
logs() {
    docker compose logs -f --tail=100
}

# ---------- 菜单 ----------
menu() {
    while :; do
        echo
        echo "========= docker-motionpro-cufe 管理菜单 ========="
        echo "  1) 环境自检"
        echo "  2) 配置账号(生成/修改 .env)"
        echo "  3) 启动 VPN 服务"
        echo "  4) 查看状态"
        echo "  5) 查看日志(实时,Ctrl+C 退出)"
        echo "  6) 测试代理连通性"
        echo "  7) 安全设置(代理仅本机可访问)"
        echo "  8) 重启服务"
        echo "  9) 停止服务"
        echo "  0) 退出"
        read -r -p "请选择: " choice
        case "$choice" in
            1) check_env || true; pause ;;
            2) configure; pause ;;
            3) start; pause ;;
            4) status; pause ;;
            5) logs ;;
            6) test_proxy; pause ;;
            7) security; pause ;;
            8) stop; start; pause ;;
            9) stop; pause ;;
            0) echo "再见!"; exit 0 ;;
            *) err "无效选择,请输入 0-9" ;;
        esac
    done
}

# ---------- 帮助 ----------
usage() {
    cat <<EOF
docker-motionpro-cufe 交互式配置与管理脚本

用法:
  $0              进入交互式菜单(首次运行自动进入配置向导)
  $0 <命令>       直接执行子命令

可用命令:
  config     配置账号(生成/修改 .env)
  start      启动服务并等待 VPN 连接
  stop       停止服务
  restart    重启服务
  status     查看容器与 VPN 状态
  logs       查看实时日志
  test       测试代理连通性
  security   切换"仅本机可访问代理"开关
  help       显示本帮助
EOF
}

# ---------- 入口 ----------
case "${1:-}" in
    "")
        echo "docker-motionpro-cufe 交互式配置脚本"
        if [ ! -f "$ENV_FILE" ]; then
            warn "检测到首次使用,先进行环境自检和账号配置"
            check_env || true
            configure
            menu
        else
            menu
        fi
        ;;
    config)   configure ;;
    start)    start ;;
    stop)     stop ;;
    restart)  stop; start ;;
    status)   status ;;
    logs)     logs ;;
    test)     test_proxy ;;
    security) security ;;
    help|-h|--help) usage ;;
    *)
        err "未知命令: $1"
        usage
        exit 1
        ;;
esac
