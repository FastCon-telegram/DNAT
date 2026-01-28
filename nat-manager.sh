#!/bin/bash

#===============================================================================
# NAT Bridge Manager - Управление DNAT правилами
# Версия: 1.0
#===============================================================================

set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

RULES_DIR="/etc/nat-bridge"
RULES_FILE="$RULES_DIR/rules.conf"

#-------------------------------------------------------------------------------
# Функции вывода
#-------------------------------------------------------------------------------
print_header() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}          ${GREEN}🌐 NAT Bridge Manager v1.0${NC}                        ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}          ${YELLOW}Управление DNAT правилами${NC}                         ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ $1${NC}"; }

#-------------------------------------------------------------------------------
# Проверка root прав
#-------------------------------------------------------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Запустите с правами root: sudo $0"
        exit 1
    fi
}

#-------------------------------------------------------------------------------
# Первоначальная настройка
#-------------------------------------------------------------------------------
initial_setup() {
    mkdir -p "$RULES_DIR"
    
    # Включаем IP forwarding
    if [[ $(cat /proc/sys/net/ipv4/ip_forward) != "1" ]]; then
        echo 1 > /proc/sys/net/ipv4/ip_forward
    fi
    
    # Делаем постоянным
    if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        sysctl -p > /dev/null 2>&1
    fi
    
    # Устанавливаем iptables-persistent
    if ! command -v netfilter-persistent &> /dev/null; then
        print_warning "Устанавливаю iptables-persistent..."
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent > /dev/null 2>&1
        print_success "iptables-persistent установлен"
    fi
}

#-------------------------------------------------------------------------------
# Сохранение правил
#-------------------------------------------------------------------------------
save_rules() {
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    netfilter-persistent save > /dev/null 2>&1 || true
    print_success "Правила сохранены"
}

#-------------------------------------------------------------------------------
# Показать правила
#-------------------------------------------------------------------------------
show_rules() {
    print_header
    echo -e "${GREEN}📋 Текущие DNAT правила${NC}"
    echo "═════════════════════════════════════════════════════════════"
    echo ""
    
    rules=$(iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep "DNAT" || true)
    
    if [[ -z "$rules" ]]; then
        print_warning "Нет активных DNAT правил"
    else
        echo -e "${YELLOW}№   Прото   Порт      →   Назначение${NC}"
        echo "─────────────────────────────────────────────────────────────"
        
        iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep "DNAT" | while read line; do
            num=$(echo "$line" | awk '{print $1}')
            proto=$(echo "$line" | awk '{print $2}')
            dpt=$(echo "$line" | grep -oP 'dpt:\K[0-9]+' || echo "-")
            dest=$(echo "$line" | grep -oP 'to:[\d.:]+' | sed 's/to://')
            printf "${GREEN}%-3s${NC} %-7s %-9s  →  ${CYAN}%s${NC}\n" "$num" "$proto" "$dpt" "$dest"
        done
    fi
    
    echo ""
    echo "═════════════════════════════════════════════════════════════"
    
    # MASQUERADE статус
    if iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -q "MASQUERADE"; then
        print_success "MASQUERADE: активен"
    else
        print_warning "MASQUERADE: не настроен"
    fi
    
    echo ""
    read -p "Нажмите Enter..."
}

#-------------------------------------------------------------------------------
# Добавить правило
#-------------------------------------------------------------------------------
add_rule() {
    print_header
    echo -e "${GREEN}➕ Добавление DNAT правила${NC}"
    echo "─────────────────────────────────────────────────────────────"
    echo ""
    
    # Входной порт
    while true; do
        read -p "Входящий порт: " src_port
        [[ "$src_port" =~ ^[0-9]+$ ]] && [ "$src_port" -ge 1 ] && [ "$src_port" -le 65535 ] && break
        print_error "Порт 1-65535"
    done
    
    # IP назначения
    while true; do
        read -p "IP назначения: " dest_ip
        [[ "$dest_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
        print_error "Неверный IP"
    done
    
    # Порт назначения
    read -p "Порт назначения [443]: " dest_port
    dest_port=${dest_port:-443}
    
    # Протокол
    echo ""
    echo "Протокол: 1) TCP+UDP  2) TCP  3) UDP"
    read -p "Выбор [1]: " proto
    proto=${proto:-1}
    
    echo ""
    echo -e "Создать: ${CYAN}:$src_port → $dest_ip:$dest_port${NC}"
    read -p "Подтвердить? (y/n): " confirm
    [[ "$confirm" != "y" ]] && return
    
    # Добавляем правила
    case $proto in
        1)
            iptables -t nat -A PREROUTING -p tcp --dport "$src_port" -j DNAT --to-destination "$dest_ip:$dest_port"
            iptables -t nat -A PREROUTING -p udp --dport "$src_port" -j DNAT --to-destination "$dest_ip:$dest_port"
            ;;
        2) iptables -t nat -A PREROUTING -p tcp --dport "$src_port" -j DNAT --to-destination "$dest_ip:$dest_port" ;;
        3) iptables -t nat -A PREROUTING -p udp --dport "$src_port" -j DNAT --to-destination "$dest_ip:$dest_port" ;;
    esac
    
    # MASQUERADE
    iptables -t nat -C POSTROUTING -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -j MASQUERADE
    
    print_success "Правило добавлено"
    save_rules
    
    read -p "Нажмите Enter..."
}

