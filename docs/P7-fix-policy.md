# P7 返工口径（Hark 11-18 拍板，dsh 照此修 rules.json）

目标：rules.json 每条与 engine/ 实际行为一致。App 真正读取的是 `default_selected`、`needs_admin`、`risk`（影响勾选与提示），这三项必须准确；其余字段是说明性元数据，也要准确但优先级次之。

## 字段口径

1. **default_selected**：引擎在默认流程里不经 y/n 就会处理 → true；需用户显式选择/交互确认/仅特定参数才跑 → false。
2. **needs_admin**：该条在引擎里的删除/命令路径用到 sudo（`sudo`、`safe_sudo_remove`、`run_with_sudo` 等）→ true，否则 false。只有部分路径需要 sudo 时取 true，并在 match 里注明哪部分。
3. **risk**（App 只认 low / medium / high）：
   - high：永久删除且不可重建的用户数据（废纸篓、下载、设备备份、会话/聊天/历史记录、用户文档、项目源文件），或 needs_admin=true 且删除系统目录内容。
   - medium：可重建但代价大（需重新下载/编译/体积大：DerivedData、模拟器与运行时、SDK/工具链、包管理器下载缓存、Docker/VM 镜像缓存、快照），或 needs_admin=true 的其他情况。
   - low：应用会自动重建的缓存、日志、临时文件、崩溃报告；以及 action=protect/report 的条目。
   - 只在明显违反上述定义时改；擦边保持原值。
4. **action**：delete（引擎自己 rm/safe_remove/mole_delete）、command（引擎调用外部命令清理，如 brew cleanup、tmutil、xcrun simctl）、protect（只保护/跳过，不删）、report（只统计/提示，不删）。
5. **in_app**：p1a-strings 里 `/Library/...` 形式的字符串等同 `~/Library/...`（App 拼在主目录后）。
   - evidence 字符串与某条 paths 同路径，或正是该 paths 所在的工具专属目录（如 `~/Library/Caches/com.openai.chat` 覆盖 `~/Library/Caches/com.openai.chat/*`）→ in_app: true，evidence 指向正确的 `p1a-strings.json:行号`。
   - 只有裸名（如 `.codex`）或同工具的其他子目录 → in_app: "unknown"，evidence 写最接近的条目并加注“（仅同工具其他路径）”。
   - 完全找不到 → in_app: "unknown"，删除 in_app_evidence。
6. **paths**：照引擎实际处理的路径写：漏的补、错的删、过宽的收窄、描述性文字换成真实路径。
7. **match**：一到三句中文，准确描述代码里的门控/条件，不写代码里没有的条件。
8. **source**：只写纯格式，不加括注（说明放 why）；`artifacts/mole-cli/<文件>:<起>-<止>`，覆盖该条完整函数或代码段（engine 行号与 artifacts 一致）。有第二处关键代码用 `secondary_source`。
9. **protected_by**：仅审计明确指出有误时改。
10. 不新增字段（除已有的 secondary_source、cli_status）。

## 必须上报给用户、不能自己改的情况（写 escalate）
- 发现**引擎本身**可能误删用户数据或越权删除（这是代码 bug，不是规则表问题）。
- 修正会把 risk=high 的条目 default_selected 改成 true。
- 审计结论与源码矛盾且无法判定。
