#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

TOPO="generic_vm.clab.yml"
UBUNTU_USER="clab"
UBUNTU_PASS='clab@123'
SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=15
  -o LogLevel=ERROR
)

# 与 generic_vm.clab.yml 中 prefix: "" 一致，容器名即节点名
LEAF1_HOST="leaf1"
LEAF2_HOST="leaf2"

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing dependency: $1 (install: $2)" >&2
    exit 1
  }
}

require sshpass "sshpass"

echo "=== [1/3] Deploying containerlab topology ==="
sudo containerlab deploy -t "$TOPO" "$@"

wait_for_ssh() {
  local label=$1
  local host=$2
  local attempt=0
  local max=72
  while [ "$attempt" -lt "$max" ]; do
    if sshpass -p "$UBUNTU_PASS" ssh "${SSH_OPTS[@]}" "${UBUNTU_USER}@${host}" "echo ok" &>/dev/null; then
      echo "  ✓ ${label} (${host}) is ready for SSH"
      return 0
    fi
    attempt=$((attempt + 1))
    echo "  … waiting for ${label} (${attempt}/${max}, ~5s)"
    sleep 5
  done
  echo "  ✗ ${label} did not accept SSH in time" >&2
  return 1
}

configure_ubuntu_leaf() {
  local label=$1
  local host=$2
  local wan_cidr=$3
  local lan_cidr=$4
  local gw=$5
  local peer_lan_cidr=${6:-}
  # 对端 leaf 的上联网段（经本机 GW 走路由器），例如 leaf2 需 172.16.0.0/24 才能回程到 leaf1 的 172.16.0.2
  local peer_uplink_cidr=${7:-}

  echo "  Configuring ${label} (WAN=${wan_cidr}, LAN=${lan_cidr}, GW=${gw}) …"
  sshpass -p "$UBUNTU_PASS" ssh "${SSH_OPTS[@]}" "${UBUNTU_USER}@${host}" bash -s <<EOF
set -euo pipefail
WAN_CIDR='${wan_cidr}'
LAN_CIDR='${lan_cidr}'
GW='${gw}'
LABEL='${label}'
PEER_LAN='${peer_lan_cidr}'
PEER_UPLINK='${peer_uplink_cidr}'
SUDO_PASS='${UBUNTU_PASS}'
s() { printf '%s\n' "\$SUDO_PASS" | sudo -S "\$@"; }

# 不要用 "ip route replace default"：会抢走管理口 enp1s0 的默认路由，SSH 立刻断，看起来像卡住。
MGT_DEV=\$(ip -4 route show default 2>/dev/null | head -1 | sed -n 's/.* dev \\([^ ]*\\).*/\\1/p' || true)
readarray -t ALL < <(ip -br link | awk '\$1 != "lo" { print \$1 }' | sort)
DATA=()
for i in "\${ALL[@]}"; do
  if [[ -n "\$MGT_DEV" && "\$i" == "\$MGT_DEV" ]]; then
    continue
  fi
  DATA+=("\$i")
done
if [[ \${#DATA[@]} -lt 2 && \${#ALL[@]} -ge 3 ]]; then
  DATA=("\${ALL[1]}" "\${ALL[2]}")
elif [[ \${#DATA[@]} -lt 2 ]]; then
  echo "Could not find two data interfaces (have: \${ALL[*]})" >&2
  exit 1
fi
WAN="\${DATA[0]}"
LAN="\${DATA[1]}"

s ip addr flush dev "\$WAN" 2>/dev/null || true
s ip addr add "\$WAN_CIDR" dev "\$WAN"
s ip link set "\$WAN" up

s ip addr flush dev "\$LAN" 2>/dev/null || true
s ip addr add "\$LAN_CIDR" dev "\$LAN"
s ip link set "\$LAN" up

# 经中心 router 访问对端 LAN（与 multitool route2 语义一致，且不破坏管理网 default）
if [[ -n "\$PEER_LAN" ]]; then
  s ip route replace "\$PEER_LAN" via "\$GW" dev "\$WAN" 2>/dev/null || true
fi
# 对端上联网段（如 leaf2 → 172.16.0.0/24，才能正确回程到 leaf1 WAN 172.16.0.2）
if [[ -n "\$PEER_UPLINK" ]]; then
  s ip route replace "\$PEER_UPLINK" via "\$GW" dev "\$WAN" 2>/dev/null || true
fi

s sysctl -w net.ipv4.ip_forward=1 >/dev/null
if s iptables -t nat -C POSTROUTING -o "\$WAN" -j MASQUERADE 2>/dev/null; then
  :
else
  s iptables -t nat -A POSTROUTING -o "\$WAN" -j MASQUERADE
fi
echo "OK \${LABEL}: WAN=\$WAN LAN=\$LAN"
EOF
  echo "  ✓ ${label} done"
}

echo ""
echo "=== [2/3] Waiting for Ubuntu (generic_vm) SSH ==="
echo "  SSH targets: ${LEAF1_HOST}, ${LEAF2_HOST} (container names = node names)"
wait_for_ssh leaf1 "$LEAF1_HOST"
wait_for_ssh leaf2 "$LEAF2_HOST"

echo ""
echo "=== [3/3] Applying Ubuntu data-plane configuration ==="
configure_ubuntu_leaf leaf1 "$LEAF1_HOST" "172.16.0.2/24" "192.168.0.1/24" "172.16.0.1" "192.168.1.0/24" "172.16.1.0/24"
configure_ubuntu_leaf leaf2 "$LEAF2_HOST" "172.16.1.2/24" "192.168.1.1/24" "172.16.1.1" "192.168.0.0/24" "172.16.0.0/24"

echo ""
echo "=== Done ==="
echo "  client1 → 192.168.0.2 (GW 192.168.0.1 on leaf1)"
echo "  client2 → 192.168.1.2 (GW 192.168.1.1 on leaf2)"
echo "  Test: docker exec -it client1 ping -c 3 192.168.1.2"
echo "  Test: docker exec -it client2 ping -c 3 192.168.0.2"