#-------------------------------------------------------------------------------
# Быстрое добавление
#-------------------------------------------------------------------------------
quick_add() {
    print_header
    echo -e "${GREEN}⚡ Быстрое добавление${NC}"
    echo "─────────────────────────────────────────────────────────────"
    echo ""
    echo "Формат: ПОРТ IP [ПОРТ_НАЗН]"
    echo "Пример: 44333 116.202.1.1 443"
    echo ""
    read -p "Ввод: " src_port dest_ip dest_port
    dest_port=${dest_port:-443}
    
    if [[ -z "$src_port" || -z "$dest_ip" ]]; then
        print_error "Неверный формат"
        sleep 2
        return
    fi
    
    iptables -t nat -A PREROUTING -p tcp --dport "$src_port" -j DNAT --to-destination "$dest_ip:$dest_port"
    iptables -t nat -A PREROUTING -p udp --dport "$src_port" -j DNAT --to-destination "$dest_ip:$dest_port"
    iptables -t nat -C POSTROUTING -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -j MASQUERADE
    
    print_success ":$src_port → $dest_ip:$dest_port"
    save_rules
    sleep 2
}

#-------------------------------------------------------------------------------
# Удалить правило
#-------------------------------------------------------------------------------
delete_rule() {
    print_header
    echo -e "${RED}🗑️  Удаление правила${NC}"
    echo "─────────────────────────────────────────────────────────────"
    echo ""
    
    rules=$(iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep "DNAT" || true)
    
    if [[ -z "$rules" ]]; then
        print_warning "Нет правил"
        sleep 2
        return
    fi
    
    echo -e "${YELLOW}№   Прото   Порт      →   Назначение${NC}"
    echo "─────────────────────────────────────────────────────────────"
    
    iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep "DNAT" | while read line; do
        num=$(echo "$line" | awk '{print $1}')
        proto=$(echo "$line" | awk '{print $2}')
        dpt=$(echo "$line" | grep -oP 'dpt:\K[0-9]+' || echo "-")
        dest=$(echo "$line" | grep -oP 'to:[\d.:]+' | sed 's/to://')
        printf "${GREEN}%-3s${NC} %-7s %-9s  →  %s\n" "$num" "$proto" "$dpt" "$dest"
    done
    
    echo ""
    read -p "Номер для удаления (q - отмена): " num
    [[ "$num" == "q" ]] && return
    
    if [[ "$num" =~ ^[0-9]+$ ]]; then
        iptables -t nat -D PREROUTING "$num" 2>/dev/null && print_success "Удалено" || print_error "Ошибка"
        save_rules
    fi
    
    read -p "Нажмите Enter..."
}

#-------------------------------------------------------------------------------
# Удалить все
#-------------------------------------------------------------------------------
flush_all() {
    print_header
    echo -e "${RED}⚠️  Удаление ВСЕХ правил${NC}"
    echo ""
    read -p "Введите 'YES' для подтверждения: " confirm
    
    if [[ "$confirm" == "YES" ]]; then
        iptables -t nat -F PREROUTING
        iptables -t nat -F POSTROUTING
        print_success "Все правила удалены"
        save_rules
    fi
    sleep 2
}

#-------------------------------------------------------------------------------
# Статус
#-------------------------------------------------------------------------------
show_status() {
    print_header
    echo -e "${CYAN}📊 Статус системы${NC}"
    echo "─────────────────────────────────────────────────────────────"
    echo ""
    
    # IP Forward
    [[ $(cat /proc/sys/net/ipv4/ip_forward) == "1" ]] && print_success "IP Forwarding: ON" || print_error "IP Forwarding: OFF"
    
    # Правила
    rules=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c "DNAT" || echo "0")
    echo -e "  DNAT правил: ${CYAN}$rules${NC}"
    
    # MASQUERADE
    iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -q "MASQUERADE" && print_success "MASQUERADE: ON" || print_warning "MASQUERADE: OFF"
    
    # persistent
    command -v netfilter-persistent &>/dev/null && print_success "iptables-persistent: OK" || print_warning "iptables-persistent: нет"
    
    echo ""
    read -p "Нажмите Enter..."
}

#-------------------------------------------------------------------------------
# Главное меню
#-------------------------------------------------------------------------------
main_menu() {
    while true; do
        print_header
        
        rules=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c "DNAT" || echo "0")
        echo -e "  Активных правил: ${CYAN}$rules${NC}"
        echo ""
        echo -e "${YELLOW}Меню:${NC}"
        echo ""
        echo "  1) 📋 Показать правила"
        echo "  2) ➕ Добавить правило"
        echo "  3) ⚡ Быстрое добавление"
        echo "  4) 🗑️  Удалить правило"
        echo "  5) 🧹 Удалить ВСЕ"
        echo "  6) 📊 Статус"
        echo "  0) 🚪 Выход"
        echo ""
        read -p "Выбор: " choice
        
        case $choice in
            1) show_rules ;;
            2) add_rule ;;
            3) quick_add ;;
            4) delete_rule ;;
            5) flush_all ;;
            6) show_status ;;
            0) print_success "Выход"; exit 0 ;;
            *) print_error "Неверный выбор"; sleep 1 ;;
        esac
    done
}

#-------------------------------------------------------------------------------
# Запуск
#-------------------------------------------------------------------------------
check_root
initial_setup
main_menu
