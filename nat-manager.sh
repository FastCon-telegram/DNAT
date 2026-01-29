#!/bin/bash

#===============================================================================
# NAT Bridge Manager v3.0 - XDP Edition
# - nftables поддержка (быстрее iptables)
# - XDP ускорение (обработка пакетов в драйвере)
# - Ring буферы + Interrupt Coalescing
# - Оптимизация Conntrack для 200K+ соединений
# - Softirq budget для 10Gbit
#===============================================================================

VERSION="3.0-XDP"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
GRAY='\033[0;90m'
NC='\033[0m'

RULES_DIR="/etc/nat-bridge"
RULES_FILE="$RULES_DIR/rules.conf"
CONFIG_FILE="$RULES_DIR/config.conf"
XDP_DIR="/etc/nat-bridge/xdp"

BACKEND="iptables"

print_header() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}       ${GREEN}🚀 NAT Bridge Manager v${VERSION}${NC}                     ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}       ${YELLOW}DNAT + XDP + nftables оптимизация${NC}                  ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ $1${NC}"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Запустите от root: sudo $0"
        exit 1
    fi
}

get_main_interface() {
    ip route | grep default | awk '{print $5}' | head -1
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    else
        BACKEND="iptables"
        OPTIMIZATION_APPLIED=0
    fi
}

save_config() {
    cat > "$CONFIG_FILE" << EOF
BACKEND="$BACKEND"
OPTIMIZATION_APPLIED="${OPTIMIZATION_APPLIED:-0}"
EOF
}

initial_setup() {
    mkdir -p "$RULES_DIR" "$XDP_DIR" 2>/dev/null || true
    touch "$RULES_FILE" 2>/dev/null || true
    
    echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
    grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null || \
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf 2>/dev/null
    
    if ! command -v nft &> /dev/null; then
        apt-get update -qq 2>/dev/null || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y nftables > /dev/null 2>&1 || true
    fi
    
    if ! command -v netfilter-persistent &> /dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent > /dev/null 2>&1 || true
    fi
    
    if ! command -v ethtool &> /dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y ethtool > /dev/null 2>&1 || true
    fi
    
    load_config
}

save_iptables() {
    mkdir -p /etc/iptables 2>/dev/null || true
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    netfilter-persistent save > /dev/null 2>&1 || true
}

ensure_masquerade_iptables() {
    iptables -t nat -C POSTROUTING -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -j MASQUERADE 2>/dev/null || true
}

add_iptables_rule() {
    local sp="$1" di="$2" dp="$3" pr="$4"
    [[ -z "$sp" || -z "$di" || -z "$dp" ]] && return
    
    if [[ "$pr" == "both" || "$pr" == "tcp" ]]; then
        if ! iptables -t nat -C PREROUTING -p tcp --dport "$sp" -j DNAT --to-destination "$di:$dp" 2>/dev/null; then
            iptables -t nat -A PREROUTING -p tcp --dport "$sp" -j DNAT --to-destination "$di:$dp" 2>/dev/null || true
        fi
    fi
    
    if [[ "$pr" == "both" || "$pr" == "udp" ]]; then
        if ! iptables -t nat -C PREROUTING -p udp --dport "$sp" -j DNAT --to-destination "$di:$dp" 2>/dev/null; then
            iptables -t nat -A PREROUTING -p udp --dport "$sp" -j DNAT --to-destination "$di:$dp" 2>/dev/null || true
        fi
    fi
}

remove_iptables_rule() {
    local sp="$1" di="$2" dp="$3" pr="$4"
    [[ -z "$sp" || -z "$di" || -z "$dp" ]] && return
    [[ "$pr" == "both" || "$pr" == "tcp" ]] && iptables -t nat -D PREROUTING -p tcp --dport "$sp" -j DNAT --to-destination "$di:$dp" 2>/dev/null || true
    [[ "$pr" == "both" || "$pr" == "udp" ]] && iptables -t nat -D PREROUTING -p udp --dport "$sp" -j DNAT --to-destination "$di:$dp" 2>/dev/null || true
}

