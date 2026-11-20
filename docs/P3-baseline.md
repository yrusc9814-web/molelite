# P3 基线测试报告（未修改的 engine/ @ dc6605c）

> 阶段：P3 步骤 2　｜　被测对象：`engine/`（= `artifacts/mole-cli` @ `dc6605cb5fbdc589715d908a9ad373874ac2cb53`，零改动）
> 测试运行器：`/workspace/tools/bats`（bats-core）　｜　平台：Linux（无 macOS 系统命令）
> 原始日志：`report/logs/P3-baseline/`（clean/analyze 相关 23 个文件）、`report/logs/P3-baseline-un/`（uninstall 相关 11 个文件），每个 `.bats` 一份 `.tap`

## 0. 结论先行

- **基线就不是全绿**：34 个测试文件里 **32 个有失败**，合计 **457 个 not ok**（clean 组 295、uninstall 组 162），另有 23 个 skip。
- 失败**绝大多数不是产品缺陷，而是 Linux 跑 macOS 测试的必然结果**：测试和被调代码直接调用 BSD `stat -f`、`/usr/libexec/PlistBuddy`、`plutil`、`mdls`/`mdfind`、`tmutil`、`diskutil`、`osascript`、`launchctl`、`security`、`xattr`、`date -v`，还有 TTY / APFS / TCC 相关行为。
- 因此本报告的用途是**清单基线**：P3 改完后逐文件对比，判定标准是「**新增失败 = 0**」，而不是「全绿」。
- 唯一一个**全绿**的用例集是 `clean_container_scan` / `clean_corepack` / `clean_developer_state` / `clean_misc` / `clean_orphaned_runtimes` / `clean_xcode_derived_data`（0 失败）。

### 总计

| 组 | 文件数 | ok | not ok | skip |
|---|---|---|---|---|
| clean / analyze（P3-baseline） | 23 | 786 | 295 | 18 |
| uninstall（P3-baseline-un） | 11 | 290 | 162 | 5 |
| **合计** | **34** | **1076** | **457** | **23** |

> 注：本任务范围内没有独立的 `analyze*.bats`——`analyze` 由 Go 的 `cmd/analyze` 单测覆盖（`go test ./cmd/analyze/`），bats 层只经 `cli.bats` 的 `mo analyze` 路径间接覆盖。步骤 3 的 analyze 核对因此走 Go 单测 + 现代码阅读。

## 1. 每个文件的通过/失败/跳过数与失败原因

失败原因一栏写的是该文件**占主导**的根因（逐条失败原因见对应 `.tap`）。

### 1.1 clean 相关（`report/logs/P3-baseline/`）

