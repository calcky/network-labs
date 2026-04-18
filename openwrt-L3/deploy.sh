#!/bin/bash
set -e

cd "$(dirname "$0")"

OPENWRT_USER="root"
OPENWRT_PASS="rocks"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"

echo "=== [1/3] Deploying containerlab topology ==="
sudo clab deploy -t lab.clab.yml --reconfigure

echo ""
echo "=== [2/3] Waiting for OpenWrt nodes to boot (2-4 min) ==="

wait_for_ssh() {
    local host=$1
    local attempt=0
    while [ $attempt -lt 60 ]; do
        if sshpass -p "$OPENWRT_PASS" ssh $SSH_OPTS "$OPENWRT_USER@$host" "echo ok" &>/dev/null; then
            echo "  ✓ $host is ready"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 5
    done
    echo "  ✗ $host did not become reachable"
    return 1
}

wait_for_ssh leaf1
wait_for_ssh leaf2

echo ""
echo "=== [3/3] Configuring OpenWrt LAN IPs ==="
echo "  (LAN_IP env var is broken in vrnetlab, fixing via SSH)"

configure_openwrt() {
    local host=$1
    local lan_ip=$2
    echo "  Configuring $host (LAN=$lan_ip) ..."
    sshpass -p "$OPENWRT_PASS" ssh $SSH_OPTS "$OPENWRT_USER@$host" <<SSHEOF
uci set network.lan.ipaddr='$lan_ip'
uci commit network

# WAN zone: allow forward

# Add WAN -> LAN forwarding rule
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='wan'
uci set firewall.@forwarding[-1].dest='lan'
uci commit firewall

/etc/init.d/network restart
/etc/init.d/firewall restart
SSHEOF
    sleep 3
    echo "  ✓ $host done"
}

configure_openwrt leaf1 192.168.1.1
configure_openwrt leaf2 192.168.2.1

echo ""
echo "=== Deployment complete ==="
echo ""
echo "  spine1  eth1:10.0.1.2/30 ── leaf1 WAN:DHCP | LAN:192.168.1.1 ── client1:192.168.1.10"
echo "  spine1  eth2:10.0.2.2/30 ── leaf2 WAN:DHCP | LAN:192.168.2.1 ── client2:192.168.2.10"
echo ""
echo "  Test: sudo docker exec client1 ping -c 3 192.168.2.10"