init_nftables() {
    nft flush ruleset 2>/dev/null || true
    nft add table ip nat 2>/dev/null || true
    nft add chain ip nat prerouting '{ type nat hook prerouting priority dstnat; policy accept; }' 2>/dev/null || true
    nft add chain ip nat postrouting '{ type nat hook postrouting priority srcnat; policy accept; }' 2>/dev/null || true
    nft add rule ip nat postrouting masquerade 2>/dev/null || true
}

save_nftables() {
    nft list ruleset > /etc/nftables.conf 2>/dev/null || true
    systemctl enable nftables 2>/dev/null || true
}

add_nftables_rule() {
    local sp="$1" di="$2" dp="$3" pr="$4"
    [[ -z "$sp" || -z "$di" || -z "$dp" ]] && return
    
    if [[ "$pr" == "both" || "$pr" == "tcp" ]]; then
        nft add rule ip nat prerouting tcp dport "$sp" dnat to "$di:$dp" 2>/dev/null || true
    fi
    
    if [[ "$pr" == "both" || "$pr" == "udp" ]]; then
        nft add rule ip nat prerouting udp dport "$sp" dnat to "$di:$dp" 2>/dev/null || true
    fi
}

remove_nftables_rule() {
    local sp="$1" di="$2" dp="$3" pr="$4"
    [[ -z "$sp" || -z "$di" || -z "$dp" ]] && return
    
    if [[ "$pr" == "both" || "$pr" == "tcp" ]]; then
        local handle=$(nft -a list chain ip nat prerouting 2>/dev/null | grep "tcp dport $sp" | grep "$di:$dp" | awk '{print $NF}')
        [[ -n "$handle" ]] && nft delete rule ip nat prerouting handle "$handle" 2>/dev/null || true
    fi
    
    if [[ "$pr" == "both" || "$pr" == "udp" ]]; then
        local handle=$(nft -a list chain ip nat prerouting 2>/dev/null | grep "udp dport $sp" | grep "$di:$dp" | awk '{print $NF}')
        [[ -n "$handle" ]] && nft delete rule ip nat prerouting handle "$handle" 2>/dev/null || true
    fi
}

add_rule_backend() {
    local sp="$1" di="$2" dp="$3" pr="$4"
    
    case "$BACKEND" in
        nftables)
            add_nftables_rule "$sp" "$di" "$dp" "$pr"
            save_nftables
            ;;
        *)
            add_iptables_rule "$sp" "$di" "$dp" "$pr"
            ensure_masquerade_iptables
            save_iptables
            ;;
    esac
}

remove_rule_backend() {
    local sp="$1" di="$2" dp="$3" pr="$4"
    
    case "$BACKEND" in
        nftables)
            remove_nftables_rule "$sp" "$di" "$dp" "$pr"
            save_nftables
            ;;
        *)
            remove_iptables_rule "$sp" "$di" "$dp" "$pr"
            save_iptables
            ;;
    esac
}

