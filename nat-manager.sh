#!/bin/bash

#===============================================================================
# NAT Bridge Manager v2.0
# - Именованные правила с поддержкой вкл/выкл
# - Отображение протокола TCP/UDP
#===============================================================================

set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

# Конфиг
RULES_DIR="/etc/nat-bridge"
RULES_FILE="$RULES_DIR/rules.conf"

#-------------------------------------------------------------------------------
# Функции вывода
#-------------------------------------------------------------------------------
print_header() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}          ${GREEN}🌐 NAT Bridge Manager v2.0${NC}                        ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}          ${YELLOW}Управление DNAT правилами${NC}                         ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ $1${NC}"; }

#-------------------------------------------------------------------------------
# Проверка root
#-------------------------------------------------------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Запустите от root: sudo $0"
        exit 1
    fi
}

#-------------------------------------------------------------------------------
# Начальная настройка
#-------------------------------------------------------------------------------
initial_setup() {
    mkdir -p "$RULES_DIR"
    touch "$RULES_FILE"

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
# Сохранение правил iptables
#-------------------------------------------------------------------------------
save_iptables() {
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    netfilter-persistent save > /dev/null 2>&1 || true
}

#-------------------------------------------------------------------------------
# Добавление MASQUERADE
#-------------------------------------------------------------------------------
ensure_masquerade() {
    if ! iptables -t nat -C POSTROUTING -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -j MASQUERADE
    fi
}

#-------------------------------------------------------------------------------
# Добавить правило iptables
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
# Удалить правило iptables
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
# Загрузить правила из конфига и применить включенные
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
# Показать все правила
#-------------------------------------------------------------------------------
show_rules() {
    print_header
    echo -e "${GREEN}📋 Список DNAT правил${NC}"
    echo "═══════════════════════════════════════════════════════════════════════"
    echo ""

    if [[ ! -s "$RULES_FILE" ]]; then
        print_warning "Нет настроенных правил"
        echo ""
        read -p "Нажмите Enter..."
        return
    fi

    echo -e "${YELLOW}#   Статус   Название              Порт       Назначение           Прото${NC}"
    echo "───────────────────────────────────────────────────────────────────────"

    local i=1
    while IFS='|' read -r name src_port dest_ip dest_port proto enabled || [[ -n "$name" ]]; do
        [[ -z "$name" || "$name" == \#* ]] && continue

        if [[ "$enabled" == "1" ]]; then
            status="${GREEN}● ВКЛ${NC}"
        else
            status="${GRAY}○ ВЫКЛ${NC}"
        fi

        # Отображение протокола
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
    echo "═══════════════════════════════════════════════════════════════════════"
    
    # Статус MASQUERADE
    if iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -q "MASQUERADE"; then
        print_success "MASQUERADE: активен"
    else
        print_warning "MASQUERADE: не настроен"
    fi

    echo ""
    read -p "Нажмите Enter..."
}

#-------------------------------------------------------------------------------
# Добавить новое правило
#-------------------------------------------------------------------------------
add_rule() {
    print_header
    echo -e "${GREEN}➕ Добавление нового правила${NC}"
    echo "───────────────────────────────────────────────────────────────"
    echo ""

    # Название правила
    read -p "Название правила (напр. aeza-spb): " rule_name
    if [[ -z "$rule_name" ]]; then
        print_error "Название обязательно"
        sleep 2
        return
    fi
    
    # Убираем спецсимволы
    rule_name=$(echo "$rule_name" | tr -d '|')

    # Проверка дубликата
    if grep -q "^$rule_name|" "$RULES_FILE" 2>/dev/null; then
        print_error "Правило '$rule_name' уже существует"
        sleep 2
        return
    fi

    # Входящий порт
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
    echo "Протокол: 1) TCP+UDP  2) Только TCP  3) Только UDP"
    read -p "Выбор [1]: " proto_choice
    proto_choice=${proto_choice:-1}
    
    case $proto_choice in
        1) proto="both" ;;
        2) proto="tcp" ;;
        3) proto="udp" ;;
        *) proto="both" ;;
    esac

    echo ""
    echo -e "Создать: ${CYAN}$rule_name${NC} — :$src_port → $dest_ip:$dest_port ($proto)"
    read -p "Подтвердить? (y/n): " confirm
    [[ "$confirm" != "y" ]] && return

    # Сохраняем в конфиг
    echo "$rule_name|$src_port|$dest_ip|$dest_port|$proto|1" >> "$RULES_FILE"

    # Применяем правило
    add_iptables_rule "$src_port" "$dest_ip" "$dest_port" "$proto"
    ensure_masquerade
    save_iptables

    print_success "Правило '$rule_name' добавлено и включено"
    read -p "Нажмите Enter..."
}

