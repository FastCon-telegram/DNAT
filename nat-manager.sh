#!/bin/bash

#===============================================================================
# NAT Bridge Manager v2.2
# - Исправлены дубликаты правил (проверка перед добавлением)
# - Именованные правила с поддержкой вкл/выкл  
# - Отображение протокола TCP/UDP
#===============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

RULES_DIR="/etc/nat-bridge"
RULES_FILE="$RULES_DIR/rules.conf"

print_header() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}          ${GREEN}🌐 NAT Bridge Manager v2.2${NC}                        ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}          ${YELLOW}Управление DNAT правилами${NC}                         ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Запустите от root: sudo $0"
        exit 1
    fi
}

initial_setup() {
    mkdir -p "$RULES_DIR" 2>/dev/null || true
    touch "$RULES_FILE" 2>/dev/null || true
    echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
    grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf 2>/dev/null
    sysctl -p > /dev/null 2>&1 || true
    
    if ! command -v netfilter-persistent &> /dev/null; then
        apt-get update -qq 2>/dev/null || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent > /dev/null 2>&1 || true
    fi
}

save_iptables() {
    mkdir -p /etc/iptables 2>/dev/null || true
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    netfilter-persistent save > /dev/null 2>&1 || true
}

ensure_masquerade() {
    iptables -t nat -C POSTROUTING -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -j MASQUERADE 2>/dev/null || true
}

