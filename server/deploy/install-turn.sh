#!/usr/bin/env bash
# 在具有公网 IP 的 Ubuntu/Debian 主机运行；密钥只保存到该主机，不打印。
# sudo bash install-turn.sh <公网 IPv4>
set -euo pipefail
[[ $EUID == 0 ]] || { echo '请通过 sudo 运行'; exit 1; }
public_ip="${1:?用法: sudo bash install-turn.sh <公网 IPv4>}"
python3 - "$public_ip" <<'PY'
import ipaddress, sys
address = ipaddress.ip_address(sys.argv[1])
if address.version != 4 or not address.is_global:
    raise SystemExit('需要公网 IPv4 地址')
PY
if ! command -v turnserver >/dev/null; then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y coturn
  systemctl disable --now coturn
fi
install -d -m 750 -o root -g turnserver /etc/coturn
if [[ ! -f /etc/coturn/uniconsole.secret ]]; then
  (umask 077; openssl rand -hex 32 > /etc/coturn/uniconsole.secret)
fi
python3 - "$public_ip" <<'PY'
from pathlib import Path
import os, socket, sys
secret = Path('/etc/coturn/uniconsole.secret').read_text().strip()
if len(secret) < 32 or not secret.isalnum():
    raise SystemExit('TURN 密钥格式无效')
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
    sock.connect(('1.1.1.1', 53))
    local_ip = sock.getsockname()[0]
text = f'''listening-port=3478
listening-ip={local_ip}
relay-ip={local_ip}
external-ip={sys.argv[1]}/{local_ip}
min-port=49160
max-port=49200
realm=uniconsole
server-name=uniconsole-turn
fingerprint
use-auth-secret
static-auth-secret={secret}
stale-nonce=600
user-quota=4
total-quota=32
max-bps=2000000
no-tls
no-dtls
no-tcp-relay
no-multicast-peers
no-cli
no-software-attribute
denied-peer-ip=0.0.0.0-0.255.255.255
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=127.0.0.0-127.255.255.255
denied-peer-ip=169.254.0.0-169.254.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
denied-peer-ip=224.0.0.0-255.255.255.255
denied-peer-ip=::1
denied-peer-ip=fc00::-fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff
denied-peer-ip=fe80::-febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff
log-file=syslog
simple-log
'''
path = Path('/etc/coturn/uniconsole.conf')
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o640)
with os.fdopen(fd, 'w') as file:
    file.write(text)
PY
chown root:turnserver /etc/coturn/uniconsole.conf
cat > /etc/systemd/system/uniconsole-turn.service <<'UNIT'
[Unit]
Description=UniConsole TURN media relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=turnserver
Group=turnserver
ExecStart=/usr/bin/turnserver -c /etc/coturn/uniconsole.conf --pidfile=
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now uniconsole-turn
systemctl restart uniconsole-turn
systemctl is-active uniconsole-turn
echo 'TURN 已启动；云安全组需允许 3478/TCP、3478/UDP、49160-49200/UDP。'
echo '共享密钥保存在 /etc/coturn/uniconsole.secret（root 只读），请同步到后端 TURN_SECRET。'