| 文件 | ok | not ok | skip | 失败原因（一句话） |
|---|---:|---:|---:|---|
| clean_ai_cli_caches.bats | 49 | 15 | 0 | 进程归属探测在 Linux 上判为 unknown（`ps`/`pgrep` 语义与 macOS 不同），清理被 fail-closed 挡住 |
| clean_app_caches.bats | 93 | 55 | 0 | 测试夹具用 `/usr/libexec/PlistBuddy` 造 Info.plist（18 处 status 127），另有 `stat -f`/`date` 失败 |
| clean_apps.bats | 28 | 67 | 1 | 已装 App 扫描依赖 `plutil`/`PlistBuddy` 解析 bundle，Linux 缺失 → `SCAN_FAILED` |
| clean_automation_browsers.bats | 5 | 3 | 0 | `dev.sh:4299` 用 BSD `stat -f %m` 取 mtime，GNU stat 输出多行文本被当算术表达式（`File: unbound variable`） |
| clean_browser_versions.bats | 20 | 3 | 0 | `Current` 符号链接版本比较依赖 BSD 行为/字节序，最新版本判定选出 2 个而非 1 个 |
| clean_cached_device_firmware.bats | 5 | 10 | 0 | 固件扫描的 `_mole_snapshot_path_identity` 走 BSD `stat -f '%d:%i'`，Linux 下失败即整体跳过 |
| clean_conductor.bats | 2 | 1 | 0 | 用户日志清理没删掉 `Library/Logs/com.conductor.app/app.log`（日志清理的 TTY/所有权路径差异） |
| clean_container_scan.bats | 8 | 0 | 0 | —（全绿） |
| clean_core.bats | 70 | 7 | 5 | 混合：`tmutil` 缺失、mail 附件 `stat -f '%B'`（birth time）缺失、TTY 相关 skip |
| clean_corepack.bats | 2 | 0 | 0 | —（全绿） |
| clean_dev_caches.bats | 139 | 35 | 1 | 受保护根路径判定（`cache path unsafe`）依赖 `stat` 身份，Linux 下恒失败；另 `grep` 读不到夹具文件 |
| clean_developer_state.bats | 10 | 0 | 0 | —（全绿） |
| clean_external.bats | 2 | 8 | 0 | 外接卷清理要求 `_mole_snapshot_path_identity` 成功，Linux 无该 stat 语义 → `could not bind mounted volume` |
| clean_hints.bats | 12 | 3 | 0 | `plutil -extract` 不存在，launchd plist 解析失败 → 不报 "Stale login item" |
| clean_mail_downloads.bats | 4 | 5 | 0 | 依赖 BSD `stat -f '%B %m'`（birth/mtime），Linux 取不到 → 资格判定一律拒绝 |
| clean_misc.bats | 24 | 0 | 0 | —（全绿） |
| clean_orphaned_runtimes.bats | 13 | 0 | 0 | —（全绿） |
| clean_summary_cancel.bats | 13 | 6 | 1 | 用例里带 `--external`，同样卡在卷身份绑定；另 124/130 退出码断言受 TTY 影响 |
| clean_system_caches.bats | 40 | 29 | 1 | Service Worker / pycache 扫描依赖 BSD `find` 语义与 `stat`，GNU findutils 下匹配与状态码不同 |
| clean_system_maintenance.bats | 66 | 18 | 0 | `tmutil`/`diskutil`/`launchctl` 缺失，Time Machine、权限修复、服务日志分支全部落到 fallback |
| clean_user_core.bats | 112 | 25 | 0 | 用户日志/DiagnosticReports 的 symlink 与归属校验依赖 `stat -f%Su`、`stat -f%Lp`，Linux 下取空 → 拒绝或误判 |
| clean_xcode_derived_data.bats | 15 | 0 | 0 | —（全绿） |
| cli.bats | 54 | 5 | 9 | `touchid` 权限断言用 `/usr/bin/stat -f "%Lp"`，GNU stat 把 `%Lp` 当文件名而**成功退出**，回退分支不触发 → perms 不等于 444；其余为 TTY/PTY skip |

### 1.2 uninstall 相关（`report/logs/P3-baseline-un/`）

| 文件 | ok | not ok | skip | 失败原因（一句话） |
|---|---:|---:|---:|---|
| uninstall.bats | 136 | 86 | 1 | 根因单一：`get_file_owner` 用 `$STAT_BSD -f%Su`，Linux 返回空 → 判为「外来属主，需 sudo」→ 再被 `_mole_privileged_path_has_mutable_ancestor` 判为可变祖先 → `cannot be removed safely by Mole from this location`（26 处） |
| uninstall_menu.bats | 13 | 1 | 1 | PTY 菜单脚本在无 TTY 环境下抛 Python traceback |
| uninstall_naming_variants.bats | 38 | 3 | 1 | 命名变体匹配依赖 macOS `mdfind`/`stat` 的路径规范化差异 |
| uninstall_process_pattern.bats | 3 | 1 | 0 | `pgrep` 转义模式在 procps-ng 下与 BSD pgrep 不等价（`escaped literal probe missing`） |
| uninstall_remove_file_list.bats | 14 | 21 | 1 | LaunchAgent 归属校验要读 plist/属主，`plutil`+`stat` 缺失 → 一律 "agent file changed or could not be inspected" |
| uninstall_review.bats | 18 | 3 | 0 | 同上：`cannot be removed safely`，预览/确认流程被前置换算挡住；另 1 处 PTY traceback |
| uninstall_safety.bats | 37 | 24 | 0 | 同上（属主/可变祖先），另有 `PlistBuddy` 夹具缺失 |
| uninstall_scan_bash32.bats | 18 | 17 | 0 | 显式以 `/bin/bash` 3.2 语义跑扫描，叠加 `stat -f %m`、`date -v`、`PlistBuddy` 缺失 |
| uninstall_steam_launcher.bats | 10 | 2 | 0 | 夹具用 `/usr/libexec/PlistBuddy` 改 `CFBundleExecutable`，缺失即失败 |
| uninstall_timeout.bats | 0 | 4 | 0 | 超时夹具依赖 `perl`/coreutils 的进程控制与直接 Trash 落点，Linux 下 move 立刻成功（`MOVE_STATUS=0`） |
| uninstall_tty_foreground.bats | 3 | 0 | 1 | —（无失败，1 个 TTY skip） |

