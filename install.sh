#!/bin/bash
#===============================================================================
# NAT Manager v3.0 Installer
#===============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║       NAT Manager v3.0-XDP Installer                         ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Run as root: sudo $0${NC}"
    exit 1
fi

# Install dependencies
echo -e "${YELLOW}[1/5] Installing dependencies...${NC}"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    iptables-persistent nftables ethtool curl wget > /dev/null 2>&1

# Download nat-manager
echo -e "${YELLOW}[2/5] Downloading NAT Manager...${NC}"
wget -q -O /usr/local/bin/nat-manager \
    https://raw.githubusercontent.com/FastCon-telegram/DNAT/main/nat-manager.sh
chmod +x /usr/local/bin/nat-manager

# Create directories
echo -e "${YELLOW}[3/5] Creating directories...${NC}"
mkdir -p /etc/nat-bridge/xdp

# Install optimization service
echo -e "${YELLOW}[4/5] Installing optimization service...${NC}"
cat > /etc/systemd/system/nat-optimization.service << 'EOF'
[Unit]
Description=NAT Manager Optimization
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c '\
    IFACE=$(ip route | grep default | awk "{print \$5}" | head -1); \
    ethtool -G $IFACE rx 4096 tx 4096 2>/dev/null || true; \
    ethtool -C $IFACE adaptive-rx on adaptive-tx on 2>/dev/null || true; \
    CURR=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo 0); \
    [ 4194304 -gt $CURR ] && sysctl -w net.netfilter.nf_conntrack_max=4194304; \
    CURR=$(cat /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || echo 0); \
    [ 1048576 -gt $CURR ] && echo 1048576 > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null; \
    CURR=$(sysctl -n net.core.netdev_budget 2>/dev/null || echo 0); \
    [ 100000 -gt $CURR ] && sysctl -w net.core.netdev_budget=100000; \
    CURR=$(sysctl -n net.core.netdev_max_backlog 2>/dev/null || echo 0); \
    [ 250000 -gt $CURR ] && sysctl -w net.core.netdev_max_backlog=250000; \
    CURR=$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0); \
    [ 134217728 -gt $CURR ] && sysctl -w net.core.rmem_max=134217728; \
    CURR=$(sysctl -n net.core.wmem_max 2>/dev/null || echo 0); \
    [ 134217728 -gt $CURR ] && sysctl -w net.core.wmem_max=134217728; \
    ethtool -K $IFACE gro on gso on tso on 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable nat-optimization.service

# Enable IP forwarding
echo -e "${YELLOW}[5/5] Enabling IP forwarding...${NC}"
echo 1 > /proc/sys/net/ipv4/ip_forward
grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || \
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Installation complete!                                      ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "Run: ${YELLOW}nat-manager${NC}"
echo ""
echo -e "For XDP support, also run:"
echo -e "  ${YELLOW}apt install clang llvm libbpf-dev linux-headers-\$(uname -r) bpftool${NC}"
echo ""