apply_rules() {
    [[ ! -f "$RULES_FILE" ]] && return
    
    while IFS='|' read -r name sp di dp pr en; do
        [[ -z "$name" || "$name" == \#* || -z "$sp" ]] && continue
        [[ "$en" == "1" ]] && add_rule_backend "$sp" "$di" "$dp" "$pr"
    done < "$RULES_FILE"
}

optimize_ring_buffers() {
    local iface=$(get_main_interface)
    [[ -z "$iface" ]] && return 1
    
    if command -v ethtool &>/dev/null; then
        local max_rx=$(ethtool -g "$iface" 2>/dev/null | grep -A4 "Pre-set" | grep "RX:" | awk '{print $2}')
        local max_tx=$(ethtool -g "$iface" 2>/dev/null | grep -A4 "Pre-set" | grep "TX:" | awk '{print $2}')
        
        [[ "$max_rx" != "n/a" && -n "$max_rx" ]] && ethtool -G "$iface" rx "$max_rx" 2>/dev/null || true
        [[ "$max_tx" != "n/a" && -n "$max_tx" ]] && ethtool -G "$iface" tx "$max_tx" 2>/dev/null || true
        return 0
    fi
    return 1
}

optimize_interrupt_coalescing() {
    local iface=$(get_main_interface)
    [[ -z "$iface" ]] && return 1
    
    if command -v ethtool &>/dev/null; then
        ethtool -C "$iface" adaptive-rx on adaptive-tx on 2>/dev/null || \
        ethtool -C "$iface" rx-usecs 50 rx-frames 64 tx-usecs 50 tx-frames 64 2>/dev/null || true
        return 0
    fi
    return 1
}

optimize_conntrack() {
    local current_max=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo 0)
    local current_hashsize=$(cat /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || echo 0)
    
    local target_max=4194304
    local target_hashsize=1048576
    
    if [[ $target_max -gt $current_max ]]; then
        sysctl -w net.netfilter.nf_conntrack_max=$target_max 2>/dev/null || true
    fi
    
    if [[ $target_hashsize -gt $current_hashsize ]]; then
        echo $target_hashsize > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true
    fi
    
    sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=1800 2>/dev/null || true
    sysctl -w net.netfilter.nf_conntrack_tcp_timeout_time_wait=10 2>/dev/null || true
    sysctl -w net.netfilter.nf_conntrack_tcp_timeout_close_wait=15 2>/dev/null || true
    sysctl -w net.netfilter.nf_conntrack_tcp_timeout_fin_wait=15 2>/dev/null || true
    sysctl -w net.netfilter.nf_conntrack_helper=0 2>/dev/null || true
    
    return 0
}

optimize_softirq_budget() {
    local current_budget=$(sysctl -n net.core.netdev_budget 2>/dev/null || echo 0)
    local current_backlog=$(sysctl -n net.core.netdev_max_backlog 2>/dev/null || echo 0)
    local current_budget_usecs=$(sysctl -n net.core.netdev_budget_usecs 2>/dev/null || echo 0)
    
    local target_budget=100000
    local target_backlog=250000
    local target_budget_usecs=10000
    
    [[ $target_budget -gt $current_budget ]] && \
        sysctl -w net.core.netdev_budget=$target_budget 2>/dev/null || true
    
    [[ $target_backlog -gt $current_backlog ]] && \
        sysctl -w net.core.netdev_max_backlog=$target_backlog 2>/dev/null || true
    
    [[ $target_budget_usecs -gt $current_budget_usecs ]] && \
        sysctl -w net.core.netdev_budget_usecs=$target_budget_usecs 2>/dev/null || true
    
    return 0
}

optimize_network_buffers() {
    local current_rmem=$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)
    local current_wmem=$(sysctl -n net.core.wmem_max 2>/dev/null || echo 0)
    
    local target_mem=134217728
    
    [[ $target_mem -gt $current_rmem ]] && \
        sysctl -w net.core.rmem_max=$target_mem 2>/dev/null || true
    
    [[ $target_mem -gt $current_wmem ]] && \
        sysctl -w net.core.wmem_max=$target_mem 2>/dev/null || true
    
    sysctl -w net.ipv4.tcp_rmem="4096 1048576 134217728" 2>/dev/null || true
    sysctl -w net.ipv4.tcp_wmem="4096 1048576 134217728" 2>/dev/null || true
    
    return 0
}