#-------------------------------------------------------------------------------
# Переключить правило (вкл/выкл)
#-------------------------------------------------------------------------------
toggle_rule() {
    print_header
    echo -e "${BLUE}🔄 Включить/Выключить правило${NC}"
    echo "───────────────────────────────────────────────────────────────"
    echo ""

    if [[ ! -s "$RULES_FILE" ]]; then
        print_warning "Нет правил"
        sleep 2
        return
    fi

    echo -e "${YELLOW}#   Статус   Название              Порт       Назначение${NC}"
    echo "───────────────────────────────────────────────────────────────"

    local i=1
    while IFS='|' read -r name src_port dest_ip dest_port proto enabled || [[ -n "$name" ]]; do
        [[ -z "$name" || "$name" == \#* ]] && continue

        if [[ "$enabled" == "1" ]]; then
            status="${GREEN}● ВКЛ${NC}"
        else
            status="${GRAY}○ ВЫКЛ${NC}"
        fi

        printf "%-3s  [%b]  %-20s  %-9s  %s:%s\n" "$i" "$status" "$name" ":$src_port" "$dest_ip" "$dest_port"
        ((i++))
    done < "$RULES_FILE"

    echo ""
    read -p "Номер правила для переключения (q - отмена): " num
    [[ "$num" == "q" ]] && return

    if ! [[ "$num" =~ ^[0-9]+$ ]]; then
        print_error "Неверный номер"
        sleep 2
        return
    fi

    # Получаем правило по номеру
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
        print_error "Правило не найдено"
        sleep 2
        return
    fi

    # Переключаем
    if [[ "$t_enabled" == "1" ]]; then
        # Выключаем
        new_enabled="0"
        remove_iptables_rule "$t_src_port" "$t_dest_ip" "$t_dest_port" "$t_proto"
        print_success "Правило '$target_name' ВЫКЛЮЧЕНО"
    else
        # Включаем
        new_enabled="1"
        add_iptables_rule "$t_src_port" "$t_dest_ip" "$t_dest_port" "$t_proto"
        ensure_masquerade
        print_success "Правило '$target_name' ВКЛЮЧЕНО"
    fi

    # Обновляем конфиг
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
    read -p "Нажмите Enter..."
}

#-------------------------------------------------------------------------------
# Удалить правило
#-------------------------------------------------------------------------------
delete_rule() {
    print_header
    echo -e "${RED}🗑️  Удаление правила${NC}"
    echo "───────────────────────────────────────────────────────────────"
    echo ""

    if [[ ! -s "$RULES_FILE" ]]; then
        print_warning "Нет правил"
        sleep 2
        return
    fi

    echo -e "${YELLOW}#   Статус   Название              Порт       Назначение${NC}"
    echo "───────────────────────────────────────────────────────────────"

    local i=1
    while IFS='|' read -r name src_port dest_ip dest_port proto enabled || [[ -n "$name" ]]; do
        [[ -z "$name" || "$name" == \#* ]] && continue

        if [[ "$enabled" == "1" ]]; then
            status="${GREEN}● ВКЛ${NC}"
        else
            status="${GRAY}○ ВЫКЛ${NC}"
        fi

        printf "%-3s  [%b]  %-20s  %-9s  %s:%s\n" "$i" "$status" "$name" ":$src_port" "$dest_ip" "$dest_port"
        ((i++))
    done < "$RULES_FILE"

    echo ""
    read -p "Номер правила для УДАЛЕНИЯ (q - отмена): " num
    [[ "$num" == "q" ]] && return

    if ! [[ "$num" =~ ^[0-9]+$ ]]; then
        print_error "Неверный номер"
        sleep 2
        return
    fi

    # Получаем правило по номеру
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
        print_error "Правило не найдено"
        sleep 2
        return
    fi

    read -p "Удалить '$target_name'? (y/n): " confirm
    [[ "$confirm" != "y" ]] && return

    # Удаляем из iptables если включено
    if [[ "$t_enabled" == "1" ]]; then
        remove_iptables_rule "$t_src_port" "$t_dest_ip" "$t_dest_port" "$t_proto"
    fi

    # Удаляем из конфига
    grep -v "^$target_name|" "$RULES_FILE" > "$RULES_FILE.tmp" && mv "$RULES_FILE.tmp" "$RULES_FILE"

    save_iptables
    print_success "Правило '$target_name' удалено"
    read -p "Нажмите Enter..."
}

#-------------------------------------------------------------------------------
# Быстрое добавление
#-------------------------------------------------------------------------------
quick_add() {
    print_header
    echo -e "${GREEN}⚡ Быстрое добавление${NC}"
    echo "───────────────────────────────────────────────────────────────"
    echo ""
    echo "Формат: НАЗВАНИЕ ПОРТ IP [ПОРТ_НАЗН]"
    echo "Пример: aeza-spb 44333 116.202.1.1 443"
    echo ""
    read -p "Ввод: " rule_name src_port dest_ip dest_port
    dest_port=${dest_port:-443}

    if [[ -z "$rule_name" || -z "$src_port" || -z "$dest_ip" ]]; then
        print_error "Неверный формат"
        sleep 2
        return
    fi

    rule_name=$(echo "$rule_name" | tr -d '|')

    if grep -q "^$rule_name|" "$RULES_FILE" 2>/dev/null; then
        print_error "Правило '$rule_name' уже существует"
        sleep 2
        return
    fi

    echo "$rule_name|$src_port|$dest_ip|$dest_port|both|1" >> "$RULES_FILE"
    add_iptables_rule "$src_port" "$dest_ip" "$dest_port" "both"
    ensure_masquerade
    save_iptables

    print_success "$rule_name: :$src_port → $dest_ip:$dest_port"
    sleep 2
}

#-------------------------------------------------------------------------------
# Переименовать правило
#-------------------------------------------------------------------------------
rename_rule() {
    print_header
    echo -e "${BLUE}✏️  Переименовать правило${NC}"
    echo "───────────────────────────────────────────────────────────────"
    echo ""

    if [[ ! -s "$RULES_FILE" ]]; then
        print_warning "Нет правил"
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
    read -p "Номер правила (q - отмена): " num
    [[ "$num" == "q" ]] && return

    # Получаем старое имя
    local line_num=0
    local old_name=""
    while IFS='|' read -r name src_port dest_ip dest_port proto enabled || [[ -n "$name" ]]; do
        [[ -z "$name" || "$name" == \#* ]] && continue
        ((line_num++))
        [[ $line_num -eq $num ]] && old_name="$name" && break
    done < "$RULES_FILE"

    if [[ -z "$old_name" ]]; then
        print_error "Не найдено"
        sleep 2
        return
    fi

    read -p "Новое название для '$old_name': " new_name
    new_name=$(echo "$new_name" | tr -d '|')

    if [[ -z "$new_name" ]]; then
        print_error "Название обязательно"
        sleep 2
        return
    fi

    sed -i "s/^$old_name|/$new_name|/" "$RULES_FILE"
    print_success "Переименовано: $old_name → $new_name"
    read -p "Нажмите Enter..."
}

#-------------------------------------------------------------------------------
# Показать статус
#-------------------------------------------------------------------------------
show_status() {
    print_header
    echo -e "${CYAN}📊 Статус системы${NC}"
    echo "───────────────────────────────────────────────────────────────"
    echo ""

    # IP Forward
    [[ $(cat /proc/sys/net/ipv4/ip_forward) == "1" ]] && print_success "IP Forwarding: ВКЛ" || print_error "IP Forwarding: ВЫКЛ"

    # Количество правил
    local total=0 enabled=0 disabled=0
    while IFS='|' read -r name src_port dest_ip dest_port proto en || [[ -n "$name" ]]; do
        [[ -z "$name" || "$name" == \#* ]] && continue
        ((total++))
        [[ "$en" == "1" ]] && ((enabled++)) || ((disabled++))
    done < "$RULES_FILE"

    echo -e "  Всего правил: ${CYAN}$total${NC} (${GREEN}$enabled ВКЛ${NC} / ${GRAY}$disabled ВЫКЛ${NC})"

    # MASQUERADE
    iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -q "MASQUERADE" && print_success "MASQUERADE: ВКЛ" || print_warning "MASQUERADE: ВЫКЛ"

    # persistent
    command -v netfilter-persistent &>/dev/null && print_success "iptables-persistent: OK" || print_warning "iptables-persistent: нет"

    echo ""
    echo -e "${YELLOW}Активные DNAT правила в iptables:${NC}"
    iptables -t nat -L PREROUTING -n 2>/dev/null | grep "DNAT" | head -10 || echo "  (нет)"

    echo ""
    read -p "Нажмите Enter..."
}

#-------------------------------------------------------------------------------
# Главное меню
#-------------------------------------------------------------------------------
main_menu() {
    while true; do
        print_header

        # Быстрая статистика
        local total=0 enabled=0
        while IFS='|' read -r name src_port dest_ip dest_port proto en || [[ -n "$name" ]]; do
            [[ -z "$name" || "$name" == \#* ]] && continue
            ((total++))
            [[ "$en" == "1" ]] && ((enabled++))
        done < "$RULES_FILE"

        echo -e "  Правил: ${CYAN}$total${NC} всего, ${GREEN}$enabled${NC} включено"
        echo ""
        echo -e "${YELLOW}Меню:${NC}"
        echo ""
        echo "  1) 📋 Показать правила"
        echo "  2) ➕ Добавить правило"
        echo "  3) ⚡ Быстрое добавление"
        echo "  4) 🔄 Включить/Выключить"
        echo "  5) ✏️  Переименовать"
        echo "  6) 🗑️  Удалить правило"
        echo "  7) 📊 Статус"
        echo "  0) 🚪 Выход"
        echo ""
        read -p "Выбор: " choice

        case $choice in
            1) show_rules ;;
            2) add_rule ;;
            3) quick_add ;;
            4) toggle_rule ;;
            5) rename_rule ;;
            6) delete_rule ;;
            7) show_status ;;
            0) print_success "До свидания!"; exit 0 ;;
            *) print_error "Неверный выбор"; sleep 1 ;;
        esac
    done
}

#-------------------------------------------------------------------------------
# Точка входа
#-------------------------------------------------------------------------------
check_root
initial_setup
apply_rules
main_menu
