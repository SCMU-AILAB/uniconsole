#!/usr/bin/env bash
# 在服务器上运行（幂等）：Postgres 容器 + .env + systemd 服务。
# 需要：docker、sudo、~/.cargo/bin/cargo。
#   PORT=8800 ADMIN=kanade bash deploy/setup.sh
set -euo pipefail

cd "$(dirname "$0")/.."
SERVER_DIR=$(pwd)
PORT=${PORT:-8800}
ADMIN=${ADMIN:-kanade}
DB_CONTAINER=uniconsole-db
DB_PORT=${DB_PORT:-5432}

rand() { head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "$1"; }

# ── .env（已存在则保留，不覆盖密钥） ──
if [[ ! -f .env ]]; then
  DB_PASSWORD=$(rand 32)
  ADMIN_PASSWORD=$(rand 16)
  cat > .env <<EOF
BIND_ADDR=0.0.0.0:${PORT}
DATABASE_URL=postgres://uniconsole:${DB_PASSWORD}@127.0.0.1:${DB_PORT}/uniconsole
DB_MAX_CONNECTIONS=20
JWT_SECRET=$(rand 64)
JWT_TTL_SECS=43200
CORS_ORIGINS=
BOOTSTRAP_ADMIN=${ADMIN}
BOOTSTRAP_PASSWORD=${ADMIN_PASSWORD}
RUST_LOG=uniconsole_server=info,tower_http=info
EOF
  chmod 600 .env
  echo "已生成 .env；初始管理员 ${ADMIN} / ${ADMIN_PASSWORD}（首次启动时创建，请登录后修改密码）"
fi
DB_PASSWORD=$(grep '^DATABASE_URL=' .env | sed -E 's#.*://uniconsole:([^@]+)@.*#\1#')

# ── Postgres 17（只监听本机） ──
if ! sudo docker ps -a --format '{{.Names}}' | grep -qx "$DB_CONTAINER"; then
  sudo docker run -d --name "$DB_CONTAINER" --restart unless-stopped \
    -e POSTGRES_USER=uniconsole -e POSTGRES_PASSWORD="$DB_PASSWORD" -e POSTGRES_DB=uniconsole \
    -p "127.0.0.1:${DB_PORT}:5432" -v uniconsole-pgdata:/var/lib/postgresql/data \
    postgres:17
fi
sudo docker start "$DB_CONTAINER" >/dev/null
for _ in $(seq 1 60); do
  sudo docker exec "$DB_CONTAINER" pg_isready -U uniconsole -q && break
  sleep 1
done

# ── 编译 ──
"$HOME/.cargo/bin/cargo" build --release -p uniconsole-server

# ── systemd ──
sudo tee /etc/systemd/system/uniconsole-server.service >/dev/null <<EOF
[Unit]
Description=UniConsole server
After=network-online.target docker.service
Wants=network-online.target

[Service]
User=$(id -un)
WorkingDirectory=${SERVER_DIR}
EnvironmentFile=${SERVER_DIR}/.env
ExecStart=${SERVER_DIR}/target/release/uniconsole-server
Restart=on-failure
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable uniconsole-server >/dev/null
sudo systemctl restart uniconsole-server

for _ in $(seq 1 30); do
  curl -sf "http://127.0.0.1:${PORT}/healthz" && echo && break
  sleep 1
done
systemctl --no-pager --lines=5 status uniconsole-server | head -12