optimize_irq_affinity() {
    local iface=$(get_main_interface)
    [[ -z "$iface" ]] && return 1
    
    systemctl stop irqbalance 2>/dev/null || true
    systemctl disable irqbalance 2>/dev/null || true
    
    local cpu_count=$(nproc)
    local irq_list=$(grep "$iface" /proc/interrupts 2>/dev/null | awk -F: '{print $1}' | tr -d ' ')
    local cpu_idx=0
    
    for irq in $irq_list; do
        if [[ -f "/proc/irq/$irq/smp_affinity" ]]; then
            local mask=$((1 << cpu_idx))
            printf "%x" $mask > "/proc/irq/$irq/smp_affinity" 2>/dev/null || true
            cpu_idx=$(( (cpu_idx + 1) % cpu_count ))
        fi
    done
    
    return 0
}

optimize_offload() {
    local iface=$(get_main_interface)
    [[ -z "$iface" ]] && return 1
    
    if command -v ethtool &>/dev/null; then
        ethtool -K "$iface" gro on gso on tso on 2>/dev/null || true
        ethtool -K "$iface" rx-gro-hw on 2>/dev/null || true
    fi
    
    return 0
}

install_xdp_deps() {
    print_info "Установка зависимостей XDP..."
    
    apt-get update -qq 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        clang llvm libbpf-dev linux-headers-$(uname -r) \
        bpftool iproute2 > /dev/null 2>&1 || {
        print_warning "Некоторые XDP зависимости не установились"
        return 1
    }
    
    print_success "XDP зависимости установлены"
    return 0
}

create_xdp_program() {
    local rules_count=0
    local xdp_rules=""
    
    while IFS='|' read -r name sp di dp pr en; do
        [[ -z "$name" || "$name" == \#* || -z "$sp" || "$en" != "1" ]] && continue
        
        local ip_hex=$(echo "$di" | awk -F. '{printf "0x%02x%02x%02x%02x", $4, $3, $2, $1}')
        
        if [[ "$pr" == "both" || "$pr" == "tcp" ]]; then
            xdp_rules+="
        if (tcp && tcp->dest == __constant_htons($sp)) {
            ip->daddr = __constant_htonl($ip_hex);
            tcp->dest = __constant_htons($dp);
            goto recompute;
        }"
            rules_count=$((rules_count + 1))
        fi
        
        if [[ "$pr" == "both" || "$pr" == "udp" ]]; then
            xdp_rules+="
        if (udp && udp->dest == __constant_htons($sp)) {
            ip->daddr = __constant_htonl($ip_hex);
            udp->dest = __constant_htons($dp);
            goto recompute;
        }"
            rules_count=$((rules_count + 1))
        fi
    done < "$RULES_FILE"
    
    if [[ $rules_count -eq 0 ]]; then
        print_warning "Нет активных правил для XDP"
        return 1
    fi
    
    cat > "$XDP_DIR/xdp_dnat.c" << 'XDPHEADER'
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/tcp.h>
#include <linux/udp.h>
#include <linux/in.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

static __always_inline __u16 csum_fold_helper(__u32 csum) {
    csum = (csum & 0xffff) + (csum >> 16);
    csum = (csum & 0xffff) + (csum >> 16);
    return (__u16)~csum;
}

static __always_inline void update_ip_checksum(struct iphdr *ip) {
    __u32 csum = 0;
    __u16 *ptr = (__u16 *)ip;
    ip->check = 0;
    #pragma unroll
    for (int i = 0; i < 10; i++) { csum += ptr[i]; }
    ip->check = csum_fold_helper(csum);
}

SEC("xdp")
int xdp_dnat_prog(struct xdp_md *ctx) {
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;
    
    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end) return XDP_PASS;
    if (eth->h_proto != __constant_htons(ETH_P_IP)) return XDP_PASS;
    
    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end) return XDP_PASS;
    
    struct tcphdr *tcp = NULL;
    struct udphdr *udp = NULL;
    
    if (ip->protocol == IPPROTO_TCP) {
        tcp = (void *)ip + (ip->ihl * 4);
        if ((void *)(tcp + 1) > data_end) return XDP_PASS;
    } else if (ip->protocol == IPPROTO_UDP) {
        udp = (void *)ip + (ip->ihl * 4);
        if ((void *)(udp + 1) > data_end) return XDP_PASS;
    } else { return XDP_PASS; }
XDPHEADER
    
    echo "$xdp_rules" >> "$XDP_DIR/xdp_dnat.c"
    
    cat >> "$XDP_DIR/xdp_dnat.c" << 'XDPFOOTER'
    return XDP_PASS;
recompute:
    update_ip_checksum(ip);
    return XDP_TX;
}
char _license[] SEC("license") = "GPL";
XDPFOOTER

    print_success "XDP программа сгенерирована"
    return 0
}

