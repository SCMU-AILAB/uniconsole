# Go2 实机链路

2026-11-13 接入设备 `go2-cf-01`（Go2 实机）。

- 狗端：`cf@192.168.31.74`，目录 `~/uniconsole/robot`，用户服务 `uniagent.service`。
- 后端：`192.168.31.144:8800`，公网入口 `1.13.195.109:8800`。
- 狗端通过局域网 WebSocket 接入后端；DDS 仅使用 `eth0`，复用已有 Go2Agent 和原生 bindings。
- 前端登录填 `http://1.13.195.109:8800`；同网段也可填 `http://192.168.31.144:8800`，并允许系统的局域网访问权限。
- 设备页进入「Go2 实机」→「申请控制权」→ 单机操控。当前账号角色及设备授权由后端校验。

真实登录后，设备、遥测、单机指令、租约、安全策略和成员仓库使用后端。
控制帧走 WebSocket，普通指令等待机器人回执。断线、窗口失焦、失去控制权或急停会清空摇杆和按键，
重连不重放旧输入。狗端保留 300 ms 看门狗、断线停止、自动重连。

遥测角度在界面中换算为度，定位朝向仍保留弧度。电池、关节温度、足端力等缺失字段显示 `—`；
Go2 未报告的实际姿态模式不使用最后下发的模式冒充。
视频和点云尚未接入；实机页明确显示相机未接入，不显示演示视频帧率或视频延迟。
其他业务页面（任务、联调、告警编辑、运维、智能体等）的仓库仍为演示实现，不属于本次实机控制验证。

## 验证

已通过前端仓库到真机的完整流程：读取在线设备、实时遥测、申请/续约控制权、Stop 回执、单机急停演练回执、
读取指令日志、释放控制权。此次未执行真实走动、起身或舞蹈；SDK 接受命令不代表动作物理完成。
公网转发链路出现过心跳超时，狗端现使用同网段直连；网络丢包仍会触发停止和重连。

可重复验证（仅使用空闲设备；不会发送运动指令）：

```bash
UNICONSOLE_E2E_SESSION_FILE=/安全路径/session.json \
UNICONSOLE_E2E_DEVICE=go2-cf-01 \
flutter test --no-pub test/e2e/live_robot_e2e_test.dart
```

会话文件与 TokenStore 格式一致，包含 `server`、`token`、`session_id`、`expires_at`、`member`，权限设为 `600`，不提交。
若终端配置了 HTTP 代理，请确保后端地址不经不支持 WebSocket 的代理；测试进程的 macOS 局域网权限与应用本身独立。
开发环境使用 `/opt/homebrew/share/flutter/bin/flutter`（Flutter 3.47.9 / Dart 3.13.7）。

狗端运维：

```bash
ssh cf@192.168.31.74
systemctl --user status uniagent
systemctl --user restart uniagent
curl http://127.0.0.1:18000/health
sudo journalctl _SYSTEMD_USER_UNIT=uniagent.service -n 50
```
