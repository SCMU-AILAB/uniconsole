#!/usr/bin/env bash
# 在狗端运行；复用已安装原生 bindings 的 Go2Agent 环境，不修改 Go2Agent 仓库。
set -euo pipefail
robot_dir="$(cd "$(dirname "$0")/.." && pwd)"
go2_dir="${1:-$HOME/Go2Agent}"
uv_bin="${UV_BIN:-$HOME/.local/bin/uv}"
test -f "$robot_dir/.env" || { echo '请先配置 robot/.env'; exit 1; }
test -x "$go2_dir/.venv/bin/python" || { echo '找不到 Go2Agent Python 环境'; exit 1; }
cd "$robot_dir"
"$uv_bin" venv --allow-existing --python "$go2_dir/.venv/bin/python"
"$uv_bin" sync --frozen --no-dev --extra video
.venv/bin/python - "$go2_dir" <<'PY'
from pathlib import Path
import subprocess
import sys
import sysconfig

go2 = Path(sys.argv[1]).resolve()
site = subprocess.check_output(
    [str(go2 / '.venv/bin/python'), '-c', 'import sysconfig; print(sysconfig.get_path("purelib"))'],
    text=True,
).strip()
Path(sysconfig.get_path('purelib'), 'go2-local.pth').write_text(f'{site}\n{go2 / "src"}\n')
PY
.venv/bin/python -c 'import unitree_sdk2_cpp; from core.runtime import SkillRuntime; from robot import UnitreeGo2Adapter'
.venv/bin/python - <<'PY'
from uniagent.config import Settings
settings = Settings.from_env()
if settings.video_enabled:
    import aiortc
    from perception.go2_front import Go2FrontCamera
if settings.lidar_enabled:
    from perception.go2_lidar import Go2Lidar
PY
chmod 600 .env
mkdir -p "$HOME/.config/systemd/user"
.venv/bin/python - "$robot_dir" <<'PY'
from pathlib import Path
import sys

def quote(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%') + '"'
root = sys.argv[1]
if '\n' in root or '\r' in root:
    raise SystemExit('安装目录不能包含换行')
unit = f'''[Unit]
Description=UniConsole Go2 robot agent
After=network-online.target

[Service]
Type=simple
WorkingDirectory={root.replace('%', '%%')}
ExecStart={quote(root + '/.venv/bin/uniagent')}
Environment=PYTHONUNBUFFERED=1
UMask=0077
Restart=on-failure
RestartSec=5
TimeoutStopSec=15

[Install]
WantedBy=default.target
'''
(Path.home() / '.config/systemd/user/uniagent.service').write_text(unit)
PY
systemctl --user daemon-reload
systemctl --user enable --now uniagent.service
systemctl --user is-active uniagent.service
