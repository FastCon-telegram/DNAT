#!/bin/bash

#===============================================================================
# NAT Bridge Manager v2.0
# - Named rules with enable/disable support
# - TCP/UDP protocol display
#===============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

# Config
RULES_DIR="/etc/nat-bridge"
RULES_FILE="$RULES_DIR/rules.conf"

#-------------------------------------------------------------------------------
# Output functions
#-------------------------------------------------------------------------------
print_header() {
    clear
    echo -e "${CYAN}+==============================================================+${NC}"
    echo -e "${CYAN}|${NC}          ${GREEN}NAT Bridge Manager v2.0${NC}                           ${CYAN}|${NC}"
    echo -e "${CYAN}|${NC}          ${YELLOW}DNAT Rules Management${NC}                             ${CYAN}|${NC}"
    echo -e "${CYAN}+==============================================================+${NC}"
    echo ""
}

print_success() { echo -e "${GREEN}[OK] $1${NC}"; }
print_error() { echo -e "${RED}[ERROR] $1${NC}"; }
print_warning() { echo -e "${YELLOW}[WARN] $1${NC}"; }
print_info() { echo -e "${BLUE}[INFO] $1${NC}"; }

#-------------------------------------------------------------------------------
# Check root
#-------------------------------------------------------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Run as root: sudo $0"
        exit 1
    fi
}

#-------------------------------------------------------------------------------
# Initial setup
#-------------------------------------------------------------------------------
initial_setup() {
    mkdir -p "$RULES_DIR"
    touch "$RULES_FILE"

    # Enable IP forwarding
    if [[ $(cat /proc/sys/net/ipv4/ip_forward) != "1" ]]; then
        echo 1 > /proc/sys/net/ipv4/ip_forward
    fi

    # Make permanent
    if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        sysctl -p > /dev/null 2>&1
    fi

    # Install iptables-persistent
    if ! command -v netfilter-persistent &> /dev/null; then
        print_warning "Installing iptables-persistent..."
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent > /dev/null 2>&1
        print_success "iptables-persistent installed"
    fi
}

#-------------------------------------------------------------------------------
# Save iptables rules
#-------------------------------------------------------------------------------
save_iptables() {
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    netfilter-persistent save > /dev/null 2>&1 || true
}

#-------------------------------------------------------------------------------
# Ensure MASQUERADE
#-------------------------------------------------------------------------------
ensure_masquerade() {
    if ! iptables -t nat -C POSTROUTING -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -j MASQUERADE
    fi
}

#-------------------------------------------------------------------------------
# Add iptables rule
#-------------------------------------------------------------------------------
add_iptables_rule() {
    local src_port=$1
    local dest_ip=$2
    local dest_port=$3
    local proto=$4  # tcp, udp, both

    if [[ "$proto" == "both" || "$proto" == "tcp" ]]; then
        iptables -t nat -A PREROUTING -p tcp --dport "$src_port" -j DNAT --to-destination "$dest_ip:$dest_port" 2>/dev/null || true
    fi
    if [[ "$proto" == "both" || "$proto" == "udp" ]]; then
        iptables -t nat -A PREROUTING -p udp --dport "$src_port" -j DNAT --to-destination "$dest_ip:$dest_port" 2>/dev/null || true
    fi
}

#-------------------------------------------------------------------------------
# Remove iptables rule
#-------------------------------------------------------------------------------
remove_iptables_rule() {
    local src_port=$1
    local dest_ip=$2
    local dest_port=$3
    local proto=$4

    if [[ "$proto" == "both" || "$proto" == "tcp" ]]; then
        iptables -t nat -D PREROUTING -p tcp --dport "$src_port" -j DNAT --to-destination "$dest_ip:$dest_port" 2>/dev/null || true
    fi
    if [[ "$proto" == "both" || "$proto" == "udp" ]]; then
        iptables -t nat -D PREROUTING -p udp --dport "$src_port" -j DNAT --to-destination "$dest_ip:$dest_port" 2>/dev/null || true
    fi
}

