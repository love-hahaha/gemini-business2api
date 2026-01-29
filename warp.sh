#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# Container-friendly Cloudflare WARP (Proxy Mode) launcher
# - No systemd required
# - No network takeover: only provides local SOCKS5
# - Command: menu.sh c
# =========================================================

VERSION="container-proxy-1.0.0"

export DEBIAN_FRONTEND=noninteractive

# ---- Config (env overridable) ----
WARP_SOCKS_PORT="${WARP_SOCKS_PORT:-40000}"
WARP_START_DELAY="${WARP_START_DELAY:-10}"          # delay before starting/connecting warp
WARP_CONNECT_RETRY="${WARP_CONNECT_RETRY:-10}"      # registration/connect retries
WARP_CONNECT_WAIT="${WARP_CONNECT_WAIT:-60}"        # wait seconds for socks5 listening
WARP_LOG_FILE="${WARP_LOG_FILE:-/var/log/warp-svc.log}"
WARP_PID_FILE="${WARP_PID_FILE:-/run/warp-svc.pid}"

# Optional: if you REALLY want a fallback reg.json (not recommended)
ALLOW_FALLBACK_REG="${ALLOW_FALLBACK_REG:-0}"

# ---- Pretty output ----
info()  { echo -e "\033[32;1m[INFO]\033[0m $*"; }
warn()  { echo -e "\033[33;1m[WARN]\033[0m $*"; }
error() { echo -e "\033[31;1m[ERR ]\033[0m $*" >&2; exit 1; }

need_root() {
  [[ "$(id -u)" == "0" ]] || error "请以 root 运行（容器里一般默认就是 root）。"
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

detect_os() {
  OS_ID="unknown"
  OS_LIKE=""
  OS_CODENAME=""
  OS_PRETTY="unknown"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"
    OS_CODENAME="${VERSION_CODENAME:-}"
    OS_PRETTY="${PRETTY_NAME:-unknown}"
  fi
  info "OS: ${OS_PRETTY}"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) error "不支持的架构: $(uname -m)（cloudflare-warp 仅常见支持 amd64/arm64）" ;;
  esac
}

apt_install_deps() {
  info "安装依赖（apt）..."
  apt-get update -y >/dev/null
  apt-get install -y --no-install-recommends \
    ca-certificates curl wget gnupg lsb-release \
    iproute2 procps net-tools openssl >/dev/null
}

apk_install_deps() {
  # Cloudflare WARP 官方不支持 Alpine 安装 cloudflare-warp 包
  info "安装依赖（apk）..."
  apk add --no-cache ca-certificates curl wget bash iproute2 procps net-tools openssl >/dev/null
}

yum_install_deps() {
  info "安装依赖（yum/dnf）..."
  (dnf -y install ca-certificates curl wget gnupg2 iproute procps-ng net-tools openssl >/dev/null 2>&1) || \
  (yum -y install ca-certificates curl wget gnupg2 iproute procps-ng net-tools openssl >/dev/null 2>&1) || true
}

install_warp_debian_ubuntu() {
  have_cmd warp-cli && have_cmd warp-svc && { info "已安装 cloudflare-warp，跳过安装"; return; }

  apt_install_deps

  # Determine codename if missing
  local codename="$OS_CODENAME"
  if [[ -z "$codename" ]]; then
    codename="$(lsb_release -sc 2>/dev/null || true)"
  fi
  [[ -n "$codename" ]] || error "无法获取系统 codename（Debian/Ubuntu），无法添加 Cloudflare 源"

  info "添加 Cloudflare WARP APT 源（codename: $codename）..."
  install -d /usr/share/keyrings /etc/apt/sources.list.d

  # Key
  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
    | gpg --dearmor --yes -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

  # Repo list
  cat >/etc/apt/sources.list.d/cloudflare-client.list <<EOF
deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${codename} main
EOF

  apt-get update -y >/dev/null
  info "安装 cloudflare-warp..."
  apt-get install -y cloudflare-warp >/dev/null

  have_cmd warp-cli && have_cmd warp-svc || error "cloudflare-warp 安装失败（未找到 warp-cli/warp-svc）"
}