# Добавить правило с проверкой на дубликат
add_iptables_rule() {
    local sp="$1" di="$2" dp="$3" pr="$4"
    [[ -z "$sp" || -z "$di" || -z "$dp" ]] && return
    
    # TCP: проверяем существование, если нет - добавляем
    if [[ "$pr" == "both" || "$pr" == "tcp" ]]; then
        if ! iptables -t nat -C PREROUTING -p tcp --dport "$sp" -j DNAT --to-destination "$di:$dp" 2>/dev/null; then
            iptables -t nat -A PREROUTING -p tcp --dport "$sp" -j DNAT --to-destination "$di:$dp" 2>/dev/null || true
        fi
    fi
    
    # UDP: проверяем существование, если нет - добавляем
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

apply_rules() {
    [[ ! -f "$RULES_FILE" ]] && return
    while IFS='|' read -r name sp di dp pr en; do
        [[ -z "$name" || "$name" == \#* || -z "$sp" ]] && continue
        [[ "$en" == "1" ]] && add_iptables_rule "$sp" "$di" "$dp" "$pr"
    done < "$RULES_FILE"
    ensure_masquerade
    save_iptables
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
    echo -e "${GREEN}📋 Список DNAT правил${NC}"
    echo "═══════════════════════════════════════════════════════════════════════"
    echo ""
    
    if [[ ! -s "$RULES_FILE" ]]; then
        print_warning "Нет настроенных правил"
        echo ""; read -rp "Нажмите Enter..."; return
    fi
    
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
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════"
    iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -q "MASQUERADE" && print_success "MASQUERADE: активен" || print_warning "MASQUERADE: не настроен"
    echo ""; read -rp "Нажмите Enter..."
}

add_rule() {
    print_header
    echo -e "${GREEN}➕ Добавление нового правила${NC}"
    echo "───────────────────────────────────────────────────────────────"
    echo ""
    
    local rn="" sp="" di="" dp="" pc="" pr="" cf=""
    
    read -rp "Название правила (напр. aeza-spb): " rn
    [[ -z "$rn" ]] && { print_error "Название обязательно"; sleep 2; return; }
    rn="${rn//|/}"
    grep -q "^${rn}|" "$RULES_FILE" 2>/dev/null && { print_error "Правило '$rn' уже существует"; sleep 2; return; }
    
    while true; do
        read -rp "Входящий порт: " sp
        [[ "$sp" =~ ^[0-9]+$ ]] && [[ "$sp" -ge 1 ]] && [[ "$sp" -le 65535 ]] && break
        print_error "Порт 1-65535"
    done
    
    while true; do
        read -rp "IP назначения: " di
        [[ "$di" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
        print_error "Неверный IP"
    done
    
    read -rp "Порт назначения [443]: " dp; dp="${dp:-443}"
    
    echo ""; echo "Протокол: 1) TCP+UDP  2) TCP  3) UDP"
    read -rp "Выбор [1]: " pc; pc="${pc:-1}"
    case "$pc" in 2) pr="tcp";; 3) pr="udp";; *) pr="both";; esac
    
    echo ""; echo -e "Создать: ${CYAN}$rn${NC} — :$sp → $di:$dp ($pr)"
    read -rp "Подтвердить? (y/n): " cf
    [[ "$cf" != "y" && "$cf" != "Y" ]] && return
    
    echo "${rn}|${sp}|${di}|${dp}|${pr}|1" >> "$RULES_FILE"
    add_iptables_rule "$sp" "$di" "$dp" "$pr"
    ensure_masquerade
    save_iptables
    
    print_success "Правило '$rn' добавлено и включено"
    sleep 2
}

quick_add() {
    print_header
    echo -e "${GREEN}⚡ Быстрое добавление${NC}"
    echo "───────────────────────────────────────────────────────────────"
    echo ""; echo "Формат: НАЗВАНИЕ ПОРТ IP [ПОРТ_НАЗН]"
    echo "Пример: aeza-spb 44333 116.202.1.1 443"; echo ""
    
    local inp="" rn="" sp="" di="" dp=""
    read -rp "Ввод: " inp
    read -r rn sp di dp <<< "$inp"
    dp="${dp:-443}"
    
    [[ -z "$rn" || -z "$sp" || -z "$di" ]] && { print_error "Неверный формат"; sleep 2; return; }
    rn="${rn//|/}"
    grep -q "^${rn}|" "$RULES_FILE" 2>/dev/null && { print_error "Правило '$rn' уже существует"; sleep 2; return; }
    
    echo "${rn}|${sp}|${di}|${dp}|both|1" >> "$RULES_FILE"
    add_iptables_rule "$sp" "$di" "$dp" "both"
    ensure_masquerade
    save_iptables
    
    print_success "$rn: :$sp → $di:$dp"
    sleep 2
}

toggle_rule() {
    print_header
    echo -e "${BLUE}🔄 Включить/Выключить правило${NC}"
    echo "───────────────────────────────────────────────────────────────"
    echo ""
    
    [[ ! -s "$RULES_FILE" ]] && { print_warning "Нет правил"; sleep 2; return; }
    
    echo -e "${YELLOW}#   Статус   Название              Порт       Назначение${NC}"
    echo "───────────────────────────────────────────────────────────────"
    
    local i=1
    while IFS='|' read -r n sp di dp pr en; do
        [[ -z "$n" || "$n" == \#* || -z "$sp" ]] && continue
        [[ "$en" == "1" ]] && st="${GREEN}● ВКЛ${NC}" || st="${GRAY}○ ВЫКЛ${NC}"
        printf "%-3s  [%b]  %-20s  %-9s  %s:%s\n" "$i" "$st" "$n" ":$sp" "$di" "$dp"
        i=$((i+1))
    done < "$RULES_FILE"
    
    echo ""
    local num=""
    read -rp "Номер правила (q - отмена): " num
    [[ "$num" == "q" || "$num" == "Q" || -z "$num" ]] && return
    [[ ! "$num" =~ ^[0-9]+$ ]] && { print_error "Неверный номер"; sleep 2; return; }
    
    local ln=0 tn="" tsp="" tdi="" tdp="" tpr="" ten=""
    while IFS='|' read -r n sp di dp pr en; do
        [[ -z "$n" || "$n" == \#* || -z "$sp" ]] && continue
        ln=$((ln+1))
        [[ $ln -eq $num ]] && { tn="$n"; tsp="$sp"; tdi="$di"; tdp="$dp"; tpr="$pr"; ten="$en"; break; }
    done < "$RULES_FILE"
    
    [[ -z "$tn" ]] && { print_error "Правило не найдено"; sleep 2; return; }
    
    local ne=""
    if [[ "$ten" == "1" ]]; then
        ne="0"; remove_iptables_rule "$tsp" "$tdi" "$tdp" "$tpr"
        print_success "Правило '$tn' ВЫКЛЮЧЕНО"
    else
        ne="1"; add_iptables_rule "$tsp" "$tdi" "$tdp" "$tpr"; ensure_masquerade
        print_success "Правило '$tn' ВКЛЮЧЕНО"
    fi
    
    local tf; tf=$(mktemp)
    while IFS='|' read -r n sp di dp pr en; do
        [[ -z "$n" ]] && continue
        [[ "$n" == "$tn" ]] && echo "${tn}|${tsp}|${tdi}|${tdp}|${tpr}|${ne}" >> "$tf" || echo "${n}|${sp}|${di}|${dp}|${pr}|${en}" >> "$tf"
    done < "$RULES_FILE"
    mv "$tf" "$RULES_FILE"
    
    save_iptables
    sleep 2
}

delete_rule() {
    print_header
    echo -e "${RED}🗑️  Удаление правила${NC}"
    echo "───────────────────────────────────────────────────────────────"
    echo ""
    
    [[ ! -s "$RULES_FILE" ]] && { print_warning "Нет правил"; sleep 2; return; }
    
    echo -e "${YELLOW}#   Статус   Название              Порт       Назначение${NC}"
    echo "───────────────────────────────────────────────────────────────"
    
    local i=1
    while IFS='|' read -r n sp di dp pr en; do
        [[ -z "$n" || "$n" == \#* || -z "$sp" ]] && continue
        [[ "$en" == "1" ]] && st="${GREEN}● ВКЛ${NC}" || st="${GRAY}○ ВЫКЛ${NC}"
        printf "%-3s  [%b]  %-20s  %-9s  %s:%s\n" "$i" "$st" "$n" ":$sp" "$di" "$dp"
        i=$((i+1))
    done < "$RULES_FILE"
    
    echo ""
    local num=""
    read -rp "Номер для УДАЛЕНИЯ (q - отмена): " num
    [[ "$num" == "q" || "$num" == "Q" || -z "$num" ]] && return
    [[ ! "$num" =~ ^[0-9]+$ ]] && { print_error "Неверный номер"; sleep 2; return; }
    
    local ln=0 tn="" tsp="" tdi="" tdp="" tpr="" ten=""
    while IFS='|' read -r n sp di dp pr en; do
        [[ -z "$n" || "$n" == \#* || -z "$sp" ]] && continue
        ln=$((ln+1))
        [[ $ln -eq $num ]] && { tn="$n"; tsp="$sp"; tdi="$di"; tdp="$dp"; tpr="$pr"; ten="$en"; break; }
    done < "$RULES_FILE"
    
    [[ -z "$tn" ]] && { print_error "Правило не найдено"; sleep 2; return; }
    
    local cf=""
    read -rp "Удалить '$tn'? (y/n): " cf
    [[ "$cf" != "y" && "$cf" != "Y" ]] && return
    
    [[ "$ten" == "1" ]] && remove_iptables_rule "$tsp" "$tdi" "$tdp" "$tpr"
    grep -v "^${tn}|" "$RULES_FILE" > "$RULES_FILE.tmp" 2>/dev/null && mv "$RULES_FILE.tmp" "$RULES_FILE"
    
    save_iptables
    print_success "Правило '$tn' удалено"
    sleep 2
}

rename_rule() {
    print_header
    echo -e "${BLUE}✏️  Переименовать правило${NC}"
    echo "───────────────────────────────────────────────────────────────"
    echo ""
    
    [[ ! -s "$RULES_FILE" ]] && { print_warning "Нет правил"; sleep 2; return; }
    
    local i=1
    while IFS='|' read -r n sp di dp pr en; do
        [[ -z "$n" || "$n" == \#* || -z "$sp" ]] && continue
        echo "$i) $n"; i=$((i+1))
    done < "$RULES_FILE"
    
    echo ""
    local num=""
    read -rp "Номер правила (q - отмена): " num
    [[ "$num" == "q" || "$num" == "Q" || -z "$num" ]] && return
    [[ ! "$num" =~ ^[0-9]+$ ]] && { print_error "Неверный номер"; sleep 2; return; }
    
    local ln=0 on=""
    while IFS='|' read -r n sp di dp pr en; do
        [[ -z "$n" || "$n" == \#* || -z "$sp" ]] && continue
        ln=$((ln+1)); [[ $ln -eq $num ]] && { on="$n"; break; }
    done < "$RULES_FILE"
    
    [[ -z "$on" ]] && { print_error "Не найдено"; sleep 2; return; }
    
    local nn=""
    read -rp "Новое название для '$on': " nn
    nn="${nn//|/}"
    [[ -z "$nn" ]] && { print_error "Название обязательно"; sleep 2; return; }
    
    sed -i "s/^${on}|/${nn}|/" "$RULES_FILE"
    print_success "Переименовано: $on → $nn"
    sleep 2
}

show_status() {
    print_header
    echo -e "${CYAN}📊 Статус системы${NC}"
    echo "───────────────────────────────────────────────────────────────"
    echo ""
    
    [[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" == "1" ]] && print_success "IP Forwarding: ВКЛ" || print_error "IP Forwarding: ВЫКЛ"
    
    local c; c=$(get_rules_count); local t e; read -r t e <<< "$c"
    echo -e "  Всего правил: ${CYAN}$t${NC} (${GREEN}$e ВКЛ${NC} / ${GRAY}$((t-e)) ВЫКЛ${NC})"
    
    iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -q "MASQUERADE" && print_success "MASQUERADE: ВКЛ" || print_warning "MASQUERADE: ВЫКЛ"
    command -v netfilter-persistent &>/dev/null && print_success "iptables-persistent: OK" || print_warning "iptables-persistent: нет"
    
    echo ""; echo -e "${YELLOW}Активные DNAT правила:${NC}"
    local dr; dr=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep "DNAT" | head -10)
    [[ -n "$dr" ]] && echo "$dr" || echo "  (нет)"
    
    echo ""; read -rp "Нажмите Enter..."
}

# Очистка дубликатов в iptables
cleanup_duplicates() {
    [[ ! -f "$RULES_FILE" ]] && return
    
    # Сначала удаляем все DNAT правила
    iptables -t nat -F PREROUTING 2>/dev/null || true
    
    # Затем добавляем только нужные (из конфига)
    while IFS='|' read -r name sp di dp pr en; do
        [[ -z "$name" || "$name" == \#* || -z "$sp" ]] && continue
        [[ "$en" == "1" ]] && add_iptables_rule "$sp" "$di" "$dp" "$pr"
    done < "$RULES_FILE"
    
    ensure_masquerade
    save_iptables
}

main_menu() {
    while true; do
        print_header
        local c; c=$(get_rules_count); local t e; read -r t e <<< "$c"
        echo -e "  Правил: ${CYAN}$t${NC} всего, ${GREEN}$e${NC} включено"
        echo ""; echo -e "${YELLOW}Меню:${NC}"; echo ""
        echo "  1) 📋 Показать правила"
        echo "  2) ➕ Добавить правило"
        echo "  3) ⚡ Быстрое добавление"
        echo "  4) 🔄 Включить/Выключить"
        echo "  5) ✏️  Переименовать"
        echo "  6) 🗑️  Удалить правило"
        echo "  7) 📊 Статус"
        echo "  8) 🧹 Очистить дубликаты"
        echo "  0) 🚪 Выход"
        echo ""
        
        local ch=""
        read -rp "Выбор: " ch
        case "$ch" in
            1) show_rules;; 2) add_rule;; 3) quick_add;; 4) toggle_rule;;
            5) rename_rule;; 6) delete_rule;; 7) show_status;;
            8) cleanup_duplicates; print_success "Дубликаты очищены"; sleep 2;;
            0) print_success "До свидания!"; exit 0;;
            *) print_error "Неверный выбор"; sleep 1;;
        esac
    done
}

check_root
initial_setup
apply_rules
main_menu
