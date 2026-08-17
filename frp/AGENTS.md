# AGENTS.md

V 语言重写的 frp（fast reverse proxy）。模块名 `vfrp`，参考实现为 Go 版 `/Volumes/Extreme/github2/frp`（只读参考，不要改动）。

## 构建与测试

- 编译检查：`v .`
- 构建产物：`make build`（输出 `bin/vfrps`、`bin/vfrpc`）
- 单元测试：`v -stats test .`
- 端到端测试：`v -stats test test/e2e/`
- 格式化：`v fmt -w .`（提交前必须跑）

## 约定

- 帧格式：v1 = `[1 字节类型][JSON]['\n']`，实现在 `pkg/msg/io.v`
- 消息结构体 JSON 字段名与 Go 版一致（snake_case）
- 共享状态一律 `sync.Mutex` 保护；连接处理用 `spawn` 线程
- 设计决策见 `plan.md`，任务进度见 `todo.md`；完成后勾选 todo.md 对应项