install_warp_rhel_like() {
  have_cmd warp-cli && have_cmd warp-svc && { info "已安装 cloudflare-warp，跳过安装"; return; }

  yum_install_deps

  info "添加 Cloudflare WARP YUM/DNF 源..."
  if have_cmd dnf; then
    curl -fsSL https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo \
      | tee /etc/yum.repos.d/cloudflare-warp.repo >/dev/null
    dnf -y install cloudflare-warp >/dev/null
  elif have_cmd yum; then
    curl -fsSL https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo \
      | tee /etc/yum.repos.d/cloudflare-warp.repo >/dev/null
    yum -y install cloudflare-warp >/dev/null
  else
    error "未检测到 yum/dnf"
  fi

  have_cmd warp-cli && have_cmd warp-svc || error "cloudflare-warp 安装失败（未找到 warp-cli/warp-svc）"
}

install_warp() {
  detect_os
  detect_arch

  if have_cmd apt-get; then
    install_warp_debian_ubuntu
    return
  fi

  if have_cmd dnf || have_cmd yum; then
    install_warp_rhel_like
    return
  fi

  if have_cmd apk; then
    apk_install_deps
    error "检测到 Alpine（apk）。Cloudflare WARP 官方 Linux Client 通常不支持 Alpine 直接安装 cloudflare-warp 包。建议换 Debian/Ubuntu 基础镜像，或改用 wireproxy 方案。"
  fi

  error "不支持的系统/包管理器：需要 apt 或 yum/dnf"
}

ensure_runtime_dirs() {
  install -d /run/cloudflare-warp /var/lib/cloudflare-warp /var/log
  chmod 755 /run/cloudflare-warp /var/lib/cloudflare-warp /var/log
}

warp_svc_running() {
  if [[ -f "$WARP_PID_FILE" ]]; then
    local pid
    pid="$(cat "$WARP_PID_FILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1 && return 0
  fi
  pgrep -x warp-svc >/dev/null 2>&1
}

start_warp_svc_bg() {
  ensure_runtime_dirs

  if warp_svc_running; then
    info "warp-svc 已在运行"
    return
  fi

  info "启动 warp-svc（后台）..."
  # setsid is nicer, but not required
  if have_cmd setsid; then
    setsid -f warp-svc >>"$WARP_LOG_FILE" 2>&1 || true
  else
    nohup warp-svc >>"$WARP_LOG_FILE" 2>&1 &
  fi

  # record pid if possible
  local pid
  pid="$(pgrep -xo warp-svc 2>/dev/null || true)"
  [[ -n "$pid" ]] && echo "$pid" > "$WARP_PID_FILE" || true
}

stop_warp_svc() {
  if warp_svc_running; then
    warn "停止 warp-svc..."
    pkill -x warp-svc >/dev/null 2>&1 || true
    rm -f "$WARP_PID_FILE" >/dev/null 2>&1 || true
  fi
}

wait_for_socket() {
  local t=0 max=10
  while (( t < max )); do
    # warp-cli talks to /run/cloudflare-warp/warp_service
    [[ -S /run/cloudflare-warp/warp_service ]] && return 0
    sleep 1
    ((t++))
  done
  return 1
}

wait_for_socks5() {
  local t=0 max="$WARP_CONNECT_WAIT"
  while (( t < max )); do
    if ss -nltp 2>/dev/null | awk '{print $4,$NF}' | grep -qE "127\.0\.0\.1:${WARP_SOCKS_PORT}.*warp-svc"; then
      return 0
    fi
    sleep 1
    ((t++))
  done
  return 1
}

warp_cli_ready() {
  warp-cli --accept-tos status >/dev/null 2>&1
}

fallback_regjson_if_enabled() {
  [[ "$ALLOW_FALLBACK_REG" == "1" ]] || return 1

  warn "注册多次失败，启用 fallback reg.json（不推荐，仅在你明确允许时使用：ALLOW_FALLBACK_REG=1）"
  install -d /var/lib/cloudflare-warp
  cat >/var/lib/cloudflare-warp/reg.json <<'EOF'
{"registration_id":"317b5a76-3da1-469f-88d6-c3b261da9f10","api_token":"11111111-1111-1111-1111-111111111111","secret_key":"CNUysnWWJmFGTkqYtg/wpDfURUWvHB8+U1FLlVAIB0Q=","public_key":"DuOi83pAIsbJMP3CJpxq6r3LVGHtqLlzybEIvbczRjo=","override_codes":null}
EOF
  return 0
}

