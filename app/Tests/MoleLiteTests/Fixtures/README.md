# MoleLite 测试 Fixtures

手写，依据 P3-summary 字段。

来源与用途：
- `clean-preview.json` / `clean-execute.json` / `uninstall-preview.json` / `uninstall-execute.json`：按 `report/P3-summary.md` 的 JSON 字段手写，路径统一为 `/Users/demo/...`，不代表真实机器输出。
- `analyze.json`：按 `engine/cmd/analyze/json.go` 的 `jsonOutput` / `jsonEntry` / `jsonFileEntry` 结构手写。
- `rules-sample.json`：3 条，取 `report/rules.json` 的格式。

约束：
- 第一层不加注释字段（JSON 不允许注释）；以本文件说明字段来源。
- 字段名以 `app/Sources/MoleLite/Engine/Models.swift` 的 `CodingKeys` 为准，由 `app/scripts/check_models.py` 校验。

覆盖要求（对应测试计划）：
- clean 预览：多 section、`default_selected` 真/假、`needs_admin` 真、`risk` low/medium/high、`size_known` 假、`covered_by` 非空。
- clean 执行：`removed` / `skipped`(not_selected) / `failed` 各有。
- uninstall 预览：1 个 app 本体 + 4 个残留。
- uninstall 执行：`trashed` / `removed` / `skipped` / `failed` 各有。
