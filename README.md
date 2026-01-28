# DNAT Manager

Интерактивный скрипт для управления DNAT правилами в iptables.

## Установка
`ash
wget -O /usr/local/bin/nat-manager https://raw.githubusercontent.com/ТВОЙ_USERNAME/DNAT/main/nat-manager.sh
chmod +x /usr/local/bin/nat-manager
`

## Использование
`ash
sudo nat-manager
`

## Возможности

- Добавление DNAT правил (TCP/UDP)
- Удаление правил
- Автосохранение (переживает перезагрузку)
- Автоматическая настройка IP Forwarding и MASQUERADE