compile_and_load_xdp() {
    local iface=$(get_main_interface)
    [[ -z "$iface" ]] && { print_error "Интерфейс не найден"; return 1; }
    
    print_info "Компиляция XDP..."
    cd "$XDP_DIR" || return 1
    
    clang -O2 -g -Wall -target bpf -I/usr/include/$(uname -m)-linux-gnu -c xdp_dnat.c -o xdp_dnat.o 2>&1 || {
        print_error "Ошибка компиляции XDP"; return 1
    }
    
    print_success "XDP скомпилирован"
    ip link set dev "$iface" xdp off 2>/dev/null || true
    
    if ip link set dev "$iface" xdp obj xdp_dnat.o sec xdp 2>/dev/null; then
        print_success "XDP загружен (native)"
        BACKEND="xdp"; save_config; return 0
    fi
    
    if ip link set dev "$iface" xdpgeneric obj xdp_dnat.o sec xdp 2>/dev/null; then
        print_success "XDP загружен (generic)"
        BACKEND="xdp"; save_config; return 0
    fi
    
    print_error "Не удалось загрузить XDP"; return 1
}

unload_xdp() {
    local iface=$(get_main_interface)
    [[ -z "$iface" ]] && return 1
    
    ip link set dev "$iface" xdp off 2>/dev/null || true
    
    if [[ "$BACKEND" == "xdp" ]]; then
        BACKEND="iptables"; save_config; apply_rules
    fi
    
    print_success "XDP выгружен"
    return 0
}

optimization_menu() {
    while true; do
        print_header
        echo -e "${MAGENTA}⚡ Оптимизация DNAT для 10Gbit${NC}"
        echo "═══════════════════════════════════════════════════════════════════════"
        echo ""
        
        local iface=$(get_main_interface)
        echo -e "Интерфейс: ${CYAN}$iface${NC} | Backend: ${GREEN}$BACKEND${NC} | CPU: ${CYAN}$(nproc)${NC}"
        echo ""
        
        echo -e "${YELLOW}Базовая оптимизация:${NC}"
        echo "  1) 📦 Ring буферы"
        echo "  2) ⏱️  Interrupt Coalescing"
        echo "  3) 🔗 Conntrack (4M)"
        echo "  4) 📊 Softirq budget (100K)"
        echo "  5) 📡 Сетевые буферы (128MB)"
        echo "  6) 🎯 IRQ Affinity"
        echo "  7) 🚀 Offload (GRO/GSO/TSO)"
        echo "  8) ⚡ Применить ВСЁ"
        echo ""
        echo -e "${YELLOW}Backend:${NC}"
        echo "  9) 🔄 nftables"
        echo " 10) 🔄 iptables"
        echo ""
        echo -e "${YELLOW}XDP:${NC}"
        echo " 11) 📥 Установить XDP"
        echo " 12) 🚀 Включить XDP"
        echo " 13) ⏹️  Выключить XDP"
        echo ""
        echo "  0) ◀️  Назад"
        echo ""
        
        read -rp "Выбор: " ch
        
        case "$ch" in
            1) optimize_ring_buffers && print_success "Ring буферы OK" || print_warning "Не поддерживается"; sleep 2;;
            2) optimize_interrupt_coalescing && print_success "Coalescing OK" || print_warning "Не поддерживается"; sleep 2;;
            3) optimize_conntrack && print_success "Conntrack 4M OK"; sleep 2;;
            4) optimize_softirq_budget && print_success "Softirq 100K OK"; sleep 2;;
            5) optimize_network_buffers && print_success "Буферы 128MB OK"; sleep 2;;
            6) optimize_irq_affinity && print_success "IRQ OK"; sleep 2;;
            7) optimize_offload && print_success "Offload OK"; sleep 2;;
            8)
                optimize_ring_buffers; optimize_interrupt_coalescing
                optimize_conntrack; optimize_softirq_budget
                optimize_network_buffers; optimize_irq_affinity; optimize_offload
                OPTIMIZATION_APPLIED=1; save_config
                print_success "Вся оптимизация применена!"; sleep 3;;
            9) iptables -t nat -F PREROUTING 2>/dev/null; init_nftables; BACKEND="nftables"; save_config; apply_rules; print_success "nftables"; sleep 2;;
            10) nft flush ruleset 2>/dev/null; BACKEND="iptables"; save_config; apply_rules; print_success "iptables"; sleep 2;;
            11) install_xdp_deps; sleep 2;;
            12) create_xdp_program && compile_and_load_xdp; sleep 3;;
            13) unload_xdp; sleep 2;;
            0) return;;
        esac
    done
}

