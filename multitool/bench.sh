#!/usr/bin/env bash
# =============================================================================
# muiltitool 转发性能一键测试脚本
#
# 依次部署四种拓扑 (bridge / bridge2 / route / route2),在 client1 上跑
# iperf3 打到 client2,自动采集 Gbits/sec 并汇总。
#
# 对 bridge / bridge2 会额外做一组对照:
#   - br_netfilter = 1 (默认)
#   - br_netfilter = 0 (关闭 bridge-nf-call-iptables)
# 以量化 br_netfilter 对桥接转发的性能影响。
#
# 用法:
#   ./bench.sh                  # 顺序测 4 个 lab
#   ./bench.sh bridge bridge2   # 只测指定 lab
#   DURATION=30 ./bench.sh      # 自定义 iperf 时长(秒,默认 10)
#
# 依赖: bash 4+, containerlab, docker, sudo
# =============================================================================

set -euo pipefail
cd "$(dirname "$0")"

# ---------- 拓扑配置 ----------
declare -A LAB_FILE=(
  [bridge]=bridge-lab.clab.yml
  [bridge2]=bridge2-lab.clab.yml
  [route]=route-lab.clab.yml
  [route2]=route2-lab.clab.yml
)

# iperf 打的目标 IP (client2 的地址)
declare -A TARGET_IP=(
  [bridge]=192.168.0.2
  [bridge2]=192.168.0.2
  [route]=192.168.1.2
  [route2]=192.168.1.2
)

# 桥接 lab 里需要切换 br_netfilter 的中间节点
declare -A BRIDGE_NODES=(
  [bridge]="spine1"
  [bridge2]="spine1 leaf1 leaf2"
)

DURATION=${DURATION:-10}
WAIT_AFTER_DEPLOY=${WAIT_AFTER_DEPLOY:-4}
RESULTS=()

# ---------- 工具函数 ----------
c_cyan()  { printf '\033[1;36m%s\033[0m\n' "$*"; }
c_green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
c_red()   { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }

log()  { printf '\n'; c_cyan  "==> $*"; }
err()  { c_red    "!!! $*"; }

# 找一个节点对应的 docker 容器名(兼容 prefix="" 以及带前缀两种情况)
find_ct() {
  docker ps --format '{{.Names}}' \
    | awk -v n="$1" '$0 ~ "(^|-)" n "$" {print; exit}'
}

# 在所有给定节点上设置 bridge-nf-call-iptables
# 用法: set_brnf 0|1 <node1> <node2> ...
set_brnf() {
  local v=$1; shift
  for n in "$@"; do
    local c
    c=$(find_ct "$n") || true
    [[ -z "$c" ]] && { err "找不到节点 $n,跳过 sysctl"; continue; }
    docker exec "$c" sysctl -w net.bridge.bridge-nf-call-iptables=$v  >/dev/null 2>&1 || true
    docker exec "$c" sysctl -w net.bridge.bridge-nf-call-ip6tables=$v >/dev/null 2>&1 || true
    docker exec "$c" sysctl -w net.bridge.bridge-nf-call-arptables=$v >/dev/null 2>&1 || true
  done
}

# 在 client1 上打 iperf 到指定 IP,解析 Gbits/sec
# 用法: run_iperf "label" <target-ip>
run_iperf() {
  local label=$1 ip=$2
  local c1 c2
  c1=$(find_ct client1); c2=$(find_ct client2)
  if [[ -z "$c1" || -z "$c2" ]]; then
    err "找不到 client1/client2 容器"
    RESULTS+=("$(printf '%-28s %10s' "$label" "FAIL")")
    return
  fi

  # 启动 one-shot server(处理完一个连接就退出,避免遗留)
  docker exec "$c2" pkill iperf3 >/dev/null 2>&1 || true
  docker exec -d "$c2" iperf3 -s -1 >/dev/null
  sleep 1

  local gbps
  gbps=$(docker exec "$c1" iperf3 -c "$ip" -t "$DURATION" -f g 2>/dev/null \
         | awk '/sender/ {print $7; exit}')
  [[ -z "$gbps" ]] && gbps="FAIL"

  printf '    → %-28s %8s Gbits/sec\n' "$label" "$gbps"
  RESULTS+=("$(printf '%-28s %8s Gbits/sec' "$label" "$gbps")")
}

# ---------- 主流程 ----------
bench_one() {
  local lab=$1
  local yml=${LAB_FILE[$lab]:-}
  local ip=${TARGET_IP[$lab]:-}

  if [[ -z "$yml" || ! -f "$yml" ]]; then
    err "未知 lab 或找不到 yml: $lab"
    return
  fi

  log "[$lab] deploy ($yml)"
  sudo containerlab deploy -t "$yml" >/dev/null

  # 等容器 exec 跑完、链路 up
  sleep "$WAIT_AFTER_DEPLOY"

  if [[ -n "${BRIDGE_NODES[$lab]:-}" ]]; then
    log "[$lab] 测试 br_netfilter=1 (默认)"
    set_brnf 1 ${BRIDGE_NODES[$lab]}
    run_iperf "$lab (brnf=1)" "$ip"

    log "[$lab] 测试 br_netfilter=0 (关闭)"
    set_brnf 0 ${BRIDGE_NODES[$lab]}
    run_iperf "$lab (brnf=0)" "$ip"
  else
    log "[$lab] 测试 L3 路由转发"
    run_iperf "$lab" "$ip"
  fi

  log "[$lab] destroy"
  sudo containerlab destroy -t "$yml" --cleanup >/dev/null
}

cleanup_on_exit() {
  err "被中断,尝试清理所有已部署的 lab..."
  for y in "${LAB_FILE[@]}"; do
    sudo containerlab destroy -t "$y" --cleanup >/dev/null 2>&1 || true
  done
}
trap cleanup_on_exit INT TERM

main() {
  local labs=("$@")
  if (( ${#labs[@]} == 0 )); then
    labs=(bridge bridge2 route route2)
  fi

  log "将测试: ${labs[*]}   每次 iperf 时长: ${DURATION}s"

  for lab in "${labs[@]}"; do
    bench_one "$lab"
  done

  echo
  c_green "==================== 汇总 ===================="
  printf '%s\n' "${RESULTS[@]}"
  c_green "=============================================="
}

main "$@"
