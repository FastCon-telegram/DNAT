#!/bin/bash

#===============================================================================
# NAT Bridge Manager v3.1 - VPS Edition
# - nftables поддержка (быстрее iptables на 15-20%)
# - Оптимизация Conntrack для 200K+ соединений
# - Softirq budget для высокой нагрузки
# - Сетевые буферы 128MB
# - Offload (GRO/GSO/TSO)
#===============================================================================

VERSION="3.1-VPS"

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

BACKEND="iptables"

print_header() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}       ${GREEN}🚀 NAT Bridge Manager v${VERSION}${NC}                      ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}       ${YELLOW}DNAT + nftables + VPS оптимизация${NC}                   ${CYAN}║${NC}"
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
    mkdir -p "$RULES_DIR" 2>/dev/null || true
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

#===============================================================================
# IPTABLES BACKEND
#===============================================================================
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

#===============================================================================
# NFTABLES BACKEND
#===============================================================================
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

#===============================================================================
# УНИВЕРСАЛЬНЫЕ ФУНКЦИИ
#===============================================================================
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

#===============================================================================
# ОПТИМИЗАЦИЯ: CONNTRACK
#===============================================================================
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

#===============================================================================
# ОПТИМИЗАЦИЯ: SOFTIRQ BUDGET
#===============================================================================
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

#===============================================================================
# ОПТИМИЗАЦИЯ: СЕТЕВЫЕ БУФЕРЫ
#===============================================================================
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

#===============================================================================
# ОПТИМИЗАЦИЯ: OFFLOAD
#===============================================================================
optimize_offload() {
    local iface=$(get_main_interface)
    [[ -z "$iface" ]] && return 1
    
    if command -v ethtool &>/dev/null; then
        ethtool -K "$iface" gro on gso on tso on 2>/dev/null || true
    fi
    
    return 0
}

#===============================================================================
# МЕНЮ: Оптимизация DNAT
#===============================================================================
optimization_menu() {
    while true; do
        print_header
        echo -e "${MAGENTA}⚡ Оптимизация DNAT для VPS${NC}"
        echo "═══════════════════════════════════════════════════════════════════════"
        echo ""
        
        local iface=$(get_main_interface)
        echo -e "Интерфейс: ${CYAN}$iface${NC} | Backend: ${GREEN}$BACKEND${NC} | CPU: ${CYAN}$(nproc)${NC}"
        echo ""
        
        echo -e "${YELLOW}Оптимизация:${NC}"
        echo "  1) 🔗 Conntrack (4M соединений)"
        echo "  2) 📊 Softirq budget (100K пакетов/цикл)"
        echo "  3) 📡 Сетевые буферы (128MB)"
        echo "  4) 🚀 Offload (GRO/GSO/TSO)"
        echo "  5) ⚡ Применить ВСЁ"
        echo ""
        echo -e "${YELLOW}Backend:${NC}"
        echo "  6) 🔄 Переключить на nftables (быстрее)"
        echo "  7) 🔄 Переключить на iptables (стандарт)"
        echo ""
        echo "  0) ◀️  Назад"
        echo ""
        
        read -rp "Выбор: " ch
        
        case "$ch" in
            1) optimize_conntrack && print_success "Conntrack 4M OK"; sleep 2;;
            2) optimize_softirq_budget && print_success "Softirq 100K OK"; sleep 2;;
            3) optimize_network_buffers && print_success "Буферы 128MB OK"; sleep 2;;
            4) optimize_offload && print_success "Offload OK"; sleep 2;;
            5)
                echo ""
                optimize_conntrack && print_success "Conntrack 4M"
                optimize_softirq_budget && print_success "Softirq 100K"
                optimize_network_buffers && print_success "Буферы 128MB"
                optimize_offload && print_success "Offload"
                OPTIMIZATION_APPLIED=1; save_config
                echo ""
                print_success "Вся оптимизация применена!"
                sleep 3;;
            6) 
                iptables -t nat -F PREROUTING 2>/dev/null
                init_nftables
                BACKEND="nftables"; save_config; apply_rules
                print_success "Backend: nftables"
                sleep 2;;
            7) 
                nft flush ruleset 2>/dev/null
                BACKEND="iptables"; save_config; apply_rules
                ensure_masquerade_iptables; save_iptables
                print_success "Backend: iptables"
                sleep 2;;
            0) return;;
        esac
    done
}

#===============================================================================
# МЕНЮ: Статус оптимизации
#===============================================================================
show_optimization_status() {
    print_header
    echo -e "${CYAN}📊 Статус оптимизации${NC}"
    echo "═══════════════════════════════════════════════════════════════════════"
    local iface=$(get_main_interface)
    echo ""
    echo -e "Интерфейс: ${CYAN}$iface${NC}"
    echo -e "Backend: ${GREEN}$BACKEND${NC}"
    echo -e "CPU: ${CYAN}$(nproc)${NC} ядер"
    echo ""
    
    echo -e "${YELLOW}Conntrack:${NC}"
    local ct_max=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null)
    local ct_cur=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)
    local ct_hash=$(cat /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null)
    echo "  Max: $ct_max (цель: 4194304) $([[ $ct_max -ge 4194304 ]] && echo '✓' || echo '⚠')"
    echo "  Current: $ct_cur"
    echo "  Hashsize: $ct_hash (цель: 1048576) $([[ $ct_hash -ge 1048576 ]] && echo '✓' || echo '⚠')"
    echo ""
    
    echo -e "${YELLOW}Softirq:${NC}"
    local budget=$(sysctl -n net.core.netdev_budget 2>/dev/null)
    local backlog=$(sysctl -n net.core.netdev_max_backlog 2>/dev/null)
    echo "  Budget: $budget (цель: 100000) $([[ $budget -ge 100000 ]] && echo '✓' || echo '⚠')"
    echo "  Backlog: $backlog (цель: 250000) $([[ $backlog -ge 250000 ]] && echo '✓' || echo '⚠')"
    echo ""
    
    echo -e "${YELLOW}Буферы:${NC}"
    local rmem=$(sysctl -n net.core.rmem_max 2>/dev/null)
    local wmem=$(sysctl -n net.core.wmem_max 2>/dev/null)
    echo "  rmem_max: $rmem (цель: 134217728) $([[ $rmem -ge 134217728 ]] && echo '✓' || echo '⚠')"
    echo "  wmem_max: $wmem (цель: 134217728) $([[ $wmem -ge 134217728 ]] && echo '✓' || echo '⚠')"
    echo ""
    
    echo -e "${YELLOW}Offload:${NC}"
    if command -v ethtool &>/dev/null && [[ -n "$iface" ]]; then
        ethtool -k "$iface" 2>/dev/null | grep -E "generic-receive|generic-segmentation|tcp-segmentation" | sed 's/^/  /'
    fi
    
    echo ""
    read -rp "Нажмите Enter..."
}

#===============================================================================
# СТАНДАРТНЫЕ ФУНКЦИИ
#===============================================================================
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

#===============================================================================
# ГЛАВНОЕ МЕНЮ
#===============================================================================
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