show_optimization_status() {
    print_header
    echo -e "${CYAN}📊 Статус оптимизации${NC}"
    echo "═══════════════════════════════════════════════════════════════════════"
    local iface=$(get_main_interface)
    echo "Интерфейс: $iface | Backend: $BACKEND | CPU: $(nproc)"
    echo ""
    echo "Conntrack: $(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)/$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null)"
    echo "Hashsize: $(cat /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null)"
    echo "Budget: $(sysctl -n net.core.netdev_budget 2>/dev/null) | Backlog: $(sysctl -n net.core.netdev_max_backlog 2>/dev/null)"
    echo "rmem_max: $(sysctl -n net.core.rmem_max 2>/dev/null) | wmem_max: $(sysctl -n net.core.wmem_max 2>/dev/null)"
    echo ""
    [[ -n "$iface" ]] && echo "XDP: $(ip link show "$iface" 2>/dev/null | grep -o "xdp[^ ]*" || echo "не загружен")"
    echo ""; read -rp "Enter..."
}

get_rules_count() {
    local t=0 e=0
    [[ -f "$RULES_FILE" ]] && while IFS='|' read -r n sp di dp pr en; do
        [[ -z "$n" || "$n" == \#* || -z "$sp" ]] && continue
        t=$((t+1)); [[ "$en" == "1" ]] && e=$((e+1))
    done < "$RULES_FILE"
    echo "$t $e"
}

show_rules() {
    print_header
    echo -e "${GREEN}📋 DNAT правила${NC} (${CYAN}$BACKEND${NC})"
    echo "═══════════════════════════════════════════════════════════════════════"
    
    if [[ ! -s "$RULES_FILE" ]]; then print_warning "Нет правил"; read -rp "Enter..."; return; fi
    
    echo -e "${YELLOW}#   Статус   Название              Порт       Назначение           Прото${NC}"
    echo "───────────────────────────────────────────────────────────────────────"
    
    local i=1
    while IFS='|' read -r n sp di dp pr en; do
        [[ -z "$n" || "$n" == \#* || -z "$sp" ]] && continue
        [[ "$en" == "1" ]] && st="${GREEN}● ВКЛ${NC}" || st="${GRAY}○ ВЫКЛ${NC}"
        case "$pr" in both) pd="TCP+UDP";; tcp) pd="TCP";; udp) pd="UDP";; *) pd="TCP+UDP";; esac
        printf "%-3s  [%b]  %-20s  %-9s  %-19s  %s\n" "$i" "$st" "$n" ":$sp" "$di:$dp" "$pd"
        i=$((i+1))
    done < "$RULES_FILE"
    
    echo ""; read -rp "Enter..."
}

