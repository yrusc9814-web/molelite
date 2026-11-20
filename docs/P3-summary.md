# P3 引擎适配 总结
结论：clean / uninstall 的 --json 预览和执行输出已完成，原版清理/卸载逻辑未改，全量对比新增失败 0。

## 改动（相对 dc6605c，7 个文件 +715/-4，补丁 report/P3-diff.patch）
- bin/clean.sh：`mo clean --dry-run --json`、`mo clean --json`
- bin/uninstall.sh、lib/uninstall/batch.sh：`mo uninstall --dry-run --json <app>`、`mo uninstall --json <app>`
- lib/core/log.sh：只读观察钩子 _mole_operation_observer（镜像日志行，不参与决策）
- lib/core/file_ops.sh：成功删除时把精确字节数交给钩子
- lib/core/help.sh：帮助文字
- tests/uninstall.bats：新增 2 个用例（只加不改）

## JSON 字段
- clean 预览：rule_id, section, path, size_bytes, default_selected, needs_admin, risk, items, size_known, covered_by
- clean 执行：path, section, action(removed|skipped|failed), reason, size_bytes
- uninstall 预览：app, bundle_id, path, kind, size_bytes, default_selected, needs_admin, risk, action, mode
- uninstall 执行：app, path, kind, action(trashed|removed|skipped|failed), reason, size_bytes
- analyze：原版已有 --json，未改
- stdout 只出 JSON，其余输出走 stderr；--json 不带目标/参数时直接拒绝

## 已知事项
- 原版 clean 是永久删除（不进废纸篓），保持原样，GUI 必须先预览再确认。
- needs_admin/risk 按 section 粗分，GUI 若需逐条精确值再对照 rules.json。
- Mac 上需补跑：全部 bats + Go 单测（analyze）。