## 2. 失败根因分类（按机制，不按文件）

| 类别 | 机制 | 影响面（约） |
|---|---|---|
| A. BSD `stat -f` 语义 | `$STAT_BSD=/usr/bin/stat` 在 Linux 是 GNU stat：`-f` 被解释成「文件系统信息」，`%Su`/`%Lp`/`%m`/`%B`/`%d:%i` 全部拿不到，且部分场景**退出码为 0 但输出是文本**（比失败更危险） | 最大单一根因，波及 clean + uninstall 两组 |
| B. `/usr/libexec/PlistBuddy` 缺失 | 测试夹具本身用它写 Info.plist（status 127） | clean_app_caches 18、uninstall_steam_launcher 2、uninstall_scan_bash32 2、uninstall_safety 2 |
| C. `plutil` 缺失 | 运行期解析 launchd plist / bundle 元数据 | clean_hints、clean_apps、uninstall_remove_file_list |
| D. `mdls`/`mdfind` 缺失 | 应用显示名、大小、Spotlight 查询 | clean_apps、uninstall_naming_variants |
| E. `tmutil`/`diskutil`/`launchctl`/`osascript`/`security`/`xattr` 缺失 | 系统维护分支 | clean_core、clean_system_maintenance、clean_cached_device_firmware、uninstall |
| F. `date -v`（BSD） | 相对时间计算 | clean_app_caches、uninstall_scan_bash32 |
| G. TTY / PTY 行为 | `script`、`/dev/tty`、alt-screen 在容器内不可用 | 全部 `# skip`，少量 PTY 脚本 traceback |
| H. 文件系统语义 | APFS clone、birth time、大小写不敏感卷、`find` 字节序 | clean_browser_versions、clean_system_caches、clean_mail_downloads |
| I. 进程表语义 | `pgrep -x`/`pgrep -f` 正则、`ps -axo` 列宽 | clean_ai_cli_caches、uninstall_process_pattern、clean_conductor |

> 结论：A/B/C/D/E/F 都属于「平台不可用」，G/H/I 属于「平台行为差异」。**没有一条是 dc6605c 在 macOS 上的逻辑缺陷**——它们是同一份代码在非 Darwin 主机上的可移植性缺口，P3 不修（任务红线：不改清理逻辑）。

## 3. 复现方式

```bash
cd <work>/mole-re
# clean / analyze 组
report/logs/run_bats.sh report/logs/P3-baseline 900 engine/tests/<file>.bats ...
# uninstall 组
report/logs/run_bats.sh report/logs/P3-baseline-un 900 engine/tests/uninstall*.bats
```
`run_bats.sh` 逐文件串行跑，导出 `MOLE_TEST_NO_AUTH=1`、`TERM=xterm-256color`，把 TAP 写进 `<outdir>/<name>.tap`，计数汇总进 `summary.tsv`。

## 4. 对 P3 的意义（判据）

1. **对比口径**：步骤 5 的全量结果按「文件 × (ok/notok/skip)」对齐本表；任何文件的 `notok` 增加即视为**新增失败**，必须为 0。
2. **新增用例要单列**：P3 会新增 `--json` 相关用例（走 `MOLE_TEST_MODE=1` + 假 HOME，不依赖 BSD 工具），它们不进基线，单独报告。
3. **不要试图修基线**：修 `get_file_owner` 之类会把 diff 从「薄适配层」变成「移植层」，违背最小改动；如需在 macOS 上验收，另开任务。