configure_and_connect_proxy() {
  info "延迟 ${WARP_START_DELAY}s 后再启动/连接 WARP（避免探针/依赖服务过早检测失败）..."
  sleep "$WARP_START_DELAY"

  start_warp_svc_bg

  info "等待 warp_service socket..."
  wait_for_socket || error "warp_service socket 未就绪（查看日志：$WARP_LOG_FILE）"

  # Some images need a bit more time after socket appears
  for _ in {1..5}; do
    warp_cli_ready && break
    sleep 1
  done

  info "设置为 Proxy 模式 + 端口 ${WARP_SOCKS_PORT}..."
  warp-cli --accept-tos mode proxy >/dev/null 2>&1 || true
  warp-cli --accept-tos proxy port "$WARP_SOCKS_PORT" >/dev/null 2>&1 || true

  # Registration
  local i=1
  while (( i <= WARP_CONNECT_RETRY )); do
    info "注册/连接尝试：${i}/${WARP_CONNECT_RETRY}"
    # If already registered, registration new may fail; that's okay
    warp-cli --accept-tos registration new >/dev/null 2>&1 || true
    # connect
    warp-cli --accept-tos connect >/dev/null 2>&1 || true

    if wait_for_socks5; then
      info "SOCKS5 已就绪：socks5h://127.0.0.1:${WARP_SOCKS_PORT}"
      warp-cli --accept-tos status 2>/dev/null || true
      return 0
    fi

    # try recover: disconnect + delete reg + retry
    warp-cli --accept-tos disconnect >/dev/null 2>&1 || true

    # if repeated missing registration, try delete then new
    if warp-cli --accept-tos status 2>/dev/null | grep -qi "Registration"; then
      warp-cli --accept-tos registration delete >/dev/null 2>&1 || true
    fi

    sleep 2
    ((i++))
  done

  # optional fallback
  if fallback_regjson_if_enabled; then
    warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
    warp-cli --accept-tos connect >/dev/null 2>&1 || true
    wait_for_socks5 && info "SOCKS5 已就绪：socks5h://127.0.0.1:${WARP_SOCKS_PORT}" && return 0
  fi

  error "WARP Proxy 启动失败：SOCKS5 未在 ${WARP_CONNECT_WAIT}s 内监听。请查看日志：$WARP_LOG_FILE"
}

status() {
  echo "=== menu.sh ${VERSION} ==="
  echo "warp-cli: $(have_cmd warp-cli && echo OK || echo NO)"
  echo "warp-svc: $(have_cmd warp-svc && echo OK || echo NO)"
  echo "warp-svc running: $(warp_svc_running && echo YES || echo NO)"
  echo "SOCKS5: 127.0.0.1:${WARP_SOCKS_PORT}"
  ss -nltp 2>/dev/null | grep -E "127\.0\.0\.1:${WARP_SOCKS_PORT}|warp-svc" || true
  warp-cli --accept-tos status 2>/dev/null || true
}

usage() {
  cat <<EOF
Usage:
  $0 c   # install (if needed) + delay start + run WARP in proxy mode (SOCKS5)
  $0 s   # status
  $0 o   # stop warp-svc
  $0 r   # restart (stop then c)

Env:
  WARP_SOCKS_PORT=40000
  WARP_START_DELAY=10
  WARP_CONNECT_RETRY=10
  WARP_CONNECT_WAIT=60
  WARP_LOG_FILE=/var/log/warp-svc.log
  ALLOW_FALLBACK_REG=0|1
EOF
}

main() {
  need_root
  local opt="${1:-c}"

  case "$opt" in
    c)
      install_warp
      configure_and_connect_proxy
      ;;
    s)
      status
      ;;
    o)
      stop_warp_svc
      ;;
    r)
      stop_warp_svc
      install_warp
      configure_and_connect_proxy
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