#-------------------------------------------------------------------------------
# Load rules from config and apply enabled ones
#-------------------------------------------------------------------------------
apply_rules() {
    while IFS='|' read -r name src_port dest_ip dest_port proto enabled || [[ -n "$name" ]]; do
        [[ -z "$name" || "$name" == \#* ]] && continue
        
        if [[ "$enabled" == "1" ]]; then
            add_iptables_rule "$src_port" "$dest_ip" "$dest_port" "$proto"
        fi
    done < "$RULES_FILE"
    
    ensure_masquerade
    save_iptables
}

#-------------------------------------------------------------------------------
# Show all rules
#-------------------------------------------------------------------------------
show_rules() {
    print_header
    echo -e "${GREEN}[RULES] DNAT Rules List${NC}"
    echo "======================================================================="
    echo ""

    if [[ ! -s "$RULES_FILE" ]]; then
        print_warning "No rules configured"
        echo ""
        read -p "Press Enter..."
        return
    fi

    echo -e "${YELLOW}#   Status   Name                  Port       Destination          Proto${NC}"
    echo "-----------------------------------------------------------------------"

    local i=1
    while IFS='|' read -r name src_port dest_ip dest_port proto enabled || [[ -n "$name" ]]; do
        [[ -z "$name" || "$name" == \#* ]] && continue

        if [[ "$enabled" == "1" ]]; then
            status="${GREEN}ON ${NC}"
        else
            status="${GRAY}OFF${NC}"
        fi

        # Protocol display
        case "$proto" in
            both) proto_disp="TCP+UDP" ;;
            tcp)  proto_disp="TCP" ;;
            udp)  proto_disp="UDP" ;;
            *)    proto_disp="$proto" ;;
        esac

        printf "%-3s  [%b]  %-20s  %-9s  %-19s  %s\n" "$i" "$status" "$name" ":$src_port" "$dest_ip:$dest_port" "$proto_disp"
        ((i++))
    done < "$RULES_FILE"

    echo ""
    echo "======================================================================="
    
    # MASQUERADE status
    if iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -q "MASQUERADE"; then
        print_success "MASQUERADE: active"
    else
        print_warning "MASQUERADE: not configured"
    fi

    echo ""
    read -p "Press Enter..."
}

#-------------------------------------------------------------------------------
# Add new rule
#-------------------------------------------------------------------------------
add_rule() {
    print_header
    echo -e "${GREEN}[ADD] Add New Rule${NC}"
    echo "-----------------------------------------------------------------------"
    echo ""

    # Rule name
    read -p "Rule name (e.g. aeza-spb): " rule_name
    if [[ -z "$rule_name" ]]; then
        print_error "Name required"
        sleep 2
        return
    fi
    
    # Remove special chars
    rule_name=$(echo "$rule_name" | tr -d '|')

    # Check duplicate name
    if grep -q "^$rule_name|" "$RULES_FILE" 2>/dev/null; then
        print_error "Rule '$rule_name' already exists"
        sleep 2
        return
    fi

    # Source port
    while true; do
        read -p "Incoming port: " src_port
        [[ "$src_port" =~ ^[0-9]+$ ]] && [ "$src_port" -ge 1 ] && [ "$src_port" -le 65535 ] && break
        print_error "Port 1-65535"
    done

    # Destination IP
    while true; do
        read -p "Destination IP: " dest_ip
        [[ "$dest_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
        print_error "Invalid IP"
    done

    # Destination port
    read -p "Destination port [443]: " dest_port
    dest_port=${dest_port:-443}

    # Protocol
    echo ""
    echo "Protocol: 1) TCP+UDP  2) TCP only  3) UDP only"
    read -p "Choice [1]: " proto_choice
    proto_choice=${proto_choice:-1}
    
    case $proto_choice in
        1) proto="both" ;;
        2) proto="tcp" ;;
        3) proto="udp" ;;
        *) proto="both" ;;
    esac

    echo ""
    echo -e "Create: ${CYAN}$rule_name${NC} -- :$src_port -> $dest_ip:$dest_port ($proto)"
    read -p "Confirm? (y/n): " confirm
    [[ "$confirm" != "y" ]] && return

    # Save to config
    echo "$rule_name|$src_port|$dest_ip|$dest_port|$proto|1" >> "$RULES_FILE"

    # Apply rule
    add_iptables_rule "$src_port" "$dest_ip" "$dest_port" "$proto"
    ensure_masquerade
    save_iptables

    print_success "Rule '$rule_name' added and enabled"
    read -p "Press Enter..."
}

