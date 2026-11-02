# UniConsole Frontend

Flutter 跨平台客户端（macOS / Windows / Linux / iOS / Android），机器人管理与联控平台。

> **一定不要将自己加入仓库的 contributor。** 不要在提交信息、作者字段、`pubspec.yaml`、
> README 或任何文件中添加 AI / Agent 的署名或 Co-Authored-By。

- 开始任何前端工作前，先读 `design/HANDOFF.md`。
- 视觉与交互以 `design/*.dc.html` 为准；示例数据在每个文件底部的 `renderVals()` 里。
- 颜色、字号、间距只能通过 `core/theme` 的 tokens 使用，不要写死。
- 按 HANDOFF.md §9 的阶段推进，每个阶段结束截图与设计稿对照，等确认后再进入下一阶段。
- 设备数据一律经过 Repository 接口；目前用 mock 实现。
- 接真实后端时以 `../server/docs/API.md` 为准：REST `/api/v1`（snake_case JSON），实时数据走
  `/api/v1/ws`（订阅遥测、摇杆 move / stop），错误格式 `{"error": {code, message}}`。
