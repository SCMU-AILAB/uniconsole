#!/usr/bin/env bash
# 在开发机运行：同步 server/ 到服务器、编译、重启。
#   deploy/deploy.sh                       # 默认 yaoyifeng@192.168.0.239
#   deploy/deploy.sh user@host --setup     # 首次部署：额外执行 setup.sh
set -euo pipefail

HOST=${1:-yaoyifeng@192.168.0.239}
REMOTE_DIR=${REMOTE_DIR:-uniconsole/server}
cd "$(dirname "$0")/.."

# 复用同一条 SSH 连接（服务器对频繁新建连接有限流）
SSH_OPTS=(-o ControlMaster=auto -o "ControlPath=$HOME/.ssh/cm-%r@%h:%p" -o ControlPersist=120 -o ConnectTimeout=15)
ssh() { command ssh "${SSH_OPTS[@]}" "$@"; }

ssh "$HOST" "mkdir -p $REMOTE_DIR"
# .env 与 target 留在服务器上（--delete 不会删除被排除的文件）
rsync -az --delete --exclude target --exclude .env -e "ssh ${SSH_OPTS[*]}" ./ "$HOST:$REMOTE_DIR/"

if [[ "${2:-}" == "--setup" ]]; then
  ssh -t "$HOST" "cd $REMOTE_DIR && bash deploy/setup.sh"
else
  ssh "$HOST" "cd $REMOTE_DIR && ~/.cargo/bin/cargo build --release -p uniconsole-server \
    && sudo systemctl restart uniconsole-server \
    && for i in \$(seq 1 30); do curl --noproxy '*' -sf http://127.0.0.1:\$(grep -oP '(?<=BIND_ADDR=0.0.0.0:)\d+' .env)/healthz && echo && break; sleep 1; done"
fi