add_rule() {
    print_header
    echo -e "${GREEN}➕ Добавить правило${NC}"
    echo ""
    
    read -rp "Название: " rn; [[ -z "$rn" ]] && return; rn="${rn//|/}"
    grep -q "^${rn}|" "$RULES_FILE" 2>/dev/null && { print_error "Существует"; sleep 2; return; }
    
    while true; do read -rp "Порт: " sp; [[ "$sp" =~ ^[0-9]+$ ]] && break; done
    while true; do read -rp "IP: " di; [[ "$di" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break; done
    read -rp "Порт назн [443]: " dp; dp="${dp:-443}"
    
    echo "1) TCP+UDP  2) TCP  3) UDP"; read -rp "[1]: " pc
    case "$pc" in 2) pr="tcp";; 3) pr="udp";; *) pr="both";; esac
    
    read -rp "Создать $rn :$sp → $di:$dp? (y/n): " cf
    [[ "$cf" != "y" ]] && return
    
    echo "${rn}|${sp}|${di}|${dp}|${pr}|1" >> "$RULES_FILE"
    add_rule_backend "$sp" "$di" "$dp" "$pr"
    [[ "$BACKEND" == "xdp" ]] && create_xdp_program && compile_and_load_xdp
    
    print_success "Добавлено"; sleep 2
}

quick_add() {
    print_header
    echo "Формат: НАЗВАНИЕ ПОРТ IP [ПОРТ_НАЗН]"
    read -rp "Ввод: " inp
    read -r rn sp di dp <<< "$inp"; dp="${dp:-443}"
    
    [[ -z "$rn" || -z "$sp" || -z "$di" ]] && return
    rn="${rn//|/}"
    
    echo "${rn}|${sp}|${di}|${dp}|both|1" >> "$RULES_FILE"
    add_rule_backend "$sp" "$di" "$dp" "both"
    [[ "$BACKEND" == "xdp" ]] && create_xdp_program && compile_and_load_xdp
    
    print_success "$rn: :$sp → $di:$dp"; sleep 2
}

