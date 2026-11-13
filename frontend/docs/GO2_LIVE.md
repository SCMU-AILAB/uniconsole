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
前置相机已接入 WebRTC，狗端默认输出 640×360、10 帧/秒，只提供真实存在的 `front` 相机。
真实雷达点云已接入操控页及感知中心，当前为二维俯视投影；电池和关节数据仍按缺失显示。
感知中心的总览与摄像头页也使用真实前摄像头，暂停画面会关闭该页的视频会话。
其他业务页面（任务、联调、告警编辑、运维、智能体等）的仓库仍为演示实现，不属于本次实机控制验证。

## 验证

已通过前端仓库到真机的完整流程：读取在线设备、实时遥测、申请/续约控制权、Stop 回执、单机急停演练回执、
读取指令日志、释放控制权。此次未执行真实走动、起身或舞蹈；SDK 接受命令不代表动作物理完成。
公网转发链路出现过心跳超时，狗端现使用同网段直连；网络丢包仍会触发停止和重连。

相机链路已通过真实后端的鉴权信令协商，收到连续 30 帧现场画面，帧时间戳递增。
macOS 原生 Flutter 集成测试也已收到并显示视频帧，验证纯视频接收（无音频请求），
保存接收画面并退出页面；狗端观看会话数恢复为 0。
测试不获取控制权，不发送运动指令。相机采集复用 Go2Agent 的 DDS，编解码不占用控制接收循环。
公网 TURN 已部署到 `1.13.195.109:3478`，详情见 [中继部署](../../server/deploy/turn.md)。
两个强制 relay 的端点已通过 TURN TCP 数据往返；UDP 3478 探测尚未到达云主机，仍需检查上游规则。
默认自动选择直连或中继，后端将 TCP URL 放在首位，兼容 aiortc 单 TURN 地址限制。
macOS 原生强制中继视频测试已通过：显示真实 640×360 图像，选中 ICE pair 的本地候选为 relay，
退出后狗端观看会话数为 0。此测试强制媒体经公网中继，客户端实际仍处于现场局域网。

雷达原生集成测试通过公网后端连续接收三帧并渲染俯视图，时间戳递增，每帧约 5600 点。
数据来自 `cloud_deskewed` PointCloud2，经新鲜的 `robot_pose` 从 odom 转为机身坐标。
前端仅在观看时订阅，断线或 2 秒无帧清空；原始点云包括地面点，此视图不代表避障判断或三维地图。

可重复验证（仅使用空闲设备；不会发送运动指令）：

```bash
UNICONSOLE_E2E_SESSION_FILE=/安全路径/session.json \
UNICONSOLE_E2E_DEVICE=go2-cf-01 \
flutter test --no-pub test/e2e/live_robot_e2e_test.dart
```

会话文件与 TokenStore 格式一致，包含 `server`、`token`、`session_id`、`expires_at`、`member`，权限设为 `600`，不提交。
若终端配置了 HTTP 代理，请确保后端地址不经不支持 WebSocket 的代理；测试进程的 macOS 局域网权限与应用本身独立。
开发环境使用 `/opt/homebrew/share/flutter/bin/flutter`（Flutter 3.47.9 / Dart 3.13.7）。

原生视频测试（不申请控制权、不发机器人指令）：

```bash
PATH=/opt/homebrew/share/flutter/bin:$PATH tool/run_macos.sh test \
  integration_test/camera_playback_test.dart \
  --dart-define=E2E_SESSION_FILE=/应用可读取的安全路径/session.json \
  --dart-define=E2E_DEVICE=go2-cf-01
```

macOS 沙盒下，会话文件可放在 `~/Library/Containers/com.ailab.uniconsole/Data/tmp/`，
权限设为 `600`；验证结束删除并注销测试会话。可选 `E2E_CAMERA_CAPTURE` 指定接收画面的保存路径，
`E2E_LIDAR_CAPTURE` 保存雷达俯视图。`E2E_RELAY_ONLY=true` 禁止客户端直连候选，
并检查实际选中的 ICE candidate pair 使用 relay，不能只检查「有 TURN 配置」。
运行测试后，使用 `tool/run_macos.sh build --debug` 恢复正常应用入口。

狗端运维：

```bash
ssh cf@192.168.31.74
systemctl --user status uniagent
systemctl --user restart uniagent
curl http://127.0.0.1:18000/health
sudo journalctl _SYSTEMD_USER_UNIT=uniagent.service -n 50
```