#-------------------------------------------------------------------------------
# Toggle rule (enable/disable)
#-------------------------------------------------------------------------------
toggle_rule() {
    print_header
    echo -e "${BLUE}[TOGGLE] Enable/Disable Rule${NC}"
    echo "-----------------------------------------------------------------------"
    echo ""

    if [[ ! -s "$RULES_FILE" ]]; then
        print_warning "No rules"
        sleep 2
        return
    fi

    echo -e "${YELLOW}#   Status   Name                  Port       Destination${NC}"
    echo "-----------------------------------------------------------------------"

    local i=1
    while IFS='|' read -r name src_port dest_ip dest_port proto enabled || [[ -n "$name" ]]; do
        [[ -z "$name" || "$name" == \#* ]] && continue

        if [[ "$enabled" == "1" ]]; then
            status="${GREEN}ON ${NC}"
        else
            status="${GRAY}OFF${NC}"
        fi

        printf "%-3s  [%b]  %-20s  %-9s  %s:%s\n" "$i" "$status" "$name" ":$src_port" "$dest_ip" "$dest_port"
        ((i++))
    done < "$RULES_FILE"

    echo ""
    read -p "Rule number to toggle (q - cancel): " num
    [[ "$num" == "q" ]] && return

    if ! [[ "$num" =~ ^[0-9]+$ ]]; then
        print_error "Invalid number"
        sleep 2
        return
    fi

    # Get rule by number
    local line_num=0
    local target_name=""
    local t_src_port="" t_dest_ip="" t_dest_port="" t_proto="" t_enabled=""
    
    while IFS='|' read -r name src_port dest_ip dest_port proto enabled || [[ -n "$name" ]]; do
        [[ -z "$name" || "$name" == \#* ]] && continue
        ((line_num++))
        if [[ $line_num -eq $num ]]; then
            target_name="$name"
            t_src_port="$src_port"
            t_dest_ip="$dest_ip"
            t_dest_port="$dest_port"
            t_proto="$proto"
            t_enabled="$enabled"
            break
        fi
    done < "$RULES_FILE"

    if [[ -z "$target_name" ]]; then
        print_error "Rule not found"
        sleep 2
        return
    fi

    # Toggle
    if [[ "$t_enabled" == "1" ]]; then
        # Disable
        new_enabled="0"
        remove_iptables_rule "$t_src_port" "$t_dest_ip" "$t_dest_port" "$t_proto"
        print_success "Rule '$target_name' DISABLED"
    else
        # Enable
        new_enabled="1"
        add_iptables_rule "$t_src_port" "$t_dest_ip" "$t_dest_port" "$t_proto"
        ensure_masquerade
        print_success "Rule '$target_name' ENABLED"
    fi

    # Update config file
    local tmp_file=$(mktemp)
    while IFS='|' read -r n sp di dp pr en || [[ -n "$n" ]]; do
        [[ -z "$n" ]] && continue
        if [[ "$n" == "$target_name" ]]; then
            echo "$target_name|$t_src_port|$t_dest_ip|$t_dest_port|$t_proto|$new_enabled" >> "$tmp_file"
        else
            echo "$n|$sp|$di|$dp|$pr|$en" >> "$tmp_file"
        fi
    done < "$RULES_FILE"
    mv "$tmp_file" "$RULES_FILE"

    save_iptables
    read -p "Press Enter..."
}

#-------------------------------------------------------------------------------
# Delete rule
#-------------------------------------------------------------------------------
delete_rule() {
    print_header
    echo -e "${RED}[DELETE] Delete Rule${NC}"
    echo "-----------------------------------------------------------------------"
    echo ""

    if [[ ! -s "$RULES_FILE" ]]; then
        print_warning "No rules"
        sleep 2
        return
    fi

    echo -e "${YELLOW}#   Status   Name                  Port       Destination${NC}"
    echo "-----------------------------------------------------------------------"

    local i=1
    while IFS='|' read -r name src_port dest_ip dest_port proto enabled || [[ -n "$name" ]]; do
        [[ -z "$name" || "$name" == \#* ]] && continue

        if [[ "$enabled" == "1" ]]; then
            status="${GREEN}ON ${NC}"
        else
            status="${GRAY}OFF${NC}"
        fi

        printf "%-3s  [%b]  %-20s  %-9s  %s:%s\n" "$i" "$status" "$name" ":$src_port" "$dest_ip" "$dest_port"
        ((i++))
    done < "$RULES_FILE"

    echo ""
    read -p "Rule number to DELETE (q - cancel): " num
    [[ "$num" == "q" ]] && return

    if ! [[ "$num" =~ ^[0-9]+$ ]]; then
        print_error "Invalid number"
        sleep 2
        return
    fi

    # Get rule by number
    local line_num=0
    local target_name=""
    local t_src_port="" t_dest_ip="" t_dest_port="" t_proto="" t_enabled=""
    
    while IFS='|' read -r name src_port dest_ip dest_port proto enabled || [[ -n "$name" ]]; do
        [[ -z "$name" || "$name" == \#* ]] && continue
        ((line_num++))
        if [[ $line_num -eq $num ]]; then
            target_name="$name"
            t_src_port="$src_port"
            t_dest_ip="$dest_ip"
            t_dest_port="$dest_port"
            t_proto="$proto"
            t_enabled="$enabled"
            break
        fi
    done < "$RULES_FILE"

    if [[ -z "$target_name" ]]; then
        print_error "Rule not found"
        sleep 2
        return
    fi

    read -p "Delete '$target_name'? (y/n): " confirm
    [[ "$confirm" != "y" ]] && return

    # Remove from iptables if enabled
    if [[ "$t_enabled" == "1" ]]; then
        remove_iptables_rule "$t_src_port" "$t_dest_ip" "$t_dest_port" "$t_proto"
    fi

    # Remove from config
    grep -v "^$target_name|" "$RULES_FILE" > "$RULES_FILE.tmp" && mv "$RULES_FILE.tmp" "$RULES_FILE"

    save_iptables
    print_success "Rule '$target_name' deleted"
    read -p "Press Enter..."
}

#-------------------------------------------------------------------------------
# Quick add
#-------------------------------------------------------------------------------
quick_add() {
    print_header
    echo -e "${GREEN}[QUICK] Quick Add${NC}"
    echo "-----------------------------------------------------------------------"
    echo ""
    echo "Format: NAME PORT IP [DEST_PORT]"
    echo "Example: aeza-spb 44333 116.202.1.1 443"
    echo ""
    read -p "Input: " rule_name src_port dest_ip dest_port
    dest_port=${dest_port:-443}

    if [[ -z "$rule_name" || -z "$src_port" || -z "$dest_ip" ]]; then
        print_error "Invalid format"
        sleep 2
        return
    fi

    rule_name=$(echo "$rule_name" | tr -d '|')

    if grep -q "^$rule_name|" "$RULES_FILE" 2>/dev/null; then
        print_error "Rule '$rule_name' already exists"
        sleep 2
        return
    fi

    echo "$rule_name|$src_port|$dest_ip|$dest_port|both|1" >> "$RULES_FILE"
    add_iptables_rule "$src_port" "$dest_ip" "$dest_port" "both"
    ensure_masquerade
    save_iptables

    print_success "$rule_name: :$src_port -> $dest_ip:$dest_port"
    sleep 2
}

#-------------------------------------------------------------------------------
# Rename rule
#-------------------------------------------------------------------------------
rename_rule() {
    print_header
    echo -e "${BLUE}[RENAME] Rename Rule${NC}"
    echo "-----------------------------------------------------------------------"
    echo ""

    if [[ ! -s "$RULES_FILE" ]]; then
        print_warning "No rules"
        sleep 2
        return
    fi

    local i=1
    while IFS='|' read -r name src_port dest_ip dest_port proto enabled || [[ -n "$name" ]]; do
        [[ -z "$name" || "$name" == \#* ]] && continue
        echo "$i) $name"
        ((i++))
    done < "$RULES_FILE"

    echo ""
    read -p "Rule number (q - cancel): " num
    [[ "$num" == "q" ]] && return

    # Get old name
    local line_num=0
    local old_name=""
    while IFS='|' read -r name src_port dest_ip dest_port proto enabled || [[ -n "$name" ]]; do
        [[ -z "$name" || "$name" == \#* ]] && continue
        ((line_num++))
        [[ $line_num -eq $num ]] && old_name="$name" && break
    done < "$RULES_FILE"

    if [[ -z "$old_name" ]]; then
        print_error "Not found"
        sleep 2
        return
    fi

    read -p "New name for '$old_name': " new_name
    new_name=$(echo "$new_name" | tr -d '|')

    if [[ -z "$new_name" ]]; then
        print_error "Name required"
        sleep 2
        return
    fi

    sed -i "s/^$old_name|/$new_name|/" "$RULES_FILE"
    print_success "Renamed: $old_name -> $new_name"
    read -p "Press Enter..."
}

#-------------------------------------------------------------------------------
# Show status
#-------------------------------------------------------------------------------
show_status() {
    print_header
    echo -e "${CYAN}[STATUS] System Status${NC}"
    echo "-----------------------------------------------------------------------"
    echo ""

    # IP Forward
    [[ $(cat /proc/sys/net/ipv4/ip_forward) == "1" ]] && print_success "IP Forwarding: ON" || print_error "IP Forwarding: OFF"

    # Rules count
    local total=0 enabled=0 disabled=0
    while IFS='|' read -r name src_port dest_ip dest_port proto en || [[ -n "$name" ]]; do
        [[ -z "$name" || "$name" == \#* ]] && continue
        ((total++))
        [[ "$en" == "1" ]] && ((enabled++)) || ((disabled++))
    done < "$RULES_FILE"

    echo -e "  Total rules: ${CYAN}$total${NC} (${GREEN}$enabled ON${NC} / ${GRAY}$disabled OFF${NC})"

    # MASQUERADE
    iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -q "MASQUERADE" && print_success "MASQUERADE: ON" || print_warning "MASQUERADE: OFF"

    # persistent
    command -v netfilter-persistent &>/dev/null && print_success "iptables-persistent: OK" || print_warning "iptables-persistent: missing"

    echo ""
    echo -e "${YELLOW}Active iptables DNAT rules:${NC}"
    iptables -t nat -L PREROUTING -n 2>/dev/null | grep "DNAT" | head -10 || echo "  (none)"

    echo ""
    read -p "Press Enter..."
}

#-------------------------------------------------------------------------------
# Main menu
#-------------------------------------------------------------------------------
main_menu() {
    while true; do
        print_header

        # Quick stats
        local total=0 enabled=0
        while IFS='|' read -r name src_port dest_ip dest_port proto en || [[ -n "$name" ]]; do
            [[ -z "$name" || "$name" == \#* ]] && continue
            ((total++))
            [[ "$en" == "1" ]] && ((enabled++))
        done < "$RULES_FILE"

        echo -e "  Rules: ${CYAN}$total${NC} total, ${GREEN}$enabled${NC} enabled"
        echo ""
        echo -e "${YELLOW}Menu:${NC}"
        echo ""
        echo "  1) Show rules"
        echo "  2) Add rule"
        echo "  3) Quick add"
        echo "  4) Enable/Disable rule"
        echo "  5) Rename rule"
        echo "  6) Delete rule"
        echo "  7) Status"
        echo "  0) Exit"
        echo ""
        read -p "Choice: " choice

        case $choice in
            1) show_rules ;;
            2) add_rule ;;
            3) quick_add ;;
            4) toggle_rule ;;
            5) rename_rule ;;
            6) delete_rule ;;
            7) show_status ;;
            0) print_success "Bye!"; exit 0 ;;
            *) print_error "Invalid choice"; sleep 1 ;;
        esac
    done
}

#-------------------------------------------------------------------------------
# Entry point
#-------------------------------------------------------------------------------
check_root
initial_setup
apply_rules
main_menu
