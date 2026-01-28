# DNAT Manager

Interactive script for managing DNAT rules in iptables.

## Installation
```bash
wget -O /usr/local/bin/nat-manager https://raw.githubusercontent.com/FastCon-telegram/DNAT/main/nat-manager.sh
chmod +x /usr/local/bin/nat-manager
```

## Usage
```bash
sudo nat-manager
```

## Features

- Add DNAT rules (TCP/UDP)
- Delete rules  
- Auto-save (persists after reboot)
- Automatic IP Forwarding and MASQUERADE setup