toggle_rule() {
    print_header
    [[ ! -s "$RULES_FILE" ]] && return
    
    local i=1
    while IFS='|' read -r n sp di dp pr en; do
        [[ -z "$n" || "$n" == \#* || -z "$sp" ]] && continue
        [[ "$en" == "1" ]] && st="${GREEN}ВКЛ${NC}" || st="${GRAY}ВЫКЛ${NC}"
        echo -e "$i) [$st] $n :$sp → $di:$dp"; i=$((i+1))
    done < "$RULES_FILE"
    
    read -rp "Номер: " num; [[ ! "$num" =~ ^[0-9]+$ ]] && return
    
    local ln=0 tn="" tsp="" tdi="" tdp="" tpr="" ten=""
    while IFS='|' read -r n sp di dp pr en; do
        [[ -z "$n" || "$n" == \#* || -z "$sp" ]] && continue
        ln=$((ln+1)); [[ $ln -eq $num ]] && { tn="$n"; tsp="$sp"; tdi="$di"; tdp="$dp"; tpr="$pr"; ten="$en"; break; }
    done < "$RULES_FILE"
    
    [[ -z "$tn" ]] && return
    
    if [[ "$ten" == "1" ]]; then
        ne="0"; remove_rule_backend "$tsp" "$tdi" "$tdp" "$tpr"
    else
        ne="1"; add_rule_backend "$tsp" "$tdi" "$tdp" "$tpr"
    fi
    
    local tf=$(mktemp)
    while IFS='|' read -r n sp di dp pr en; do
        [[ -z "$n" ]] && continue
        [[ "$n" == "$tn" ]] && echo "${tn}|${tsp}|${tdi}|${tdp}|${tpr}|${ne}" >> "$tf" || echo "${n}|${sp}|${di}|${dp}|${pr}|${en}" >> "$tf"
    done < "$RULES_FILE"
    mv "$tf" "$RULES_FILE"
    
    [[ "$BACKEND" == "xdp" ]] && create_xdp_program && compile_and_load_xdp
    print_success "Переключено"; sleep 2
}

delete_rule() {
    print_header
    [[ ! -s "$RULES_FILE" ]] && return
    
    local i=1
    while IFS='|' read -r n sp di dp pr en; do
        [[ -z "$n" || "$n" == \#* || -z "$sp" ]] && continue
        echo "$i) $n :$sp → $di:$dp"; i=$((i+1))
    done < "$RULES_FILE"
    
    read -rp "Номер: " num; [[ ! "$num" =~ ^[0-9]+$ ]] && return
    
    local ln=0 tn="" tsp="" tdi="" tdp="" tpr="" ten=""
    while IFS='|' read -r n sp di dp pr en; do
        [[ -z "$n" || "$n" == \#* || -z "$sp" ]] && continue
        ln=$((ln+1)); [[ $ln -eq $num ]] && { tn="$n"; tsp="$sp"; tdi="$di"; tdp="$dp"; tpr="$pr"; ten="$en"; break; }
    done < "$RULES_FILE"
    
    [[ -z "$tn" ]] && return
    
    read -rp "Удалить $tn? (y/n): " cf; [[ "$cf" != "y" ]] && return
    
    [[ "$ten" == "1" ]] && remove_rule_backend "$tsp" "$tdi" "$tdp" "$tpr"
    grep -v "^${tn}|" "$RULES_FILE" > "$RULES_FILE.tmp" && mv "$RULES_FILE.tmp" "$RULES_FILE"
    [[ "$BACKEND" == "xdp" ]] && create_xdp_program && compile_and_load_xdp
    
    print_success "Удалено"; sleep 2
}

show_status() {
    print_header
    echo -e "${CYAN}📊 Статус${NC}"
    echo ""
    [[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" == "1" ]] && print_success "IP Forward: ON" || print_error "IP Forward: OFF"
    
    local c=$(get_rules_count); read -r t e <<< "$c"
    echo "Правил: $t всего, $e включено"
    echo "Backend: $BACKEND"
    echo "Conntrack: $(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)/$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null)"
    
    echo ""; read -rp "Enter..."
}

cleanup_duplicates() {
    case "$BACKEND" in
        nftables) nft flush chain ip nat prerouting 2>/dev/null;;
        *) iptables -t nat -F PREROUTING 2>/dev/null;;
    esac
    apply_rules
}

main_menu() {
    while true; do
        print_header
        local c=$(get_rules_count); read -r t e <<< "$c"
        echo -e "  Правил: ${CYAN}$t${NC}, ${GREEN}$e${NC} вкл | Backend: ${MAGENTA}$BACKEND${NC}"
        [[ "$OPTIMIZATION_APPLIED" == "1" ]] && echo -e "  ${GREEN}Оптимизация применена${NC}"
        echo ""
        echo "  1) 📋 Показать правила"
        echo "  2) ➕ Добавить"
        echo "  3) ⚡ Быстрое добавление"
        echo "  4) 🔄 Вкл/Выкл"
        echo "  5) 🗑️  Удалить"
        echo "  6) 📊 Статус"
        echo "  7) 🧹 Очистить дубликаты"
        echo ""
        echo -e "  ${MAGENTA}8) ⚡ Оптимизация DNAT${NC}"
        echo -e "  ${CYAN}9) 📈 Статус оптимизации${NC}"
        echo ""
        echo "  0) 🚪 Выход"
        echo ""
        
        read -rp "Выбор: " ch
        case "$ch" in
            1) show_rules;; 2) add_rule;; 3) quick_add;; 4) toggle_rule;;
            5) delete_rule;; 6) show_status;;
            7) cleanup_duplicates; print_success "Очищено"; sleep 2;;
            8) optimization_menu;; 9) show_optimization_status;;
            0) exit 0;;
        esac
    done
}

check_root
initial_setup
apply_rules
main_menu
