#!/usr/bin/env bash
# =============================================================================
# linux-bridge lab 一键部署 / 销毁脚本
#
# 用法:
#   ./lab.sh up      # 创建 Linux bridge + 部署 containerlab
#   ./lab.sh down    # 销毁 lab + 删除 Linux bridge + 清理 iptables FORWARD 残留
#   ./lab.sh status  # 查看当前状态
#
# 依赖: sudo, ip, iptables, containerlab
# =============================================================================

set -euo pipefail
cd "$(dirname "$0")"

BRIDGE=br01
YML=lab.clab.yml

c_cyan()  { printf '\033[1;36m%s\033[0m\n' "$*"; }
c_green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
c_red()   { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }

log() { c_cyan "==> $*"; }
ok()  { c_green "✓ $*"; }
err() { c_red "✗ $*"; }

bridge_exists() { ip link show "$BRIDGE" >/dev/null 2>&1; }

cmd_up() {
  if bridge_exists; then
    ok "Linux bridge $BRIDGE 已存在,跳过创建"
  else
    log "创建 Linux bridge: $BRIDGE"
    sudo ip link add name "$BRIDGE" type bridge
    sudo ip link set "$BRIDGE" up
    ok "bridge $BRIDGE 已创建并 up"
  fi

  log "部署 containerlab 拓扑"
  sudo containerlab deploy -t "$YML"
  ok "部署完成"
}

cmd_down() {
  if [[ -f "$YML" ]]; then
    log "销毁 containerlab 拓扑"
    sudo containerlab destroy -t "$YML" --cleanup || err "destroy 报错,继续清理"
  fi

  log "清理桥侧残留 veth (br01-c*)"
  # containerlab 异常中止时可能在 root netns 里留下桥侧 veth,顺手清掉
  local leftover
  leftover=$(ip -brief link show 2>/dev/null \
              | awk '/^br01-c[0-9]+/ {sub(/@.*/, "", $1); print $1}' || true)
  if [[ -z "$leftover" ]]; then
    ok "无残留 veth"
  else
    for v in $leftover; do
      sudo ip link del "$v" 2>/dev/null && ok "已删除 $v" || err "删除 $v 失败"
    done
  fi

  if bridge_exists; then
    log "删除 Linux bridge: $BRIDGE"
    sudo ip link set "$BRIDGE" down || true
    sudo ip link del "$BRIDGE"
    ok "bridge $BRIDGE 已删除"
  else
    ok "Linux bridge $BRIDGE 不存在,跳过"
  fi

  log "清理 iptables FORWARD 链中 containerlab 遗留规则"
  # 按行号倒序删除,避免删除过程中行号错位
  local rules
  rules=$(sudo iptables -vL FORWARD --line-numbers -n \
            | grep "set by containerlab" \
            | awk '{print $1}' \
            | sort -rn || true)
  if [[ -z "$rules" ]]; then
    ok "FORWARD 链无残留规则"
  else
    local n=0
    for r in $rules; do
      sudo iptables -D FORWARD "$r"
      n=$((n + 1))
    done
    ok "已清理 $n 条 FORWARD 残留规则"
  fi

  # 如果系统启用了 ip6tables,也顺带清一下
  if command -v ip6tables >/dev/null 2>&1; then
    rules=$(sudo ip6tables -vL FORWARD --line-numbers -n 2>/dev/null \
              | grep "set by containerlab" \
              | awk '{print $1}' \
              | sort -rn || true)
    if [[ -n "$rules" ]]; then
      local n=0
      for r in $rules; do
        sudo ip6tables -D FORWARD "$r"
        n=$((n + 1))
      done
      ok "已清理 $n 条 ip6 FORWARD 残留规则"
    fi
  fi
}

cmd_status() {
  log "Linux bridge $BRIDGE"
  if bridge_exists; then
    ip -brief link show "$BRIDGE"
    ip -brief link show master "$BRIDGE" 2>/dev/null || true
  else
    echo "  (未创建)"
  fi

  log "containerlab 拓扑 (name=br01)"
  sudo containerlab inspect --name br01 2>/dev/null || echo "  (未部署)"

  log "FORWARD 链中 containerlab 遗留规则"
  sudo iptables -vL FORWARD -n --line-numbers | grep "set by containerlab" || echo "  (无)"
}

usage() {
  cat <<EOF
Usage: $0 <up|down|status>

  up       创建 Linux bridge $BRIDGE 并部署 containerlab 拓扑
  down     销毁拓扑 + 删除 bridge + 清理 iptables FORWARD 残留
  status   查看当前状态
EOF
  exit 1
}

case "${1:-}" in
  up|deploy|start)    cmd_up ;;
  down|destroy|stop)  cmd_down ;;
  status|show)        cmd_status ;;
  *)                  usage ;;
esac
