# P7 任务 A：rules.json 与引擎源码对齐审计

- 规则源：`report/rules.json`（169 条，14 个 category）
- 引擎：`engine/`（HEAD `978bade`，基于 `dc6605c` + `--json` + `MOLE_SELECTION_FILE`）
- 审计口径：逐条核对 `paths` 是否仍存在、`source` 行号是否偏移、`default_selected` / `risk` / `action` 是否与代码一致
- 结论取值：`OK` / `行号偏移` / `不一致` / `找不到`

## 0. 方法与环境（对全部 category 通用）

1. 先比对 `artifacts/mole-cli` 与 `engine` 的同名文件，确认行号基线：
   - `lib/clean/user.sh`：**字节相同**（`diff` 退出 0）
   - `lib/core/app_protection.sh`：**字节相同**
   - `lib/core/file_ops.sh`：仅两处 `_MOLE_OPERATION_SIZE_BYTES` 赋值（`--json` 字节数上报），首处在原 1844 行之后 +5 行、第二处在原 2244 行之后 +5 行；**本 category 引用的 1135–1390、1478–1720 行号区间不受影响**
2. 因此 `source` 行号可视为与 artifacts 基线一致；凡引用 `user.sh` / `app_protection.sh` 的条目，行号应无偏移。
3. `risk` 字段在 `report/P1b-rules.md` 中**没有给出判定口径**（仅字段清单），故本次按「代码层面是否真的会造成不可恢复删除 / 是否需额外授权」交叉判断，并在说明里注明依据；这类判断标注为「口径待定」而非硬性不一致。
4. `default_selected` 依据代码是否在该 section 默认执行（`clean_user_essentials` 被 `_run_cleanup_step` 无条件调用，无 y/n 询问）。

---

## 1. category: trash（2 条，已完成）

| id | 结论 | 说明 | engine 新位置 |
|---|---|---|---|
| trash-01 | OK | 见下方逐项核对，4 个字段全部一致；仅 `protected_by` 有语义细节（见注 1） | `lib/clean/user.sh:42-167`（无偏移） |
| trash-02 | 不一致（action 字段） | `paths` / `match` / 行号全部正确，但 `action: "delete"` 与代码矛盾：该条描述的是**保护**逻辑，引擎从不删除 `~/.Trash` 目录本身（见注 2） | `lib/clean/user.sh:43-45`（无偏移） |

### trash-01 逐项核对

| 字段 | rules.json | engine 代码 | 结论 |
|---|---|---|---|
| `paths` | `~/.Trash/*` | `user.sh:63-64` / `:152`：`find "$HOME/.Trash" -mindepth 1 -maxdepth 1 -print0` —— `-maxdepth 1` 严格只取一级子项，不递归 | ✅ 一致 |
| `match`①「只取一级子项」 | 同上 | `-mindepth 1 -maxdepth 1` | ✅ |
| `match`②「需能列出 ~/.Trash，否则跳过并提示 FDA」 | `ls -A` 探测失败即跳过 | `user.sh:51-55`：`[[ -d ... ]] && ! command ls -A ... >/dev/null 2>&1` → 打印 `Trash · skipped, grant Full Disk Access to your terminal` 并 `return 0` | ✅ 文案与行为均一致 |
| `match`③「逐项仍需通过 validate_path_for_deletion」 | — | `user.sh:104`（dry-run 预览）/ `:152` 循环内 `:139 safe_remove "$item" true` → `file_ops.sh:1520 validate_path_for_deletion` | ✅ |
| `match`④「与最终 sink 网关」 | — | `safe_remove` 内 `file_ops.sh:1518/1520` 校验 + `:1538` 白名单 + `:1665` live-cache 复检，最终 `rm` | ✅ |
| `default_selected` | `true` | `clean_user_essentials`（`user.sh:267`）在 `:334` 直接 `clean_trash`，无 y/n 询问；由 `bin/clean.sh:2086 _run_cleanup_step clean_user_essentials` 默认调用 | ✅ |
| `action` | `delete` | `safe_remove` → `file_ops.sh` 段内**无 sudo**，走永久 `rm`（非废纸篓）；失败计入 `skipped_count`（`user.sh:141-143`） | ✅（确为删除；注意是永久删除，见注 3） |
| `risk` | `high` | 一级子项被永久 `rm -rf`，无回收站；`validate_path_for_deletion` 对一级 Trash 子项还豁免了 `should_protect_path` | ✅ 合理（口径待定） |
| `needs_admin` | `false` | `safe_remove` 全段（`file_ops.sh:1478-1720`）无 `sudo`；权限不足只记 skipped | ✅ |

**注 1（protected_by 语义）**：`file_ops.sh:1373-1374` 对「`~/.Trash` 直接子项」显式豁免 `should_protect_path`（P-11 的本意）。因此列表中 `P-03`（关键字判定）、`P-04` 的白名单分支实际**不会**拦住一级子项；真正生效的是：`P-04` 在 `user.sh:75` 的逐项白名单跳过、`P-05` 在 `user.sh:76-77/95-96` 的编译模型缓存跳过、`OP-06` 的「不处理卷 Trash」范围限定。这是 `protected_by` 标注粒度问题，不是 `paths/行号/default_selected/risk/action` 不一致。

**注 2（trash-02 为什么不判 OK）**：代码里 `~/.Trash` 只作为 `is_path_whitelisted` 的**入参**出现（`user.sh:43`），命中即 `return 0` 整体跳过（保护）。`find` 带 `-mindepth 1`，`rm` 只作用于子项，引擎**任何路径都不会删除 `~/.Trash` 目录本身**。若按 `action: "delete"` 字面实现（把 `~/.Trash` 自身列入删除候选），会与引擎行为相反并造成误删。建议改为 `action: "protect"`（或 `"skip"`），`default_selected` 保留 `true`。

**注 3（范围说明，非缺陷）**：`lib/core/help.sh:82-83` 的「默认进废纸篓」只适用于 uninstall 的 `mole_delete`（`file_ops.sh:2409`，`MOLE_DELETE_MODE` 默认 `permanent`，`trash` 需显式选择）；clean 的 Trash 清空是永久删除，与 `risk: high` 相符。

### 本 category 汇总

| 结论 | 条数 |
|---|---:|
| OK | 1 |
| 行号偏移 | 0 |
| 不一致 | 1（trash-02，仅 `action` 字段） |
| 找不到 | 0 |
| **合计** | **2** |

**建议改动（仅记录，未改 rules.json）**：`trash-02.action`：`delete` → `protect`；可选：`trash-02.match` 补一句「引擎只跳过，不删除该目录」。

---

## 2. category: user_cache（32 条，进行中）

本 category 的 32 条按 `rules.json` 数组顺序排列，但 id 编号并不连续：`user_cache-02/-03/-10/-13` 被分到别的 category（`logs` / `app_leftovers`），另有 `app_cache-01..15`、`cloud_office-01/02`、`virtualization-01..03` 共 22 条也挂在本 category 下。因此「前 16 条」= `user_cache-01/04/05/06/07/08/09/11/12/14/15/16`（12 条）+ `app_cache-01/02/03/04`（4 条）。

文件基线（本次实测）：
- `lib/clean/user.sh`：artifacts 与 engine **字节相同**（3945 行），行号无偏移。
- `lib/clean/app_caches.sh`：artifacts 与 engine **字节相同**（2247 行），行号无偏移。
- `lib/core/file_ops.sh`：仅 1844/2244 行之后各 +5 行（`--json` 字节数），**1044–1135 与 1478–1720 区间行号不变**。
- `lib/core/base.sh`：engine 在 558 行后插入了 89 行 `MOLE_SELECTION_FILE` 支持，**558 行之后的行号整体 +89**（`mole_deno_cache_root` 等随之后移）。凡引用 base.sh 的条目按 engine 新行号标注。

### 2.1 批次 1：user_cache-01 / -04 / -05 / -06

| id | 结论 | 说明 | engine 新位置 |
|---|---|---|---|
| user_cache-01 | OK | `paths`/`match` 五条断言、`default_selected`、`action`、`needs_admin` 全部对得上；`source` 行号正好覆盖「候选构造 + 守卫调用 + 75 分支」，无偏移。见注 2.1-a | `lib/clean/user.sh:286-322`（无偏移） |
| user_cache-04 | OK | 9 个 `paths` 与 `:1282-1298` 逐条对得上（含 `photoanalysisd` 无 `/*` 的整目录删除），行号无偏移。`match` 的 label 清单漏了 `QuickLook cache` 一条（9 路径 8 标签）。见注 2.1-b | `lib/clean/user.sh:1282-1298`（无偏移） |
| user_cache-05 | OK | 18 个 `paths` 与 `:1310-1332` 一一对应、顺序一致；P-01 的容器 carve-out 断言经 `app_protection.sh:503` 验证成立。`protected_by` 漏了 `P-05`。见注 2.1-c | `lib/clean/user.sh:1310-1332`（无偏移） |
| user_cache-06 | OK | 3 个 `paths` 与 `:1096-1098` 逐条一致；`match`「不动 chat.db 与附件本体」成立（`~/Library/Messages/Attachments`、`chat.db` 均未出现在本函数）。`source` 指向被调函数行区间，函数入口在 `:1077`。见注 2.1-d | `lib/clean/user.sh:1096-1098`（无偏移） |

#### 注 2.1-a（user_cache-01 细节）

| 字段 | rules.json | engine 代码 | 结论 |
|---|---|---|---|
| `paths` | `~/Library/Caches/*` | `user.sh:289` `for user_cache_target in "$HOME/Library/Caches"/*` | ✅ 一级子项 |
| `match`①排除 Google | — | `:296` `[[ "${user_cache_target##*/}" == "Google" ]] && continue`（注释 `:291-295` 说明 Chrome 在跑时整目录会失败） | ✅ |
| `match`②排除 DENO_DIR 根（含物理路径等价） | — | `:297-299` 字面比较、`:300-307` `cd -P` 物理路径比较，双向都判 `$target` 与 `$target/*` | ✅ |
| `match`③逐项过 should_protect_path / 白名单 / 编译模型缓存 | — | `bin/clean.sh:1160` / `:1168` / `:1185`（`_safe_clean_impl` 的扫描期三道闸） | ✅ |
| `match`④删除边界再复检 Deno 根，变了即整批停（75） | — | 守卫 `user.sh:175-206` 每次 sink 前重算 `mole_deno_cache_root`，命中即 `return 1`；因未设 `_MOLE_SAFE_CLEAN_SKIP_PATH`，`bin/clean.sh:1466` 置 `delete_guard_stopped=1` 并 `break`，`:1715` `return 75`，调用方 `user.sh:319-322` 打印 stopped 行 | ✅ |
| `default_selected` | `true` | `bin/clean.sh:2086` `_run_cleanup_step clean_user_essentials`（仅受 `EXTERNAL_VOLUME_TARGET` 分支影响），无 y/n | ✅ |
| `risk` | `medium` | 一级 cache 目录整树 `rm -rf`，无回收站；Chrome/Deno 有专门豁免 | ✅（口径待定） |
| `needs_admin` | `false` | `safe_clean`→`safe_remove` 段（`file_ops.sh:1478-1720`）无 `sudo` | ✅ |
| `action` | `delete` | 永久 `rm`，非废纸篓 | ✅ |

**注（行为细节，非字段不一致）**：`:288` 的整个 `for` 循环套在 `if [[ "$deno_cache_root_valid" == "true" ]]` 里。`mole_deno_cache_root`（`base.sh:326`，engine 新行号）对空/`/`/`$HOME`/`$HOME/Library`/`$HOME/Library/Caches`/`$HOME/.cache` 以及含 `..`、`//`、控制字符的 `DENO_DIR` 返回非 0，此时**整批 cache 扫描被跳过**并打印 `DENO_DIR unresolved`（`:323-329`）。`match` 只写了「排除已解析的根」，没写「DENO_DIR 无效则整批放弃」；复刻时若漏掉这点会在畸形 `DENO_DIR` 下把 `~/Library/Caches` 扫穿。建议 `match` 补一句。

#### 注 2.1-b（user_cache-04 细节）

- `paths` 逐条核对：`:1282` photoanalysisd（**无 `/*`**，整目录）、`:1283` akd、`:1284` WebKit.Networking/*、`:1286` QuickLook.thumbnailcache、`:1287` `Quick Look/*`（源码为 `Quick\ Look` 转义空格）、`:1288` `com.apple.iconservices*`、`:1292` IdentityCaches/*、`:1293` Suggestions/*、`:1298` `AddressBook/Sources/*/Photos.cache`。9 条全部命中，`paths` 里的写法与源码一一对应。
- `match` 的 label 串为 8 个，源码有 9 个 label：漏掉 `:1287` 的 `"QuickLook cache"`。不影响 `paths`，属文案完整性。
- `source` 区间 `:1282-1298` 是连续的，中间夹着两条**不属于本规则**的调用：`:1285` `_clean_user_log_directory .../DiagnosticReports`（属 `logs`）、`:1289` `_clean_incomplete_downloads`（属 `user_cache-09`）。复刻时不能把整段当一个规则实现。
- `risk: low` 与「Apple 自有、可再生」一致；`:1288` 的 `iconservices*` 是唯一带尾部通配的条目，会连 `com.apple.iconservices.store` 一起命中（与 `in_app_evidence` 指向的字符串吻合）。

#### 注 2.1-c（user_cache-05 细节）

- 18 条 `paths` 与 `:1310-1332` 顺序完全一致，均为 `.../Caches/*` 或 `.../tmp/*` 形式（**删子项、留目录**）。
- `match` 关于「容器内 `Data/Library/Caches` 与 `Data/tmp` 在 P-01 中被显式视为可再生」成立：`app_protection.sh:501-508` 对 `*/Data/Library/Caches/*` 与 `*/Data/tmp/*` 置 `_container_cache_path=true`，绕过 `should_protect_data` 的 `com.apple.*` 兜底；容器本体不在 `paths` 里。
- **`protected_by` 建议补 `P-05`**：`:1333-1335` 明确写「E5RT bundle cache 原先在这里清，现在由 `holds_compiled_model_cache()` 保护」，而 `safe_clean`（`bin/clean.sh:1185`）与 `safe_remove`（`file_ops.sh:1656`）都会对这批路径跑该判定。当前只列 `P-01` 会低估保护面。
- `needs_admin: false` 成立：6 条 `~/Library/Caches/*` 与 12 条容器路径都在用户域，`safe_remove` 段无 `sudo`。

#### 注 2.1-d（user_cache-06 细节）

- 三条路径 `:1096-1098` 精确匹配，均为 `.../` 下一级子项：`StickerCache/*`、`Caches/Previews/Attachments/*`、`Caches/Previews/StickerCache/*`。
- `match` 的「不动 `chat.db` 与附件本体」成立：`~/Library/Messages/Attachments`、`~/Library/Messages/chat.db` 在整个 engine 里只出现在 `lib/core/ui.sh:591`（作为提示/保护对象）与 `app_protection_data.sh` 的通用词表，不在任何删除路径里。
- `source` 指向的是 `clean_support_app_data()`（`:1077`）内部的 Messages 段；该函数另有 `CrashReporter`（`:1080-1087`）与 `idleassetsd` 注释（`:1089-1093`）两段。`risk: low`/`default_selected: true` 成立（`clean_app_caches:1300` 无条件调用）。
- 该段**无进程守卫**：Messages 运行中也照删（贴纸/预览缓存可再生）。rules.json 未声明这一点，不矛盾，但复刻时不要额外加守卫。

### 2.2 批次 2：user_cache-07 / -08 / -09 / -11

| id | 结论 | 说明 | engine 新位置 |
|---|---|---|---|
| user_cache-07 | 不一致（`paths` + `protected_by`） | 判定函数与 `source` 行号对得上，但 `paths` 写的是 `~/Library/Application Support/com.apple.idleassetsd/…`，而引擎实际扫的是 `~/Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/com.apple.wallpaper.caches/extension-com.apple.wallpaper.extension.*/*.bmp`；且 `Application Support/com.apple.idleassetsd` 是**永不删除**路径。见注 2.2-a | `lib/clean/user.sh:1188-1272`（判定 `:1189-1257`，执行 `:1261-1272`） |
| user_cache-08 | OK | 4 个 `.sfl2` + 4 个 `.sfl` + 1 个 plist 与 `:347-362` 完全一致；`safe_clean` 直接删文件（非整目录），`default_selected`/`risk`/`needs_admin` 均成立。`source:345-363` 精确。见注 2.2-b | `lib/clean/user.sh:345-363`（无偏移） |
| user_cache-09 | OK | 三个扩展名、`~/Downloads` 一级子项、无句柄才删、双重身份绑定全部对上；补充 `lsof` 不可用（state=2）时也跳过。见注 2.2-c | `lib/clean/user.sh:365-432`（rules 写 `-440`，尾部多算 8 行） |
| user_cache-11 | OK | 两个 Mail Downloads 根、`_mail_attachment_is_untouched_copy` 与 sink guard 均对上；补 Mail 运行即整段跳过、整目录 ≥5MB 才扫两条前置条件。见注 2.2-d | `lib/clean/user.sh:440-594`（rules 写 `-604`，尾部多算 10 行） |

#### 注 2.2-a（user_cache-07 为什么不判 OK）

| 字段 | rules.json | engine 代码 | 结论 |
|---|---|---|---|
| `paths` | `~/Library/Application Support/com.apple.idleassetsd/… 渲染残留（_wallpaper_stale_render_files 判定）` | `user.sh:1191` `root="$HOME/Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/com.apple.wallpaper.caches"`；`:1201` 只遍历 `extension-com.apple.wallpaper.extension.*`，`:1206` 只收 `-maxdepth 1 -type f -name '*.bmp'` | ❌ 目录完全不同 |
| `protected_by` | `P-01`、`N-14` | `N-14` = `app_protection.sh:628-634`，保护的是 `*/Library/Application Support/com.apple.idleassetsd(/|/*)` 与 `.../com.apple.wallpaper(/|/*)`，**正好是 rules.json 写的那个目录**；实际删除的 `~/Library/Containers/com.apple.wallpaper.agent/...` 不在 `N-14` 覆盖面内 | ❌ 保护面标错对象 |
| `match` | 仅当陈旧（mtime/在用判定） | `:1199` 7 天 cutoff；`:1217-1250` awk 排除「每种显示尺寸的最新一张 + 全局最新一张」的 digest，再 `< cutoff` 才输出；`:1250` 取最旧 50 个 | ✅ 实质一致 |
| `default_selected` | `true` | `clean_app_caches:1309` 无条件 `_clean_wallpaper_renders` | ✅ |
| `action` / `needs_admin` | `delete` / `false` | `:1269` `safe_clean` 永久删；无 `sudo` | ✅ |
| `risk` | `low` | 失败只重渲染；`_MOLE_WALLPAPER_RENDERS` 上限 50 | ✅（口径待定） |

**为什么这是硬伤**：`user.sh:1089-1093` 的注释明确写「不要在 `clean_support_app_data` 里扫 `com.apple.idleassetsd`」，`N-14` 也把它列为永不删除。rules.json 把这条规则的 `paths` 写成那个被双重保护的目录，等于让复刻者去删一个引擎从不碰、且明令保护的位置；而真正会删的 `Containers/com.apple.wallpaper.agent` 渲染缓存反而没被 `paths` 描述。建议：`paths` 改为 `~/Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/com.apple.wallpaper.caches/extension-com.apple.wallpaper.extension.*/*.bmp`，`protected_by` 去掉 `N-14`。

#### 注 2.2-b（user_cache-08 细节）

- `paths` 9 条 vs 源码 `:347-356` 的 `recent_lists` 数组（`RecentApplications/Documents/Servers/Hosts` × `.sfl2`/`.sfl`）+ `:362` 的 `com.apple.recentitems.plist`，逐条一致。
- 前缀 `:357` 有 `[[ -d "$shared_dir" ]]` 守卫：目录不存在时只删 plist，不报错。
- `match`「命中即往 `safe_clean`（非整目录删除）」准确：`:359`/`:362` 传的是具体文件路径，`safe_clean` 走 `safe_remove` 单文件删除。
- `in_app_evidence` 指向 `P1a strings:467-468`（`/Library/Preferences/ByHost` 等）与 `paths` 无关，属证据粒度问题，不影响字段一致性。

#### 注 2.2-c（user_cache-09 细节）

- `paths` 三条：`.download` / `.crdownload` / `.part`，与 `:395` 的 `extensions` 数组一致；`:401` 用 `"$HOME/Downloads/"*."$ext"`，天然只匹配一级子项，与 `match` 的「必须是直接子项」一致。
- `match` 的「删除前必须证明无打开句柄」成立：`:404` 先探一次，`:409-413` `open_state==0` 即跳过并打印 `Skipping active download`；**补充**：`:414-418` 在 `open_state==2`（探测不可用）时也跳过，rules.json 未提。
- `match` 的「guard 绑定身份（parent inode + target inode）」成立：`_incomplete_download_delete_guard_allows`（`:365-387`）先 `_mole_snapshot_path_identity` 取 parent/target inode，再探句柄，再 `_mole_path_matches_identity` 复核，并把三者塞进 `_MOLE_SAFE_CLEAN_EXPECTED_*` 供 `safe_remove` 最终校验。
- `protected_by: ["OP-03"]` 准确：`file_ops.sh:280-302` 的 `_mole_is_incomplete_download_path` 正是这条规则的最终闸门（含 Homebrew `*.incomplete`，属别的 category）。
- `source` 尾部 `-440` 略长：`_clean_incomplete_downloads` 实际在 `:432` 结束，`:434-440` 已是 Mail 段注释。属「区间包含」而非行号漂移，不单独记「行号偏移」。

#### 注 2.2-d（user_cache-11 细节）

- `paths`：`match` 描述的判定面是 `~/Library/Containers/com.apple.mail/…` 与 `Mail Downloads`，源码 `:487-490` 的 `mail_dirs` 为 `$HOME/Library/Mail Downloads` 与 `$HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads`，一致（rules.json 未把 `paths` 写成字面量，只写了判定面，可接受）。
- 两条 rules.json 未写的前置条件：
  1. `:496-499` Mail 在运行 → 整段跳过（`mole_clean_process_guard _mail_process_state`）；
  2. `:535-541` 单个 Mail Downloads 目录 `< MOLE_MAIL_DOWNLOADS_MIN_KB`（默认 5120KB）→ 跳过该目录。
- `match` 的两个守卫都成立：`_mail_attachment_is_untouched_copy`（`:442-474`，要求 regular file、`nlink==1`、属主为当前 UID、`f_mtime <= f_birth+2`、目录 birth 早于 30 天窗口、`f_birth <= d_birth+2` 且 `d_mtime <= d_birth+2`）；`_mail_attachment_delete_guard`（`:476-478`）作为 `_MOLE_SAFE_REMOVE_FINAL_GUARD` 在 `:568` 交给 `safe_remove`。
- `risk: medium` 合理：虽然「未改动副本」判定很严，但删的是用户可见文件而非纯缓存，且 Mail 的重新下载依赖服务器仍有原件。
- `source` 尾部 `-604` 略长：`_clean_mail_downloads` 在 `:594` 结束。

### 2.3 批次 3（部分）：user_cache-12 / -14

（dsh 会话两次超时未落盘，以下为其推理结论经 Hark 复核后代写，2026-11-16 23:40）

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| user_cache-12 | OK | 6 个容器内 paths（Logs、Library/Logs、tmp、Library/tmp、Caches、Library/Caches）与 match（跳过 Apple 容器/不可读/符号链接与隐藏项、Safari 相关整容器跳过、Logs 恒可清其余四类受 should_protect_data 约束、section 预算）均成立；action=delete（safe_remove）、needs_admin=false 成立。 | `lib/clean/user.sh:1559-1782`（rules 写 `-1784`，尾部多 2 行） |
| user_cache-14 | 不一致（`needs_admin` + 一条 path 不可达） | 函数仅 `IS_M_SERIES=true` 时执行。`/Library/Apple/usr/share/rosetta/rosetta_update_bundle` 命中 `file_ops.sh:1060` 关键路径拒删（`/Library/Apple/*` return 0），**永远删不掉**；另两条都在 `~/Library/Caches`，无需提权。故 `needs_admin:true` 不成立，该 path 应移出或标为受保护。paths 顺序与源码不同（不影响）。 | `lib/clean/user.sh:3936-3945`（rules 写 `-3943`，覆盖三条调用） |

### 2.4 批次 4：user_cache-15 / -16

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| user_cache-15 | 不一致（`paths` 含未扫描的 MobileSync + `in_app_evidence` 与规则无关） | 候选实际只有两类：`~/Library/iTunes/{iPhone,iPad,iPod,Apple TV} Software Updates` 下 `-maxdepth 1 -name "*.ipsw"`，与 `~/Library/Group Containers/*.group.com.apple.configurator` 下递归 `*.ipsw`；`~/Library/Application Support/MobileSync` 明确不入候选（`:3007` 注释 “never scan device backups or partial downloads”），该 path 应删。`match` 成立：`_cached_device_firmware_delete_guard` 在 sizing 前、预览 sizing 后各查一次，并经 `_MOLE_SAFE_REMOVE_FINAL_GUARD` 在 sink 复检（父/文件身份三元组 + `_mole_paths_have_open_handle`；rc=2、超时或信号一律不删）。`default_selected` 成立：`clean.sh:2159` 在 “Device backups & firmware” 段无条件调用（`_run_cleanup_step` 无门控）。`action:delete`、`needs_admin:false` 成立：候选全在 `$HOME/Library` 下，不落入 `file_ops.sh:1044` `_mole_is_critical_deletion_path` 的拒绝臂（`/Library`、`/Library/Apple/*`、`/System/*`、`/Users/<name>` 根等），sink 不会因关键路径拦截。`in_app_evidence` 的 `~/Library/MobileDevice`（`p1a-strings.json:569`）与本规则任一 path 都不重合，不足以支撑 `in_app:true`。 | `lib/clean/user.sh:2986-3122`（守卫 `:2986-3003`，函数 `:3008-3122`；rules 写 `-3128`，尾部多 6 行） |
| user_cache-16 | 不一致（`paths` 写错 + `match` 应为非空） | 实际目标只有一条：`~/Library/Group Containers/group.com.apple.coreservices.useractivityd/shared-pasteboard`，不是 `~/Library/Handoff`（`engine/` 与 `app/` 内均无 `Library/Handoff`）。`match:null` 不成立，实际有四层判定：根目录为符号链接即返回、`is_path_whitelisted` 根级跳过、逐项跳过符号链接与 `should_protect_path`/白名单命中项、`find -mmin +60` 只取 1 小时前的项（另 `-mindepth/-maxdepth 1` 不递归）。`default_selected` 成立：`clean_app_caches` 末尾 `:1405` 调用它，而 `clean_app_caches` 在 `clean.sh:2092` 的 “App caches” 段无条件执行。`action:delete`（`safe_remove`）、`risk:low`、`needs_admin:false` 成立（路径在 `$HOME/Library/Group Containers` 下，不进 `file_ops.sh:1044` 关键路径拒绝臂）；`in_app:unknown` 无证据可推翻。 | `lib/clean/user.sh:1413-1463`（rules 写 `-1465`，尾部多 2 行；调用点在 `:1405`，所属 `clean_app_caches` 起于 `:1274`） |

### 2.5 批次 5：app_cache-01 / -02

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| app_cache-01 | OK | `paths` 17 条与 `:1107-1123`、`:1127-1128` 逐条对得上（顺序一致；`…/vesktop/sessionData/Code Cache/*` 是 `:1111` 的省略写法，`~/Library/Caches/com.feishu.*/*` 对应 `:1123`）。`match` 三句均成立：Discord/Legcord/Vesktop/Slack 走 `mole_safe_clean_app_cache`（`:1107-1112`）→ `base.sh:2126-2135` → 进程守卫 `_mole_named_app_cache_running`（`base.sh:2038-2041`，pgrep `-x <App>` 或 `/<App>.app/`，进程在跑即跳过）；Feishu/Lark 的 service worker 与磁盘缓存两个守卫确在 `:1124-1128` 作为第 2/3 参数传入 `_clean_messaging_container_roots`（`:984-1042`，`:1014` 把它绑为 `_MOLE_SAFE_REMOVE_FINAL_GUARD`）；Teams 旧版分支确由 `:1131` 的 `-d ~/Library/Application Support/Microsoft/Teams` 门控。`default_selected` 成立：调用链 `clean.sh:2125`（“Apps & utilities” 段，`_run_cleanup_step` 见 `clean.sh:2022-2036`，直接 `"$@"` 无 y/n）→ `:2221` → 循环 `:2228` → `:1106`；注意它属 “Apps & utilities” 段而非 `:2092` 的 “App caches” 段。`action:delete`（`safe_clean` `clean.sh:1720-1721` → `_safe_clean_impl` → `safe_remove`）、`needs_admin:false`（`clean.sh:1076-1450` 与 `file_ops.sh:1478-1720` 两区间内均无 `sudo`，17 条路径全在 `$HOME`）成立；`risk:low` 口径待定（只删缓存目录子项，飞书容器项经 `app_protection.sh:503` 的 `*/Data/Library/Caches/*` carve-out 放行，不会被 `should_protect_data` 拦下）。三点粒度注（均不影响字段一致性）：①`:1132-1137` 的 6 条 Teams 旧版路径与 `:1129` 的 Feishu SW（`clean_feishu_service_worker_caches` `:710-801`，6 个 `LarkShell`/`LarkInternational`/沙箱 `aha|iron/users` 根）只在 `match` 里被提到、未进 `paths`；②`~/Library/Caches/LarkShell` 无 `/*`（代码作 root 传入，实际清 `root/*`，`:1030`）；③`protected_by` 的 P-10 是 `_is_wechat_web_profile_cache_child`（`app_protection.sh:385-396`，只管微信 radium web profile），本规则 17 条 path 无一落入，P-10 实际对应 `:1139` 的 `clean_wechat_container_caches`（rules 归 app_cache-15）。`in_app_evidence` 的 11 个锚点是 `/Library/Caches/<同名 id>`（系统级，与规则 `~/Library/Caches` 同 id 不同根），且其中 `:123` 为 `com.parallels.desktop.console`，与本规则无关。 | `lib/clean/app_caches.sh:1106-1140`（无偏移；函数头 `:1106`、收尾 `:1140`，调用点 `:2228`） |
| app_cache-02 | OK | `paths` 4 条与 `:1143`（`dd.work.exclusive4aliding`）、`:1144`（`com.alibaba.AliLang.osx`）、`:1146`（`iDingTalk/log`）、`:1147`（`iDingTalk/holmeslogs`）逐条一致，顺序也相同；两条日志项位于 `:1145` 的 `-d ~/Library/Application Support/iDingTalk` 门控内。`match:null` 成立：`clean_dingtalk` 只有该目录存在性判断，无进程守卫、无年龄/深度过滤、无白名单以外的特殊分支，而 `_safe_clean_impl:1113` 已先剔除不存在的目标，故该 `-d` 不改变可删集合（口径上仍可补一句「仅当 iDingTalk 目录存在时清日志」）。`source` 恰好是整个函数（`:1142` 函数头、`:1149` 收尾），无尾部多余行。`default_selected` 成立：`clean.sh:2125`（“Apps & utilities” 段）→ `:2221` → 循环 `:2228` → `:1142`，`_run_cleanup_step`（`clean.sh:2022-2036`）无 y/n。`action:delete`（`safe_clean` `clean.sh:1720-1721` → `_safe_clean_impl` → `safe_remove`）、`needs_admin:false`（4 条路径全在 `$HOME`，删除段无 `sudo`）、`risk:low`（口径待定：两条是 `log`/`holmeslogs` 诊断日志，`com.alibaba.AliLang.osx` 是安全组件的可再生缓存）均成立；本规则是这 4 条路径在 rules.json 中的唯一归属，无其它条目重复登记。`in_app_evidence` 仅 `p1a-strings.json:76` = `/Library/Caches/com.alibaba.DingTalkMac`：bundle id 与两条 cache 路径（App Store 版 `dd.work.exclusive4aliding`、`com.alibaba.AliLang.osx`）都不同、根也不同（`/` vs `~`），只能算厂商级弱证据（该 id 在 `app_protection_data.sh:513` 还是 uninstall 的「受保护」项），不足以证明 in-app 端会清这 4 条。 | `lib/clean/app_caches.sh:1142-1149`（无偏移） |

### 2.6 批次 6：app_cache-03 / -04

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| app_cache-03 | OK | 6 条 `paths` 与 `:1189`/`:1190`/`:1193`/`:1196`/`:1200-1201`/`:1198` 逐条命中；`match` 的 Adobe 三项进程守卫与「只清 Media Cache Files、保留 index 库」均成立；`source:1188-1203` 恰好覆盖整个 `clean_design_tools`，无偏移；`default_selected`、`action`、`needs_admin` 成立；`risk:low` 口径待定。逐项见注 2.6-a | `lib/clean/app_caches.sh:1188-1203`（无偏移；函数头 `:1188`、收尾 `:1203`） |
| app_cache-04 | OK | 5 条字面 `paths` 与 `:1264-1268` 逐条一致；剪映项只写「判定面」，实际为 `:1229` 的 `~/Movies/JianyingPro/User Data/Cache` + `:1245-1247` 的 7 个可再生子目录（未列进 `paths`，按 user_cache-11 先例可接受）。`match` 两句成立（剪映 `:1233-1240` 跳过，`CacheClip` 见 `:1267`）；`source:1205-1276` 覆盖 helper + 两个函数，仅尾部 `:1271-1276` 是下一节 Autodesk 注释（多 6 行，非行号漂移）；`default_selected`、`action`、`needs_admin` 成立；`risk:medium` 口径待定。逐项见注 2.6-b | `lib/clean/app_caches.sh:1205-1276`（功能段 `:1205-1270`；`jianying_pro_is_running` `:1205-1226`、`clean_jianying_pro_generated_caches` `:1228-1261`、`clean_video_tools` `:1263-1270`；尾部多 6 行） |

#### 注 2.6-a（app_cache-03 逐项核对）

| 字段 | rules.json | engine 代码 | 结论 |
|---|---|---|---|
| `paths`① Sketch cache | `~/Library/Caches/com.bohemiancoding.sketch3/*` | `:1189` `safe_clean ~/Library/Caches/com.bohemiancoding.sketch3/*` | ✅ |
| `paths`② Sketch app cache | `~/Library/Application Support/com.bohemiancoding.sketch3/cache/*` | `:1190` 同路径（源码用 `Application\ Support` 转义空格） | ✅ |
| `paths`③ Adobe 共享缓存 | `~/Library/Caches/Adobe/*` | `:1193` 作为 `_dev_safe_clean_process_guarded` 的路径参数 | ✅ |
| `paths`④ com.adobe.* 缓存 | `~/Library/Caches/com.adobe.*/*` | `:1196` 同上（第 2 个 guarded 调用） | ✅ |
| `paths`⑤ Media Cache Files | `~/Library/Application Support/Adobe/Common/Media Cache Files/*` | `:1200-1201` 同路径（源码两处转义空格） | ✅ |
| `paths`⑥ Figma 缓存 | `~/Library/Caches/com.figma.Desktop/*` | `:1198` `safe_clean ... "Figma cache"` | ✅ |
| `paths` 顺序 | ⑤ Media Cache 列在 ⑥ Figma 之前 | 源码 ⑥ 在 `:1198`、⑤ 在 `:1200-1201` | 内容无差，仅第 5/6 项顺序相反（不影响，参照 user_cache-14 先例） |
| `match`①「Adobe 相关三项按进程守卫」 | `_adobe_app_running` / `_adobe_media_cache_running` | `:1192`/`:1195` 用 `_adobe_app_running`（定义 `:1182-1185`，`pgrep -f '^/Applications/Adobe [^/]+(/Adobe [^/]+)?[.]app/Contents/MacOS/'`）；`:1200` 用 `_adobe_media_cache_running`（定义 `:1170-1173`，匹配 Adobe 视频类 `.app` 路径）；两者经 `base.sh:2097-2124 _dev_safe_clean_process_guarded` 在 sizing 前与每次 sink 前复核 | ✅ |
| `match`②「只清 Media Cache Files（index 数据库保留）」 | 同左 | `:1165-1166` 注释：conformed audio/peak files 由 sibling **Media Cache 数据库**索引，该数据库 “stays untouched”；全文件仅 `:1200-1201` 一处触碰 `Media Cache Files`，无任何 `Media Cache`（无 Files）删除项 | ✅ |
| `source` 行号 | `app_caches.sh:1188-1203` | `:1188` `clean_design_tools() {`，`:1203` `}`；`app_caches.sh` 与 artifacts 字节相同（`cmp` 退出 0，均 2247 行） | ✅ 无偏移 |
| `default_selected` | `true` | `clean.sh:2125` `_run_cleanup_step clean_user_gui_applications`（“Apps & utilities” 段）→ `app_caches.sh:2228-2229` 的 `for app_group ... clean_design_tools ...` 循环 → `:1188`；`_run_cleanup_step`（`clean.sh:2022-2036`）直接 `"$@"`，无 y/n | ✅ |
| `action` | `delete` | `safe_clean`（`clean.sh:1720-1721`）→ `_safe_clean_impl` → `safe_remove`（`file_ops.sh:1478`）永久 `rm`，非废纸篓 | ✅ |
| `needs_admin` | `false` | 6 条路径全在 `$HOME`；`clean.sh:1076-1450` 与 `file_ops.sh:1478-1720` 两区间内 `grep sudo` 均无命中 | ✅ |
| `risk` | `low` | Sketch/Figma/Adobe 缓存与 Media Cache Files（conformed audio、peak 文件）均为可再生；失败只触发重建 | ✅（口径待定） |
| `in_app` | `true` | 锚点 `p1a-strings.json:89` = `/Library/Caches/com.bohemiancoding.sketch3`、`:499-500` = `/Library/Logs/Adobe`、`/Library/Logs/CreativeCloud`：bundle id/厂商对得上，但根是系统级 `/Library`，与本条 `~/Library` 不同根；Figma 无锚点 | 弱证据，不足以证明 in-app 端会清这 6 条（不推翻 `true`） |

**注（`protected_by` 粒度，非字段不一致）**：`N-12`（`report/protect.json:242`）的两条相关 glob 是 `*/Library/Caches/Adobe *` 与 `*/Library/Caches/* Adobe*`，匹配的是「`Caches/Adobe <X>`」这种带空格的目录名，**不覆盖**本条的 `Caches/Adobe/*`（其子项名不带前导空格）；这 6 条实际起作用的是通用 `P-01`（`should_protect_path`，`app_protection.sh:406`，扫描期 `clean.sh:1160` 与 sink `file_ops.sh:1375` 各查一次）以及 `is_path_whitelisted` 等通用闸门。建议 `protected_by` 只留 `P-01`，或补一条真正命中 `Caches/Adobe/*` 的保护项。

#### 注 2.6-b（app_cache-04 逐项核对）

| 字段 | rules.json | engine 代码 | 结论 |
|---|---|---|---|
| `paths`① 剪映生成缓存 | 「剪映/JianyingPro 生成缓存（`clean_jianying_pro_generated_caches` 判定面）」 | `:1229` `cache_root="$HOME/Movies/JianyingPro/User Data/Cache"`；`:1230` 要求根目录存在且非符号链接；`:1245-1247` 7 个子目录 `recognize frameThumbnail audioWave AlgorithmCache ILASDKDB ttsTemp tmp`；`:1251-1256` 逐项要求 `-d && ! -L`；`:1260` `safe_clean "${targets[@]}"` | ⚠️ 非字面路径：未写根目录与 7 子目录，只指向判定函数。内容不矛盾，复刻需照上述行号（先例 user_cache-11） |
| `paths`② ScreenFlow | `~/Library/Caches/net.telestream.screenflow10/*` | `:1264` `safe_clean ... "ScreenFlow cache"` | ✅ |
| `paths`③ Final Cut | `~/Library/Caches/com.apple.FinalCut/*` | `:1265` | ✅ |
| `paths`④ DaVinci Resolve | `~/Library/Caches/com.blackmagic-design.DaVinciResolve/*` | `:1266` | ✅ |
| `paths`⑤ CacheClip | `~/Movies/CacheClip/*` | `:1267` `safe_clean ~/Movies/CacheClip/* "DaVinci Resolve CacheClip"` | ✅ |
| `paths`⑥ Premiere Pro | `~/Library/Caches/com.adobe.PremierePro.*/*` | `:1268` | ✅ |
| `paths` 顺序 | 剪映列第 1 | 代码在 `:1269` 最后调用 `clean_jianying_pro_generated_caches` | 顺序不同（不影响） |
| `match`①「剪映进程运行中即跳过」 | — | `:1232-1240`：`jianying_pro_is_running`（`:1205-1226`，`pgrep -x VideoFusion-macOS` 或 `pgrep -f /VideoFusion-macOS.app/Contents/MacOS/VideoFusion-macOS`）返回非 1 即打印 skipped 并 `return 0`；**补充**：rc=2（`pgrep` 缺失/探测失败）同样跳过，理由显示 `process state unknown`（`:1236`） | ✅（可补「未知状态也跳过」） |
| `match`②「DaVinci 的 ~/Movies/CacheClip 是渲染缓存」 | — | `:1267` 的 label 为 `"DaVinci Resolve CacheClip"`；`:1266` 另清 `com.blackmagic-design.DaVinciResolve` | ✅ |
| `source` 行号 | `app_caches.sh:1205-1276` | 功能内容到 `:1270` 为止；`:1271-1276` 已是 `autodesk_cache_process_state` 的注释块（`:1277` 才是函数头） | 无偏移；尾部多 6 行（区间包含） |
| `default_selected` | `true` | `clean.sh:2125` → `app_caches.sh:2221 clean_user_gui_applications` → `:2228-2229` 循环含 `clean_video_tools` → `:1263` / `:1269`；`_run_cleanup_step`（`clean.sh:2022-2036`）直接 `"$@"`，无 y/n | ✅ |
| `action` | `delete` | `safe_clean`（`clean.sh:1720-1721`）→ `_safe_clean_impl` → `safe_remove`（`file_ops.sh:1478`）永久 `rm`；`:1260` 删的是整个子目录，`:1264-1268` 删各自 `/*` 子项 | ✅ |
| `needs_admin` | `false` | 全部在 `$HOME`（含 `~/Movies`）；`clean.sh:1076-1450`、`file_ops.sh:1478-1720` 内 `grep sudo` 无命中 | ✅ |
| `risk` | `medium` | Final Cut / Premiere / DaVinci 缓存与 `CacheClip` 是渲染中间产物，删除后需重新渲染（非原始素材）；剪映段 `:1242-1244` 注释明确只清 scratch，排除 rendered/remuxed media、导入素材与工程数据 | ✅（口径待定） |
| `in_app` | `true` | 唯一锚点 `p1a-strings.json:80` = `/Library/Caches/com.apple.FinalCut`：bundle id 对得上，但根是系统级 `/Library`，与本条 `~/Library/Caches/...` 不同根；其余 5 条无锚点 | 弱证据（不推翻 `true`） |

**注（保护面）**：`protected_by` 只列 `P-01`，与代码一致：这 6 条不落入 `protect.json` 的任何专用 never-delete glob（`grep FinalCut/CacheClip/DaVinci/PremierePro` 仅命中 `:327` 的 uninstall 规则），删除前只经通用 `should_protect_path`（`app_protection.sh:406`）与 `safe_remove` 的 `validate_path_for_deletion`（`file_ops.sh:1520`）。剪映段根目录的 `-d && ! -L` 守卫（`:1230`）rules.json 未写，复刻时不可省。

### 2.7 批次 7：app_cache-05

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| app_cache-05 | 不一致（`in_app_evidence` 与本条无关） | `paths` 三条字面命中（`:1882`/`:1883`/`:1914`），Fusion 项为判定面（根 `:1695`）；`match` 成立（可信根 `:1315`、current `:1476`、只删更旧 `:1530-1595`、guard `:1597` 于 `:1635`/`:1679` 复核并绑 final guard）；`source` 起点 `:1277` 无偏移、尾多 7 行 Futu 注释；`default_selected`（`clean.sh:2125`→`:2229`，无 y/n）、`action:delete`、`needs_admin:false`（`$HOME`、无 `sudo`）成立；`risk:high` 待定。`in_app`：证据 `/Library/Logs/CreativeCloud` 与 paths 无一同路径，不足支撑 `true`。 | `lib/clean/app_caches.sh:1277-1928`（起点无偏移；功能段 `:1277-1921`；尾部 `:1922-1928` 多 7 行） |

### 2.8 批次 8：app_cache-06

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| app_cache-06 | 不一致（`in_app_evidence` 与本条无关） | `paths` 12 条与 `:1964-1975` 同序逐条命中；`match:null` 成立（函数内无进程/年龄/深度守卫，仅通用闸门）；`source:1963-1976` 起点即函数头无偏移，`:1976` 已是 `clean_futu_update_downloads`、`:1977` 才是 `}`（尾差 1 行）；`default_selected` 成立（`clean.sh:2125` “Apps & utilities” 段，`_run_cleanup_step` 见 `clean.sh:2022-2036` 无 y/n → `app_caches.sh:2229` 循环 → `:1963`）；`action:delete`（`clean.sh:1720` → `:1076 _safe_clean_impl` → `safe_remove`）、`needs_admin:false`（全在 `$HOME`、函数内无 `sudo`）、`risk:low` 待定（纯可再生缓存）、`protected_by:P-01` 一致（`protect.json` 无这些 app 的专用 glob）均成立。`in_app`：证据仅 `/Library/Caches/com.yetone.magpie`、`/Library/Caches/magpie`，与 12 条 paths 无一相同路径，不足支撑 `true`。 | `lib/clean/app_caches.sh:1963-1977`（起点无偏移；功能段 `:1963-1976`） |

### 2.9 批次 9：app_cache-07

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| app_cache-07 | 不一致（`in_app_evidence` 与 paths 不同路径） | `paths` 13 条同序逐条命中（`:1982`/`:1983`/`:1985`、`:1986-1988`、`:1989-1993`、`:1995-2001`、`:2002-2004`；QQMusic 容器四项由 `:1996` 的 `-d` 门控）；`match` 成立：Podcasts tmp 只删 `StreamedMedia` 整目录 + 三类指定 glob，`:1986-1988` 的 glob 仅匹配 tmp 一级子项，不动其它内容；`source` 起点即函数头无偏移，`:2006` 已是 `# Video players.`（尾多 1 行，属区间包含）；`default_selected` 成立（`clean.sh:2125` “Apps & utilities” 段 → `app_caches.sh:2221` → `:2230` 循环，`_run_cleanup_step` 见 `clean.sh:2022-2037`，无 y/n）；`action:delete`（`safe_clean` → `safe_remove` 永久 rm）、`needs_admin:false`（函数内无 `sudo`，13 条全在 `$HOME`）、`risk:low` 待定（均可再生缓存）均成立；`in_app`：`:84` 为 com.apple.mail（不在 paths 内）、`:120` 仅给 bundle id，二者均非 paths 中的路径，不足支撑 `true`。 | `lib/clean/app_caches.sh:1979-2005`（rules 写 `-2006`，尾多 1 行；调用点 `:2230`） |

### 2.10 批次 10：app_cache-08

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| app_cache-08 | 不一致（`in_app_evidence` 与 paths 不同路径） | `paths` 12 条同序命中（`:2008`/`:2009`/`:2010`/`:2011`/`:2012`；第 6 条为判定面：`:2014` 容器根 + `:2016-2018` 的 `Upgrade`/`VideoNative`/`documentCache`，由 `:2015` 的 `-d` 门控；`:2020`/`:2021`/`:2022`/`:2023`/`:2024`/`:2026`，末条由 `:2025` 门控）。`match` 成立：`:2016` 的 label 即 “Tencent Video old installer”，与「旧安装器可与缓存一起清」一致，函数内无其它守卫。`source` 起点即函数头 `:2007`，`:2028` 为 `}`，`:2029` 已是 `# Download managers.`（尾多 1 行，属区间包含，非偏移）。`default_selected` 成立（`clean.sh:2125` “Apps & utilities” 段 → `app_caches.sh:2221` → `:2230` 循环含 `clean_video_players`，`_run_cleanup_step` 见 `clean.sh:2022-2037`，无 y/n）。`action:delete`（`safe_clean` → `safe_remove` 永久 rm）、`needs_admin:false`（函数内无 `sudo`，12 条全在 `$HOME`）、`risk:low` 待定（均为可再生缓存/旧安装器）均成立；`protected_by:P-01` 一致（protect.json 无这些 app 的专用 glob）。`in_app`：证据是 `/Library/Caches/...`（系统级根）与 “SenPlayer” 简称，与本条 `~/Library/...` 无一相同路径，不足支撑 `true`。 | `lib/clean/app_caches.sh:2007-2029`（起点即函数头，尾多 1 行；调用点 `:2230`） |

### 2.11 批次 11：app_cache-09

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| app_cache-09 | OK | `paths` 6 条字面同序命中（`:2031`–`:2036`，前四条无 `/*`）；第 7 条判定面（`:2044` 根、`:2054-2059` 数字名+`seg.x0`、`:2065` 龄期≥30）。`match` 成立（`:2040` `NeatDB.db` 不动）。`source` 起点即函数头 `:2030`，`:2103` 为 `}`，`:2104` 已属下一节（尾多 1 行）。`default_selected` 成立（`clean.sh:2125`→`:2221`→`:2230`，无 y/n）。`action:delete`、`needs_admin:false`（`$HOME`，无 `sudo`）、`risk:low` 待定；`protected_by:P-01` 一致。`in_app:unknown` 无证据可对照。注：Downie 无分段逻辑（措辞不准）。 | `lib/clean/app_caches.sh:2030-2104`（起点即函数头，尾多 1 行；`:2037` 调 `clean_neatdm_stale_segments`，循环在 `:2230`） |

### 2.12 批次 12：app_cache-10

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| app_cache-10 | 不一致（`in_app_evidence` 与 paths 不同路径；`match` 误写 `N-09`） | 17 条 `paths` 同序命中：Steam 缓存 `:2106` + 5 子目录 `:2108-2112`；Epic `:2114`、Battle.net `:2115`/`:2117`、EA `:2119`、GOG `:2120`、Riot `:2121`；Minecraft `:2123-2126`；Lunar `:2129-2133`；PCSX2 `:2135`/`:2137`/`:2138`；RPCS3 `:2141`/`:2142`。`source` 起点即函数头 `:2105`、`:2144` 收尾、`:2145` 属下一节（尾多 1 行）。`match` 行为成立：Steam 只清可重建 cache，uninstall 整库保护是 `P-09`（`app_protection.sh:370-379`、`:429` 仅在 uninstall 模式生效），非 `N-09`（=iCloud Drive，`protect.json:194`）。`default_selected` 成立（`clean.sh:2125`→`app_caches.sh:2221`→`:2231`，无 y/n）；`action:delete`、`needs_admin:false`（17 条全在 `$HOME`、无 `sudo`）、`risk:medium` 待定。`in_app`：`/Library/Caches/Steam` 与 17 条 `~/…` 无一相同路径，不足支撑 `true`。 | `lib/clean/app_caches.sh:2105-2145`（无偏移；`:2138` 的 PCSX2 日志受 `:2136` 的 `Application Support/PCSX2` 门控） |

### 2.13 批次 13：app_cache-11

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| app_cache-11 | 不一致（`in_app_evidence` 与 paths 不同路径） | `paths` 10 条同序命中（`:2147-2149`、`:2153-2155`、`:2159-2160`、`:2164-2165`，均无 `/*`）；`match` 成立（无进程守卫）；`source` 起点 `:2146` 无偏移，`:2166` 为 `}`，`:2167` 属下一节（尾多 1 行）；`default_selected` 成立（`clean.sh:2125` → 无 y/n → `app_caches.sh:2231`）；`action:delete`（`clean.sh:1475`/`:1597`）、`needs_admin:false`（`$HOME`、无 `sudo`）、`risk:low` 待定、`protected_by:P-01` 一致。`in_app`：证据仅 bundle id/简称，与 paths 无一相同路径，不足支撑 `true`。 | `lib/clean/app_caches.sh:2146-2167`（无偏移；`:2146-2150`/`:2152-2156`/`:2158-2161`/`:2163-2166` 四函数） |

### 2.14 批次 14：app_cache-12

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| app_cache-12 | 不一致（`in_app_evidence` 与 paths 不同路径） | `paths` 15 条全部命中：14 条字面同序（`:2169-2178`、`:2182-2183`、`:2185-2186`），第 15 条为判定面（`:2188` 的 `-d` 门控 + `:2189-2194` 六行 Cache/Code Cache/GPUCache/DawnGraphiteCache/DawnWebGPUCache/logs）。`match` 成立：仅 mihomo-party 六行走 `mole_safe_clean_app_cache`（`base.sh:2126`）→`_dev_safe_clean_process_guarded`（`:2132`）→`_mole_named_app_cache_running`（`:2038`，`pgrep -x mihomo-party` 与 `mihomo-party.app/`），其余 14 条为裸 `safe_clean`、无进程守卫。`source` 起点即 `clean_shell_utils` 函数头 `:2168`，无偏移；`:2198` 为 `}`，`:2199` 已是 `# Note-taking apps.`（尾多 1 行，属区间包含）；区间内 `:2197` 的 Stash 行不属本条。`default_selected` 成立（`clean.sh:2125` →`app_caches.sh:2221` →`:2228-2233` 循环含两函数，`_run_cleanup_step` 见 `clean.sh:2022`，无 y/n）。`action:delete`、`needs_admin:false`（全在 `$HOME`、`safe_remove` 段无 `sudo`）、`risk:low` 待定、`protected_by:P-01` 一致（`protect.json` 无这些 app 的专用 glob）。`in_app`：证据为 bundle id 而非路径，与 paths 无一相同路径，不足支撑 `true`。 | `lib/clean/app_caches.sh:2168-2199`（起点即函数头，尾多 1 行；两函数 `:2168-2179`/`:2181-2198`，调用点 `:2232`） |

### 2.15 批次 15：app_cache-13

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| app_cache-13 | 行号偏移（起点晚 3 行，漏 `paths[0]`；`in_app` 亦不一致） | `paths` 12/13 字面命中（`:2201-2206`、`:2210-2211`、`:2215-2218`）；`paths[0]` Stash 在 `:2197`，落区间外——起点晚 3 行，应回溯 `:2196`；终点 `:2219` 精确。`match` 成立：三函数 `:2200`/`:2209`/`:2214` 均裸 `safe_clean`，Notion SW 在 `:802`。`default_selected` 成立（`clean.sh:2125`→`:2221`，无 y/n）。`action:delete`（`clean.sh:1475`）、`needs_admin:false`（无 `sudo`）、`risk:low` 待定。`in_app`：证据为系统级 `/Library/Caches/...` 与 bundle id，无一同路径，不足支撑 `true`。 | `lib/clean/app_caches.sh:2197-2219`（rules 写 `2200-2219`，起点晚 3 行；调用点 `:2233`） |

### 2.16 批次 16：app_cache-14

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| app_cache-14 | 不一致（`in_app_evidence` 与 paths 不同路径） | `paths` 8 条字面命中（`:623-630`、`:633-635`），2 条判定面（`:589-613`、`:650-657`），漏 `CodeBuddyExtension/*`（`:641`/`:645`）。`match` 成立（`:557` xml1、`:616-619`）。`source` 起点 `:538` 无漏项，`:660-673` 属 Feishu 注释（尾多 14 行）。`default_selected` 成立（`clean.sh:2120`→`dev.sh:6316`→`:622`，无 y/n）。`action:delete`、`needs_admin:false`（无 `sudo`）、`risk:medium` 待定。`in_app`：`/Library/Caches/Zed` 与 bundle id 均非 paths 同路径。 | `lib/clean/app_caches.sh:538-659`（`:660-673` 多 14 行；调用点 `dev.sh:6316`） |

### 2.17 批次 17：app_cache-15

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| app_cache-15 | 不一致（`match` 目标不存在；`paths[1]` 越出 `source` 且重复） | `paths[0]` `:1044`/`:984`；`paths[1]` `:1121` 越出 `source`，重复 app_cache-01。`match` 不成立：无 `Data/Library/Caches`/`Data/tmp`，实清 `:1051-1065`/`:1075`/`:1093-1096`，守卫 `:941`/`:963` 在。`source` `:878` 精确、`:1103` 收尾（+2）。`default_selected` 成立（`clean.sh:2125`→`:1139`，无 y/n）；`action:delete`（`:1034`）、`needs_admin:false`（`$HOME`/无 `sudo`）、`risk:medium` 待定。`in_app`：证据 `/Library/Containers/…/Caches` 非 `paths` 同路径。 | `lib/clean/app_caches.sh:878-1103`（起点无偏移；`:1104-1105` 多 2 行；`paths[1]` 在 `:1121`） |

### 2.18 批次 18：cloud_office-01

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| cloud_office-01 | 不一致（`source` 文件名错、`paths[3]` 非路径、`in_app` 不同路径） | `paths` 前 3 条命中 `:2417-2419`；第 4 条为判定面描述非路径，实三条未列（`:2388`/`:2411`/`:2431`）。`match` 成立：守卫 `:799-809` 用于 `:2385`/`:2401`/`:2421`，只清缓存不碰同步目录；前 3 条裸 `safe_clean` 无守卫。`source` 文件名错：`app_caches.sh` 仅 2247 行，实为 `user.sh:2380-2437`（尾 2 行越界），行号无偏移。`default_selected` 成立（`clean.sh:2105`→`:2416`，无 y/n）。`action:delete`（`:1720`→`:1076`→`safe_remove`）、`needs_admin:false`（无 `sudo`）、`risk:medium` 待定。`in_app`：证据为 `/Library/...`，与 paths 无同路径，不足支撑 `true`。 | `lib/clean/user.sh:2380-2437`（rules 写 `app_caches.sh:2380-2439`；调用点 `clean.sh:2416`） |

### 2.19 批次 19：cloud_office-02

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| cloud_office-02 | 不一致（仅 `in_app_evidence` 与 paths 不同路径） | `paths` 8 条字面同序命中（`:2446`/`:2453`/`:2460`/`:2461`/`:2462`/`:2463`/`:2464`/`:2465`）；第 9 条为判定面描述（Word `:2450-2452`、Excel `:2457-2459`，PowerPoint 容器未清）。`match` 成立（容器只删 `Caches/*`、`tmp/*`、`Logs/*`，容器本体保留）。`source` 起点 `:2440` 即函数头、无偏移，`:2466` 为 `}`，`:2468` 已属下一节（尾多 2 行，区间包含）。`default_selected` 成立（`clean.sh:2098-2105` “Cloud & Office” 段 → `:2411` → `:2428`，`_run_cleanup_step` 见 `clean.sh:2022-2038`，无 y/n）；`action:delete`（`:1720`→`:1076`→`file_ops.sh:1478` 永久 rm）、`needs_admin:false`（全在 `$HOME`、无 `sudo`）、`risk:low` 待定。`in_app`：证据为 `/Library/Caches/com.microsoft.*`（系统级根），与本条 `~/Library/...` 及容器路径无一相同，不足支撑 `true`。 | `lib/clean/user.sh:2440-2466`（rules 写 `-2468`，尾多 2 行；调用点 `clean.sh:2428`） |

### 2.20 批次 20：virtualization-01

| 字段 | rules.json（`report/rules.json:2210-2224`） | engine 源码 | 结论 |
|---|---|---|---|
| `paths`① UTM app 缓存 | `~/Library/Caches/com.utmapp.UTM/*` | `user.sh:2482` `safe_clean … "UTM app cache"` | OK |
| `paths`② 沙箱缓存 | `~/Library/Containers/com.utmapp.UTM/Data/Library/Caches/*` | `user.sh:2483` `"UTM sandbox cache"` | OK |
| `paths`③ 沙箱 tmp | `~/Library/Containers/com.utmapp.UTM/Data/tmp/*` | `user.sh:2484` `"UTM temporary files"` | OK（三条同序、无遗漏） |
| `match`「UTM 未运行；不动镜像」 | `_utm_process_state`；不动虚拟机镜像 | `user.sh:2477-2480` `mole_clean_process_guard _utm_process_state "UTM started"`；probe 见 `user.sh:834-836`（`mole_pgrep_any -x "UTM"`）；`base.sh:2020-2033` 仅 state=1 放行，state=0/2 均拦（未知状态也跳过）；三条 paths 不含镜像，`com.utmapp.UTM` 另在 `app_protection_data.sh:419` 的 `DATA_PROTECTED_BUNDLES` | OK（可补「未知状态也跳过」；`:2472-2475` 无目标即提前返回） |
| `source` 行号 | `user.sh:2469-2486` | `:2469` 函数头 `clean_utm_caches()`，`:2485` 为 `}`，`:2486` 空行 | OK 无偏移（尾多 1 行，属区间包含） |
| `default_selected` | `true` | `clean.sh:2130` `_run_cleanup_step clean_virtualization_tools`（“Virtualization” 段）→ `user.sh:2586` → `:2469`；`_run_cleanup_step`（`clean.sh:2022-2044`）直接 `"$@"`，无 y/n | OK |
| `action` | `delete` | `safe_clean`（`clean.sh:1720-1721`）→ `_safe_clean_impl` → `safe_remove`（`file_ops.sh:1478-1869`，`:1816`/`:1818` `rm -rf`），非废纸篓 | OK |
| `needs_admin` | `false` | 三条全在 `$HOME`；`user.sh:2469-2485`、`file_ops.sh:1478-1869` 内 `grep sudo` 无命中 | OK |
| `risk` | `medium` | 只删 `Caches/*`、`tmp/*` 三类子项，镜像与 `.utm` 未触及；删除后可重建 | OK（口径待定） |
| `in_app` | `true` | `in_app_evidence` = `p1a-strings.json:138` `/Library/Caches/com.utmapp.UTM`、`:336` `/Library/Containers/com.utmapp.UTM/Data/tmp`：均为系统级 `/Library` 根，与本条 `~/Library` 三条不同路径 | 不一致 |

**结论**：仅 `in_app` 不成立（`in_app_evidence` 两条与 `paths` 三条无一相同路径，不足支撑 `true`），其余 7 项与源码一致；`source` 起点无偏移。

### 2.21 批次 21：virtualization-02

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| virtualization-02 | 不一致（`paths` 非路径，缺实际目标 `~/.tart/cache`） | `paths` 为判定面描述、无路径；实际目标 `$HOME/.tart/cache`（`:2488`）未列。`match` 成立：`tart` 门控（`:2490`）、`pgrep -x tart`（`:2511`/`:2537`），仅 `tart prune --entries caches --older-than`（`:2547`）清缓存，镜像未动。`source` 起点即函数头 `:2487`，`:2580` `}`、`:2581` 空行（尾多 1 行，属区间包含），无偏移。`default_selected` 成立（`clean.sh:2130`→`:2590`，无 y/n）。`action:delete` 一致（`tart prune`）；无 `sudo`→`needs_admin:false`；`risk:medium` 待定。`in_app:unknown` 无证据，一致。 | `lib/clean/user.sh:2487-2581`（起点无偏移；尾多 1 行；调用点 `clean.sh:2130`→`user.sh:2590`） |

### 2.22 批次 22：virtualization-03

| 字段 | rules.json | engine 源码 | 结论 |
|---|---|---|---|
| `paths`① VMware | `~/Library/Caches/com.vmware.fusion` | `user.sh:2584` `safe_clean … "VMware Fusion cache"` | OK |
| `paths`② Parallels | `~/Library/Caches/com.parallels.*` | `user.sh:2585` `"Parallels cache"` | OK |
| `paths`③ VirtualBox | `~/VirtualBox VMs/.cache` | `user.sh:2587` `~/VirtualBox\ VMs/.cache`（转义空格，同路径） | OK |
| `paths`④ Lima | `~/Library/Caches/lima/download/by-url-sha256/*` | `user.sh:2588` `"Lima download cache"` | OK |
| `paths`⑤ Vagrant | `~/.vagrant.d/tmp/*` | `user.sh:2589` `"Vagrant temporary files"` | OK（只 `tmp/*`） |
| `match`「只清缓存与下载缓存；不动 box 本体与镜像」 | — | 五条均落在 `Caches`/`.cache`/`download`/`tmp` 子项（`:2584-2589`）；`.vagrant.d/boxes`、`VirtualBox VMs` 其余内容未出现；全库仅 `app_protection_data.sh:420` 另提 `com.vmware.fusion`（App 数据保护名单，不拦缓存） | OK |
| `source` 行号 | `user.sh:2582-2594` | `:2582` 函数头 `clean_virtualization_tools()`，`:2591` `}`，`:2592` 空行，`:2593` 起为下一节注释 | OK 无偏移（尾多 2 行，属区间包含） |
| `default_selected` | `true` | `clean.sh:2130` `_run_cleanup_step clean_virtualization_tools`（“Virtualization” 段，无条件）→ `:2582`；`_run_cleanup_step`（`clean.sh:2022-2052`）直接 `"$@"`，无 y/n | OK |
| `action` | `delete` | `safe_clean`（`clean.sh:1720`）→ `_safe_clean_impl` → `safe_remove`（`file_ops.sh:1478`，永久 `rm`） | OK |
| `needs_admin` | `false` | 五条全在 `$HOME`；`:2582-2591` 内无 `sudo` | OK |
| `risk` | `medium` | 只删缓存/下载缓存/`tmp`，可重建；`com.vmware.fusion` 无 `/*` 为整目录删，范围仍限缓存 | OK（口径待定） |
| `in_app` | `true` | `in_app_evidence`：`p1a-strings.json:123` `/Library/Caches/com.parallels.desktop.console` 为 `~/Library/Caches/…` 后缀形式，同 id 同后缀命中 `paths`②；`:469` 为 Preferences 路径，非本条 paths | OK |

**结论**：8 项与源码一致；`source` 起点 `:2582` 无偏移（尾多 2 行属区间包含）；`in_app` 由 `:123` 单独支撑（`:469` 不计）。

<!-- user_cache 追加点 -->

## category: logs（7 条）

### user_cache-02

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| user_cache-02 | OK | `paths`：`:332` 传 `$HOME/Library/Logs`，`:241` 仅一级子项 ✅。`match`：`:243-253` 遇 `DiagnosticReports` 只收子项后 `continue`（`#1689`）；`:227-233` 祖先非链接+身份快照，`:210-222`/`:258-260` sink 前复检 ✅。`default_selected`：`clean.sh:2086` 无条件 ✅。`action`：永久 `rm -rf`（`file_ops.sh:1816`）；无 `sudo`→`needs_admin:false` ✅。`risk:low` 待定；`in_app:unknown` 无 `in_app_evidence`，一致。行号无偏移；`source` 止`:260`（漏`:261-265`）；`match`“只清其中的文件”实含子目录。 | `lib/clean/user.sh:224-260,332`（无偏移；守卫 `:210-222`；尾漏 `:261-265`） |

### user_cache-03

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| user_cache-03 | OK | `paths` 与 `:1281` 字面同路径（`~/Library/Saved\ Application\ State/*`，转义空格，`*` 仅一级子项）。`match:null` 无需核：该行无守卫，只走通用闸门（`clean.sh:1160` should_protect_path、`file_ops.sh:1520` validate_path_for_deletion）。`source:1281` 精确无偏移（函数头 `clean_app_caches` 在 `:1274`）。`default_selected`：`clean.sh:2092` 无条件（无 y/n，`_run_cleanup_step` 见 `:2022-2053`）。`action:delete`：`safe_clean`（`:1720`）→`:1076`→`file_ops.sh:1816` 永久 `rm -rf`。`needs_admin:false`（全在 `$HOME`，sudo 仅 System 段）。`risk:low` 待定：仅删 savedState 恢复状态；但 `:1290-1291` 以「可恢复用户文档」为由排除 `Autosave Information`，本条未排除，low 略乐观。`in_app:unknown` 无 `in_app_evidence`，一致。 | `lib/clean/user.sh:1281`（无偏移；调用点 `clean.sh:2092`） |

### user_cache-10

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| user_cache-10 | OK | paths：`:249-250` 收集 `DiagnosticReports/*`，`:243` 仅在 root 为 `~/Library/Logs`（`:332` 调用）时进入 ✅。match：目录本体保留（`:244` #1689）、只收其子项 ✅（子项含子目录，非仅文件，微差）。source `:243-253` 逐行对齐无偏移，sink `:260`。default_selected：`clean.sh:2086` 无条件（`:2022-2042` 无 y/n）✅。action：`file_ops.sh:1816` 永久 `rm -rf` ✅；needs_admin false（无 sudo、在 `$HOME`）✅；risk low 待定。in_app：`日志` 下 `/Library/Logs/DiagnosticReports` 同后缀，支持 true ✅。 | `lib/clean/user.sh:243-253`（无偏移；sink `:260`） |

### system-02

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| system-02 | OK | `paths`/`match` 一致：`:324` 基址 `/Library/Logs/DiagnosticReports` + 通配 `*`，`:325` 传 type `f`、maxdepth `1`，仅删一级普通文件；年龄取 `MOLE_CRASH_REPORT_AGE_DAYS`（`base.sh:160`=7，`-mtime +7`，`file_ops.sh:3762/3784/3786`）。`source:322-341` 起于 spinner、止于预算 `fi`，`system.sh` 与 artifacts 字节相同，无偏移。`default_selected:true` 成立但受 `SYSTEM_CLEAN` 门控（`clean.sh:33` 初值 false；`:1867`/`:1877` 需 sudo，否则 `:777-831` 询问），与 `needs_admin:true` 自洽。`risk:medium` 口径待定（永久删、7 天阈值）。`action:delete` 走 `safe_sudo_find_delete` 的 sudo 批删（`file_ops.sh:3987`），非废纸篓；`needs_admin` 因 `:324` 走 sudo 为 true。`in_app`：`p1a:501` 同串同后缀，支持 true。 | `lib/clean/system.sh:322-341`（无偏移；sink `:324-325`；调用点 `clean.sh:2071`） |

### system-03

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| system-03 | OK | `paths`：`:346-347` 基址 `/private/var/log` + `*.log`，追加 `*.gz`/`*.asl`（`-o` 组合见 `file_ops.sh:3767-3773`），三条全中；`*` 字面一层、实际 `-maxdepth 3` 会深入子目录。`match`：年龄取 `MOLE_LOG_AGE_DAYS`（`base.sh:159`=7，`-mtime +7` 见 `file_ops.sh:3777-3778`）、depth `3`、type `f` ✅；N-01 仅锁 `/private`、`/private/var` 本体及 `db/tmp/folders/audit/root` 子树（`file_ops.sh:1072,1078-1080`），`/private/var/log` 不在其中、可删 ✅。`source:342-367` 起于 spinner、止于预算 `fi`，`system.sh` 与 artifacts 字节相同，无偏移。`default_selected:true` 受 `SYSTEM_CLEAN` 门控（`clean.sh:33` 初值 false、`:2069` 门、`:2071` 调用；需 sudo，与 `needs_admin:true` 自洽）。`action:delete` 走 sudo 批删 `/bin/rm -f`（`file_ops.sh:3998`），非废纸篓；`risk:medium` 口径待定。`in_app:true` 由 `p1a:449`（`/private/var/log` 同路径）支撑；`:515` 是 `/var/log/daily.out`，前缀不同且 `*.out` 不在 patterns 内，不计。 | `lib/clean/system.sh:342-367`（无偏移；sink `:346-347`；调用点 `clean.sh:2071`） |

### system-04

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| system-04 | OK | `paths`：`:370-371` 两目录经 `:382` 的 `"*"` 通配、depth 5 覆盖 ①②；`/Library/Logs/adobegc.log` 由 `:401` 基址 `/Library/Logs`＋`adobegc.log`、depth 1 精确删 ✅。`match`：年龄取 `MOLE_LOG_AGE_DAYS`=7（`base.sh:159`，`-mtime +7` 见 `file_ops.sh:3786`）、depth 5、type f ✅；预算耗尽 `:377-380` 置 124 并 `break`、`:414-415` 报该段不完整 ✅。`source:368-419` 起于 spinner、止于 `log_success` 的 `fi`，无偏移（仅尾漏 `:420-423` 预算守卫）。`default_selected:true` 受 `SYSTEM_CLEAN` 门控（`clean.sh:33` 初值 false、`:2069` 门、`:2071` 调用 `clean_deep_system`，无 y/n，需 sudo）。`action:delete`＝sudo 批删 `/bin/rm -f`（`file_ops.sh:4006`），非废纸篓；`needs_admin:true`（`:3678` 起 `sudo -n` 探测，未授权即鉴权失败）。`risk:low` 口径待定。`in_app:true`：`p1a:499-500` 的 `/Library/Logs/Adobe`、`/Library/Logs/CreativeCloud` 同后缀支撑。注：`paths` 的 `Adobe/*` 字面一层，实际递归 depth 5，`match` 已注明。 | `lib/clean/system.sh:368-419`（无偏移；sink `:382`/`:401`；调用点 `clean.sh:2071`） |

### system-10

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| system-10 | 行号偏移 | `paths` 两条落实：`:779`/`:784` `/private/var/db/diagnostics`＋`*`、`:801` `/private/var/db/DiagnosticPipeline`＋`*` ✅；`match` 成立：depth 5、type f、`-mtime +7`（`file_ops.sh:3786`，`MOLE_LOG_AGE_DAYS=7` 见 `base.sh:159`），两条均在 `validate_path_for_deletion` 的 `/private` 白名单（`file_ops.sh:1357-1358`）✅。`source:771-810` 偏移：`:771` 是 wallpaper 段尾 `if [[ $idle_tmp_cleaned -gt 0 ]]`，诊断段实起 `:779`、止 `:823`（`:810` 落在 `diag_status=$diag_rc`），起点 +8 且尾漏 `:811-823`。`default_selected:true` 受 `SYSTEM_CLEAN` 门控（`clean.sh:2069`/`:2071`，sudo 后才置 true）。`action:delete` 为 sudo 批删 `/bin/rm -f`（`file_ops.sh:4006`）；`needs_admin:true` 与 `file_ops.sh:3678` 的 `sudo -n` 一致；`risk:medium` 口径待定。`in_app:true` 由 `p1a:443` 同路径支撑，`:442` 仅为父目录前缀不计。 | `lib/clean/system.sh:779-823`（相对声明起点 +8；sink `:784`/`:801`；调用点 `clean.sh:2069`/`:2071`） |

<!-- logs 追加点 -->

## category: app_leftovers（6 条）

### user_cache-13

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| user_cache-13 | 行号偏移 | `paths`：`:2751-2758` 八条子目录逐一命中，`Cache`/`CachedData` 由 `:2760-2765` 的可再生标记门控 ✅；`<app>` 即 `:2739` 遍历的 `~/Library/Application Support/*` ✅。但函数 `:2863-2983` 另删 `Group Containers/group.com.apple.contentdelivery/{Logs,Library/Logs}`（sink `:2887`/`:2939`），未列入 `paths`。`match`：白名单/保护 `:2723-2737`、候选项复检 `:2768` ✅；>100 项走 `:2778-2799` 整目录 `safe_remove`（连 `Cache` 本体删，非仅 `/*`）；逐项 `:2801-2858`，0.4s 测量超时＋每 250 项进度 ✅；「app 运行则整 app 跳过」仅凭 `SingletonLock`（`:2673-2685`），无锁的运行中 App 测不到，部分成立。`source`：起点 `:2687` 为函数头无偏移，止 `:2862` 只是应用循环 `done`，函数实止 `:2983`，尾漏 121 行。`default_selected`：`clean.sh:2135` 在 Application Support 段无条件 `_run_cleanup_step`（`:2022-2053` 直接 `"$@"`，无 y/n）✅。`action`：`safe_remove`（`file_ops.sh:1478`）→校验 `:1520`→`rm -rf` `:1816`，永久删非废纸篓 ✅。`needs_admin:false`（`:2687-2983` 无 `sudo`）✅。`risk:medium` 待定：仅可再生缓存/崩溃报告，但批量删整目录。`in_app:unknown` 无 `in_app_evidence`，一致 ✅。 | `lib/clean/user.sh:2687-2983`（声明止 `:2862` 早 121 行；候选表 `:2750-2765`；调用点 `clean.sh:2135`） |

### app_leftovers-01

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| app_leftovers-01 | 不一致（`in_app`） | `paths` 为描述式但落点正确：`user.sh:1073` 传 `$HOME`→`apps.sh:37-39` 加 `-maxdepth 5`；`:2056` 传卷根→全深度（调用方另传 `-xdev` 等排除表 `:1975-1979`），未列外接卷目标。`match` 六项剪枝与 `:28-35` 逐条一致，`"$@"` 即调用方排除表，`-prune -o` 顺序正确。`source:10-118` 恰为整函数（`apps.sh` 与 artifacts 字节相同），无偏移。`default_selected`：`clean.sh:2087` 无条件（`_run_cleanup_step` `:2038` 直接 `"$@"`；仅白名单哨兵 `:129-130` 可置 `PROTECT_FINDER_METADATA`）。`action`：`apps.sh:80`→`file_ops.sh:1518` 校验→`:1816` 永久 `rm -rf`，非废纸篓。`needs_admin:false`（段内无 `sudo`）。`risk:low` 待定：仅删 `.DS_Store`、可再生，但卷内无深度上限。`in_app:true` 不成立：`p1a:61` `/Library/Caches/FreeCADStartThumbnails` 与 `.DS_Store` 无同后缀，无同路径证据，应为 `unknown`。 | `lib/clean/apps.sh:10-118`（无偏移；排除表 `:28-35`；depth `:37-39`；sink `:80`；调用点 `user.sh:1073`/`:2056`；`clean.sh:2087`） |

### app_leftovers-02

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| app_leftovers-02 | 不一致（`paths` + `in_app`） | `paths` 八条仅三条成立：`:1204-1208` 只含 `~/Library/Caches`（前缀 `com.*:org.*:net.*:io.*`）、`~/Library/Logs`（同前缀）、`~/Library/Saved Application State/*.savedState`。App Support 归 `user.sh:2687-2983`，`Preferences/<id>.plist` 无扫描，LaunchAgents/Containers/Group Containers 被 `:1200-1203` 明令排除（`:2422` 亦不动 user LaunchAgents；Containers 见 `:2504` stub=app_leftovers-04）。`match` 全成立（`:524-828` 扫描、`:853-931` 孤儿判定、`:931-953` 陈旧、`:1096-1109` 扫描失败即跳过、`:1248`/`:1253` 判定与白名单、`:1262` 快照、`:1291` 删除前复核）。`source` 无实质偏移：`:1075-1323` 实际止于 `:1319`，`:119-162` 多含下一函数签名。`default_selected:true`（`clean.sh:2140` 无条件）、`action:delete` 永久 `rm -rf`（`clean.sh:1728`→`file_ops.sh:1478`→`:1816`）、`needs_admin:false`（段内无 `sudo`）均成立；`risk:high` 口径待定（整目录批量永久删）。`in_app:true` 不成立：证据 766/772 实为 `p1a-strings.json` 的 Swift 类型名（CleanScreenInputBlockerContext、OptimizeWhitelistStore），非 `/Library/...` 路径，与 `paths` 无同路径。 | `lib/clean/apps.sh:1204-1208`（候选表）、`:1075-1319`（整函数）、`:524-1074`（扫描/判定）；`bin/clean.sh:2140` |

### app_leftovers-03

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| app_leftovers-03 | OK | `paths` 两目录成立（引用扫描 `:1850`、正式扫描 `:1996`/`:2041`）；`PrivilegedHelperTools` 亦由 `:2086-2093` 扫描并删其 binary，`paths` 未列（描述不全，不单独改判）。`match` 四项 helper 全部对上：`_orphan_service_vendor_protected` `:1391-1402`（`:1671`/`:1941`/`:2124`）、`_privileged_helper_is_developer_id_signed` `:1334-1349`（`:1759`/`:2170`）、`_privileged_helper_bundle_id_from_binary` `:1351-1386`（`:1739`）、`_privileged_helper_root_exists` `:1324-1326`（`:2086`）；「只删可证明宿主已不存在」成立：`:1641` `_plist_is_orphaned` 先读 Program、`:1443` 强制保护表、`bundle_has_installed_app`，删除前 `:2269`/`:2352` 复算 identity 并复判，`:2197-2206` 扫描不全即整体跳过。`source` 起点 `:1324` 即首个 helper，无偏移；函数实止 `:2420`，`:2421-2430` 为 policy 注释与下节头部（尾多 10 行，区间包含）。`default_selected:true`：`clean.sh:2141` 在 “App leftovers” 段无条件调用，函数内 `:1407` 另受 `SYSTEM_CLEAN` 门控。`action:delete`＝`safe_sudo_remove`（`:2368`）→`file_ops.sh:2014`→`:2245` `sudo rm -rf`，非废纸篓；`needs_admin:true`（`:1418-1419` `sudo -n true`、`:2245`）；`risk:high` 口径待定（root 级永久删注册/helper）。`in_app:true` 成立：`p1a-strings.json:518-542` 含 `/Library/LaunchAgents`、`/Library/LaunchDaemons`（同 id 同后缀），`:779` `StartupItemScanner`。另注（非本条判项）：`command` 写 `launchctl`，但 `apps.sh` 全文 0 处 `launchctl`（`:2339-2347` 注释明确不做 load/unload），该字段与代码不符。 | `lib/clean/apps.sh:1324-2430`（起点无偏移；helpers `:1324`/`:1334`/`:1351`/`:1391`；函数 `:1406-2420`；扫描 `:1996`/`:2041`/`:2086`；sink `:2368`→`file_ops.sh:2245`；调用点 `clean.sh:2141`） |

### app_leftovers-05

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| app_leftovers-05 | 不一致（`match` 年龄 + `in_app`） | `paths` 落点成立：`:1080` `$HOME/Library/Application Support/CrashReporter`，经 `file_ops.sh:3507` 固定 `-maxdepth 5 -type f` 扫描。`match` 的年龄错：`:1078 support_age_days=30`、`:1083` 传 30 → `-mtime +30`（`file_ops.sh:3508-3510`），不是 `MOLE_LOG_AGE_DAYS=7`；「maxdepth 限定」成立。`source:1077-1105` 起点即函数头，无偏移，但函数实止 `:1099`，`:1100-1105` 已是下一函数注释（尾多 6 行）；`:1096-1098` 的 Messages 缓存属 user_cache-06。`default_selected:true`：`:1300` 无条件调用，`clean_app_caches` 由 `clean.sh:2092` 直接 `_run_cleanup_step`，无 y/n。`action:delete`＝`:1083`→`file_ops.sh:3558 safe_remove` 永久删，非废纸篓；`needs_admin:false`（`:1077-1099` 段内无 `sudo`）。`risk:low` 口径待定：只删 ≥30 天的崩溃报告文件。`in_app:true` 不成立：`p1a-strings:69/95` 是 `/Library/Caches/SentryCrash/`、`/Library/Caches/com.crashlytics.data/`（等同 `~/Library/Caches/…`），父目录与末级名都与 `Application Support/CrashReporter` 不同，非同后缀。 | `lib/clean/user.sh:1077-1099`（声明止 `:1105`，尾多 6 行；`support_age_days` `:1078`；`safe_find_delete` `:1083`；sink `file_ops.sh:3558`；调用点 `user.sh:1300`/`clean.sh:2092`） |

### app_leftovers-04

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| app_leftovers-04 | 不一致（`in_app` 无证据，`source` 起点偏早） | `paths` 2 条即模式表 `:2518`/`:2520`（`$HOME/Library/Containers/` 下 glob）。`match` 成立：无其它兄弟项才继续（`:2543-2555`），`_container_stub_app_exists`（`:2431-2471`）查 `/Applications/CleanMyMac X.app`、`~/Applications`、Setapp 及 mdfind（超时按已安装）。`source` 末行 `:2639` 精确、起点应为 `:2504`。`default_selected`（`clean.sh:2148` 无 y/n）、`action:delete`（`:2500-2501` `rm -f`+`rmdir`，绕开 `safe_remove`）、`needs_admin:false`（无 sudo）均成立；`risk:medium` 口径待定。`in_app:true` 不成立：`p1a-strings.json` 全文无 `macpaw`，`:242` 实为 `/usr/bin/networkQuality`；`~/Library/Containers` 根仅有 `:579` 的 `com.docker.docker`，同根不同 id。 | `lib/clean/apps.sh:2431-2639`（模式表 `:2516-2521`、兄弟项检查 `:2541-2555`、调用 `:2560`、删除 `:2500-2501`；入口 `bin/clean.sh:2148`） |

<!-- app_leftovers 追加点 -->

## category: browser（20 条）

### browser-01

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| browser-01 | 不一致（`paths` 漏 1 条 + `in_app`） | `paths` 13 条对上 `:840/842/844/846/848/850/852/854/856/860/862/864/866`，漏 `:858` 的根级 `.../Chrome/GraphiteDawnCache/*`（只列了 `*/GraphiteDawnCache/*`；`:2154` 的 targets 清单同样含该根级项）。`match` 三态成立：`base.sh:75-101`（0 运行 / 1 未运行 / 2 未知），`user.sh:2167` 只有未运行才清、运行则 defer、未知打印 `skipped (process state unknown)`；叶级 `safe_clean_guarded` 回调 `mole_clean_process_guard`（`base.sh:2020-2034`）只停不删。`source:838-867` 即整函数，无偏移。`default_selected:true`：`clean.sh:2097` 在 Browsers 段无条件 `_run_cleanup_step`（`:2022` 直接 `"$@"`，无 y/n）。`action:delete`＝`safe_clean`→`file_ops.sh:1816` 永久 `rm -rf`，非废纸篓。`needs_admin:false`（段内无 `sudo`）。`risk:low` 口径待定。`in_app:true` 不成立：`p1a:62/103` 为 `/Library/Caches/Google/Chrome`、`/Library/Caches/com.google.Chrome`（＝`~/Library/Caches/…`），后缀与 `Application Support/Google/Chrome` 不同。 | `lib/clean/user.sh:838-867`（无偏移；漏项 `:858`；调用点 `clean.sh:2097` / `user.sh:2167`） |

### browser-02

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| browser-02 | OK | `paths` 两条字面命中：`~/Library/Caches/Firefox/*`（`:871`）、`~/Library/Application\ Support/Firefox/Profiles/*/cache2/*`（`:873`），只取 `*` 子项，未含 profile 本体。`match` 成立：`_firefox_process_state`（`:795-797`）为 `mole_pgrep_any -x "Firefox"` 三态（`base.sh:75-101`：0 运行 / 1 未运行 / 2 未知）；`:2305` 仅 state=1 才 `:2310` 清，运行则 `mole_defer_cleanup_family`，未知打印 `skipped (process state unknown)`；叶级另经 `_user_safe_clean_process_guarded`（`:15-40`）逐项复检。`source:869-874` 即整函数（`:874` 为 `}`），与 artifacts 同文件逐字节一致、无偏移。`default_selected:true` 成立：`clean.sh:2097` 在 Browsers 段无条件 `_run_cleanup_step`（定义 `:2022`，`:2036` 直接 `"$@"`，无 y/n）。`action:delete`＝`safe_clean`（`clean.sh:1720`）→`_safe_clean_impl`→`safe_remove`（`file_ops.sh:1478`，`:1816` 永久 `rm -rf`），非废纸篓。`needs_admin:false`（`clean_browsers` `:2128-2377` 全在 `$HOME`、无 `sudo`）。`risk:low` 口径待定：仅删可重建缓存。`in_app`：`p1a-strings.json:60` `/Library/Caches/Firefox` 即 `~/Library/Caches/Firefox` 后缀同路径，支持 `true`（`:67` Mozilla updates 不计）。 | `lib/clean/user.sh:869-874`（无偏移；`paths` `:871`/`:873`；调用点 `clean.sh:2097`→`user.sh:2310`） |

### browser-03

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| browser-03 | OK | `paths` 两条字面命中：`:878` 的 `~/Library/Caches/com.dropbox.*`、`:880` 的 `~/Library/Caches/com.getdropbox.dropbox`，均只取 `Caches` 下一级项。`match` 成立：`_dropbox_process_state`（`:799-801`）为 `mole_pgrep_any -x "Dropbox"` 三态（`base.sh:75-101`：0 运行 / 1 未运行 / 2 未知）；`clean_cloud_storage` `:2384-2398` 仅 state=1 才 `:2393` 清，运行则 `mole_defer_cleanup_family`，未知打印 `skipped (process state unknown)`；叶级另经 `_user_safe_clean_process_guarded`（`:15-40`）复检。`source:876-882` 起点即函数入口，函数实际止于 `:881`，末端 `:882` 仅多含一行空行；artifacts 与 engine 该文件 `cmp` 字节相同，无偏移。`default_selected:true`：`clean.sh:2105` 在 Cloud & Office 段无条件 `_run_cleanup_step`（`:2036` 直接 `"$@"`，无 y/n）。`action:delete`＝`safe_clean`（`clean.sh:1720`）→`_safe_clean_impl`→`safe_remove`（`file_ops.sh:1816` 永久 `rm -rf`），非废纸篓。`needs_admin:false`（`_safe_clean_impl` 与 `safe_remove` 段内无 `sudo`）。`risk:low` 口径待定：仅删可重建缓存。`in_app:true` 成立：`p1a-strings.json:102` 的 `/Library/Caches/com.getdropbox.dropbox` 与第二条同 id 同后缀（≡`~/Library/Caches/…`）。 | `lib/clean/user.sh:876-881`（无偏移；`paths` `:878`/`:880`；调用点 `clean.sh:2105`→`user.sh:2384-2398`） |

### browser-04

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| browser-04 | 不一致（`needs_admin`、`in_app`；`source` 末端多 2 行） | `paths` 成立：`:622` 拼 `Contents/Frameworks/Google Chrome Framework.framework/Versions`，`:677-687` 排除 `Current` 及其指向版本、`:660-670` 保留比 Current 新的暂存版本，其余（`:683` 另有保护/白名单/编译缓存三闸）进候选；app 路径见 `:891-894`（`~/Applications` 也在列）。`match` 成立：`is_google_chrome_running`（`:779-784`）→`mole_pgrep_any`（`base.sh:75-101`：0 运行 / 1 未运行 / 2 未知），`:694-704` 非 1 即 defer 或打 `skipped`，`:706-726` 每删一项前复检两次。`source` 起点精确，但共享函数实际止于 `:776`、包装函数止于 `:899`，两端各多含一空行 + 下一函数注释（`:778` 属 `is_google_chrome_running`、`:901` 属 `clean_edge_old_versions`），属区间越界而非整体偏移。`default_selected:true`：`clean.sh:2097` 在 Browsers 段无条件 `_run_cleanup_step`（`:2022`，`:2036` 直接 `"$@"`，无 y/n）。`action:delete`＝`safe_remove`/`safe_sudo_remove` 永久 `rm -rf`（`file_ops.sh:1816`/`:2245`），非废纸篓。`risk:medium` 口径待定。`needs_admin:false` 不成立：`:739-742` 在 `SYSTEM_CLEAN=true` 且有 sudo 会话时改走 `safe_sudo_remove`（`/Applications/Google Chrome.app` 属 root，`clean.sh:1866-1868` 可置 true；`sudo.sh:303-309` 仅 `sudo -n` 探测，不弹密码）。`in_app:true` 不成立：`p1a:103-104` 是 `~/Library/Caches/…`，与 paths 的 app 包内后缀不同。 | `lib/clean/user.sh:605-776`、`884-899`（无偏移；`paths` `:622`/`:660-687`；调用点 `user.sh:2340`） |

### browser-05

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| browser-05 | 不一致（`needs_admin`、`in_app`；`source` 末端多 2 行） | `paths` 两项成立：`:909-911` 取 `/Applications/Microsoft Edge.app`、`$HOME/Applications/…`，经 `_clean_chromium_old_versions` 拼 `Contents/Frameworks/Microsoft Edge Framework.framework/Versions`（`:622`），`Current`、其指向版本及较新暂存版本不删（`:644`/`:652-674`/`:681`）；`:921` 即 EdgeUpdater `…/EdgeUpdater/apps/msedge-stable`。`match` 成立：`is_microsoft_edge_running`（`:787-789`）三态，`:694-704` 非 1 即 defer/`skipped`，逐项再复检（`:707-711`、`:720-724`）；updater 同（`:979-988`、`:1002-1006`），并按已装版本保留等于/更新者（`:965-970`）。`source:902-1050` 起点精确，但两函数实止 `:1048`，`:1049` 空行、`:1050` 属下一函数注释（末端多 2 行）。`default_selected:true`：`bin/clean.sh:2097` Browsers 段无条件 `_run_cleanup_step`（定义 `:2022`，`:2036` 直接 `"$@"`，无 y/n）。`action:delete`＝`safe_remove`（`file_ops.sh:1478`→`:1816` 永久 `rm -rf`），非废纸篓；updater `:1018` 同。`risk:medium` 口径待定。`needs_admin:false` 不成立：`:739-742` 在 `SYSTEM_CLEAN=true` 且有 sudo 会话时对 `/Applications` 下旧版本改走 `safe_sudo_remove`（`file_ops.sh:2014`→`:2245`；`clean.sh:1867` 可置 true，`sudo.sh:303-309` 仅 `sudo -n` 探测）。`in_app:true` 不成立：`p1a-strings:117` 是 `~/Library/Caches/com.microsoft.edgemac`，与 `Versions`、`EdgeUpdater/apps` 后缀均不同。 | `lib/clean/user.sh:902-1048`（无偏移；`:902`/`:920` 两函数；`paths` `:622`/`:921`；调用点 `:2341-2342`；`bin/clean.sh:2097`） |

### browser-06

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| browser-06 | 不一致（`needs_admin`、`in_app`；`source` 末端多 2 行） | `paths` 成立：`:1058-1061` 取 `/Applications/Brave Browser.app`、`$HOME/Applications/…`，`:1064` 传入 `_clean_chromium_old_versions`，`:622` 拼 `Contents/Frameworks/Brave Browser Framework.framework/Versions`；`Current`、其指向版本与较新暂存版本不删（`:663`/`:671-682`）；`:1054-1056` 的 `MOLE_BRAVE_APP_PATHS` 覆盖未声明。`match` 成立：`is_brave_browser_running`（`:791-793`）三态（`base.sh:75-101`），`:696-704` 非 1 即 defer/`skipped`，`:706-726` 逐项复检两次。`source:1051-1068` 起点精确，但函数实止 `:1066`，`:1067` 空行、`:1068` 属下一函数注释（末端多 2 行）；user.sh 与 artifacts 逐字节相同、无偏移。`default_selected:true`：`clean.sh:2097` Browsers 段无条件 `_run_cleanup_step`（`:2022`，`:2036` 直接 `"$@"`，无 y/n）。`action:delete`＝`safe_remove`（`file_ops.sh:1478`→`:1816` 永久 `rm -rf`）或 `safe_sudo_remove`（`:2245`），非废纸篓。`risk:medium` 口径待定。`needs_admin:false` 不成立：`:739-742` `SYSTEM_CLEAN=true` 且有 sudo 会话时对 `/Applications` 旧版本走 `safe_sudo_remove`（`clean.sh:1866-1868` 可置 true；`sudo.sh:303-309` 仅 `sudo -n`）。`in_app:true` 不成立：`p1a-strings:48-51,91` 是 `/Library/Caches/BraveSoftware`、`/Library/Caches/com.brave.Browser`（≡`~/Library/Caches/…`），与 app 包内 `Versions` 后缀不同。 | `lib/clean/user.sh:1051-1066`（无偏移；`paths` `:1058-1061`/`:622`；调用点 `:2343`；`bin/clean.sh:2097`） |

### browser-07

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| browser-07 | OK | `paths` 字面命中单行 `:2131`；`user.sh` 与 artifacts `cmp` 字节相同，`source:2131` 无偏移。`match:null` 成立：本行为裸 `safe_clean`，无进程/版本守卫，仅过通用闸门（`clean.sh:1160` 保护、`:1168` 白名单、`:1178` selection、`:1185` 编译缓存）。`default_selected:true`：`clean.sh:2097` Browsers 段 `_run_cleanup_step`（`:2022`/`:2036`）无 y/n。`action:delete`：`safe_clean`（`clean.sh:1720`）→`_safe_clean_impl`（`:1076`）→`safe_remove`（`file_ops.sh:1478`）→`rm -rf`（`:1816`）永久删除，非废纸篓。`needs_admin:false`：路径在 `$HOME`，且 `:1076-1722` 与 `safe_remove` 段无 `sudo`。`risk:low` 口径待定（纯可再生缓存；本行无进程守卫，Safari 运行时也照删）。`in_app:unknown` 与证据一致：p1a 仅有 `/Applications/Safari.app`（`p1a-strings.json:406`），无 `/Library/Caches/com.apple.Safari`，非同路径。 | `lib/clean/user.sh:2131`（无偏移；`paths` `:2131`；调用点 `bin/clean.sh:2097`；sink `lib/core/file_ops.sh:1478`→`:1816`） |

### browser-08

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| browser-08 | 不一致（`paths`；`source` 区间） | `paths` 错配：规则写 `~/Library/Caches/com.google.Chrome/*`，而 `clean_browsers` 只清 `~/Library/Caches/Google/Chrome/*`（`:2135`/`:2137`），无 `Caches/com.google.Chrome` 的专项删除（该串仅作 bundle id，见 `browser_clones.sh:48-51`）；同名路径只落入 `clean_user_essentials` 的通用 `Caches/*` 扫描（`:289-309`），该处无 Chrome 守卫且显式跳过 `Google`。`match`「Chrome 进程守卫」本身成立但绑在 `Google/Chrome`：`:2136` `_user_safe_clean_process_guarded` + `:779-784 is_google_chrome_running`，三态见 `base.sh:75-101`，`:2020-2033` 为守卫（运行→defer、未知→skip）。`source:2136-2140` 与真实 `if/调用/fi` 块 `:2135-2138` 不符（起 +1、止 +2，`:2139-2140` 属下段注释）。`default_selected:true` 对：`bin/clean.sh:2097` 无条件 `_run_cleanup_step`（`:2022`/`:2036`，无 y/n）。`action:delete` 对：`safe_clean`（`clean.sh:1720`）→`_safe_clean_impl`（`:1076`）→`safe_remove`（`file_ops.sh:1478`）→`:1816` 永久 `rm -rf`。`needs_admin:false` 对（段内及 `safe_remove` 无 `sudo`）。`risk:low` 口径待定（纯可再生缓存；若按 `paths` 落地则通用扫描无 Chrome 守卫）。`in_app:true` 成立：`p1a:103` 与 `paths` 同后缀（≡`~/Library/…`），但证据不支撑代码实际的 `Google/Chrome`。 | `lib/clean/user.sh:2135-2138`（`paths` `:2135`/`:2137`；守卫 `:2136`、`:779-784`；调用点 `bin/clean.sh:2097`）；`com.google.Chrome` 仅见 `:289-309` 通用扫描 |

### browser-09

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| browser-09 | OK | `paths` 四条逐字落在 `:2178-2181`：`GoogleUpdater/crx_cache/*`、`GoogleUpdater/*.old`、`Caches/Chromium/*`、`Caches/com.microsoft.edgemac/*`，均为单层 `*`。`match:null` 成立：四行为裸 `safe_clean`，无进程/版本守卫，仅过通用闸门（`clean.sh:1160` 保护、`:1168` 白名单、`:1178` selection、`:1185` 编译缓存），与 `protected_by:P-01` 自洽。`source:2178-2181` 精确即这四行，`user.sh` 与 artifacts 字节相同、无偏移。`default_selected:true`：`clean.sh:2097` Browsers 段无条件 `_run_cleanup_step`（`:2022`，`:2036` 直接 `"$@"`，无 y/n）。`action:delete`＝`safe_clean`（`clean.sh:1720`）→`_safe_clean_impl`（`:1076`）→`safe_remove`（`file_ops.sh:1478`）→`:1816` 永久 `rm -rf`，非废纸篓。`needs_admin:false`（四条及 `safe_remove` 段无 `sudo`）。`risk:low` 口径待定（纯可再生缓存与旧版文件）。`in_app:true` 由 `p1a:117` 的 `/Library/Caches/com.microsoft.edgemac`（≡`~/Library/Caches/…`）同 id 同后缀支撑；`p1a:98` 实为 `com.docker.*`，非同路径，属错引，Chromium/GoogleUpdater 无对应串。 | `lib/clean/user.sh:2178-2181`（无偏移；sink 即 `:2178-2181`；调用点 `bin/clean.sh:2097`；删除链 `bin/clean.sh:1720`→`lib/core/file_ops.sh:1478`→`:1816`） |

### browser-10

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| browser-10 | 不一致（`paths` 漏 6 条；`match` 未覆盖首条） | `paths` 前五组逐字命中 `:2184`、`:2187-2191`、`:2192`、`:2196-2200`、`:2204-2206`，漏 6 条根级叶子：`:2193` `Arc/GrShaderCache/*`、`:2194` `Arc/GraphiteDawnCache/*`、`:2195` `Arc/Crashpad/completed/*`、`:2201` `Arc/User Data/ShaderCache/*`、`:2202` `Arc/User Data/GrShaderCache/*`、`:2203` `Arc/User Data/GraphiteDawnCache/*`；`:2210-2215` 两段 Service Worker/CacheStorage 也未列入。`match` 守卫仅包 `:2187-2206`：`:2186` `mole_clean_process_guard _arc_process_state`（`_arc_process_state`＝`mole_pgrep_any -x "Arc"`，`:815-817`；三态 `base.sh:75-101`；守卫 `base.sh:2020-2033`），运行或未知即 `:2208` 报停；首条 `~/Library/Caches/company.thebrowser.Browser/*`（`:2184`）在守卫之前，Arc 在跑也照删，且整块以 `:2183` `[[ -d .../Arc ]]` 为前置。`source:2184-2207` 起于首条删除、止于 `:2207` `else`（`if` 在 `:2183`、`fi` 在 `:2209`），两端不闭合，无整体行号偏移（`user.sh` 与 artifacts 字节相同）。`default_selected:true`：`clean.sh:2097` Browsers 段无条件 `_run_cleanup_step`（`:2022`/`:2036`，无 y/n）。`action:delete`＝`safe_clean`（`clean.sh:1720`）→`_safe_clean_impl`（`:1076`）→`safe_remove`（`file_ops.sh:1478`）→`:1816` 永久 `rm -rf`，非废纸篓。`needs_admin:false` 与 `risk:low`（口径待定）成立，段内无 `sudo`。`in_app:true` 成立：`p1a:145` 的 `/Library/Caches/company.thebrowser.Browser` 与 `paths` 首条同 id 同后缀。 | `lib/clean/user.sh:2184-2206`（无偏移；`paths` `:2184`/`:2187-2192`/`:2196-2206`；漏项 `:2193-2195`/`:2201-2203`；守卫 `:2186`、`base.sh:2020-2033`；调用点 `bin/clean.sh:2097`） |

### browser-11

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| browser-11 | 不一致（`match`、`paths` 漏项、`source` 区间） | `paths` 四组逐字命中 `:2223`（`Caches/company.thebrowser.dia/*`）、`:2235`、`:2236`、`:2237-2240`、`:2241-2243`，但漏 `:2250-2253` 的 `Dia/User Data/*/Service Worker/CacheStorage`。`match:null` 不成立：`:2224-2234` 有自建 `pgrep -x "Dia"` 三态守卫，仅 state=1 才清，运行/未知均在 `:2245-2247` 打 skipped；且首条 `:2223` 在守卫之前，Dia 运行时照删。`source:2223-2243` 恰覆盖所列删除行、无行号偏移（`user.sh` 与 artifacts 字节相同），但守卫 `if`（`:2224`）与 `fi`（`:2254`）在区间外。`default_selected:true`：`clean.sh:2097` Browsers 段无条件 `_run_cleanup_step`（`:2022`/`:2036`，无 y/n）。`action:delete`＝`safe_clean`（`clean.sh:1720`）→`safe_remove`（`file_ops.sh:1478`）→`:1816` 永久 `rm -rf`，非废纸篓。`needs_admin:false` 成立（`:2211-2254` 无 `sudo`）；`risk:low` 口径待定。`in_app:true` 成立：`p1a-strings.json:146` 即 `/Library/Caches/company.thebrowser.dia`，与首条同 id 同后缀。 | `lib/clean/user.sh:2223-2243`（无偏移；`paths` `:2223`/`:2235-2236`/`:2237-2240`/`:2241-2243`；漏 `:2250-2253`；守卫 `:2224-2234`；跳过 `:2245-2247`；调用点 `bin/clean.sh:2097`；sink `lib/core/file_ops.sh:1478`→`:1816`） |

### browser-12

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| browser-12 | 不一致（`paths` 漏 2 项、`in_app`） | `paths` 两组合计 11 条逐字命中 `:2262-2267`（六种 per-profile cache）与 `:2268-2272`（component_crx_cache/ShaderCache/GrShaderCache/GraphiteDawnCache/Crashpad/completed），无错项；但漏 `:2258` 的 `~/Library/Caches/BraveSoftware/Brave-Browser/*` 与 `:2276-2279` 的 `*/Service Worker/CacheStorage`（`caches.sh:74`）。`match` 成立：`:2261` `mole_clean_process_guard` + `is_brave_browser_running`（`:791-793` `mole_pgrep_any -x "Brave Browser"`）三态（`base.sh:2020-2034`），仅未运行才清、运行/未知走 `:2273-2275` 报停；Caches 分支另经 `_user_safe_clean_process_guarded`（`:16-40`），整块以 `:2255` 目录存在为前置。`source:2257-2272` 与 artifacts 逐字节相同、无偏移，起于未声明的 Caches 分支守卫删除、止于末条 `safe_clean`（`:2261` 守卫 `if`、`:2275` `fi` 属区间外结构行）。`default_selected:true`＝`clean.sh:2097` Browsers 段无条件 `_run_cleanup_step`（`:2022`/`:2036` 直接 `"$@"`，无 y/n）。`action:delete`＝`safe_clean`（`clean.sh:1720`）→`_safe_clean_impl`（`:1076`）→`safe_remove`（`file_ops.sh:1478`）→`:1816` 永久 `rm -rf`。`needs_admin:false`（段内无 `sudo`）；`risk:low` 口径待定。`in_app:true` 不成立：`p1a:48-51,91` 均为 `/Library/Caches/BraveSoftware{,/Brave-Browser,-Beta,-Nightly}`、`/Library/Caches/com.brave.Browser`，落在 `Caches` 下，与 `paths` 的 `Application Support` 分支不同路径，反而正好对应漏掉的 `:2258`。 | `lib/clean/user.sh:2257-2272`（无偏移；`paths` `:2262-2272`；漏 `:2258`/`:2276-2279`；守卫 `:2261`、`:791-793`、`base.sh:2020-2034`；调用点 `bin/clean.sh:2097`；sink `lib/core/file_ops.sh:1478`→`:1816`） |

### browser-13

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| browser-13 | OK | `paths` 四组共 8 条逐字命中：`:2282` 的 `Caches/net.imput.helium/*`、`:2283` 的 `*/GPUCache/*`、`:2284-2288` 的 component_crx_cache/extensions_crx_cache/GrShaderCache/GraphiteDawnCache/ShaderCache（五项顺序与源码一致）、`:2289` 的 `*/Application Cache/*`，无漏项也无错项（省略号 `…` 指 `~/Library/Application Support`，与源码一致）。`match:null` 成立：八行全为裸 `safe_clean`，无进程/版本/年龄守卫，仅 `:2281` 的 `-d` 前置与通用闸门（`clean.sh:1160` 保护、`:1168` 白名单、`:1178` selection、`:1185` 编译缓存）；补充两点行为细节——整块以 `~/Library/Application Support/net.imput.helium` 存在为前提（仅有 `Caches` 时首条不执行），且 Helium 运行中无守卫照删。`source:2282-2289` 精确覆盖 8 条删除行，`if`/`fi`（`:2281`/`:2290`）在区间外，`user.sh` 与 artifacts 字节相同、无偏移。`default_selected:true`：`clean.sh:2097` 在 Browsers 段无条件 `_run_cleanup_step`（定义 `:2022`，`:2036` 直接 `"$@"`，无 y/n）。`action:delete`＝`safe_clean`（`clean.sh:1720`）→`_safe_clean_impl`（`:1076`）→`safe_remove`（`file_ops.sh:1478`）→`:1816` 永久 `rm -rf`，非废纸篓。`needs_admin:false`（`:2281-2290` 无 `sudo`，全部路径在 `$HOME` 下）。`risk:low` 口径待定（仅可再生缓存；Helium 未列入保护名单，`grep net.imput` 仅见本段与 `browser_clones.sh`）。`in_app:true` 成立：`p1a:154` 的 `/Library/Caches/net.imput.helium` 与首条同 id 同后缀（≡`~/Library/Caches/…`）。 | `lib/clean/user.sh:2282-2289`（无偏移；`paths` `:2282`/`:2283`/`:2284-2288`/`:2289`；前置 `:2281`；调用点 `bin/clean.sh:2097`；sink `lib/core/file_ops.sh:1478`→`:1816`） |

### browser-14

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| browser-14 | 不一致（`in_app`） | `paths` 五条逐字命中 `:2293`（`~/Library/Caches/Yandex/YandexBrowser/*`）、`:2294`/`:2295`/`:2296`（`…/YandexBrowser/ShaderCache`、`GrShaderCache`、`GraphiteDawnCache`，即规则里的三处并列项）、`:2297`（`…/YandexBrowser/*/GPUCache/*`，`…`≡`~/Library/Application Support`），无漏项无错项，整块前置为 `:2292` 的 `[[ -d ~/Library/Application\ Support/Yandex ]]`。`match:null` 成立：五行全为裸 `safe_clean`，无进程/版本守卫。`source:2293-2297` 恰即这五行删除语句，`artifacts/mole-cli/lib/clean/user.sh` 同切片 `diff` 相同、无偏移（`if`/`fi` 落在 `:2292`/`:2298`，区间外）。`default_selected:true`：`bin/clean.sh:2097` 在 Browsers 段无条件 `_run_cleanup_step`（定义 `:2022`，`:2036` 直接 `"$@"`，无 y/n）。`action:delete`＝`safe_clean`（`bin/clean.sh:1720`）→`_safe_clean_impl`（`:1076`）→`safe_remove`（`lib/core/file_ops.sh:1478`）→`:1816` 永久 `rm -rf`，非废纸篓。`needs_admin:false` 成立（`:2291-2298` 无 `sudo`）。`risk:low` 口径待定。`in_app:true` 不成立：证据 `p1a-strings.json:141` 为 `/Library/Caches/com.yandex.browser`（≡`~/Library/Caches/…`），与 `paths` 任一后缀均不同，属错引。 | `lib/clean/user.sh:2293-2297`（无偏移；`paths` `:2293`/`:2294-2296`/`:2297`；前置 `:2292`；调用点 `bin/clean.sh:2097`；sink `lib/core/file_ops.sh:1478`→`:1816`） |

### browser-15

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| browser-15 | OK | `paths` 单条 `~/Library/Caches/com.operasoftware.Opera/*` 与 `:2315` 的裸 `safe_clean … "Opera cache"` 逐字一致。`match:null` 成立：该行在 `clean_browsers`（`:2128-2377`）顶层，前置 Firefox 块 `:2299-2314` 已闭合，无进程/版本/年龄守卫。`source:2315` 精确无偏移（`user.sh` 与 artifacts 字节相同）。`default_selected:true`：`clean.sh:2097` Browsers 段 `_run_cleanup_step`（`:2022`，`:2036` 直接 `"$@"`）无 y/n。`action:delete`＝`safe_clean`（`clean.sh:1720`）→`_safe_clean_impl`（`:1076`）→`safe_remove`（`file_ops.sh:1478`）→`:1816` 永久 `rm -rf`，非废纸篓。`needs_admin:false`（`:2128-2377` 无 `sudo`，路径在 `$HOME`）。`risk:low` 口径待定（纯可再生缓存；Opera 运行中亦照删）。`in_app:true` 成立：`p1a-strings.json:122` 即 `/Library/Caches/com.operasoftware.Opera`，与 `paths` 同 id 同后缀（≡`~/Library/Caches/…`）。`protected_by:P-01` 自洽。 | `lib/clean/user.sh:2315`（无偏移；`paths`/sink 同一行；调用点 `bin/clean.sh:2097`；删除链 `bin/clean.sh:1720`→`:1076`→`lib/core/file_ops.sh:1478`→`:1816`） |

### browser-16

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| browser-16 | 不一致（`paths` 漏 1 条、`match` 未覆盖首条；`source` 区间不闭合） | `paths` 三条对上 `:2318`、`:2321-2325`、`:2326-2329`，漏 `:2333-2335` 的 `*/Service Worker/CacheStorage` 循环（`caches.sh:74` 同走 `safe_clean`）。`match` 守卫仅包 `:2321-2329`：`:2320` `mole_clean_process_guard _vivaldi_process_state`（`:819-820` `mole_pgrep_any -x "Vivaldi"`；三态 `base.sh:75-101`；守卫 `base.sh:2020-2033`），首条 `:2318` 在守卫前，Vivaldi 运行时照删；`else`（`:2330-2331`）只 `mole_report_guard_stop` 记日志。`source:2318-2329` 起止均为删除行，`if`(`:2317`)/`fi`(`:2332`) 与 SW 循环在区间外，无整体行号偏移（`user.sh` 与 artifacts 字节相同）。`default_selected:true`：`clean.sh:2097` 无条件 `_run_cleanup_step`（`:2022`，`:2036` 直接 `"$@"`，无 y/n）。`action:delete`＝`safe_remove` 永久 `rm -rf`（`file_ops.sh:1478`→`:1816`），非废纸篓。`needs_admin:false`（`:2316-2336` 无 `sudo`）。`risk:low` 口径待定。`in_app:true` 成立：`p1a-strings.json:139` 与首条同 id 同后缀。 | `lib/clean/user.sh:2318-2329`（无偏移；`paths` `:2318`/`:2321-2325`/`:2326-2329`；漏 `:2333-2335`；守卫 `:2320`、`:819-820`、`base.sh:2020-2033`；调用点 `bin/clean.sh:2097`；sink `lib/core/file_ops.sh:1478`→`:1816`） |

### browser-17

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| browser-17 | OK | `paths` 三条逐字命中 `:2337-2339`（Comet、Orion、Zen 各为单层 `*`）。`match:null` 成立：三行均为裸 `safe_clean`，位于 `clean_browsers`（`:2128-2377`）顶层，前序 Vivaldi 块与 SW 循环均已闭合，无进程/版本守卫，仅过通用闸门（`clean.sh:1160`/`:1168`/`:1178`/`:1185`）。`source` 精确无偏移（`user.sh` 与 artifacts 字节相同）。`default_selected:true`＝`bin/clean.sh:2097` 无条件 `_run_cleanup_step`（`:2022`/`:2036`，无 y/n）。`action:delete`＝`safe_clean`（`clean.sh:1720`）→`_safe_clean_impl`（`:1076`）→`safe_remove`（`file_ops.sh:1478`→`:1816` 永久 `rm -rf`）。`needs_admin:false`（段内无 `sudo`）。`risk:low` 口径待定（可再生缓存；三条无进程守卫，运行中也照删）。`in_app:true`：`p1a-strings.json:108`/`:165` 为 `/Library/Caches/com.kagi.kagimacOS`、`/Library/Caches/zen`，与后两条同后缀；Comet 无对应串。 | `lib/clean/user.sh:2337-2339`（无偏移；`paths`/sink 同三行；调用点 `bin/clean.sh:2097`；删除链 `bin/clean.sh:1720`→`:1076`→`lib/core/file_ops.sh:1478`→`:1816`） |

### browser-18

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| browser-18 | 不一致（`match` 未覆盖首条；`source` 区间不闭合；`in_app`） | `paths` 三组对上 `:2346`（`Caches/com.tencent.QQBrowser3/*`）、`:2348-2349`（`*/Code Cache/*`、`*/GPUCache/*`）、`:2350-2354`（ShaderCache、GrShaderCache、GraphiteDawnCache、component_crx_cache、Crashpad/completed，顺序一致），无漏项错项；整块以 `:2345` `[[ -d …Application Support/QQBrowser3 ]]` 为前置，仅有 Caches 时不执行。`match`「QQ 浏览器进程守卫」仅包 `:2348-2354`：`:2347` `mole_clean_process_guard _qqbrowser_process_state`（`:823-825` `mole_pgrep_any -x "QQBrowser3"`；三态 `base.sh:75-101`；守卫 `base.sh:2020-2033`），首条 `:2346` 在守卫前，QQ 浏览器运行时照删；`:2355-2356` 仅 `mole_report_guard_stop` 记日志。`source:2346-2355` 起于首条删除、止于 `:2355` `else`（`if` 在 `:2345`/`:2347`、`fi` 在 `:2357`/`:2358`），两端不闭合，无整体行号偏移。`default_selected:true`：`clean.sh:2095-2097` Browsers 段无条件 `_run_cleanup_step`（`:2022`/`:2036` 直接 `"$@"`，无 y/n）。`action:delete`＝`safe_clean`（`clean.sh:1720`）→`_safe_clean_impl`（`:1076`）→`safe_remove`（`file_ops.sh:1478`）→`:1816` 永久 `rm -rf`，非废纸篓。`needs_admin:false`（`:2344-2358` 无 `sudo`）。`risk:low` 口径待定。`in_app:true` 不成立：`p1a-strings.json:337` 为 `/Library/Containers/com.wuziqi.SenPlayer/Data/tmp/videoCache`，与 `paths` 任一后缀均不同，属错引；全文亦无 `QQBrowser3` 串。 | `lib/clean/user.sh:2346-2354`（无偏移；`paths` `:2346`/`:2348-2349`/`:2350-2354`；前置 `:2345`；守卫 `:2347`、`:823-825`、`base.sh:2020-2033`；调用点 `bin/clean.sh:2097`；sink `lib/core/file_ops.sh:1478`→`:1816`） |

### browser-19

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| browser-19 | 不一致（`match`） | `paths` 11 条逐字命中 `:2362-2372`（`\|` 为并列简写：`Caches/*/Cache`＋`Code Cache` 占两行、GPU 三行、根级六项），无漏项错项。`source:2362-2372` 恰为这 11 行 `safe_clean`；`user.sh` 与 artifacts `cmp` 字节相同（3945 行），无偏移（`if` `:2361`、`fi` `:2375` 属结构行在区间外）。`match:null` **不成立**：`:2361` 有 `mole_clean_process_guard _browseros_process_state "BrowserOS started"`（`:827-832` 为 `-x BrowserOS`/`-x "BrowserOS Helper"`/`-f "/BrowserOS[.]app/"`；三态 `base.sh:2020-2033`），仅 state=1 才清，运行/未知均走 `:2374` 记 skipped；11 条全在守卫内，应填「BrowserOS 进程守卫」。`default_selected:true`＝`clean.sh:2097` Browsers 段无条件 `_run_cleanup_step`（`:2022`/`:2036` 直接 `"$@"`，无 y/n）。`action:delete`＝`safe_clean`（`clean.sh:1720`）→`_safe_clean_impl`（`:1076`）→`safe_remove`（`file_ops.sh:1478`）→`:1816` 永久 `rm -rf`，非废纸篓。`needs_admin:false` 成立（`:2359-2376` 无 `sudo`）；`risk:low` 口径待定。`in_app:unknown` 成立且自洽：本条无 `in_app_evidence`，p1a 全文（`grep -c` = 0）无 BrowserOS 串，不宣称在 App 内。 | `lib/clean/user.sh:2362-2372`（无偏移；`paths` 即 `:2362-2372`；前置 `:2360`；守卫 `:2361`、`:827-832`、`base.sh:2020-2033`；调用点 `bin/clean.sh:2097`；sink `lib/core/file_ops.sh:1478`→`:1816`） |

### browser-20

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| browser-20 | 不一致（`match`） | `paths` 为判定面描述（可接受），落点即 `clean_service_worker_cache`，实际目标由调用方传入 `.../Service Worker/CacheStorage`（`user.sh:2176`、`app_caches.sh:762`、`dev.sh:2073`）。`match` 不成立：函数 `find -mindepth 2 -maxdepth 2`（`:103`）只清 CacheStorage 内的 origin 子目录，不含「HTTP cache 类目录」；且无进程/句柄判定，`:173` 的 `delete_guard` 只是可选回调（Feishu/Notion/dev 传进程守卫），Chrome/Arc/Dia/Brave/Vivaldi 调用只传两参、无守卫，`:143`/`:177` 是路径身份快照而非句柄。`source` 起 `:74` 无偏移，函数止 `:229`，`:230-231` 已属下一函数（尾多 2 行）。`default_selected:true`＝`clean.sh:2097` 无条件 `_run_cleanup_step`（`:2022`/`:2036` 无 y/n）。`action:delete`＝`:189`→`file_ops.sh:1478`→`:1816` 永久 rm。`needs_admin:false`（无 `sudo`）。`risk:medium` 口径待定。`in_app:unknown` 自洽（无 evidence，p1a 无对应串）。 | `lib/clean/caches.sh:74-229`（起点无偏移；尾 `:230-231` 越界；调用方 `lib/clean/user.sh:2176`、`lib/clean/app_caches.sh:762`、`lib/clean/dev.sh:2073`；sink `lib/core/file_ops.sh:1478`→`:1816`） |

<!-- browser 追加点 -->

## category: dev_tools（30 条）

### dev_tools-01

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| dev_tools-01 | OK | `paths` 4 条按序命中 `:713`（`"$HOME/Library/Caches/pnpm"/metadata*/*`）、`:718`（`~/.tnpm/_cacache/*`）、`:719`（`~/.tnpm/_logs/*`）、`:723`（`~/Library/Caches/Yarn/*`）。`match` 成立：`:710` 调 `clean_pnpm_stores`（`:542-608`），`:545` 经 `pnpm_process_blocks_prune`（`:459`，进程在或状态未知均 fail-closed 跳过 prune）、`:582` 经 `is_safe_pnpm_store_path`（`:479`，要求绝对路径且拒 `..`/换行）拒绝不安全 store；两守卫函数在 `source` 区间外。`source` 起 `:663` 即函数头，止 `:724` `}`，`:725-727` 为下一函数注释（尾 3 行属区间包含）。`default_selected`＝`clean.sh:2120` 无条件 `_run_cleanup_step`（`:2022-2052` 直接 `"$@"`，无 y/n）。`action:delete`＝`safe_clean`→`file_ops.sh:1478`→`:1816`/`:1818` 永久 `rm -rf`。`needs_admin:false`（`:663-724` 无 `sudo`）。`risk:low` 仅 pnpm metadata、tnpm 缓存/日志与 Yarn v1 下载缓存，可再生（口径待定）。`in_app:true` 成立：`p1a-strings.json:71/159` 的 `/Library/Caches/Yarn`、`/Library/Caches/pnpm` 为主二进制内 `~/Library` 后缀串，分别对应 `paths`④ 与①（pnpm metadata 的父目录）。 | `lib/clean/dev.sh:663-727`（起点无偏移；尾 3 行属下一函数注释；`match` 守卫在 `:459-488`/`:542-608`；调用点 `bin/clean.sh:2120`；sink `lib/core/file_ops.sh:1478`→`:1816`） |

### dev_tools-02

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| dev_tools-02 | OK | `paths` 7 条按序命中 `:956`（pyenv）、`:957`（poetry）、`:965`/`:966`（pypoetry artifacts/cache）、`:968`/`:969`/`:970`（ruff/mypy/pytest）。`match` 成立：`:958-964` 注释明确 virtualenvs 属硬保护、仅命名 artifacts 与 cache 两个可再生兄弟；`base.sh:222` 的 `pypoetry/virtualenvs*` 白名单佐证，dev.sh 从不删该根。`source` 起 `:946` 即函数头（`:945` 为注释），止 `:979` 的 `}`，`:980` 仅空行。`default_selected`＝`clean.sh:2120`→`dev.sh:6286` 无条件调用，无 y/n。`action:delete`＝`_safe_clean_impl`（`clean.sh:1475`）→`file_ops.sh:1478`→`:1816`/`:1818` 永久 `rm -rf`（非废纸篓）。`needs_admin:false`（区间无 `sudo`）。`risk:low` 均为可再生缓存（口径待定）。`in_app:true` 成立：`p1a-strings.json:160-161` 的 `/Library/Caches/pypoetry/artifacts`、`/cache` 即 `paths`③④ 的用户主目录后缀串，同 id 同后缀；`:178` 的 `~/…/virtualenvs` 属保护侧。 | `lib/clean/dev.sh:946-979`（起点无偏移；尾 `:980` 为空行；`match` 白名单 `lib/core/base.sh:222`；调用点 `bin/clean.sh:2120`；sink `lib/core/file_ops.sh:1478`→`:1816`） |

### dev_tools-03

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| dev_tools-03 | OK | `paths`：GOCACHE/GOMODCACHE 由 `:1224`/`:1234` 经 `mole_go_cache_root`（`base.sh:291`，`go env` 解析）取得，`:1243-1248` 分别以 `-modcache`/`-cache` 清理；`~/go/pkg/mod` 非硬编码、是 GOMODCACHE 默认值，`$HOME/go` 及 `$HOME`、`Library`、`Caches`、`.cache` 在 `:1001-1006`/`base.sh:314-319` 被拒，即“根不可整体删”所指的 `~/go` 父根；GOMODCACHE 的 `pkg/mod` 叶根则由 `go clean -modcache` 整体移除（`:1080-1085` 注释、`:1243-1244`）。`match` 成立：`:995` 做 `cd -P` 物理化、两次 `validate_path_for_deletion`+`should_protect_path`、要求根属调用者 uid；`:981` 对 GOCACHE 直接放行、GOMODCACHE 用 `mole_pgrep_any -x go -x gopls`（rc=0 延后删除、>1 未知即停）；`:1022` 在 owner 命令前复检符号链接/进程/路径身份；“预算化”即 `:1070` `run_with_timeout`（`MOLE_TIMEOUT_PKG_CLEANUP_SEC`=20s，`timeouts.sh:65`）与 `:1188-1196` 超时跳过，无条数/体积上限。`source` 起 `:981` 为进程守卫函数头（非 `clean_go_cache_root` 的 `:1073`），区间含 5 个函数、止 `:1250` `}`，`:1251` 空行，无偏移（`dev.sh` 与 artifacts 字节相同）。`default_selected`＝`clean.sh:2120`→`:6281`→`:6287` 无条件，`_run_cleanup_step`（`:2022-2053`）无 y/n。`action:delete`＝`go clean -cache`/`-modcache` 删除（非 `safe_remove`），GOCACHE 清子目录、GOMODCACHE 删根。`needs_admin:false`（区间无 `sudo`；`:1013-1017` 反要求 uid 相符）。`risk:medium` 口径待定（需重下载/重建，非不可恢复）。`in_app:unknown` 与缺失 `in_app_evidence` 自洽。 | `lib/clean/dev.sh:981-1251`（无偏移；函数 `:981`/`:995`/`:1022`/`:1073`/`:1218`；调用点 `bin/clean.sh:2120`；解析 `lib/core/base.sh:291`；超时 `lib/core/timeouts.sh:65`） |

### dev_tools-04

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| dev_tools-04 | 不一致（`paths` 多列 `~/.cargo/git`；`in_app` 证据错引） | `paths` 实际只删 `${cargo_home}/registry/cache/*`（`:1431-1435` 唯一入参），`:1409` 注释「Keep … and git」与 `:1418`「Cargo 1.88+ owns … git dependencies」明确保留 git，规则却把它列为判定面；同函数 `:1440` 还删 `rustup/downloads/*` 未列入，故 registry/cache 对得上而整体不准确。`match` 成立：`rust_cache_root_physical_path`（`:1329-1345`，`cd -P` 且须落在 CARGO_HOME 内）、`rust_build_process_state`（`:1317-1325`，cargo/rustc/rustdoc/clippy-driver/cargo-nextest）、保留工具链 `check_rust_toolchains`（`:1501-1523`，仅 `check_multiple_versions`→`mole_review_row` 上报不删）。`source` 起 `:1317` 即函数头、无偏移，止 `:1442` 已是下一函数注释（`clean_dev_rust` 在 `:1419`，`}` 在 `:1441`）。`default_selected:true`＝`clean.sh:2120` 无条件 `_run_cleanup_step`（`:2022-2052`）→`dev.sh:6290`，无 y/n。`action:delete`＝`_dev_safe_clean_process_guarded`（`base.sh:2097`）→`safe_clean_guarded`（`clean.sh:1728`）→`safe_remove`（`file_ops.sh:1478`）→`:1816` 永久 `rm -rf`。`needs_admin:false`（区间无 `sudo`）。`risk:medium` 口径待定（可再生、需重下载）。`in_app:true` 不成立：`:237` 实为 `/usr/bin/codesign`，cargo 串在 `:614`，且命令串非 `~/.cargo/...` 同后缀路径。 | `lib/clean/dev.sh:1317-1442`（无偏移；`paths` `:1431`；保留 git `:1409`/`:1418`；rustup `:1440`；`clean_dev_rust` `:1419`；工具链 `:1501`；调用点 `bin/clean.sh:2120`、`dev.sh:6290`；sink `lib/core/file_ops.sh:1478`→`:1816`） |

### dev_tools-05

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| dev_tools-05 | 不一致（`in_app`） | `paths` 5 条按序逐字命中 `:1444-1447`、`:1453`，无漏项错项；`match` 成立：`:1451-1452` 注释明确 `~/.cpan/sources` 是安装源、保留不清，只删 `:1453` 的 build 树。`source:1443-1458` 起点即 `clean_dev_ruby` 函数头 `:1443`（无偏移），但尾越 4 行（`:1455` 空行 + `:1456-1458` 属下个函数 `_version_dirs_besides` 的注释），实际所需为 `:1443-1454`。`default_selected:true`＝`clean.sh:2120` `_run_cleanup_step`（`:2022`，`"$@"` 无 y/n）→`dev.sh:6281`→`:6247`（亦无 y/n）→`:6291`/`:6292`。`action:delete`＝`safe_clean`（`clean.sh:1720`）→`_safe_clean_impl`（`:1076`）→`safe_remove`（`file_ops.sh:1478`）→`:1816` 永久 `rm -rf`。`needs_admin:false`（区间无 `sudo`）；`risk:low` 口径待定（均可重建/重下载）；`protected_by:P-01` 自洽（`clean.sh:1160`）。`in_app:true` 不成立：证据 `p1a-strings.json:240` 实为 `/usr/bin/killall`，命令串，与 5 条 `paths` 无同后缀。 | `lib/clean/dev.sh:1443-1454`（起点无偏移；`paths` `:1444-1447`/`:1453`；`match` `:1451-1452`；调用点 `bin/clean.sh:2120`、`dev.sh:6247`/`:6291-6292`；sink `lib/core/file_ops.sh:1478`→`:1816`） |

### dev_tools-06

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| dev_tools-06 | 不一致（`match` 的进程判定；`in_app` 证据 2/3 不对应 `paths`；`source` 尾 +5） | `paths`②③ 逐字命中：`:1566` `$HOME/Library/Containers/com.docker.docker/Data`（`:1579` 白名单命中即返回），`:1525` `$HOME/Library/Group\ Containers/*dev.orbstack/data`。①「docker system prune 类」失准：实际仅 `:1634` `docker builder prune -f --filter until=168h` 与 `:1636` `docker image prune -f`，从不跑 `system prune`，`:1556-1558` 注明容器/卷/网络/tagged images 永不触碰。`match` 的「docker 进程判定」不存在：区间无 pgrep，`:1560-1561` 明言「no process guard is needed」；daemon 判定成立（`:1569` 要求 unix:// + `:1592` `docker info` 探活）。OrbStack 段只 `get_path_size_kb` 出建议行（`:1676-1690`，`left for manual prune`），从不进删除 sink，P-07 无显式调用；`safe_clean` 仅清 `:1692` buildx cache。`source` 起 `:1523` 即函数头无偏移，尾 `:1698` 越 5 行（`:1694-1698` 属 `clean_dev_nix` 注释），实际止 `:1693`。`default_selected`＝`clean.sh:2120`→`:6281`→`:6293`→`:1673`，全链无 y/n。`action:command` 成立；`needs_admin:false`（无 sudo）；`risk:high` 口径待定。`in_app:true` 仅 1/3：`:579` 与 `paths`② 同后缀，`:98-99`、`:152` 的 Caches 串在 `paths` 无对应条目。 | `lib/clean/dev.sh:1523-1693`（起点无偏移；尾 `:1694-1698` 越界；`paths` `:1525`/`:1566`；`match` `:1569`/`:1579`/`:1592`；`command` `:1634`/`:1636`；OrbStack `:1676-1690`；buildx `:1692`；调用 `bin/clean.sh:2120`→`dev.sh:6281`/`:6293`/`:1673`） |

### dev_tools-07

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| dev_tools-07 | OK | `paths` 唯一项逐字命中 `:1692` `safe_clean ~/.docker/buildx/cache/* "Docker BuildX cache"`，无漏错。`match:null` 自洽：该行无进程/daemon/白名单附加判定，仅描述串。`source:1692` 即该删除行，单行无偏移（`dev.sh` 与 artifacts 字节一致，269420 B）。`default_selected`＝`clean.sh:2120` `_run_cleanup_step`（`:2022-2053` 直接 `"$@"`）→`dev.sh:6281` `clean_developer_tools`→`:6293` `_run_developer_cleanup_step clean_dev_docker`→`:1672` 函数→`:1692`，全链无 y/n。`action:delete`＝`safe_clean`（`clean.sh:1720`）→`_safe_clean_impl`（`:1076`，先 `should_protect_path` `:1160`、`is_path_whitelisted` `:1168`）→`safe_remove`（`file_ops.sh:1478`）→`:1816` 永久 `rm -rf`；该路径不在默认/安全白名单（`base.sh:172-215`），仅 `whitelist.sh:159` 可选菜单行，默认不拦。`needs_admin:false`（`:1672-1693` 无 `sudo`）。`risk:low` 可再生（口径待定）；`protected_by:P-01` 与 `:1160` 一致。`in_app:unknown` 自洽：无 `in_app_evidence` 可对。 | `lib/clean/dev.sh:1692`（单行无偏移；调用 `bin/clean.sh:2120`→`dev.sh:6281`/`:6293`/`:1672`；sink `lib/core/file_ops.sh:1478`→`:1816`） |

### dev_tools-08

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| dev_tools-08 | OK | `paths` 5 条按序逐字命中 `:1706-1710`（`cache`/`tmp`/`logs` 子目录），`match` 成立；`:1705` 的 `clean_github_cli_cache` 已单列 dev_tools-21，不属本条。`source:1704-1712` 起点即 `clean_dev_cloud` 函数头，函数止 `:1711`，`:1712` 为下一节注释（尾多 1 行，属区间包含），无偏移。`default_selected`＝`clean.sh:2120` 无条件 `_run_cleanup_step`（`:2022-2053`，无 y/n）→`dev.sh:6281`→`:6294`。`action:delete`＝`safe_clean`（`clean.sh:1720`）→`_safe_clean_impl`（`:1076`）→`safe_remove`（`file_ops.sh:1478`→`:1816` 永久 `rm`）。`needs_admin:false`（`:1704-1711` 无 `sudo`，全在 `$HOME`）；`risk:low` 待定（仅缓存/日志）。`in_app:unknown` 自洽：无 `in_app_evidence`，p1a 亦无同后缀串。 | `lib/clean/dev.sh:1704-1711`（起点无偏移；尾多 1 行；调用 `bin/clean.sh:2120`→`dev.sh:6281`/`:6294`；sink `lib/core/file_ops.sh:1478`→`:1816`） |

### dev_tools-09

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| dev_tools-09 | 不一致（`in_app`） | `paths` 11 条按序逐字命中 `:1714-1724`（typescript/electron/node-gyp、`.node-gyp`、turbo、vite、`.cache/vite`、webpack、parcel、eslint、prettier），无漏错。`match` 的前端缓存面成立；其排除注脚落在本区间外——`:1712` 仅 `# Frontend build caches.`，m2 排除注释在 `:3277-3282`（JVM 段），yarn/berry 由 `app_protection.sh:416` 的 P-01 名单以代码保护，11 条与之无交集。`source` 起 `:1713` 即函数头无偏移，止 `:1725` `}`，`:1726` 为下一节注释（尾多 1 行属区间包含）。`default_selected`＝`clean.sh:2120` `_run_cleanup_step`（`:2022-2053` 直接 `"$@"`，无 y/n）→`dev.sh:6281`→`:6297`→`:1713`。`action:delete`＝`safe_clean`（`:1720`）→`_safe_clean_impl`→`safe_remove`（`file_ops.sh:1478`）→`:1816` 永久 `rm -rf`。`needs_admin:false`（区间无 `sudo`，全在 `$HOME`）。`risk:low` 口径待定。`in_app:true` 不成立：`:151` 为 `/Library/Caches/electron` 即 `~/Library/Caches/electron`，而 `paths`② 是 `~/.cache/electron/*`，同词非同路径；11 条无一在 `~/Library` 下。 | `lib/clean/dev.sh:1713-1726`（起点无偏移；尾 `:1726` 属下一节注释；`paths` `:1714-1724`；调用 `bin/clean.sh:2120`→`dev.sh:6281`/`:6297`；sink `lib/core/file_ops.sh:1478`→`:1816`） |

### dev_tools-10

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| dev_tools-10 | 不一致（`in_app` 证据后缀不同） | `paths` 唯一项逐字命中 `:3509` `safe_clean ~/Library/Logs/JetBrains/*`；`:3506-3507` 注释说明仅清可重建日志、不动会触发重建索引的 cache 子树，`match:null` 自洽（无附加判定）。`source` 起 `:3508` 即函数头无偏移，尾超界：函数止 `:3510`，`:3511-3521` 属下一目标（AI agent 版本清理）的注释与全局变量。`default_selected`＝`clean.sh:1883` `_run_cleanup_step`（`:1785`，无 y/n）→`dev.sh:6281`→`:6302`。`action:delete`＝`safe_clean`（`clean.sh:1483`）→`_safe_clean_impl`（`:849`）→`safe_remove`（`file_ops.sh:1478`）；`needs_admin:false`（区间无 sudo）；`risk:low` 口径待定。`in_app:true` 不成立：`p1a:64` 是 `/Library/Caches/JetBrains`（即 `~/Library/Caches/JetBrains`），后缀 Caches≠Logs；全文 JetBrains 串仅 `:64/:173/:175/:481`，无 Logs/JetBrains。`base.sh:182-185` 白名单只护 Caches 与 Application Support，未护 Logs，删除不被拦。 | `lib/clean/dev.sh:3508-3510`（`paths` `:3509`；尾 `:3511-3521` 超界；调用 `bin/clean.sh:1883`→`dev.sh:6281`/`:6302`；sink `bin/clean.sh:1483`→`lib/core/file_ops.sh:1478`） |

### dev_tools-11

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| dev_tools-11 | 不一致（`match` 的「数据库 CLI」） | `paths` 19 条逐字命中 `:4409`/`:4410`/`:4417-4418`/`:4426-4434`/`:6223-6224`/`:6228-6231`/`:6236`/`:6244`，无漏错。`match` 其余成立：Deno 根排除（`:4419-4421`，守卫 `user.sh:175-201`）、Prometheus WAL 注释 `:4428-4429`（实由 `app_protection.sh:414` 保护）、Haskell 无阶段 `:6238-6241`、`~/.mix/archives` 保留 `:6234`；但「数据库 CLI」不属本条——数据库/API 客户端缓存为 `:4437-4444`，已单列 dev_tools-30（`rules.json:1047-1057`）。`source` 两段起止皆函数边界（`:4408` 头 / `:4435` `}`，`:6220` 头 / `:6245` `}`），无偏移。`default_selected:true`＝`clean.sh:2120`→`dev.sh:6281`→`:6296`/`:6305`/`:6306`/`:6309`/`:6311-6312`，`_run_cleanup_step`（`:2022-2053` 直接 `"$@"`）无 y/n。`action:delete`＝`safe_clean`（`clean.sh:1720`）→`_safe_clean_impl`（`:1076`，`:1160`/`:1168`）→`safe_remove`（`file_ops.sh:1478`）→`:1816` 永久 `rm -rf`。`needs_admin:false`（两段无 `sudo`）；`risk:low` 口径待定（均为可再生缓存）。`in_app:true` 成立：`p1a:147` 的 `/Library/Caches/composer` 即 `paths`② 的主目录后缀；`p1a:68` 的 `/Library/Caches/Prisma` 在本条无对应条目。 | `lib/clean/dev.sh:4408-4435, 6220-6245`（两段均无偏移；`paths` `:4409`/`:4410`/`:4417-4418`/`:4426-4434`/`:6223-6224`/`:6228-6231`/`:6236`/`:6244`；数据库段 `:4437-4444` 属 dev_tools-30；调用 `bin/clean.sh:2120`→`dev.sh:6281`/`:6296`/`:6305-6306`/`:6309`/`:6311-6312`；sink `bin/clean.sh:1720`→`:1076`→`lib/core/file_ops.sh:1478`→`:1816`） |

### dev_tools-12

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| dev_tools-12 | 不一致（`in_app`；`paths`⑤ 偏宽） | `paths` 前六项逐字命中 `:3253`/`:3256-3257`/`:3263-3264`；⑤ `~/.expo/*` 偏宽——代码只清 `:3266-3272` 七个子目录，`:3265` 注明保留 `state.json`。`match` 成立：`:3254-3255` CocoaPods/Flutter 已注释，`:6299` 以 `--strict` 运行（`:6248-6276` 失败即返回）。`source` 起点即函数头 `:2994` 无偏移，尾 `:3275` 多 2 行（`:3274-3275` 属 `clean_dev_jvm` 注释）；`dev.sh` 与 artifacts 字节一致。`default_selected`＝`clean.sh:2120`→`dev.sh:6281`/`:6299`，无 y/n。`action:delete`＝`safe_clean`（`clean.sh:1720`）→`_safe_clean_impl`（`:1076`）→`safe_remove`（`file_ops.sh:1478`）→`:1816` 永久 `rm`。`needs_admin:false`（区间无 sudo）；`risk:medium` 口径待定。`in_app:true` 不成立：`p1a:344` DerivedData、`p1a:53` CocoaPods 均不在 `paths` 内（后者代码已注释）。 | `lib/clean/dev.sh:2994-3273`（起点无偏移；尾 `:3274-3275` 越界、属下一节注释；`paths` `:3253`/`:3256-3257`/`:3263-3264`/`:3266-3272`；`match` `:3254-3255`/`:6299`；调用 `bin/clean.sh:2120`→`dev.sh:6281`/`:6299`；sink `bin/clean.sh:1720`→`:1076`→`lib/core/file_ops.sh:1478`→`:1816`） |

### dev_tools-13

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| dev_tools-13 | OK | `paths` 唯一描述项成立：`:3286` 取 `$HOME/.gradle`，`:3303-3307` 仅列 `notifications`/`daemon`/`workers` 子项，`:3308-3313` 仅列 `caches/build-cache-*` 的子项，不触 `.gradle` 根与 `caches/modules-2` 等；`:3277-3282` 逐字点名 `~/.m2/repository`、`~/.ivy2/cache`、`~/.sbt/boot`、`~/.sbt/launchers` 为保留项，`:3283-3285` 说明 Maven 删除路径已移除。`match` 成立：`:3361` 调 `gradle_daemon_running`（`:450`→`base.sh:75` 三态 probe），0 运行→`:3363` defer、1→继续、其余→`:3394-3396` 跳过，三组删除边界 `:3370`/`:3379`/`:3388` 复检同一 probe。`source` 起 `:3276` 即函数头、无偏移；止 `:3399`，`:3400` 为下一函数注释（尾 +1 属区间包含）。`default_selected:true`＝`clean.sh:2120` `_run_cleanup_step`（`:2022` 直接 `"$@"`，无 y/n）→`dev.sh:6281`→`:6300`（`:6247` 包装亦无 y/n）。`action:delete`＝`_dev_safe_clean_process_guarded`（`base.sh:2097`）→`safe_clean_guarded`（`clean.sh:1728`）→`_safe_clean_impl`（`:1076`）→`safe_remove`（`file_ops.sh:1478`）→`:1816` 永久 `rm -rf`。`needs_admin:false`（区间无 `sudo`）。`risk:medium` 口径待定（仅缓存/守护进程/通知，可重建）；另 `base.sh:176-177` 默认白名单覆盖 `caches/*`、`daemon/*`，`:3343` 先行过滤，故默认仅清 notifications/workers。`in_app:true` 成立：`p1a-strings.json:555` 即 `~/.m2/repository`，与 `paths` 同后缀（对应其中明确排除项）。 | `lib/clean/dev.sh:3276-3399`（起点无偏移；尾 `:3400` 属下一函数注释；`paths` `:3286`/`:3303-3313`；保留注释 `:3277-3282`；`match` `:450`/`:3361`/`:3370`/`:3379`/`:3388`；白名单 `lib/core/base.sh:176-177`/`lib/core/app_protection.sh:685`；调用 `bin/clean.sh:2120`→`dev.sh:6281`/`:6300`；sink `lib/core/base.sh:2097`→`bin/clean.sh:1728`/`:1076`→`lib/core/file_ops.sh:1478`→`:1816`） |

### dev_tools-14

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| dev_tools-14 | 不一致（`match` 的「版本比对」；`in_app` 证据不同路径） | `paths` 唯一项成立：`:3402` 取 `$HOME/Library/Application Support/JetBrains/Toolbox/apps`，`:3432` 列产品目录、`:3500` 列 `ch-*` 通道，`:3496` 删其下旧版本目录。`match` 半成立：活动版本确被保留——`:3444-3455` 解析 `current` 符号链接、`:3465` 跳过其目标；但「版本比对」不存在，保留项由 `:3480-3482` 的 `stat -f%m` + `sort -rn` 按最近修改取 `MOLE_JETBRAINS_TOOLBOX_KEEP` 个（默认 1，`:3405`），不比较版本号。`source` 起点 `:3401` 即函数头、无偏移，尾超 3 行：函数止 `:3504`，`:3505` 空行、`:3506-3507` 属 `clean_dev_jetbrains_logs` 注释。`default_selected:true`＝`clean.sh:2120` 无条件 `_run_cleanup_step`（`:2022-2052` 直接 `"$@"`，无 y/n）→`dev.sh:6281`→`:6301`。`action:delete`＝`safe_clean`（`clean.sh:1720`）→`_safe_clean_impl`（`:1076`）→`safe_remove`（`file_ops.sh:1478`→`:1816` 永久 `rm -rf`）。`needs_admin:false`（区间无 `sudo`）。`risk:medium` 口径待定（旧 IDE 可重下载）。`protected_by:P-01` 仅通用闸门（`app_protection.sh:406`，无 JetBrains 项），`base.sh:185` 的白名单被 `:3416` 显式过滤。`in_app:true` 不成立：`p1a-strings.json:175` 是 `~/Library/Caches/com.jetbrains.toolbox`，与 `paths` 的 `Application Support/JetBrains/Toolbox/apps` 不同路径。 | `lib/clean/dev.sh:3401-3504`（起点无偏移；尾 `:3505-3507` 越界；`paths` `:3402`/`:3432`/`:3500`；保留 `:3444-3455`/`:3465`/`:3405`；排序 `:3480-3482`；调用 `bin/clean.sh:2120`→`dev.sh:6281`/`:6301`；sink `bin/clean.sh:1720`/`:1076`→`lib/core/file_ops.sh:1478`→`:1816`） |

### dev_tools-15

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| dev_tools-15 | OK | `paths` 判定面成立：`:4273` 函数即 `clean_dev_automation_browsers`，profile 实为 `$DARWIN_USER_TEMP_DIR/playwright_chromiumdev_profile-*`（`:4293` `getconf`、`:4297` glob），不触 `~/Library/Caches/ms-playwright`；`paths` 用描述式、未给具体 glob，建议补。`match` 三条成立：残留进程＝`:4244` ppid=1 + `:4246` etime ≥1h + `:4251` 命令行匹配；陈旧 profile＝`:4300` ≥2h 且 `:4302-4303` `pgrep` 无引用（rc≠1 视为未知即保留）；N-12 由 `app_protection.sh:603-606` 覆盖 ms-playwright/camoufox/Cypress/puppeteer。`source` 起 `:4238` 为 helper（主函数 `:4273`），止 `:4357` `}`、`:4358` 空行，无偏移。`default_selected:true`＝`clean.sh:2120` `_run_cleanup_step`（`:2022-2053` 直接 `"$@"`，无 y/n）→`dev.sh:6281`→`:6304`（`:6247-6278` 包装亦无 y/n）。`action:delete`＝profile 经 `:4354` `safe_clean` 永久删（`file_ops.sh:1478`→`:1816` `rm -rf`），进程 `:4326` TERM 后 `:4344` `kill -9`（与 `command` 字段一致）。`needs_admin:false`（区间无 `sudo`）；`risk:medium` 口径待定（ppid+命令行双重身份绑定压住误杀）。`in_app:true` 成立：`p1a:176` `~/Library/Caches/ms-playwright` 与 `paths[0]` 同 id 同后缀，`p1a:174` camoufox 在 `paths` 无对应项（1/2）。 | `lib/clean/dev.sh:4238-4357`（起点 helper、主函数 `:4273`；尾 `:4358` 空行；`paths` `:4251`/`:4293`/`:4297`；`match` `:4244`/`:4246`/`:4300`/`:4302-4303`；`command` `:4326`/`:4344`；删除 `:4354`；调用 `bin/clean.sh:2120`→`dev.sh:6281`/`:6304`；sink `lib/core/file_ops.sh:1478`→`:1816`） |

### dev_tools-16

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| dev_tools-16 | OK | `paths` 14 条逐条命中：`:6129-6135` 七条 `~/Library/Caches/*`（Unity/MongoDB Compass/Figma/GitHub Desktop/SentryCrash/KSCrash/crashlytics）、:6136-6142` Antigravity 5 项、`:6148-6154` Filo/production 5 项、`:6156-6163` Claude 5 项+sentry、`:6165-6174` Qoder 7 项（含 CachedData、CachedExtensionVSIXs、logs）、`:6176` prisma、`:6178` opencode、`:6217` com.wondershare.Installer，无漏错。`match` 成立：4 组 Electron 目录各有 `-d` 存在性门控，`mole_safe_clean_app_cache`（`base.sh:2126-2134`）→`_dev_safe_clean_process_guarded`→`_mole_named_app_cache_running`（`base.sh:2038-2041`，`pgrep -x` 或 `/<App>.app/`），运行/未知即跳过。`source:6128-6218` 起即 `clean_dev_misc` 函数头、止 `}`，无偏移；区间内还夹 `:6144-6146`/`:6184-6215` 的 `~/.gemini`、agent-browser、Codex 等调用，属它条（复刻勿整段照搬）。`default_selected:true`＝`clean.sh:2120` 无条件 `_run_cleanup_step`（`:2022-2036` 直接 `"$@"`）→`dev.sh:6281`→`:6310`。`action:delete`＝`safe_clean`→`file_ops.sh:1478`→`:1816` 永久 `rm -rf`。`needs_admin:false`（区间无 `sudo`）。`risk:low` 口径待定（纯缓存/崩溃报告，Qoder `logs`、Claude `sentry`、Wondershare 安装器载荷可再生）。`in_app:true` 成立：`p1a-strings.json:65` KSCrash、`:95` com.crashlytics.data 与 `paths`⑥⑦ 同 id 同后缀；`:68` 为 `/Library/Caches/Prisma`（与 `~/.cache/prisma` 根不同）、`:125` 为 plausiblelabs 无对应项。 | `lib/clean/dev.sh:6128-6218`（无偏移；`paths` `:6129-6135`/`:6136-6142`/`:6148-6154`/`:6156-6163`/`:6165-6174`/`:6176`/`:6178`/`:6217`；守卫 `lib/core/base.sh:2126-2134`/`:2038-2041`；调用 `bin/clean.sh:2120`→`dev.sh:6281`/`:6310`；sink `lib/core/file_ops.sh:1478`→`:1816`） |

### dev_tools-17

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| dev_tools-17 | 不一致（`in_app` 证据不同路径） | `paths` 唯一项逐字命中 `:6202`（`:6200` 先 `-d` 门控），无漏错。`match` 成立：`safe_find_delete`（`file_ops.sh:3477`）固定 `-maxdepth 5 -name -type f`（`:3507`），年龄用 `-mtime +$MOLE_LOG_AGE_DAYS`（`:3508-3510`；只读 7 天，`base.sh:159`）。`source:6199-6205` 起点即注释、无偏移；外层 `fi` 在 `:6206`，尾少 1 行属区间包含。`default_selected`＝`clean.sh:2120`→`dev.sh:6281`→`:6310`→`:6128`，`_run_cleanup_step`（`clean.sh:2022`）与 `_run_developer_cleanup_step`（`dev.sh:6247`）均直接 `"$@"`，无 y/n。`action:delete`＝逐项过 `should_protect_path`/`is_path_whitelisted`（`file_ops.sh:3533`/`:3536`）后 `safe_remove`（`:3558`）永久 `rm -rf`（`:1816`/`:1818`），非废纸篓。`needs_admin:false`（区间无 `sudo`，全在 `$HOME`）。`risk:low` 口径待定（仅 7 天前 `.log`，永久删但可再生）。`in_app:true` 不成立：`p1a-strings.json:96` 为 `~/Library/Caches/com.cursor.Cursor`、`:148` 为 `~/Library/Caches/cursor-compile-cache`，与 `paths` 的 `~/.local/share/cursor-agent/*.log` 后缀不同；`:416` 是 `~/bin/cursor-agent` 可执行文件。 | `lib/clean/dev.sh:6199-6206`（起点无偏移；尾 `:6206` 为外层 `fi`；`paths` `:6200`/`:6202`；深度/类型 `lib/core/file_ops.sh:3507`、`-mtime` `:3508-3510`；调用 `bin/clean.sh:2120`→`dev.sh:6281`/`:6310`；sink `lib/core/file_ops.sh:1478`→`:3558`→`:1816`） |

### dev_tools-18

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| dev_tools-18 | 不一致（`action`） | `paths` 四条逐字命中 `app_protection.sh:603-606`（命名目录与 `/*` 变体都在），前三条另在 `base.sh:173-175` 默认白名单；`match`「永不删除（N-12）」成立（`protect.json:231` N-12 恰为这四条；`should_protect_path` 在扫描 `clean.sh:1160` 与 sink `file_ops.sh:1375` 双闸，无旁路）。`source:6207-6210` 即四行注释原文，`dev.sh` 与 artifacts 字节一致，无偏移；`:6211-6212` 属下一目标。`action:"delete"` 与代码矛盾：该区间无 `safe_clean`/`rm`，只登记保护，应改 `protect`（同 trash-02）。`default_selected:false`、`needs_admin:false` 成立；`risk:low` 口径待定。`in_app:true` 成立：`p1a:172/174/176/549` 与四条逐字相同。 | `lib/clean/dev.sh:6207-6210`（无偏移；`paths` `lib/core/app_protection.sh:603-606`、`lib/core/base.sh:173-175`；`match` `bin/clean.sh:1160`/`lib/core/file_ops.sh:1375`） |

### dev_tools-19

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| dev_tools-19 | 不一致（`match` 的校验归属） | `paths` 唯一项逐字命中 `:162`（`${COREPACK_HOME:-$HOME/.cache/node/corepack}`），删除面在根之下（`:179` 为 `$corepack_home/*`；corepack 存在时交 `corepack cache clean`），根保留。`match` 的「拒绝 /、$HOME、$HOME/Library」成立，但由 `:164-168` 的内联 `case` 实现，不是 `owner_cache_root_is_safe`；后者（`:8-26`）走 `validate_path_for_deletion`+白名单+物理路径解析，对 `$HOME/Library` 不拦（`file_ops.sh:1044` 只拒 `/` 与单层 `/Users/<name>`），且仅经 `:177`→`clean_tool_cache:75` 在 corepack 存在分支间接调用。`source` 起 `:161` 函数头无偏移，止 `:182` 为空行（函数实止 `:181`）。`default_selected:true`＝`clean.sh:2120`→`dev.sh:6281`→`:6285`→`:663`→`:714`，两处 step 包装（`clean.sh:2022`、`dev.sh:6247`）均直接 `"$@"`，无 y/n。`action:delete` 成立：`:177` owner 命令或 `:179` `safe_clean`→`file_ops.sh:1478`→`:1816` 永久 `rm`；`needs_admin:false`（区间无 sudo）；`risk:low` 口径待定（缓存可重下）。`in_app:unknown` 自洽：无 `in_app_evidence`，p1a 亦无 corepack 串。 | `lib/clean/dev.sh:161-182`（起点无偏移；尾 `:182` 空行；`paths` `:162`；`match` `:164-168`；helper `:8-26`/`:75`；调用 `bin/clean.sh:2120`→`dev.sh:6281`/`:6285`/`:663`/`:714`；sink `lib/core/file_ops.sh:1478`→`:1816`） |

### dev_tools-20

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| dev_tools-20 | OK | `paths` 唯一项即 `:205` 的默认根；uv 可解析时 `:213` 改用 `uv cache dir` 结果，该字面量只是兜底，建议按实测根补注。`match` 成立：进程门 `uv_process_state`（`:183-185`，`mole_pgrep_any -x uv -x uvx`）经 `:220`→`:194` 进 `base.sh:2020` `mole_clean_process_guard`，仅 rc=1（无进程）放行，运行/未知均保留；根安全在 uv 存在分支由 `clean_tool_cache`（`:216`→`:51`）的 `:75` `owner_cache_root_is_safe` 校验，uv 缺失分支只用 `:205` 固定根加 `safe_clean` 逐子项保护。`source:183-223` 起点无偏移，尾 `:223` 为空行（函数实止 `:222`），区间另夹 `:187-190` `bun_process_state` 与 `:192-202` 共用 helper，属它条。`default_selected:true`＝`clean.sh:2120`→`dev.sh:6281`→`:6286`→`:946`/`:967`，`clean.sh:2022` 与 `dev.sh:6247` 两处 step 包装均直接 `"$@"`、无 y/n。`action:delete` 成立但分支不同：uv 存在跑 `uv cache prune`（`:216`），uv 缺失才 `safe_clean` glob 删内容、根保留（`:220`→`file_ops.sh:1478`→`:1816` 永久 rm）。`needs_admin:false`（区间无 sudo）；`risk:low` 口径待定（缓存可重下）。`in_app:unknown` 自洽：无 `in_app_evidence`，p1a 无 uv 串（`:548-553` 为 huggingface 等）。 | `lib/clean/dev.sh:183-223`（起点 helper 无偏移；主函数 `:204`；尾 `:223` 空行；`paths` `:205`/`:213`；`match` `:183-185`/`:212`/`:216`/`:220`；helper `:194-202`；进程门 `lib/core/base.sh:2020`；根校验 `dev.sh:75`；调用 `bin/clean.sh:2120`→`dev.sh:6281`/`:6286`/`:946`/`:967`；sink `lib/core/file_ops.sh:1478`→`:1816`/`:1818`） |

### dev_tools-22

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| dev_tools-22 | OK | `paths` 5 条按序逐字命中 `:394-398`，即 `clean_conda_metadata_caches`（`:392`）的默认 `conda_pkg_roots`，无漏错。`match` 成立：`:400`/`:431` 调 `conda_cache_whitelisted`（`:381-390`，任一根本身或 `/.mole-cache-guard` 命中 `is_path_whitelisted` 即整体 skip）；删除面仅 pkgs_dirs，`:438-439` 只跑 `conda clean --yes --index-cache --tarballs --logfiles`，从不触 envs（`envs` 仅见 `:959`/`:964` 的 Poetry 注释）。补充：conda 可用时 `:414-430` 以 `conda info --json` 的 `pkgs_dirs` 替换默认五根（自定义 pkgs 目录同清，`paths` 仅默认根）；conda 缺失走 `:444-447` 仅 `debug_log`，不删除。`source:381-449` 起于 `conda_cache_whitelisted` 函数头、止于 `:449` 空行（主函数止 `:448`），`dev.sh` 与 artifacts `cmp` 字节相同（6331 行），无偏移。`default_selected:true`＝`clean.sh:2120` `_run_cleanup_step`（`:2022`，`:2036` 直接 `"$@"`）→`dev.sh:6281`→`:6286` `clean_dev_python`→`:978`，两处 step 包装均无 y/n。`action:delete`＝`conda clean` 删除缓存（非 `safe_remove`/废纸篓），`owner_cache_root_is_safe`（`:8-26`）在 `:432-437` 逐根校验。`needs_admin:false`（区间无 `sudo`）。`risk:medium` 口径待定（tarball/index/log 可再生，需重下载）。`in_app:unknown` 自洽：无 `in_app_evidence`，p1a 全文无 conda/miniforge/anaconda 串。 | `lib/clean/dev.sh:381-449`（无偏移；`paths` `:394-398`；主函数 `:392`；`match` `:381-390`/`:400`/`:431`；`command` `:438-439`；校验 `:8-26`/`:432-437`；调用 `bin/clean.sh:2120`→`dev.sh:6281`/`:6286`/`:978`） |

### dev_tools-23

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| dev_tools-23 | OK | `paths` 成立：`PNPM_HOME`/`$HOME/Library/pnpm` 为二进制查找目录（`:512-514`），`$HOME/Library/pnpm/store` 是默认 store 字面量（`:543`，仅 `:562` 无二进制时提示用），真实根由 `pnpm store path`（`:578-579`）取得并经 `is_safe_pnpm_store_path`（`:479-488`，要求绝对路径、拒 `..` 与控制符）校验。`match` 成立：`pnpm_process_blocks_prune`（`:459-475`，rc≠1 含状态未知一律阻断）在 `:545` 门控；无二进制 `:561-563`、不可用二进制 `:571-575`、同 store 去重 `:588-598` 均跳过。`source:459-613` 起点无偏移（`dev.sh` 与 artifacts 字节相同），尾 `:611-613` 为空行+下一函数注释，`clean_pnpm_stores` 实止 `:610`。`default_selected:true`＝`clean.sh:2120`→`dev.sh:6281`→`:6285`→`clean_dev_npm`（`:663`）→`:710`，`_run_cleanup_step`（`clean.sh:2036`）与 `_run_developer_cleanup_step`（`dev.sh:6264`）均直接 `"$@"`，无 y/n。`action:delete` 成立：`:601-603` 经 `clean_tool_cache`（`:61` 白名单、`:75` 根校验）跑 owner 命令 `pnpm store prune`，非 `rm`。`needs_admin:false`（`:459-613` 无 `sudo`）；`risk:medium` 口径待定（只删未被引用包，可重下）。`in_app:unknown` 自洽：无 `in_app_evidence`，`p1a:159` 的 `/Library/Caches/pnpm` 后缀为 `Caches/pnpm`（已归 dev_tools-01），与 `pnpm/store` 不同。 | `lib/clean/dev.sh:459-613`（`paths` `:512-514`/`:543`/`:578-588`；`match` `:459-475`/`:545`/`:561-575`；`command` `:601-603`；调用 `bin/clean.sh:2120`→`dev.sh:6281`/`:6285`/`:663`/`:710`；无偏移） |

### dev_tools-24

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| dev_tools-24 | OK | `paths` 逐字命中 `:621` 的 `bun_default_cache="$HOME/.bun/install/cache"`；实际删除面是该根 `/*` 或 `bun pm cache` 解析出的配置根（`:629`），根自身保留，rules 已注明 `bun_default_cache`，可接受。`match` 成立：`bun_process_state`（`:187-190`，`mole_pgrep_any -x bun -x bunx`）经 `:641` 门控（运行/未知即 `:642` 延后），`:616` 在命令边界再复检；`:640` 白名单命中时跳过进程守卫，但 `clean_tool_cache:61` 会按白名单 skip，净效果仍不删。`source:614-662` 起于 helper `_bun_pm_cache_rm`（主函数 `clean_bun_cache` `:620-661`），尾 `:662` 为空行，属区间包含；`dev.sh` 与 artifacts `cmp` 字节相同（6331 行），无偏移。`default_selected:true`＝`clean.sh:2120`→`dev.sh:6281`→`:6285` `clean_dev_npm`→`:715`，`clean.sh:2036` 与 `dev.sh:6264` 两处 step 包装均直接 `"$@"`，无 y/n。`action:delete` 成立：bun 可用走 `:645` owner 命令 `bun pm cache rm`（经 `clean_tool_cache:75` 根校验），不可用/查不到根则 `:623`/`:657` 走 `safe_clean` 删子项（`file_ops.sh:1478`→`:1816` 永久 `rm -rf`）。`needs_admin:false`（区间无 `sudo`）。`risk:low` 口径待定（可重下载）。`in_app:unknown` 自洽：无 `in_app_evidence`，p1a 无 `.bun` 后缀串。 | `lib/clean/dev.sh:614-662`（起点 helper `:614`、主函数 `:620-661`、尾 `:662` 空行；`paths` `:621`；`match` `:187-190`/`:616`/`:641`；命令 `:645`；缺失分支 `:623`/`:657`；调用 `bin/clean.sh:2120`→`dev.sh:6281`/`:6285`/`:715`；sink `lib/core/file_ops.sh:1478`→`:1816`） |

### dev_tools-25

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| dev_tools-25 | 不一致（`match`/`paths` 归属 + `in_app` 证据） | `paths` 首项逐字命中 `:664`（`npm_default_cache`），实际删除面是 `_cacache`/`_logs`/`_prebuilds` 子项（`:684`；`:690`/`:706` `safe_clean`）和配置根上的 `npm cache clean --force`（`:675`）；第二项「受守卫的 dev cache 根」在 npm 路径不存在。`match` 不成立：`clean_dev_npm`（`:663-724`）没有任何 npm 进程守卫，也未调用 `guarded_dev_cache_cleanup_state`/`guarded_dev_cache_root_physical_path`；这组 helper（`:728-809`、`:812-873`）只被 `:895` PyInstaller 与 `:936` Clang 调用，属 dev_tools-26，`source` 第二段误挂。`default_selected:true` 成立（`clean.sh:2120`→`dev.sh:6281`→`:6285`，`:6264` 直接 `"$@"` 无 y/n）；`action:delete` 成立（owner 命令 + `safe_clean`→`file_ops.sh:1478`→`:1816` 永久 rm）；`needs_admin:false`；`risk:medium` 口径待定。`in_app:true` 不成立：`p1a-strings.json:639` 是裸串 `npm`（命令名），非路径，与 `~/.npm` 不同后缀。 | `lib/clean/dev.sh:663-724`（`clean_dev_npm`，起点无偏移、函数实止 `:724`；`paths` `:664`/`:684`；`command` `:675`；`safe_clean` `:690`/`:706`；helper `:728-873` 实为 dev_tools-26；调用 `bin/clean.sh:2120`→`dev.sh:6281`/`:6285`；sink `lib/core/file_ops.sh:1478`→`:1816`） |

### dev_tools-27

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| dev_tools-27 | 不一致（`paths`/`match` 误挂 `resolve_tool_home`；`match`「仅 Caches 下」不成立；`source` 尾越 24 行） | `paths` 首项成立但 `~/Library/Caches/mise` 只是兜底：`get_mise_cache_path`（`:1252-1268`）先取 `MISE_CACHE_DIR`（`:1253-1255`），有 mise 时取 `mise cache path`（`:1260`），仅 mise 缺失才 `echo "$HOME/Library/Caches/mise"`（`:1267`）。`paths` 的「`resolve_tool_home` 判定面」误挂：该 helper 定义于 `:1298-1313`，只被 cargo/rustup 调用（`:1421-1422`、`:1505`），mise 路径不经它。`match`「仅 Caches 下的 mise 根」亦不成立——前两分支可指向任意绝对路径，`clean_tool_cache:75` 只做 `validate_path_for_deletion`+白名单，不限 Caches；「解析失败即跳过」成立（`:1272-1274` 失败 `return 0`）。`source` 起 `:1252` 无偏移（`dev.sh` 与 artifacts 字节相同），尾 `:1316` 越 24 行：`clean_dev_mise` 实止 `:1292`，`:1293-1316` 属 `resolve_tool_home` 及其注释。`default_selected:true` 成立（`clean.sh:2120`→`dev.sh:6281`→`:6288`，`clean.sh:2036`/`dev.sh:6264` 直接 `"$@"`，无 y/n）。`action:delete` 成立：有 mise 走 `:1278` `clean_tool_cache` 的 `mise cache clear`；无 mise 走 `:1291` `safe_clean "$mise_cache_path"/*`→`file_ops.sh:1478`→`:1816` 永久 rm（根保留）。`needs_admin:false`（区间无 `sudo`）；`risk:low` 口径待定（可重建）。`in_app:unknown` 自洽：无 `in_app_evidence`，p1a 全文无 mise 串。 | `lib/clean/dev.sh:1252-1292`（起点无偏移；尾 `:1293-1316` 越界、含 `resolve_tool_home` `:1298-1313`；`paths` `:1253-1255`/`:1260`/`:1267`；`match` `:1262`/`:1272-1274`；`action` `:1278`/`:1291`；调用 `bin/clean.sh:2120`→`dev.sh:6281`/`:6288`；sink `lib/core/file_ops.sh:1478`→`:1816`；`resolve_tool_home` 实用于 `:1421-1422`/`:1505`） |

### dev_tools-28

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| dev_tools-28 | 不一致（`action` 与代码相反；`match` 运行态门不存在；`in_app` 证据不同路径） | `paths` 命中 `:1525` glob（`:1526` `-d` 门控，只取首个）；`source` 起点 `:1523` 无偏移，但函数实止 `:1531`，`:1532-1535` 属下一 helper 的空行+注释（尾越 4 行）。`action:"delete"` 不成立：`clean_dev_docker`（`:1672`）在 `:1676` 取路径、`:1679` 算体积后，仅于 `:1687-1690` 用 `ICON_REVIEW` 打印提示行，注释明写「The row is advisory and never deletes」「left for manual prune」，区间无 `safe_clean`/`rm`/`safe_remove`。`match` 的「可定位」成立，「非活动运行镜像」无任何运行态检查；P-07 `is_orbstack_runtime_path`（`app_protection.sh:301-319`，经 `should_protect_path:450`）确会保护 `*dev.orbstack` 与 `~/.orbstack`，但因不删故非门控。`default_selected:true` 仅对应默认打印该提示（`clean.sh:2120`→`dev.sh:6281`→`:6293`，`clean.sh:2036`/`dev.sh:6264` 直接 `"$@"`，无 y/n），不产生删除。`needs_admin:false`（区间无 `sudo`）；`risk:high` 口径待定。`in_app:true` 不成立：`p1a:152` 为 `/Library/Caches/io.orbstack`，id 与后缀均不同（`io.orbstack` vs `dev.orbstack`；`Caches/...` vs `Group Containers/*/data`）。 | `lib/clean/dev.sh:1523-1531`（`paths` `:1525-1526`；`source` 尾 `:1532-1535` 越界；advisory `:1672-1697`，其中 `:1676`/`:1679`/`:1687-1690`；保护 `lib/core/app_protection.sh:301-319`/`:450`；调用 `bin/clean.sh:2120`→`dev.sh:6281`/`:6293`） |

### dev_tools-29

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| dev_tools-29 | OK | `paths` 为判定面描述，实际唯一字面路径是 `:1701` 的 `/nix/store`（仅作 `clean_tool_cache` 的 cache_path 做白名单/根校验，不直接 `rm`）；删除由同行 `nix-store --gc` 执行，只清未被 GC root 引用的 store paths，profile/generation 保留（`:1694-1698`）。`match:null` 不矛盾，但未记 `:1700` 的 `command -v nix-store` 门、`:61`/`:75` 白名单与 `owner_cache_root_is_safe`、`:1701` 的 20s 超时（`timeouts.sh:65`）。`source` 起 `:1699` 即函数头、无偏移（`dev.sh` 与 artifacts 字节相同），函数止 `:1702`，尾 `:1703` 为下一节注释（尾多 1 行属区间包含）。`default_selected`＝`clean.sh:2120`→`dev.sh:6281`→`:6295`，无 y/n；`action:delete` 成立（owner 命令）；`needs_admin:false` 与无 `sudo` 一致；`risk:medium` 口径待定；`in_app:unknown` 自洽（无 `in_app_evidence`，p1a 无 nix 路径）。 | `lib/clean/dev.sh:1699-1702`（起点无偏移；尾 `:1703` 越 1 行注释；`paths`/`command` `:1701`；门 `:1700`；helper `:51`/`:61`/`:75`；timeout `lib/core/timeouts.sh:65`、`lib/core/timeout.sh:206`；调用 `bin/clean.sh:2120`→`dev.sh:6281`/`:6295`） |

### dev_tools-21

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| dev_tools-21 | 不一致（`paths` 是判定面描述、非路径，缺默认 `~/.cache/gh`；`in_app` 自洽） | `paths` 唯一项写的是「判定根」而非路径；实际目标为 `$cache_root/gh`（`dev.sh:268`），`cache_root` = `XDG_CACHE_HOME` 或 `$HOME/.cache`（`base.sh:238`/`:244`），默认即 `~/.cache/gh`，未列。`match` 成立：`:321` `command -v gh` 门、`:323` `mole_clean_process_guard github_cli_process_state`（`:224-226`，`mole_pgrep_any -x gh`；仅 rc=1 无进程放行，运行/未知均拦）、`:236` 二次复检；「有界」＝`:329` 探测与 `:253` 清理均 `run_with_timeout "$MOLE_TIMEOUT_PKG_CLEANUP_SEC"`；真实清除由 `gh config clear-cache`（`:254`，`XDG_CACHE_HOME=$physical_parent`）完成，不走 mole `rm`。`source` 起点 `:224` 即 `github_cli_process_state` 函数头、`:379` 收 `}`、`:380` 空行，`dev.sh` 与 artifacts `cmp` 字节相同（6331 行），无偏移。`default_selected:true` 成立（`clean.sh:2120` 无条件 → `dev.sh:6281` → `:6294` → `:1705`；`clean.sh:2022-2053` 直接 `"$@"`，无 y/n）。`action:delete` 成立（owner 命令清除，同 `tart prune`/`nix-store --gc` 口径）；`needs_admin:false`（`:224-380` 无 `sudo`，全在用户域）；`risk:low` 待定（gh 缓存可重建）。`in_app:unknown` 自洽：本条无 `in_app_evidence`，p1a 亦无 `gh` 路径串。 | `lib/clean/dev.sh:224-380`（起点即 `github_cli_process_state` 函数头，无偏移；`_run_github_cli_clear_cache_bound:228-259`；`clean_github_cli_cache:261-379`；`paths` 实为 `:268` 的 `$cache_root/gh`；进程门 `:323`；有界 `:253-254`/`:329`；调用 `bin/clean.sh:2120`→`dev.sh:6281`/`:6294`→`:1705`） |

### dev_tools-26

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| dev_tools-26 | 不一致（`paths[1]` 把 __pycache__ 并进 clang 模块缓存；`in_app` 自洽） | 两条 `paths` 均为判定面描述（先例 user_cache-11 可接受）：PyInstaller 根实为 `$HOME/Library/Application Support/pyinstaller`（`dev.sh:882-883`），只收 `bincache*` 非链接子项（`:888-891`），经 `clean_guarded_dev_cache_root`（`:812-871`，守卫回调 `guarded_dev_cache_cleanup_state:766`）删除；clang 根为 `$(mole_darwin_user_cache_root)/clang`（`:919`/`:925`，`base.sh:264-286`），收全部一级项含点文件（`:928`）。但 `clean_clang_module_cache` 不含任何 __pycache__ 逻辑，Python 字节码缓存属 `caches.sh:909 clean_python_bytecode_cache_group`（rules.json 另有条目），`paths[1]` 把两者混为一条。`match` 成立：pyinstaller 守卫 `:895-896`→`pyinstaller_build_process_state:874-879`（`-x pyinstaller`、`[p]yinstaller`/`[P]yInstaller`）；clang 守卫 `:936-939`→`clang_module_cache_process_state:904-914`（先 `xcode_build_tooling_process_state`，仅 rc=1 放行，再 `-x clang/clangd/swiftc/sourcekit-lsp/SourceKitService`）。`source` 起点 `:874` 即函数头、无偏移，`:943` 收 `}`，`:945` 已是 `# Python/pip ecosystem caches.` 注释（尾多 1 行，属区间包含）。`default_selected:true`（`clean.sh:2120` 无条件 → `dev.sh:6281` → `:6286 clean_dev_python`（`:971` 调用）/`:6305 clean_dev_other_langs`（`:4422` 调用），`_run_cleanup_step` 无 y/n）。`action:delete`（`safe_clean`→`safe_remove`→`file_ops.sh:1816` 永久 rm；`dev.sh` 与 artifacts 字节相同，6331 行）。`needs_admin:false`（`:874-943` 无 `sudo`，PyInstaller 在 `$HOME` 下、clang 在用户 DARWIN_USER_CACHE_DIR）。`risk:low` 口径待定。`in_app:unknown` 自洽：无 `in_app_evidence`，p1a 亦无 pyinstaller/clang 路径串，无可比同路径。 | `lib/clean/dev.sh:874-943`（起点即函数头，无偏移；`pyinstaller_build_process_state:874-879`、`clean_pyinstaller_bincache:881-902`、`clang_module_cache_process_state:904-914`、`clean_clang_module_cache:916-943`；`:945` 为下一节注释，尾多 1 行；删根 helper `:766`/`:812-871`；调用 `bin/clean.sh:2120`→`dev.sh:6281`/`:6286`/`:6305`） |

### dev_tools-30

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| dev_tools-30 | 不一致（`in_app`） | `paths` 12 条与 `:4438-4443`（database 段 6 条）、`:4447-4452`（api_tools 段 6 条）逐条同序逐字命中，无漏错；`com.navicat.*`/`com.dbeaver.*`/`com.redis.RedisInsight` 无 `/*`（取目录本身）亦与规则一致。`match` 成立：两段只有 `safe_clean`，无 pgrep/进程判定，与「无进程守卫」相符；`:4436`/`:4445` 注释分别点名 `Database tool caches` 与 `API/debugging tool caches`（调试工具，非 API 客户端）；`protected_by:P-01` 仅是 `clean.sh:1160`/`file_ops.sh:1375` 的通用闸门（`app_protection.sh:246` 只护 `com.getpostman.*`、`com.insomnia.*` 数据目录，与本条 id 不同）。`source` 起点 `:4437` 即 `clean_dev_database` 函数头、无偏移；区间跨两个函数（`:4444` `}`、`:4446` 头、`:4453` `}`），尾 `:4454` 为空行，实际范围 `:4437-4453`。`default_selected:true`＝`clean.sh:2120`→`dev.sh:6281`→`:6307`/`:6308`，`_run_developer_cleanup_step`（`:6247`）在 `:6264` 直接 `"$@"`，无 y/n。`action:delete`＝`safe_clean`（`clean.sh:1720`）→`_safe_clean_impl`（`:1076`，`:1160`/`:1168` 双闸）→`safe_remove`（`file_ops.sh:1478`）→`:1816` 永久 `rm -rf`；`needs_admin:false`（两段无 `sudo`，全在 `$HOME/Library/Caches`）；`risk:low` 口径待定（均为可再生缓存，且 `base.sh:172-189` 默认白名单未覆盖这些 id，默认即会删）。**`in_app:true` 不成立**：`:481` 为 `/Library/Preferences/jetbrains.ws.*.plist`、`:479` 为 `/Library/Preferences/com.sqlitebrowser.sqlitebrowser.plist`，虽可按 `~/Library/...` 后缀看待，但 id（jetbrains.ws / sqlitebrowser）与全部 12 条 `paths` 无一相同，后缀也是 `Preferences` 而非 `Caches`，不构成同 id 同后缀支持。 | `engine/lib/clean/dev.sh:4437-4453`（`paths` `:4438-4443`/`:4447-4452`；调用 `bin/clean.sh:2120`→`dev.sh:6281`/`:6307-6308`；sink `bin/clean.sh:1720`/`:1076`→`lib/core/file_ops.sh:1478`→`:1816`）；`report/p1a-strings.json:479,481` |

<!-- dev_tools 追加点 -->

## category: ai_tools（20 条）

### ai_tools-01

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| ai_tools-01 | 不一致（`in_app` 证据不同路径；`match` 漏「无符号链接」分支） | `paths` 逐字命中 `:4364`；`source` 三段行号全对：主函数 `:4359-4405`、specs `:4363-4367`、guard `:3727-3822`（`:3823` 空行）、plan `:3558-3652`（`:3653` 空行），`dev.sh` 与 artifacts `cmp` 字节相同（6331 行），无偏移。`match`：默认 1（`:4360-4361`）、活动版本解析（`:4379-4381`）、plan 超时/未知保留（`:3840-3848`，代码串为 `inventory unknown`，rules 多一个下划线）均成立；但「解析失败或链接断裂即整族保留」仅在 `-L` 为真时成立——`~/.local/bin/claude` 根本不存在时 `:4379` 整段跳过，`active_path` 为空、`ACTIVE_REQUIRED=false`（`:3853-3854`），仍保留最新 N 个并删其余（`:3638-3645`）；guard 对 lsof 有句柄/未知的单版本保留（`:3809-3820`）亦未写入。`default_selected:true` 成立（`bin/clean.sh:2120`→`dev.sh:6281`→`:6303`，`clean.sh:2036`/`dev.sh:6264` 直接 `"$@"` 无 y/n）。`action:delete` 成立（`:3884` `safe_clean`→`file_ops.sh:1816` 永久 `rm -rf`）；`needs_admin:false`（区间无 `sudo`）；`risk:medium` 口径待定。`in_app:true` 不成立：`p1a:587` 是 `ai_tool_dirs` 里的裸名 `.claude`（`protect.json:464` 明列为不自动清理的状态目录），与 `~/.local/share/claude/versions/*` 不同路径，也不是 `/Library/...` 后缀形式。 | `lib/clean/dev.sh:4359-4405`（specs `:4363-4367`；guard `:3727-3822`；plan `:3558-3652`；删除 `:3884`；调用 `bin/clean.sh:2120`→`dev.sh:6281`/`:6303`；sink `lib/core/file_ops.sh:1816`） |

### ai_tools-02

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| ai_tools-02 | 不一致（`in_app` 证据不同路径；`source` 过窄；`match`「同上」继承 01 的失效分支） | `paths` 逐字命中 `:4365`（spec 首段 `$HOME/.local/share/cursor-agent/versions`，删除面为其下条目、根保留）；符号链接 `~/.local/bin/cursor-agent` 为 spec 第三段（`:4379`/`:4381` 解析），成立。`match` 主体成立：共享循环 `:4370-4402`，活动版本由 `_resolve_versioned_agent_active_path`（`:3654-3719`）解析、plan `:3639` 排除，保留最新 `MOLE_AI_AGENTS_KEEP`（默认 1，`:4360-4361`）；但 `:4379` 需 `-L` 为真，链接不存在时 `active_path` 为空仍删旧版，故「同上」若含 01 的「断裂即整族保留」不成立，lsof 单版本保留（`:3805-3820`）亦未记。`source:4365` 行号无偏移，但仅一行 spec，未覆盖共享循环/helper，过窄（01 记 `:4359-4405`）。`default_selected:true`＝`clean.sh:2120`→`dev.sh:6281`→`:6303`（`--strict` 仅影响错误传播，`:6266` 直接 `"$@"` 无 y/n）。`action:delete` 成立（`:3884` `safe_clean`→`file_ops.sh:1816` 永久 `rm -rf`）；`needs_admin:false`（无 `sudo`）；`risk:medium` 口径待定。`in_app:true` 不成立：`p1a:594` 是 `ai_tool_dirs` 裸名 `.cursor`（≈`~/.cursor`），与 `~/.local/share/cursor-agent/versions/*` 不同路径，也非 `/Library` 后缀。 | `lib/clean/dev.sh:4365`（spec 行，无偏移；共享循环 `:4359-4405`；解析 `:3654-3719`；plan `:3636-3648`；删除 `:3884`；调用 `bin/clean.sh:2120`→`dev.sh:6281`/`:6303`；sink `lib/core/file_ops.sh:1478`→`:1816`） |

### ai_tools-03

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| ai_tools-03 | OK | `paths` 逐字命中 `:4366` 的 spec 首段 `$HOME/.copilot/pkg/universal`（删除面为其下版本子项，根保留）。`match` 成立：`~/.local/bin/copilot` 经 `:4379` `-L` 门控、`:4381` 解析（`_resolve_versioned_agent_active_path:3654-3719`），`:3639` 排除活动版本，另按 mtime 保留最新 `MOLE_AI_AGENTS_KEEP`（默认 1，`:4360-4361`），lsof 有句柄/未知时单版本保留（`:3809-3820`），活动版本未知整族跳过（`:4382-4392`）；「多留 1 个旧版 + 句柄保留」未写入 `match`，属完备性小疵。`source` 无偏移：`dev.sh` 与 artifacts `cmp` 字节相同（6331 行），`file_ops.sh` 的 `--json` 改动不在本文件。`default_selected:true`＝`clean.sh:2120`→`dev.sh:6281`→`:6303`（`clean.sh:2036`/`dev.sh:6264` 直接 `"$@"`，无 y/n）。`action:delete` 成立（`:3884` `safe_clean`→`file_ops.sh:1816` 永久 `rm -rf`）；`needs_admin:false`（区间无 `sudo`）；`risk:medium` 口径待定（可重装）。`in_app:true` 成立：`p1a:593` 的 `.copilot`（`ai_tool_dirs`）即 `~/.copilot`，与 `paths` 同路径、同后缀 id。 | `lib/clean/dev.sh:4366`（spec 行，无偏移；共享循环 `:4359-4405`；解析 `:3654-3719`；plan `:3558-3652`/`:3639`；guard `:3727-3822`/`:3809-3820`；删除 `:3884`；调用 `bin/clean.sh:2120`→`dev.sh:6281`/`:6303`；sink `lib/core/file_ops.sh:1478`→`:1816`） |

### ai_tools-04

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| ai_tools-04 | 不一致（`in_app` 证据不同路径；`source` 尾行越界 20 行） | `paths` 逐字命中 `:4082-4083`（spec 首段，删除面为两目录下的版本子项、根保留，与 `/*` 一致）。`match` 四条成立：多版本门 `:4086-4103`；SDK 版本读 `claude-code-vm/.sdk-version` 首行并经 `:3922-3931` 校验（`:3939-3949`），未知则整族保留（`:4109-4112`）；Claude Desktop 运行中或进程态未知即跳过（`:3933-3936` 的 `mole_pgrep_any`、`:4176-4186`），逐目标守卫 `:3959-4024` 复检；`_deny_versioned_agent_delete` 恒返 1（`:4070-4072`），用于 `:4154-4173` 无可删目标的记账分支防策略竞态。未写入 `match`：活动版本条目须在每个存在的 root 下真实存在且非链接，否则整族保留（`:4114-4124`）；另按 mtime 保留 `MOLE_AI_AGENTS_KEEP`（默认 1，`:4360-4361`）个旧版（`:3638-3645`）。`source` 起点与 specs 行号对，但尾 `:4237` 越界 20 行（函数实止 `:4217`，`:4219-4237` 为 playwright 注释）。`default_selected:true`＝`clean.sh:2120`→`dev.sh:6281`→`:6303`，无 y/n。`action:delete` 成立（`:4211`→`clean.sh:1720`→`file_ops.sh:1816` 永久 `rm -rf`）；`needs_admin:false`（无 `sudo`）；`risk:medium` 口径待定。`in_app:true` 不成立：`p1a:587` 是 `ai_tool_dirs` 裸名 `.claude`，`p1a:398` 是 `/Applications/Claude.app`，均非 `~/Library/Application Support/Claude/claude-code/*`（p1a 无 `claude-code` 串）。 | `lib/clean/dev.sh:3922-4217`（specs `:4081-4084`；清法 `:4074-4217`；guard `:3959-4024`；deny `:4070-4072`；删除 `:4211`→`bin/clean.sh:1720`→`lib/core/file_ops.sh:1816`；调用 `bin/clean.sh:2120`→`dev.sh:6281`/`:6303`） |

### ai_tools-05

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| ai_tools-05 | OK | `paths` 逐字命中 `:4518` / `:4530-4535`：3 profile × 2 leaf＝6，删除面是 `"$physical_leaf"/*`（`:4572`），叶子与 profile 目录保留，与 6 条 `/*` 一一对应；`app_protection.sh:440-445` 用同一 6 条、同样只放行 `/*` 子项的白名单独立复证「只清这 6 个」。`match` 成立：`:4554-4564` 中状态 0（运行）→`:4561` 延后、2（未知）→`:4558` 打印 skipped，仅 1 继续；每叶删除前经 `_codex_desktop_cache_delete_guard_allows`（`:4490-4492`→`base.sh:2020-2032`）复检；`:4526-4529` 注释逐项列明 Local Storage / IndexedDB / cookies / sessions / preferences 与 Application Support 兄弟目录为非目标。`source` 无偏移（`dev.sh` 与 artifacts 字节相同），`4517-4575` 恰为函数体，`4530-4535` 即 profiles/leaves。`default_selected:true`＝`clean.sh:2120`→`dev.sh:6281`→`:6310`→`:6183`，`clean.sh:2036` / `dev.sh:6264` 均直接 `"$@"`，无 y/n。`action:delete` 成立（`:4570-4573`→`:4505`→`clean.sh:1720`/`:1597`→`file_ops.sh:1478`→`:1816` 永久 `rm -rf`）；`needs_admin:false`（区间无 `sudo`）；`risk:medium` 口径待定（可重建缓存）。`in_app:true` 成立：`p1a:55-58` 为 `/Library/Caches/Codex{,/Default,/Default/Partitions,/codex-browser-app}`，即 `~/Library/Caches/...` 后缀，同 id 同后缀。小疵：`match` 未记 `:4521-4524` 根不安全即跳过与 `:4659` 逐级拒符号链接。 | `lib/clean/dev.sh:4517-4575`（`paths` `:4518`；profiles `:4530-4534`、leaves `:4535`；非目标注释 `:4526-4529`；守卫 `:4554-4564`；删除 `:4570-4573`→`:4505`；调用 `bin/clean.sh:2120`→`dev.sh:6281`/`:6310`/`:6183`；sink `bin/clean.sh:1720`/`:1597`→`lib/core/file_ops.sh:1478`/`:1816`；白名单 `lib/core/app_protection.sh:440-445`） |

### ai_tools-06

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| ai_tools-06 | 不一致（`in_app` 证据不同路径；`source` 尾行越界 18 行） | `paths` 逐字命中 `:4872`，删除面为 `find -P "$staging_root" -mindepth 1 -maxdepth 1 -type d`（`:4914`），只取一级子目录，与 `Installation/*` 一致。`match` 四项均成立：陈旧复检 `_codex_staging_entry_is_still_stale`（`:4687-4730`，`:4691` 限直子项、`:4692` 拒符号链接、superseded 在边界重解安装版本 `:4713` 并比 `staged≤installed` `:4717`、age 模式走 `-mtime +MOLE_ORPHAN_AGE_DAYS` `:4728`）；build 版本三件套 `:4792-4869`（bundle id `com.openai.codex` + 十进制门；安装侧两固定路径 + mdfind，多版本不一致即失败）；Sparkle 更新器 `:4577-4581`→`:4940`（未知 skip、运行 defer）；无打开文件 `:4583-4629`（`lsof +D`，rc2 视为不可判）→`:4952`；sink 前二次复检 `:4732-4763`。`source` 起点 `:4577` 即首个 helper、无偏移，尾 `:5008` 越函数体 18 行（`:4991` 空行 + `:4992-5008` 下节 daemon 注释）。`default_selected:true`＝`clean.sh:2120`→`dev.sh:6281`→`:6310`→`clean_dev_misc:6128`→`:6189`，无 y/n。`action:delete` 成立（`:4776`/`:4780` `safe_clean(_guarded)`→`clean.sh:1720`/`:1728`→`file_ops.sh:1816` 永久 `rm -rf`）；`needs_admin:false`（`:4577-4990` 无 `sudo`）；`risk:medium` 口径待定（可重新下载）。`in_app:true` 不成立：`p1a:359` 为 `/Library/HTTPStorages/com.openai.chat`，后缀与 `Library/Caches/com.openai.codex/org.sparkle-project.Sparkle/Installation` 不同、id 亦不同（`com.openai.chat`），p1a 全文无 `com.openai.codex` 串。`match` 未记：白名单整段跳过 `:4917`、Codex 运行/未知即 defer-skip `:4928-4937`、根与条目物理路径闸 `:4874`/`:4892`。 | `lib/clean/dev.sh:4871-4990`（`paths` `:4872`；扫描 `:4891-4914`；白名单 `:4917`；进程 `:4928`；更新器 `:4577-4581`/`:4940`；打开文件 `:4583-4629`/`:4952`；guard `:4687-4730`/`:4732-4763`；版本 `:4792-4869`；删除 `:4973`→`clean.sh:1728`→`lib/core/file_ops.sh:1478`/`:1816`；调用 `bin/clean.sh:2120`→`dev.sh:6281`/`:6310`/`:6128`/`:6189`） |

### ai_tools-07

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| ai_tools-07 | 不一致（`paths` 多一级；`source` 尾越 13 行；`in_app` 证据指向 `.cline`） | `paths` 应为 `~/.codex/packages/app-server-daemon/releases/*`：`root` 在 `:5170`、删除面是 `find -P "$releases_dir" -mindepth 1 -maxdepth 1 -type d`（`:5147`）下的一级目录，根下 `current` / `auto-update-version` / `install.lock` / `install.lock.d` / 遗留 `standalone/` 按 `:4999-5001` 明确保留。`match` 四项成立：名字 `:5009`、keep `:5016`、锁 `:5047`（fd9 + perl `LOCK_NB`，经 `:5205`）、打开态 `:5070`；未记 `release_count>1` 门 `:5186`、白名单 `:5188`、`install.lock.d` `:5200`、lsof 未知即跳过 `:5141-5153`；「保留最新」实为保留 `current` 指向 + marker 版本，非 mtime 最新。`source` 起 `:5009` 正确，函数实止 `:5217`，`:5218-5230` 越界（空行 + Crashpad 注释）。`default_selected:true`＝`bin/clean.sh:2120`→`dev.sh:6310`→`:6191`，`:6264` 与 `clean.sh:2036` 均直接 `"$@"`，无 y/n。`action:delete` 成立（`:5160`→`clean.sh:1475`→`file_ops.sh:1478`→`:1816` 永久 `rm -rf`）；`needs_admin:false`（区间无 `sudo`）；`risk:medium` 口径待定（单版本约 320MB，可重下）。`in_app:true` 不成立：`p1a:589` 是 `.cline`（`.codex` 在 `:591`），id 与后缀均不同；即便改指 `:591`，裸 `.codex` 也只到 `~/.codex`，未含 `packages/app-server-daemon`。 | `lib/clean/dev.sh:5009-5217`（`paths` `:5170-5171`/`:5147`；helper `:5009`/`:5016`/`:5047`/`:5070`/`:5082`；删除 `:5160`；门 `:5186`/`:5188`/`:5200`/`:5205`；非目标 `:4999-5001`；调用 `bin/clean.sh:2120`→`dev.sh:6310`/`:6191`；sink `bin/clean.sh:1475`→`lib/core/file_ops.sh:1478`/`:1816`） |

### ai_tools-08

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| ai_tools-08 | 不一致（`paths` 尾部 glob 不可用且漏 `-type f`；`match` 进程闸错挂、漏 `codex_desktop_process_state`） | `source:5231-5362` 无偏移：`dev.sh` 与 artifacts 字节相同（6331 行），起点即 helper `codex_crashpad_handler_process_state`（`:5231-5238`），主函数 `clean_codex_crashpad_pending` 实止 `:5361`，尾 `:5362` 空行。`paths` 根 `:5241` 正确，但尾部 `pending?**` 不是可用 glob（照抄保护侧 `app_protection.sh:548` 的 `pending/?*` 且漏斜杠），实际删除面只是 `-type f -mtime +$MOLE_ORPHAN_AGE_DAYS` 的直子普通文件（`:5254-5255`、`:5348-5349`），子目录与符号链接均不删，`paths` 未记这层收窄。`match` 的年龄（`:5255`）、handler 闸（`:5271-5280`）、打开文件闸（`:5287-5300`，helper `:4583`）、「更深一层受 N-07 保护」（`protect.json` N-07 与 `app_protection.sh:545-548` 实测一致）成立；但「进程」闸被挂在 `codex_crashpad_handler_process_state` 上，真正的 Codex 进程闸是 `codex_desktop_process_state`（`:5260`，运行即 `mole_defer_cleanup_family "Codex"` 整族延后），未记；物理路径闸 `:5245`、sink 前逐项复检直子项/非链接 `:5313-5315`、每千条复检 `:5317-5319` 亦未记。`default_selected:true` 成立：`bin/clean.sh:2120`→`dev.sh:6281`→`:6310`→`clean_dev_misc:6128`→`:6194`，`:6264` 直接 `"$@"`，无 y/n。`action:delete` 成立（`:5341` `safe_remove`→`file_ops.sh:1816` 永久 `rm -rf`）；`needs_admin:false`（区间无 `sudo`）；`risk:low` 口径待定（可再生的诊断文件，且有年龄下限）。`in_app:unknown` 自洽：p1a 全文 0 处 `Crashpad`，只有 `/Library/Caches/Codex*`（属 ai_tools-05），与 `paths` 不同后缀；`in_app_evidence` 引的 `app_protection.sh:536-548` 实测即该 carve-out。 | `lib/clean/dev.sh:5231-5362`（helper `:5231-5238`；主函数 `:5240-5361`；`paths` `:5241`；年龄 `:5255`/`:5349`；进程 `:5260`；handler `:5271`；打开文件 `:5287`；复检 `:5313-5319`；sink `:5341`→`lib/core/file_ops.sh:1816`；调用 `bin/clean.sh:2120`→`dev.sh:6281`/`:6310`/`:6194`；保护 `lib/core/app_protection.sh:536-548`） |

### ai_tools-09

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| ai_tools-09 | OK | `paths` 命中 `:5446` 的 `$HOME/.cache/codex-runtimes`；删除面为 `find -mindepth 1 -maxdepth 1 -type d`（`:5469`/`:5514`）的一级子目录，根保留，仅目录（`/*` 略宽于实际）。`match` 四项均成立：非活动且陈旧 `:5463-5464`/`:5497`/`:5502`；进程态 2（未知）`:5476-5477` 打印 skipped、0（运行）`:5480` defer，仅 1 继续；白名单根 `:5449`、逐项 `:5486` 跳过；清不完（含活动/失败）落 `:5534` 人工复核行。`source` 无偏移：`dev.sh` 与 artifacts `cmp` 字节相同（6331 行），`:5375-5536` 恰为 helper 起点至函数尾。`default_selected:true`＝`bin/clean.sh:2120`→`dev.sh:6281`→`:6310`→`clean_dev_misc:6128`/`:6187`，`:6264` 直接 `"$@"` 无 y/n。`action:delete`＝`:5504`→`:5429` `safe_clean_guarded`→`bin/clean.sh:1728`→`file_ops.sh:1816` 永久 `rm -rf`；`needs_admin:false`（`:5375-5536` 无 `sudo`）；`risk:medium` 口径待定（运行时需重下）。`in_app:unknown` 自洽：无 `in_app_evidence`；p1a 仅 `/Library/Caches/Codex`（`:55-58`，属 ai_tools-05）与裸 `.codex`（`:591`），无 `~/.cache/codex-runtimes` 同 id 同后缀证据。未记 `mole_cleanup_targets_exist`（`:5465`）与仅 `-type d` 两处收窄。 | `lib/clean/dev.sh:5375-5536`（无偏移；`paths` `:5446`；扫描 `:5463-5469`；进程 `:5472-5483`；白名单 `:5449`/`:5486`；删除 `:5502-5504`→`:5429`；复核 `:5518-5534`；调用 `bin/clean.sh:2120`→`dev.sh:6281`/`:6310`/`:6128`/`:6187`；sink `bin/clean.sh:1720`/`:1728`→`lib/core/file_ops.sh:1816`） |

### ai_tools-10

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| ai_tools-10 | 不一致 | paths `~/.codex` 与 `dev.sh:5541` 一致；match“永不默认清理、只写 debug 日志”成立（`:5544` 仅 `debug_log`，无 rm）；source `5538-5545` 成立（含头注释 :5538-5539）；default_selected:false 成立（`:6198` 无条件调用但无删除）；needs_admin:false 成立；**action:delete 不成立**，代码不删任何东西，应为 protect/none（同 trash-02、dev_tools-28）；**in_app_evidence 行号错**：p1a-strings `:589` 为 `.cline`，`.codex` 在 `:591`，in_app:true 本身成立；risk:high 口径待定。（Hark 依 dsh 3 次未写盘的分析复核后补写） | `engine/lib/clean/dev.sh:5538-5545`、调用 `:6198`；`report/p1a-strings.json:591` |

### ai_tools-11

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| ai_tools-11 | 不一致 | **paths 过宽**：`~/.codex/.tmp/*` 实为两固定根 `bundled-marketplaces`、`marketplaces/.staging`（`:5627-5630`）下以 3 前缀（`:5631-5635`）开头的一级目录，照 paths 会连已完成 marketplace 一起删，与 `:5619-5620` 注释相反；**source 尾越**：函数 `:5619-5749`，报告止 `:5751`（下一节注释），起 `:5547` 为 helper 变量，可接受；**in_app 不成立**：`:589` 为 `.cline`，`.codex` 在 `:591` 且只到 `~/.codex` 未及 `.tmp`（同 ai_tools-07 口径）。match 大体成立但漏年龄门 `:5560/:5665`、进程态 `:5684-5694`、lsof `:5712-5729`；default_selected:true 成立（`:6196` 无条件）；action:delete 成立（`:5732`→`file_ops.sh:1816`）；needs_admin:false；risk:medium 口径待定。（dsh 已得结论、超时未写盘，Hark 抽查后补写） | `engine/lib/clean/dev.sh:5547-5749`（主体 `:5619-5749`） |

### ai_tools-12

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| ai_tools-12 | 不一致（仅 in_app_evidence 引用） | paths 4 条与 `app_caches.sh:1152-1155` 逐条一致；match 成立（Codex 只 `debug_log` `:1161-1163`，`~/.cache/lm-studio` 仅注释声明不清 `:1156-1160`）；source `1151-1164` 恰为 `clean_ai_apps` 全函数，无偏移；default_selected:true 成立（`bin/clean.sh:2125` `_run_cleanup_step clean_user_gui_applications`，无 y/n）；action:delete 成立（`safe_clean`→`file_ops.sh:1816`）；needs_admin:false；in_app:true 成立（p1a `:78`、`:111` 同 id 同后缀），但 ChatGPT 引的 `:52` 是 `ChatGPTHelper`，应为 `:121` `/Library/Caches/com.openai.chat`；`Logs/Claude` 无 p1a 证据；risk:low 口径待定。（dsh 已得结论、超时未写盘，Hark 抽查后补写） | `engine/lib/clean/app_caches.sh:1151-1164`；`report/p1a-strings.json:121` |

### ai_tools-13

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| ai_tools-13 | 不一致（仅 `in_app` 证据路径不同） | `paths` 9 条与 `dev.sh:5789-5797` 逐条同序命中（均 `/*` 取子项、根保留）。`match` 成立：探针 `:5363-5369`，`:5799-5809` 状态 2 打印 skipped、0 整族延后、仅 1（未运行）继续；「`~/.gemini/tmp` 永不清理」见 `:5828-5829` 注释，engine 内无其它删除点。`source` `5784-5830` 恰为 `clean_antigravity_caches` 函数体（`dev.sh` 与 artifacts `cmp` 字节相同，6331 行），无偏移。`default_selected:true` 成立（`clean.sh:2120`→`dev.sh:6281`→`:6310`→`:6128`→`:6144`，`_run_cleanup_step:2022-2052` 直接 `"$@"`，无 y/n）。`action:delete` 成立（`safe_clean`/`_dev_safe_clean_process_guarded`，Service Worker 经 `caches.sh:74-123` 删 `CacheStorage` 下两级目录（`:103`），sink `file_ops.sh:1816`）；`needs_admin:false` 成立（区间无 `sudo`）；`risk:medium` 口径待定（可再生浏览器缓存，但含 Service Worker 站点离线态）。**`in_app:true` 不成立**：`p1a:596` 为裸名 `.gemini`，非 `/Library/...` 后缀形式，与 `~/.gemini/antigravity-browser-profile/...` 既非同后缀也非同 id（p1a 全文无 `antigravity-browser-profile` 串）。 | `engine/lib/clean/dev.sh:5784-5830`（`paths` `:5789-5797`；探针 `:5363-5369`；守卫 `:5799-5809`；非目标 `:5828-5829`；调用 `bin/clean.sh:2120`→`dev.sh:6281`/`:6310`→`:6128`/`:6144`；sink `lib/clean/caches.sh:74`→`lib/core/file_ops.sh:1816`）；`report/p1a-strings.json:596` |

### ai_tools-14

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| ai_tools-14 | 不一致（`paths` 漏 `t3code-v2`；`in_app_evidence` 指向 `.t3`） | `paths` 的 `T3 Code*` 只命中 `T3 Code (Alpha)`；实际还有 `t3code-v2`（`:5845`，当前主 profile，注释记 120 MiB），大小写敏感的 glob 覆盖不到，故 `paths` 不全；真实删除面是两 profile 的 `Partitions/t3code-preview-*/{Cache,Code Cache}`（`:5844-5857`、`:5882-5885`）。`match` 成立：`:5869-5878` 仅 probe 返回 1（未运行）继续，0 整族延后、2 打印 skipped；`:5836-5841` 注释明确 `~/.t3` 存线程历史/凭据、非目标。`source` `5832-5890` 无偏移（helper `5832-5834`、函数 `5842-5889`，尾 `:5890` 空行；`dev.sh` 与 artifacts 字节相同，6331 行）。`default_selected:true`（`bin/clean.sh:2120`→`dev.sh:6310`→`:6128`→`:6185`，无 y/n）；`action:delete` 成立（`:5887`→`lib/core/base.sh:2097`→`safe_clean`→`lib/core/file_ops.sh:1816`）；`needs_admin:false`（区间 0 处 `sudo`）；`risk:medium` 口径待定（可再生缓存）。`in_app:unknown` 与 p1a 无 T3 Code 同路径证据不冲突，但 `in_app_evidence` 以 `.t3` 立论，非 `paths` 同路径（`p1a:585-610` 的 `ai_tool_dirs` 无 `.t3`，全文亦无 `T3 Code`）。 | `engine/lib/clean/dev.sh:5832-5890`（`paths` `:5844-5857`/`:5882-5885`；探针 `:5832-5834`；进程态 `:5869-5878`；非目标 `:5836-5841`；删除 `:5887-5888`；调用 `bin/clean.sh:2120`→`dev.sh:6310`/`:6128`/`:6185`；sink `lib/core/base.sh:2097`→`lib/core/file_ops.sh:1816`）；`report/p1a-strings.json:585-610` |

### ai_tools-15

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| ai_tools-15 | OK | `paths` 与 `dev.sh:5892` 的 `$HOME/.cache/chrome-devtools-mcp/chrome-profile` 一致，`:5895-5907` 仅列 Default 下 Cache/Code Cache/GPUCache/Dawn/Shader/Graphite 缓存、component_crx_cache、extensions_crx_cache 与 Service Worker/CacheStorage（均可重建，配置/会话不删）。`match` 成立：探针 `:5371-5373`（`pgrep -f chrome-devtools-mcp`），`:5910-5919` 仅 state=1（未运行）继续，运行态延后、未知态打 skipped。`source` 起点 5891 精确、函数实止 `:5946`，rules 写 `-5961` 尾部多 15 行（`:5947-5961` 已属 ai_tools-16 的 agent-browser 注释/变量），按本审计口径属区间包含、非行号漂移。`default_selected:true`（`bin/clean.sh:2120`→`dev.sh:6281`/`:6310`/`:6128`/`:6212`，`_run_cleanup_step:2022-2052` 无 y/n）。`action:delete`（`safe_clean`/`_dev_safe_clean_process_guarded`→`file_ops.sh:1816` 永久 `rm`）、`needs_admin:false`（区间无 `sudo`，候选全在 `$HOME`）、`risk:low` 口径待定。`in_app:unknown`：无 `in_app_evidence`，p1a 全文无 `chrome-devtools-mcp` 同路径串，不冲突。 | `engine/lib/clean/dev.sh:5891-5946`（rules 写 `-5961`，尾多 15 行；`paths` `:5892`/`:5895-5907`；探针 `:5371-5373`；守卫 `:5910-5919`；调用 `bin/clean.sh:2120`→`dev.sh:6281`/`:6310`/`:6128`/`:6212`；sink `lib/core/file_ops.sh:1816`） |

### ai_tools-17

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| ai_tools-17 | 不一致（`action` 无删除、`in_app` 证据指向 `.cline` 且未达子路径；`source` 尾越 10 行） | `paths` 对得上：`~/.codex/worktrees`、`~/.t3/worktrees` 在 `:3164` 固定容器表，`~/.claude/worktrees` 走 `:3199` 的 `-path "*/.claude/worktrees"` 与 purge 搜索根 `:73`（`~/.t3` 注释「仅作为搜索根」不准，`:3164` 也把它当容器上报）。`match` 成立：`:3237` 只 `mole_review_row`，注释 `:3203-3207` 明确仅上报、`git worktree remove` 由人工决定，本体不删；容器根入 purge 搜索路径 `purge_shared.sh:72-74`。`source` 起 `:3155` 正确，但函数止 `:3250`，`:3251-3260` 已是 docker 段注释（尾越 10 行）；`secondary_source:66-75` 无偏移。`default_selected:false` 成立（`:3919` 仅为 Large files 复核行，不进删除选择）；`needs_admin:false`（`:3155-3260` 无 `sudo`）。**`action:delete` 不成立**：全路径无 `safe_remove`/`rm`，应改 report/none（同 ai_tools-10）。`risk:high` 口径待定（实际无删除，偏高）。**`in_app:true` 不成立**：`p1a:587` 为 `.claude`、`p1a:589` 实为 `.cline`（`.codex` 在 `:591`），二者均为 `ai_tool_dirs` 裸名，只到 `~/.codex`/`~/.claude`，未含 `worktrees` 子路径，也非 `/Library/...` 后缀。 | `lib/clean/user.sh:3153-3250`（containers `:3155-3201`；report `:3209-3250`；`paths` `:3164`/`:3199`；调用 `:3919`）；`lib/clean/purge_shared.sh:72-74`；`report/p1a-strings.json:589,591` |

### ai_tools-18

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| ai_tools-18 | 不一致（仅 `in_app` 证据路径不同） | `paths` 与 `apps.sh:1117` 的 `$HOME/Library/Application Support/Claude/vm_bundles` 一致，`:1125-1126` 仅取一级 `*.bundle` 目录。`match` 成立：孤儿判定 `:955-1012`（`:965` Claude 进程探针、`:968` 已安装清单 `grep -Fxq com.anthropic.claudefordesktop`、`:973` 7 天老化）；`:1143` 白名单跳过、`:1152` 身份快照、`:1171` 尺寸>0、`:1179` `safe_clean_guarded orphan_cleanup_candidate_still_eligible`。`source` 区间与函数体吻合（`apps.sh` 与 artifacts 字节相同，2639 行，无偏移；`:1198` 为 claude 段结束）。`default_selected:true` 成立（`bin/clean.sh:2140` 无条件 `_run_cleanup_step`，`:2022-2052` 无 y/n）。`action:delete`（`safe_clean`→`_safe_clean_impl:1076`→`file_ops.sh:1816` 永久 `rm`）、`needs_admin:false`（区间无 `sudo`）成立；`risk:medium` 口径待定（可再生 VM 镜像，但永久删除）。**`in_app:true` 不成立**：`p1a:398` 为 `/Applications/Claude.app`，与 `~/Library/.../vm_bundles` 既非同路径，也非 `/Library/...` 主目录后缀，同 id 不同后缀。 | `engine/lib/clean/apps.sh:955-1030,1117-1200`（`paths` `:1117`/`:1125-1126`；白名单 `:1143`；快照 `:1152`；尺寸 `:1171`；守卫删除 `:1179`；调用 `bin/clean.sh:2140`；sink `bin/clean.sh:1475`→`lib/core/file_ops.sh:1816`）；`report/p1a-strings.json:398` |

### ai_tools-19

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| ai_tools-19 | 不一致（`paths` 漏 CodeBuddyExtension 两项；`in_app` 证据后缀不同） | `paths` 中 Code 五条、Cursor 一条与 `app_caches.sh:623-628` 逐条命中，CodeBuddy CN 八项与 `:650-657` 同集合同序，Zed 两条命中 `:633-634`；但 `:638-645` 实际删除的 `~/Library/Application Support/CodeBuddyExtension/{Cache,logs}/*` 未列入 `paths`（`match` 却已提到「CodeBuddy 共享缓存进程判定」），属漏项。`source` 起点 616 精确（`_codebuddy_shared_cache_running:616-619` 即 `match` 所指共享守卫），函数体实止 `:659`，尾 `:660-673` 为 Feishu 注释，属区间包含、非行号偏移；`app_caches.sh` 与 artifacts 字节相同（2247 行）。`default_selected:true` 成立（`bin/clean.sh:2120`→`dev.sh:6310`→`:6316` 无条件 `_run_developer_cleanup_step`，无 y/n）。`action:delete`（`mole_safe_clean_app_cache`→`_dev_safe_clean_process_guarded`→`safe_clean`，sink `file_ops.sh:1816` 永久 `rm`）、`needs_admin:false`（全文件无 `sudo`）成立；`risk:low` 口径待定（均为可再生缓存/可重下 VSIX）。**`in_app:true` 不成立**：`:92-93` 为 `~/Library/Caches/com.codebuddy.extension[.cn]`、`:72` 为 `~/Library/Caches/Zed`、`:606-607` 为 `~/.trae`/`~/.vscode`，与 `Application Support/{Code,Cursor,CodeBuddy CN,Zed}` 后缀均不同。 | `engine/lib/clean/app_caches.sh:616-673`（`paths` `:623-628`/`:633-634`/`:650-657`；漏项 `:638-645`；共享守卫 `:616-619`；调用 `bin/clean.sh:2120`→`lib/clean/dev.sh:6310`/`:6316`；sink `lib/core/file_ops.sh:1816`）；`report/p1a-strings.json:92-93,72,606-607` |

### ai_tools-20

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| ai_tools-20 | OK | `paths` 是机制描述而非字面路径：`clean_versioned_agent_root` 通用函数确实存在，但仅由 `:4363-4367` 三个固定 spec 实例化，「任何 `<agent>/versions` 型根」略宽（同 dev_tools-29 口径，可接受）。`match` 成立：keep 默认 1（`:4360-4361`；`:3618` 条目不足即不删、`:3636-3651` 按 mtime 保留最新 N 并排除活动版本）；活动版本未知/断链 → `:4382-4391` debug 后 `continue` 整族保留；清单/stat 未知 → `:3844-3848` 置 `inventory unknown` 并 `return 0`；删除前 `_versioned_agent_delete_guard_allows` 重解析活动版本并重算保留集（`:3757-3800`），目标不符只跳过该目标或整族停止。小疵：启动器软链**不存在**（非断链）时 `:4379` 整段不进、`ACTIVE_REQUIRED=false`（`:3853-3854`），仍删旧版，`match` 的「活动版本未知即整族保留」未覆盖此情形；lsof 有句柄/未知保留单版本（`:3805-3820`）未写入。`source` 无偏移：`dev.sh` 与 artifacts 字节相同（6331 行），`:3522` 起首个 helper、`:3921` 为 `count_versioned_agent_entries`（止 `:3920`）后的空行、`:4359-4405` 恰为 `clean_dev_ai_agents` 函数体。`default_selected:true`＝`bin/clean.sh:2120`→`dev.sh:6281`→`:6303`，`clean.sh:2036`/`dev.sh:6264` 直接 `"$@"`，无 y/n。`action:delete` 成立（`:3860`/`:3884` `safe_clean(_guarded)`→`file_ops.sh:1816` 永久 `rm -rf`）；`needs_admin:false`（两区间 0 处 `sudo`）；`risk:medium` 口径待定（旧版可重下，但为永久删除）；`in_app:unknown` 自洽（无 `in_app_evidence`，与 `paths` 无冲突）。 | `lib/clean/dev.sh:3522-3921,4359-4405`（机制 `:3830-3887`；specs `:4363-4367`；plan `:3558-3652`/`:3618`/`:3636-3651`；resolve `:3654-3725`；guard `:3727-3822`/`:3757-3800`；删除 `:3860`/`:3884`；调用 `bin/clean.sh:2120`→`dev.sh:6281`/`:6303`；sink `lib/core/file_ops.sh:1816`） |

### ai_tools-16

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| ai_tools-16 | 行号偏移（2 行；`in_app` 无支撑） | `paths` 精确命中 `:6090` `$HOME/.agent-browser/browsers`，删除面为 `:5997-5998` `find -mindepth 1 -maxdepth 1 -name 'chrome-*'` 的一级目录，只删 `chrome-<ver>`（`:6049` 正则）且须含 Chrome 二进制（`:6052`）——所谓「旧版本」实为「按名字字节序最后一个含二进制的 chrome-*」之外的全部（`:6015-6022`，注释 `:5950-5953` 明言非版本序）。`match` 成立：`~/bin` 软链经 `_agent_browser_physical_path`（`:5976-5987`，逐跳 readlink + `cd -P`）解析，用作保留判定（`:6037-6044`/`:6055-6059`），**并非**「在用版本」；`config.json` 仅在 `:6024-6030` 作 pin 来源读取，`:5957-5958` 注释声明 config/会话/profile 永不为目标。`source` 起点 `:5949` 偏移 +2（注释实起 `:5948`，`:5948-5958` 为单块注释、`:5949` 无规则边界）；尾 `:6127` 越函数体 2 行（`clean_agent_browser_old_chrome` 实止 `:6125`，`:6127` 为 clean_dev_misc 头注释）。`default_selected:true` 成立（`bin/clean.sh:2120`→`dev.sh:6281`→`:6310`→`:6128`→`:6146` 无条件调用，`:6264` 直接 `"$@"`，无 y/n）。`action:delete` 成立（`:6107` `safe_clean_guarded`→`clean.sh:1728`→`_safe_clean_impl`→`file_ops.sh:1490`/`safe_remove:1478`→`:1816` 永久 `rm -rf`）；`needs_admin:false`（`:6089-6125` 无 `sudo`）；`risk:medium` 口径待定（单份约 360 MB 可重下）。`in_app:unknown` 成立但无正/反证据：p1a 全文无 `agent-browser`/`browsers`/`Chrome for Testing` 串，`:62`/`:103` 为 `/Library/Caches/{Google/Chrome,com.google.Chrome}`，同 id 不同后缀。**建议**：`source` 改 `:5948-6125`。 | `engine/lib/clean/dev.sh:5948-6125`（rules 写 `5949-5961,5962-6127`；`paths` `:6090`；扫描 `:5997-5998`；保留选取 `:6015-6022`；软链解析 `:5976-5987`/`:6037-6044`；pin `:6024-6030`/`:6031`/`:6053-6054`；年龄 `:6062`；进程 `:5963`/`:6072`；删除 `:6107`；guard `:6070-6087`；调用 `bin/clean.sh:2120`→`dev.sh:6281`/`:6310`/`:6128`/`:6146`；sink `bin/clean.sh:1728`→`lib/core/file_ops.sh:1478`/`:1816`） |

<!-- ai_tools 追加点 -->

## category: xcode（11 条）

### xcode-01

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| xcode-01 | OK | `paths`：`app_caches.sh:216` 定 `$HOME/Library/Developer/Xcode/DerivedData`，`:228` 按 `/*` 逐项目枚举，与 `~/.../DerivedData/*` 完全对应。`match` 全中：进程名清单在 `app_protection.sh:62-65`（Xcode/xcodebuild/xctest/XCTRunner/XCBBuildService/swift-frontend，`_xcode_cleanup_process_state` 见 `app_caches.sh:5-7`）；仅「确证无进程」（state=1）才继续，state=2 未知在 `:246-254` 打印 skipped（dry-run 另见 `:277-280`、`:295-298`）；逐项目 `:231` 过 `should_protect_path`/白名单/`holds_compiled_model_cache`，`projects+=` 后按项目循环、`:368` 逐项目 `safe_remove` = 项目级绑定。`source` 无偏移：`:215-397` 为函数体，398 只是下一函数注释行，起点精确。`default_selected:true`＝`bin/clean.sh:2120`→`dev.sh:6315 --strict clean_xcode_tools`→`app_caches.sh:527`→`:215`，无 y/n 询问。`action:delete` 成立（`safe_remove`→`file_ops.sh:1816` 永久 `rm -rf`）。`needs_admin:false`（`:215-397` 与 `file_ops.sh:1478-1830` 均无 sudo）。`risk:medium` 口径待定（永久删除但可由构建重建，与 medium 相符）。`in_app:true` 自洽：`p1a-strings.json:344` 为 `/Library/Developer/Xcode/DerivedData`，即 App 拼在用户主目录后的同后缀路径，与 `paths` 同 id 同目标。 | `lib/clean/app_caches.sh:215-397`（`paths` `:216`/`:228`；`match` `:231`、`:245-255`、`:368`；进程表 `lib/core/app_protection.sh:62-65`；入口 `bin/clean.sh:2120`→`dev.sh:6315`→`app_caches.sh:527`；sink `lib/core/file_ops.sh:1816`） |

### xcode-02

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| xcode-02 | OK | `paths` 与 `app_caches.sh:475` 存在性检查、`:489` 删除 glob 同为 `~/Library/Caches/com.apple.dt.Xcode/*`。`match` 成立：`:482-484` 仅 state=1（工具链未运行，`_xcode_cleanup_process_state` 见 `:5-7`/`app_protection.sh:62-65`）才进入；删除前由 `_xcode_app_cache_delete_guard_allows`（`:49-55`）经 `safe_clean_guarded` 逐项复核（`bin/clean.sh:1724-1733`）。`source` 无偏移：`:485-495` 正是该 cache 删除块。`default_selected:true`：`bin/clean.sh:2120`→`dev.sh:6315 --strict clean_xcode_tools`→`:399`，无 y/n。`action:delete` 成立（`safe_clean`→`file_ops.sh:1816` 永久 `rm -rf`）。`needs_admin:false`（`:399-535` 无 sudo）。`risk:low` 口径待定（永久删除但缓存可重建）。`in_app:unknown` 自洽：无同 id 同后缀 `in_app_evidence`，p1a 中亦无 `com.apple.dt.Xcode` 串。 | `lib/clean/app_caches.sh:485-495`（`paths` `:475`/`:489`；守卫 `:49-55`；过程门 `:482-484`；入口 `bin/clean.sh:2120`→`dev.sh:6315`→`app_caches.sh:399`；sink `lib/core/file_ops.sh:1816`） |

### xcode-03

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| xcode-03 | OK | `paths` 与 `:501` 复检、`:521` 删除 glob 同为 `~/Library/Developer/Xcode/Products/*`（`:476` 同）。`match` 成立：`:481-484`/`:507-509` 仅 state=1（Xcode 未运行；`_xcode_cleanup_process_state`=`xcode_build_tooling_process_state`，进程表 `app_protection.sh:62-65`）才进入；`:497-499` 注释明示缓存阶段可能耗时，`:500-505` 重置后重新校验 Products/DerivedData 候选，无候选 `:505` 直接 return。`source` 无偏移（artifacts 与 engine 字节相同）：`496` 为空行，实体 `497-527`，`:527` 收尾 `clean_xcode_derived_data`。`default_selected:true`=`bin/clean.sh:2120`→`dev.sh:6315 --strict clean_xcode_tools`→`:399`，无 y/n。`action:delete` 成立（`_app_cache_safe_clean_guarded`→`safe_clean`→`safe_remove`→`file_ops.sh:1816` 永久 `rm -rf`）。`needs_admin:false`（`:399-535` 无 sudo）。`risk:medium` 口径待定（永久删除但构建产物可重建）。`in_app:unknown` 自洽：无 `in_app_evidence`，p1a 中亦无 Products 同后缀串（仅 DerivedData 等）。 | `lib/clean/app_caches.sh:496-527`（`paths` `:476`/`:501`/`:521`；守卫 `:49-55`；过程门 `:507-517`；入口 `bin/clean.sh:2120`→`dev.sh:6315`→`app_caches.sh:399`；sink `lib/core/file_ops.sh:1816`） |

### xcode-04

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| xcode-04 | OK | `paths` 3 条与扫描候选 `:413-415`、删除 glob `:427`（Caches/*）、`:436`（Devices/*/data/tmp/*）、`:456`（Logs/CoreSimulator/*）逐条同形，均为 `/*` 一级子项；扫描期另含 device leaf（`:142-177`，属 xcode-05）。`match` 全中：进程表 `:16-20` 为 Xcode/Simulator/xcodebuild/xctest/XCTRunner，经 `_simulator_cleanup_process_state`（`:10-21`）委派 `_coresimulator_activity_state`（`dev.sh:2003`）后追加 `simctl`（`dev.sh:1918-1948`）与已启动模拟器探测（`dev.sh:1951-1985`）；守卫定名 `_simulator_app_cache_delete_guard_allows` 在 `:57-59`，经 `mole_clean_process_guard`（`base.sh:2020-2033`）仅 state=1（确证均未运行）放行，state 0 与 2 均拒删。`source` `:399-470` 精确无偏移：`:399` 函数头，`:418-469` 为本条 Simulator 段，`:470` 空行。`default_selected:true`（`bin/clean.sh:2120`→`dev.sh:6315 --strict clean_xcode_tools`→`:399`，无 y/n）。`action:delete`（`_app_cache_safe_clean_guarded:186`→`clean.sh:1728 safe_clean_guarded`→`safe_remove`→`file_ops.sh:1816` 永久 rm，非废纸篓）。`needs_admin:false`（`:399-470` 无 sudo）。`risk:medium` 口径待定（缓存/临时文件可再生，但设备 `data/tmp/*` 为整树删除且无回收站）。`in_app:true` 成立：`p1a-strings.json:566` `~/Library/Developer/CoreSimulator` 是三条 paths 的共同前缀，`:171` `/Library/Developer/CoreSimulator/Caches` 即同一 App 拼在用户主目录后的后缀，同 id 同后缀。 | `lib/clean/app_caches.sh:399-470`（`paths` `:413-415`/`:427`/`:436`/`:456`；守卫 `:57-59`；进程表 `:16-20`+`lib/clean/dev.sh:1918-2003`；入口 `bin/clean.sh:2120`→`dev.sh:6315`→`app_caches.sh:399`；sink `lib/core/file_ops.sh:1816`） |

### xcode-05

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| xcode-05 | OK | `paths` 5 条与 `_SIMULATOR_DEVICE_LEAVES` 逐条一致（`:68-74`，代码存 `data/...` 后缀，拼在 `Devices/<udid>/` 下）；`match` 成立：`:76-120` 单次 `plutil` 快照 + awk 按根字典 depth==1 判定，`state` 须 `<integer>1</integer>`（`:105`）、`isDeleted` 缺失或 `<false/>`（`:108-114`），读失败/类型不符 return 1 视为未知并保留；`:124-138` 再验无链接、叶子在白名单、删前重读 plist；poster store 只整删（`:71-73` 注释：只删 descriptors 会致 `staticdescriptors` 空、相册渲染失败）；`:142-162` 只枚举这 5 个非空叶子。`source:61-177` 无偏移（起于叶清单注释、止于 `_defer_app_cache_guard_family` 前）。`default_selected` 成立：`clean.sh:2120` 无条件 → `dev.sh:6315` `_run_developer_cleanup_step --strict`（`:6247-6277` 直接 `"$@"`，无 y/n）→ `app_caches.sh:399`。`action:delete`（`:442-452` → `safe_clean` → `safe_remove` → `file_ops.sh:1816`）、`needs_admin:false`（全在 `$HOME`，无 `sudo`）成立；`risk:high` 口径待定（整目录删除不可撤销，重启才重建、自定义壁纸丢失）。`in_app` 成立：`p1a-strings.json:567` = `~/Library/Developer/CoreSimulator/Devices`，与 paths 同根同 id、仅缺 `data/...` 后缀，按后缀等效算支持（父目录锚点，粒度偏粗）。 | `lib/clean/app_caches.sh:61-177`（无偏移；清单 `:68-74`、判定 `:76-138`、枚举 `:142-162`、删除守卫 `:166-176`） |

### xcode-06

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| xcode-06 | 不一致（`match`） | `paths` 即 `dev.sh:2185` 的 `/Library/Developer/CoreSimulator/Caches`，`:2192` 只取一级子项、不删根本身（规则未写 `/*` 属省略）。`match` 前半成立：进程守卫 `:2217`（`_coresimulator_activity_state`=`dev.sh:2003`，含 `:1995` 已启动模拟器复核）+ `:2298`/`:2320` 删前逐项复检，state≠1 即停。但「身份绑定」不存在：`:2326` `safe_sudo_remove "$entry" "$entry_size_kb"` 只传 2 个参数，`expected_parent`/`_id`/`_target_id` 全缺，`file_ops.sh:2230` 与 `:2359` 的身份三元组检查因此短路，sizing 到 `file_ops.sh:2245` `sudo rm -rf` 之间无 inode/dev/哈希绑定。其余字段均符：`source` 起 2181 正确、实体止 2367（到 2372 只是下一函数 5 行注释；dev.sh 与 artifacts 字节相同，无漂移）；`default_selected` 由 `bin/clean.sh:2120`→`dev.sh:6281/6299 --strict`→`:2994`→`:2997` 无 y/n，但受 `:2183 SYSTEM_CLEAN` 与 `:2283` sudo 门控（交互下 Enter 默认继续）；`action:delete`（`file_ops.sh:2245` 永久 rm）、`needs_admin:true`（`:2284`）、`risk:high`（系统级不可恢复，口径待定）成立；`in_app` 成立：`p1a-strings.json:171` 同 id 同后缀。 | `lib/clean/dev.sh:2181-2367`（path `:2185`、sink 调用 `:2326`；sink `lib/core/file_ops.sh:2230`/`:2245`；入口 `bin/clean.sh:2120`→`dev.sh:6299`→`:2997`） |

### xcode-07

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| xcode-07 | OK | `paths` 六条与 `dev.sh:3241-3246` 六个调用逐条一致（iOS/macOS/watchOS/tvOS/visionOS/xrOS DeviceSupport，均 `~/Library/...` 的版本子项）。`match` 成立：`:2376-2378` 保留最近 2 个版本（`MOLE_XCODE_DEVICE_SUPPORT_KEEP` 可覆盖），`:2386` 只取一级目录、`:2505` 取 `sorted_dirs[keep_count:]`，`:2438`/`:2517`/`:2536`/`:2588`/`:2651` 五处进程守卫（`_xcode_xctest_devices_process_running` 在 `:2007`，state≠1 即跳过或延后），size 仅用于统计与预算续算（`:2527`/`:2580` `get_path_size_kb`+`mole_item_size_continues`，非阈值判定），`:2594 safe_remove` 删整版本；`:2640`/`:2643` 收集保留版本内 `Symbols/System/Library/Caches/*` 与 `*.log`，`:2665`/`:2672` 经 `_xcode_safe_clean_guarded` 删除，与「符号缓存处理」对应。`source` 起点 `:2373` 精确、实体止 `:2678`（`-2679` 多含 1 行空行），`:3241-3246` 精确；dev.sh 与 artifacts 字节相同，无漂移。`default_selected:true`（`bin/clean.sh:2120`→`dev.sh:6281 clean_developer_tools`→`:6299 --strict clean_dev_mobile`→`:2994`→`:3241`，无 y/n）。`action:delete`（`file_ops.sh:1816` 永久 `rm -rf`）；`needs_admin:false`（全在 `$HOME`，`:2373-2679` 与 sink 均无 sudo，也无 SYSTEM_CLEAN 门控）；`risk:medium` 口径待定（1-3GB 调试符号永久删、默认只留 2 版，设备重连可重建）。`in_app:true` 成立：p1a 的 `/Library/Developer/Xcode/DeviceLogs`（:496）正是 App 拼在用户主目录后的后缀，与 `paths` 同 id 且同 `~/Library/Developer/Xcode` 父目录；:345 DocumentationCache 不属本规则，但不影响同 id 同父目录的判定。 | `lib/clean/dev.sh:2373-2678`（paths `:3241-3246`；keep `:2376`/`:2505`；守卫 `:2438`/`:2588`；sink 调用 `:2594`；入口 `bin/clean.sh:2120`→`dev.sh:6299`→`:2994`；sink `lib/core/file_ops.sh:1816`） |

### xcode-08

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| xcode-08 | OK | `paths` 3 条全中：`dev.sh:1740` 默认 `/Library/Developer/Xcode/DocumentationCache`、`:3251` RuntimeRoot Caches、`:3261` IB Support（转义空格）。`match` 成立：`:1740` 经 `mole_test_path_override`，`file_ops.sh:2842-2847` 仅在 `MOLE_TEST_MODE`/`MOLE_TEST_NO_AUTH` 下取值＝测试用；系统级路径 `:1837-1842 ensure_sudo_session` 要 sudo。`source` 起点 `:1736` 精确、实体止 `:1908`，区间尾多含 9 行（1909 空行 + 1910-1917 下一函数注释），属区间包含非偏移；`3251-3262` 起于块内 path 行（块头 `:3248`），覆盖两条 path。`default_selected:true`：`clean.sh:2120`→`dev.sh:6281`→`:6299 --strict clean_dev_mobile`→`:2996`，无 y/n，仅受 `:1738 SYSTEM_CLEAN` 门控（交互 Enter 默认继续）。`action:delete` 成立（`:1869 safe_sudo_remove`→`file_ops.sh:2014` sudo rm；另两条 `safe_clean`→`file_ops.sh:1816`），只删最新之外的旧 index、根目录不删。`needs_admin:true`（`:1838`）。`risk:medium` 口径待定（sudo 永久删但缓存可再生）。`in_app:true` 成立：p1a `:345` 与 `paths[0]` 完全同路径。 | `lib/clean/dev.sh:1736-1908`（`:1740` path/override、`:1838` sudo、`:1869` sink；`:3248-3252` RuntimeRoot、`:3258-3262` IB Support；sink `lib/core/file_ops.sh:2014`/`:1816`；入口 `bin/clean.sh:2120`→`dev.sh:6299`→`:2996`） |

### xcode-09

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| xcode-09 | OK | `paths` 唯一项 `~/Library/Developer/XCTestDevices` 与 `dev.sh:2127` 的 `$HOME/Library/Developer/XCTestDevices` 一致（另有 `MOLE_XCODE_XCTEST_DEVICES_DIR` 覆盖，rules 未记，属补充非矛盾）；`source` 2007-2180 正好覆盖 `_xcode_xctest_devices_process_running`(2007-2046) + `_xctest_devices_delete_guard_allows`(2058-2060) + `clean_xcode_xctest_devices`(2125-2180)，无偏移；`match` 两个函数名逐字存在，且 root 先过 `should_protect_path`/白名单/编译模型缓存预判(:2133-2137)，`find -mindepth 1 -maxdepth 1` 只取一级子项(:2171)、root 保留(:2168-2169 注释)；`default_selected=true` 成立（`clean_developer_tools:6299`→`clean_dev_mobile:2998` 无条件调用，无 y/n）；`action=delete` 成立（:2175 `_xcode_safe_clean_guarded`→`safe_clean`→`safe_remove:1478`→`file_ops.sh:1816` 永久 rm，非废纸篓）；`needs_admin=false` 成立（全链无 sudo）；`risk=medium` 口径待定（用户级目录、测试克隆可重建，未见不可恢复证据，不硬判不一致）；`in_app=unknown` 成立（p1a 无 XCTestDevices/XCTest 字符串，`/Library/...` 后缀式证据不适用） | `lib/clean/dev.sh:2125-2180`（探针 2007-2046、守卫 2058-2060） |

### xcode-10

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| xcode-10 | 不一致（`action` 应为 report，无删除点；`~/Library/MobileDevice` 在 engine 中不存在） | `paths` 第 1 条成立：`user.sh:3809` 与预取队列 `:3329` 均拼 `$HOME/Library/Developer/Xcode/Archives`；但只经 `_report_large_or_stop`→`_report_large_review_dir`（`:3657-3677`，仅 `-d`+`du`+上报）输出，全链无 `safe_clean`/`rm`，`action: delete` 与此矛盾（同 ai_tools-17 应改 `report`）；`:3809` 上方注释亦写明 Archives 存 dSYM、按次数/月份区分「值得保留」，语义是提示人工。第 2 条 `~/Library/MobileDevice` 在 `engine/` 全树（含大小写不敏感）0 命中，CLI 确无对应点，属 App 侧独有字符串。`source` 568-569 与 p1a 逐字一致，无偏移（`user.sh` 与 artifacts 字节相同）。`default_selected: false` 成立（`check_large_file_candidates` 需显式进入）；`needs_admin: false` 成立（`:3657-3682` 全段无 `sudo`）。`in_app: true` 成立：同 id 同后缀，`/Library/Developer/Xcode/Archives`、`/Library/MobileDevice` 即 App 拼在 `$HOME` 后的后缀（同 `~/Library/...`）。`risk: high` 口径待定（只读上报，本身无不可恢复删除）。`match` 的「CLI 侧未见自动删除规则」与代码相符。 | `lib/clean/user.sh:3809`（所属 `check_large_file_candidates`，起于 `:3478`；helper `_report_large_review_dir:3657-3677`）+ 预取 `:3329`；另 `cmd/analyze/insights.go:60` 亦仅 analyze 只读列举；`~/Library/MobileDevice` 在 `engine/` 无任何命中；p1a 基线 `report/p1a-strings.json:568-569`（无偏移） |

### xcode-11

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| xcode-11 | OK | `source:2680-2993` 无偏移：`:2680` 是 simctl 段起点 `_sim_runtime_size_kb`，`:2992` 为 `check_orphaned_simulator_runtimes` 收尾 `}`（`:2993` 空行，`:2994` 起为下一函数 `clean_dev_mobile`），artifacts 同区间逐字节相同。`paths` 是判定面描述，对应 `:2890-2952` 的行筛选：`:2941` 仅 `Ready` 且 `deletable=true`、`:2942` 每个 runtimeIdentifier 只被一个镜像服务，绝不触碰 `/Library/Developer/CoreSimulator` 卷（`:2860-2864`、`:2884-2886` 注释）。`match` 成立：`_simctl_developer_dir_is_usable` `:2700-2707`（`xcrun --find simctl`）、`_simctl_first_launch_complete` `:2717-2724`（`xcodebuild -checkFirstLaunchStatus`，超时/信号一律不启用 simctl），`_run_simctl` `:2826` 再验 ready；`:2963`/`:2970` 两次 `-j` 任一失败或 `:2978` 无 `"devices"` 即 `return 0`，`:3222` 仅 `simctl_available==true` 才调用、`:3229` 否则 debug 跳过。`action:command` 成立：执行面只有只读 `runtime list -j`/`list devices -j`（`:2822-2829`），`runtime delete` 仅出现在提示文本 `:2988`，`:2991` 直接 `return 0`。`default_selected:false` 成立：虽在 `:6299` 的 `clean_dev_mobile` 主流程内，但全程零删除，不构成默认删除项。`risk:high` 口径待定（只读提示，风险实为"用户手动删 runtime 需重下载"）。`needs_admin:true` 仅宽松成立：`:2683-2684` 在 `has_sudo_session` 时用 `sudo -n du` 读体积，删除动作本身不提权。`in_app:true` 成立：`p1a:656` 为命令串 `simctl`，与 `command:"xcrun simctl"` 同 id 同后缀。 | `lib/clean/dev.sh:2680-2993`（`paths` `:2890-2952`/`:2941-2942`；`match` `:2700-2707`、`:2717-2724`、`:2826`、`:2963`、`:2970`、`:2978`、`:3222`/`:3229`；只读命令 `:2828`；提示 `:2988`；`sudo` `:2684`；调用 `:6299`） |

<!-- xcode 追加点 -->

## category: optimize（19 条）

### optimize-19

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| optimize-19 | OK | `paths` 是机制描述而非字面路径，对应 `execute_optimization`（`:2104`）。`match` 全中：`:2108` 先查 catalog handler，未知 action 在 `:2109-2110` 报错 `return 1`（未 start、未执行）；`:2113-2116` 再查 handler 是否存在；`:2121` 仅 `network_optimization` 映射 legacy `system_maintenance`，经 `is_whitelisted`（`whitelist.sh:321`）命中即在 `:2124-2128` 记 SKIPPED 返回 0；正常路径 `:2131-2133` 才 start→handler→finish。`source:2104-2134` 恰为整函数（`tasks.sh` 与 artifacts 字节相同、2134 行，无偏移）。`default_selected:false` 成立：optimize 为独立命令，`bin/clean.sh` 不调用（`:2146` 仅注释）；但显式 `mo optimize` 会在 `bin/optimize.sh:315-323` 串行执行全部目录项，故 false 指「默认 clean 流程不选」，非「需用户逐个勾选」。`risk:low` 口径待定（分派器本身不改状态，下游 handler 含 DNS/Spotlight/权限等系统副作用）。`action:command` 成立（`:2131-2132` 直接调用 shell handler，`command:null` 无外部命令串）。`needs_admin:false` 成立（`:2104-2134` 无 `sudo`；sudo 在各 handler 内，如 `:191`）。`in_app:unknown` 自洽：无 `in_app_evidence`，与 `paths` 无冲突，不足以立 `true`。 | `lib/optimize/tasks.sh:2104-2134`（`match` `:2108`/`:2109-2110`/`:2113-2116`/`:2121`/`:2122-2128`/`:2131-2133`；catalog `lib/optimize/catalog.sh:89,101`；白名单 `lib/manage/whitelist.sh:321`；入口 `bin/optimize.sh:315-323`） |

### optimize-18

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| optimize-18 | 不一致（`in_app`） | `paths` 为机制描述，对应 `opt_login_items_audit`；`match` 全中：`_login_items_snapshot`（`:1621`）经 osascript 取登录项，`_login_item_build_metadata_inventory`（`:1684`）读 Info.plist 构建元数据清单，`_login_item_build_app_inventory`（`:1728`）扫描 `~/Applications`、`/Applications` 得应用清单，`sfltool dumpbtm` 仅在 `sudo -n true` 成功后兜底（`:1919`/`:1928`，`:1911-1913` 注释明确避免弹窗），末尾只报 broken 并提示到系统设置删除（`:2098`），无删除。`source:1621-2103` 覆盖 helper 至主函数 `:1958-2101`，`:2102-2103` 为空行+下节注释（尾多 2 行），tasks.sh 与 artifacts 字节相同、无偏移。`default_selected:false` 与 optimize 独立命令一致；`action:command`（`:1928`）、`needs_admin:true`（`sudo -n`）成立；`risk:medium` 口径待定（只读审计、不改文件）。`in_app:true` 不成立：`p1a:653` 是裸命令串 `sfltool`，非 `paths` 同路径/同后缀，不能支撑。 | `lib/optimize/tasks.sh:1621-2101`（主函数 `:1958-2101`；helper `:1621`/`:1684`/`:1728`/`:1811`；BTM `:1908-1948`；catalog `lib/optimize/catalog.sh:73`） |

### optimize-17

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| optimize-17 | OK | `paths` 为机制描述，对应 `opt_coreduet_cleanup`（`:1547`）。`match` 全中：`:1549` 目标 `~/Library/Application Support/Knowledge/knowledgeC.db`（用户主目录，故 `in_app_evidence` 的 `/Library/...` 后缀形式同 id 同后缀即算支持）；`:1558-1559` 只把 `-wal`/`-shm` 纳入 `:1561-1563` 的 `du -skcP` 体积统计（`:1569`）；`:1578` <100MB 直接 healthy 返回；`:1585` 无 sqlite3 即 UNAVAILABLE 返回；`:1592-1594` 注释明确「不得先 unlink sidecar」；`:1597-1598` 仅 `DELETE ... ZOBJECT ... ; VACUUM;`（SQLite 自行 recover/checkpoint），全函数体（`:1547-1615`）无 `unlink`/`rm`/`safe_remove`，SQL 失败走 `:1600-1602` 只记 `sql_failed`。`source:1547-1620` 起点即函数头无偏移，函数实止 `:1615`，`:1616-1620` 为下节 `_login_items_snapshot` 注释（尾多 5 行，区间包含；tasks.sh 与 artifacts 字节相同）。`default_selected:false` 与 optimize 独立命令一致；`needs_admin:true` 与 optimize-19 同口径：`:1547-1615` 内无 `sudo`，但 `bin/optimize.sh:305-312` 在未取到 admin 时整体跳过 sudo-required 任务（口径待定）。`action:command`（`:1585`/`:1597` 调 `sqlite3`）、`command:sqlite3` 成立；`protected_by:OP-04` 成立（`report/protect.json:427-430`：in-use SQLite 族含 `-wal`/`-shm`/`-journal` 拒删，`file_ops.sh:250-274`，sink 复检 `:1308`/`:1683`）。`risk:high` 口径待定：写 `~/Library` 用户库且含 `VACUUM` 重写，但无 sidecar unlink、无不可恢复删除，high 偏保守。`in_app:unknown` 自洽：无 `in_app_evidence`，与 `paths` 无冲突，不足以立 `true`。 | `lib/optimize/tasks.sh:1547-1615`（无偏移；`match` `:1558-1563`/`:1569-1574`/`:1578-1581`/`:1585-1588`/`:1592-1603`；catalog `lib/optimize/catalog.sh:85`；入口 `bin/optimize.sh:315-323`；OP-04 `lib/core/file_ops.sh:250-274`/`:1308`/`:1683`；尾多 `:1616-1620`） |

### optimize-16

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| optimize-16 | 不一致（`in_app`、`needs_admin`） | `paths` 是机制描述，命中 `opt_disk_verify`（`:1505`）。`match` 成立：`:1502-1504` 注释明示默认禁用及 SIGKILL 不可中断原因，`:1506-1510` 未设 `MOLE_ENABLE_DISK_VERIFY=1` 即 SKIPPED，`:1512-1516` dry-run 再跳过；删除点只有 `:1523` `diskutil verifyVolume /`，`:1538` 仅提示手工 `repairVolume`，不执行修复。`source:1501-1546` 起点为段注释、函数实体 `:1505-1544`，`:1546` 已是下一函数注释，属区间尾宽 1 行、非偏移（tasks.sh 与 artifacts 字节相同，2134 行）。`default_selected:false` 成立（任务自身默认跳过；catalog 末位 `true` 是 safe 值非默认选中）。`action:command` 与 `command` 成立（`:1523`）。`risk:medium` 口径待定（只读校验、无删除，但注释称可致系统冻结）。`needs_admin:true` 代码无支撑：`:1505-1544` 无 `sudo`，也未使用 `optimize_sudo_available`；仅 `:1538` 建议文本含 `sudo`。`in_app:true` 不成立：`p1a-strings.json:622` 是裸命令名 `diskutil`，不是 `paths` 同路径/同后缀。 | `lib/optimize/tasks.sh:1501-1544`（函数 `:1505`；默认禁用 `:1506-1510`；命令 `:1523`；修复提示 `:1538`；catalog `lib/optimize/catalog.sh:70-73`；入口 `bin/optimize.sh:315-323`） |

### optimize-15

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| optimize-15 | OK（`risk` 口径待定） | `paths` 为机制描述，命中 `opt_notification_cleanup`。`match` 全中：`:1433-1448` `resolve_notification_center_db`（`:1438` 组容器优先，`:1442` 回退 `getconf DARWIN_USER_DIR`），解析失败在 `:1452` 报 unavailable；`:1455` 取大小、`<51200KB` 直接 unchanged；`:1473-1476` sqlite3 `DELETE ... delivered_date < -30 days; VACUUM`，成功后在 `:1483-1484` `launchctl kill SIGTERM gui/1000/com.apple.notificationcenterui.agent`（恰为「清理后重启通知中心」，命令串用具体 target，无占位符）。`source:1432-1500` 起点是段注释、终点为函数尾空行，函数实体 `:1450-1499`，非行号偏移（tasks.sh 与 artifacts 字节相同，2134 行）。`default_selected:false` 按本 category 既有口径成立（optimize 为独立命令，`bin/clean.sh` 不调用；catalog 末位 `true` 是自动执行安全值，`:144-145` 拒绝非 safe 项自动跑）。`risk:medium` 口径待定（永久删除 30 天前已投递通知并 VACUUM，有 50MB 阈值，可致通知历史不可恢复）。`action:command`、`needs_admin:false` 成立（`:1432-1499` 无 `sudo`，仅 `bin/optimize.sh:307-310` 全局 `ensure_sudo_session`；`command` 字段可补 sqlite3 一步）。`in_app:unknown` 自洽：本 id 无 `in_app_evidence`，`p1a-strings` 中仅 `/System/Library/.../UserNotifications` 与 `MoleNotificationCenter`，与 `paths` 不同路径同后缀。 | `lib/optimize/tasks.sh:1432-1500`（解析器 `:1433-1448`；入口 `:1450`；unavailable `:1452`；阈值 `:1461`；SQL `:1473-1476`；kill `:1483-1484`；catalog `lib/optimize/catalog.sh:82-84`；入口 `bin/optimize.sh:310-320`） |

### optimize-14

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| optimize-14 | OK（`risk` 口径待定） | `paths` 为机制描述，命中 `opt_shared_file_list_repair`。`match` 全中且**只删损坏项**：`:1400` 每文件先 `plutil -lint`，仅 lint 失败才在 `:1403` `safe_remove "$sfl_file" true`（永久 `rm`，经 `file_ops.sh:1816`）；`:1399` 显式跳过 `ApplicationRecentDocuments`（近期文档＝用户条目），`find` 侧 `:1370` 亦以 `! -path` 排除；`:1369` 只匹配 `*.sfl2/3/4` 普通文件，合法列表一律不动 → 即「重建 sharedfilelist 而不删用户条目」。`source:1348-1431` 起点正是函数签名行，终点为尾空行（函数实体 `:1348-1424`，`:1432` 起才是 `resolve_notification_center_db`），**无行号偏移**（`lib/optimize/tasks.sh` 与 artifacts 字节相同，2134 行；`file_ops.sh` 仅 +5 行且不在本链路上）。`default_selected:false` 按本 category 既有口径成立（optimize 为独立命令，`bin/clean.sh` 不调用；catalog `:67-69` 末位 `true` 只是自动执行安全值，`:144-145` 拒非 safe 自动跑）。`risk:medium` 口径待定（Finder 收藏/最近项目条目永久删除不可恢复，但仅限 lint 失败项）。`action:command` 成立（`plutil` 判定 + `safe_remove`，非整目录删除）。`needs_admin:false` 成立（`:1348-1424` 内 0 处 `sudo`，权限不足只记 unavailable/skipped）。`in_app:unknown` 自洽：本 id 无 `in_app_evidence`；按同路径判定，`p1a-strings` 无 `sharedfilelist`/`sfl2-4`/`Application Support` 同后缀命中，与 `paths` 无冲突（`/System/Library/.../Finder.app` 是系统只读，路径不同）。 | `lib/optimize/tasks.sh:1348-1424`（`sfl_dir` `:1349`；无目录 unchanged `:1350-1354`；scan 排除 `:1369-1370`；permission-only unavailable `:1388-1391`；RecentDocuments 跳过 `:1399`；lint 门 `:1400`；删除 `:1403`；catalog `lib/optimize/catalog.sh:67-69`；入口 `bin/optimize.sh:318-323`；sink `lib/core/file_ops.sh:1816`） |

### optimize-13

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| optimize-13 | 行号偏移 | `paths` 是机制描述，命中 `opt_periodic_maintenance`（实为 `:1297`，`source` 写 `1294` 偏早 3 行；区间 `1294-1347` 覆盖函数体 `:1297-1345` 及尾随空行/下节注释，方向为「起点含前置注释」。`engine/lib/optimize/tasks.sh` 与 `artifacts/mole-cli` 同名文件 `diff` 退出 0、均 2134 行，故偏移来自 `source` 自身而非 `--json` 改动）。`match` 成立：`:1298-1303` 用 `command -v periodic` 判存在，缺失即 `opt_msg "skipped (not available on this macOS version)"` + `UNAVAILABLE` + `return 0`，与「macOS 26+ 已移除 → 直接跳过并说明」一致；需要提权亦在 `:1322-1326` 走 `optimize_sudo_available` 失败即 skipped。`command: "sudo periodic daily weekly monthly"` 与 `:1330` 逐字一致（含 `2>&1` 捕获）。`default_selected:false` 按本 category 既有口径成立（optimize 为独立命令，`bin/clean.sh` 不调用，`:2146` 仅注释；`bin/optimize.sh:318-323` 串行跑全部目录项；catalog `:64-66` 末位 `true` 只是自动执行安全值，`:144-145` 拒非 safe 项）。`risk:low` 口径待定（不删用户数据，仅触发系统 `/etc/periodic` 脚本并写 `daily.out`，但属系统级维护、失败只记 warning）。`needs_admin:true` 成立（`:1330` 直接 `sudo periodic`）。`action:command` 成立。`in_app` 口径：`p1a_evidence` 为 `p1a-strings.json:645` 的裸命令名 `periodic`（`commands` 第 32 项，非 `/Library/...` 路径串），与 `paths`「机制描述」非同路径同后缀，不足以立 `true`，故判 `in_app:true` 无支撑（应为 `unknown`）。 | `lib/optimize/tasks.sh:1297-1345`（函数头 `:1297`；存在性判定 `:1298-1303`；sudo 门 `:1322-1326`；命令 `:1330`；catalog `lib/optimize/catalog.sh:64-66`、安全值 `:144-145`；入口 `bin/optimize.sh:318-323`；`source` 起点 `1294` 实为前置注释 `:1294-1296`） |

### optimize-12

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| optimize-12 | 不一致（`match` 第 3 条） | `paths` 的机制描述命中 `opt_launch_agents_cleanup`（`:1235`）。`match` 前两条成立：卷挂载判定 `launch_agent_volume_mounted`（`:1218-1228`，调用 `:1267-1268`）；函数内无 `launchctl`，注释 `:1233-1234` 明示不 unload。但「判定损坏后才动」不成立：代码仅在 `:1278-1279` `printf` 报告，`:1290` 明言 `left in ~/Library/LaunchAgents`，`:1291` 返回 `ATTENTION`，从不删除/移动/停用 plist，rule 的 cleanup 语义与 `risk:medium` 无对应动作（risk 口径待定，只读审计实际或低于 medium）。`source:1218-1293` 起点为挂载 helper 签名、终点为函数尾空行，完整覆盖 `:1218-1292`，无行号偏移。`default_selected:false` 按 optimize 独立命令口径成立（`bin/optimize.sh:318-323` 串行跑全部项；catalog `:79-81` 末位 `true` 仅为自动执行安全值）。`action:command` 可（内置只读任务），`needs_admin:false` 成立（全段无 sudo）。`in_app:true` 成立：`p1a-strings.json:522-542` 的 `/Library/LaunchAgents` 与 paths 同 `LaunchAgents` 后缀（等同 `~/Library/...`），`:779 StartupItemScanner` 同源。 | `lib/optimize/tasks.sh:1218-1292`（主函数 `:1235`；破损判定 `:1267-1268`；报告 `:1278-1279`；仅报告 `:1290-1291`；catalog `lib/optimize/catalog.sh:79-81`；入口 `bin/optimize.sh:318-323`） |

### optimize-11

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| optimize-11 | 不一致（`match` 字段） | `paths` 为机制描述，命中 `opt_legacy_overrides_audit`。`source:1148-1217` 起点正是函数签名（`tasks.sh:1148`）、终点为函数尾空行（`}` 在 `:1213`），无行号偏移（`tasks.sh` 与 artifacts 基线一致，`--json` 只改 `file_ops.sh`）。**`match`「只审计与提示，不删除」不成立**：探针在 `:1166`/`:1176` 读 `NSAppSleepDisabled` 与 diskimages `skip-verify*`，命中后 `:1203` 执行 `defaults delete <domain> <key>` 真删覆盖键（`changed` 计数、`:1204` 打印 Removed override），`MOLE_DRY_RUN=1` 时才只预览（`:1198-1201`）；注释 `:1145-1147` 与 catalog 描述 `Remove hidden App Nap and disk-image verification overrides`（`lib/optimize/catalog.sh:49-51`）同样表明是修复删除，非只读审计。`default_selected:false` 按本 category 既有口径成立（optimize 独立命令，`bin/optimize.sh:318-323` 串行跑全部目录项；catalog 末位 `true` 只是自动执行安全值，`:144-145` 拒非 safe 项）。`action:command` 可（执行 `defaults delete` 命令，非路径删除，不经 `safe_remove`/`file_ops.sh:1816`）；仅删键、不写回、不碰 plist 文件本身，`:1193` 另有 `is_path_whitelisted` 跳过。`needs_admin:false` 成立（全段无 `sudo`，写的是用户域偏好）。`risk:low` 口径待定（删的是显式覆盖键、macOS 回落默认，可手动恢复）。`in_app`：该条 `in_app:"unknown"` 且无 `in_app_evidence`，`paths` 亦无路径可比，未见矛盾。 | `engine/lib/optimize/tasks.sh:1148-1213`（探针 `:1166`/`:1176`；plist 拼接 `:1171`/`:1181`；白名单 `:1193`；dry-run `:1198-1201`；删除 `:1203`；catalog `lib/optimize/catalog.sh:49-51`、`:144-145`；入口 `bin/optimize.sh:318-323`） |

### optimize-10

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| optimize-10 | OK | `paths` 为机制描述，命中 `opt_prevent_network_dsstore`（`:1099`），非字面路径。`match`「写 defaults，不改文件」成立：仅 `:1110` 读、`:1124-1131` 写用户域偏好，全段无 `safe_remove`/文件删除，不触碰 plist 文件。`source:1099-1147` 起点正是函数签名，无行号偏移；本函数实际止于 `:1139`，`:1141-1147` 是下一任务注释，仅区间尾部略宽。`default_selected:false` 按 optimize 独立命令既有口径成立：clean 不调用此项，`mo optimize` 在 `bin/optimize.sh:317-321` 串行跑全部目录项；catalog 末位 `true`（`catalog.sh:46-48`）只是自动执行安全值。`risk:low` 口径待定（写两个用户偏好、幂等可逆，无删除）。`action:command` 成立（`defaults write` 外部命令，非路径删除）。`needs_admin:false` 成立（全段无 `sudo`）。`in_app:unknown` 自洽：无 `in_app_evidence`，`paths` 亦无路径可比。注：`command` 只写 `DSDontWriteNetworkStores`，代码 `:1101` 同时写 USB 键 `DSDontWriteUSBStores`（`:1124-1131`），属覆盖范围备注，不改变上述字段结论。 | `engine/lib/optimize/tasks.sh:1099-1139`（读 `:1110`；键表 `:1101`；写 `:1124-1131`；汇总 `:1138`；catalog `lib/optimize/catalog.sh:46-48`；入口 `bin/optimize.sh:317-321`） |

### optimize-09

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| optimize-09 | 不一致（`in_app`） | `paths` 为机制描述，分别命中 `opt_spotlight_index_optimize`（`:879`）与 `opt_prune_spotlight_orphan_rules`（`:987`）。`match` 成立：孤儿清理只对 `resolver_rc==1`（应用确已卸载）的条目 `removed`（`:1043-1046`），`System.*`/`com.apple.*` 及 Spotlight 自身开关（如 `Custom.relatedContents`）一律 `keep`（`:1026-1040`）；索引重建是独立 catalog 任务（`catalog.sh:58-61`），仅在 AC 且两次探针均慢时执行 `sudo mdutil -E /`（`:949-957`）。`source:879-1098` 起点正是函数签名，无行号偏移；区间含第二函数 `:987-1093` 及下一节注释 `:1095-1098`（尾宽 4 行，非偏移；tasks.sh 与 artifacts 字节相同）。`default_selected:false` 按本 category 既有口径成立（`mo optimize` 在 `bin/optimize.sh:315-323` 串行跑全部目录项，catalog 末位 `true` 只是安全值）。`risk:medium` 口径待定（重建索引重负载但非删除，孤儿规则写偏好可回退）。`action:command` 成立（`mdutil` `:882`/`:957`、`mdfind` `:924`；孤儿侧另有 `plutil`/`defaults`）；`needs_admin:true` 成立（`:951-957` 经 `optimize_sudo_available` 后 `sudo mdutil -E`，未授权则 skipped）。`in_app:true` 无支撑：本 id 无 `in_app_evidence`，p1a 仅有 `mdfind` 命令串与 `/Library/Spotlight`，非 `paths` 同路径/同后缀，不能立 true。 | `engine/lib/optimize/tasks.sh:879-1098`（索引 `:879-977`；孤儿 `:987-1093`；`mdutil` `:882`/`:957`；`mdfind` `:924`；保留规则 `:1026-1040`；catalog `lib/optimize/catalog.sh:58-61`；入口 `bin/optimize.sh:315-323`） |

### optimize-08

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| optimize-08 | OK（`risk` 口径待定） | `paths` 是机制描述，命中 `opt_disk_permissions_repair`（`tasks.sh:825`）。`match` 成立：`:844-845` 先过 `optimize_sudo_available`（`tasks.sh:39-44`，未取到 admin 即 skipped 返回），`:855` 直接 `sudo diskutil resetUserPermissions / "$user_id"`，故「需 sudo」✓；`:835` `user_id=$(id -u)` 且传 `"/"` 为卷、仅修当前用户 home 的 ACL，`needs_permissions_repair`（`:69-88`）也只探 `$HOME`、`$HOME/Library`、`$HOME/Library/Preferences`，故「只针对当前用户 home」✓。`source:825-878` 起点正是函数签名，无行号偏移；函数实止 `:876`，`:877` 空行、`:878` 为下节 `opt_spotlight_index_optimize` 注释（区间尾宽 2 行，非偏移；`tasks.sh` 与 artifacts 字节相同、均 2134 行，`--json` 只改 `file_ops.sh`）。`default_selected:false` 按本 category 既有口径成立（clean 流程不调用 optimize；但 `mo optimize` 在 `bin/optimize.sh:318` 串行跑全部目录项，「不在默认任务集」仅指非 clean 默认，且实跑另受 `:837` `needs_permissions_repair` 门控，无问题时不执行）。`action:command`（`:855`）、`needs_admin:true`（`:844`+`:855`）成立。`risk:high` 口径待定：代码自带标签为 `debug_risk_level "MEDIUM" "Requires sudo, modifies permissions"`（`:831`），与 rule 的 high 不一致，但 `resetUserPermissions` 会递归改写 home 权限、无回滚，判 high 偏保守可接受。`in_app:unknown` 自洽：本 id 无 `in_app_evidence`，`paths` 亦为机制描述无字面路径，不构成冲突。 | `lib/optimize/tasks.sh:825-876`（函数头 `:825`；`id -u` `:835`；检测门 `:837`；dry-run 分支 `:843`；sudo 门 `:844-845`；命令 `:855`；catalog `lib/optimize/catalog.sh:55-57`；入口 `bin/optimize.sh:318`；尾宽 `:877-878`） |

### optimize-07

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| optimize-07 | 不一致（`match`「需 sudo」、`needs_admin`、`in_app`） | `paths` 为机制描述，命中 `opt_sqlite_vacuum`（`:528`）。`match` 两条成立：`:543-563` 先 `pgrep -x Mail/Safari/Messages`，任一在跑即 `SKIPPED` 返回（可安全独占）；`:596` 显式跳过 `-wal`/`-shm`，且逐库 `:598` `should_protect_path`、`:640` `PRAGMA integrity_check`，与 OP-04「在用 SQLite 族跳过」一致（`file_ops.sh:250-274`，sink 复检 `:1308`/`:1683`）。**但「需 sudo」不成立**：`:528-712` 全段无 `sudo`、未调 `optimize_sudo_available`，只操作 `$HOME/Library` 下 Mail/Messages/Safari 用户库（`:577-582`），`needs_admin:true` 无代码支撑（`bin/optimize.sh:307-311` 的 `ensure_sudo_session` 是 optimize 全局前置，非本任务要求）。`source:528-719` 起点即函数签名，函数实止 `:712`，`:713-719` 为尾随空行与下节注释（尾宽 7 行，非偏移；`tasks.sh` 与 artifacts 字节相同、2134 行）。`default_selected:false` 与 optimize 独立命令口径一致（catalog `:43-45` 末位 `true` 是自动执行安全值，`:148-150` 拒非 safe 项自动跑）。`action:command`、`command:"sqlite3 <db> VACUUM"` 成立（`:650`）。`risk:high` 口径待定：代码自带 `debug_risk_level "LOW"`（`:534`），VACUUM 重写库但不删数据，high 偏保守。`in_app:true` 不成立：`p1a-strings.json:245` 是裸命令串 `/usr/bin/sqlite3`，与机制描述的 `paths` 非同路径同后缀。 | `lib/optimize/tasks.sh:528-712`（函数头 `:528`；busy 判定 `:543-563`；WAL 跳过 `:596`；防护 `:598`；integrity `:640`；VACUUM `:650`；catalog `lib/optimize/catalog.sh:43-45`、`:148-150`；入口/全局 sudo `bin/optimize.sh:307-311`；OP-04 `lib/core/file_ops.sh:250-274`/`:1308`/`:1683`） |

### optimize-06

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| optimize-06 | 不一致（`match`、`command`） | `paths` 的机制描述命中 `opt_quarantine_cleanup`（`:465`）。**`match`/`command` 反向**：代码清的是 `~/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2` 这张 SQLite 库的**下载跟踪记录**——`:497` 先 `SELECT COUNT(*) FROM LSQuarantineEvent`，`:510-512` 非 dry-run 时执行 `sqlite3 … "DELETE FROM LSQuarantineEvent; VACUUM;"`，`:522` 报 `Quarantine history cleared (N entries)`；全程**没有** `xattr -d com.apple.quarantine`（`engine/` 内 `xattr` 仅见于 `bin/slim.sh:641-642` 的 `-rsd com.apple.FinderInfo`/`ResourceFork`），且 `:469` 自述 "Only clears download tracking metadata, does not affect file quarantine flags"——即清库、不动文件隔离标记，与规则「只清 com.apple.quarantine 标记，不动文件本身」相反。判定面另有：`:474-478` 无 `sqlite3` 即 `UNAVAILABLE`、`:482-486` 库不存在即 `UNCHANGED`、`:488-492` `should_protect_path` 命中即跳过。`source:465-527` 起点即函数签名、无偏移，`}` 在 `:525`，`:526` 空行、`:527` 为下一任务注释（尾宽 2 行，非偏移；`tasks.sh` 与 artifacts 字节相同、2134 行）。`default_selected:false` 按本 category 既有口径成立（`bin/optimize.sh:318-323` 串行跑全部目录项，catalog `:76-78` 末位 `true` 只是自动执行安全值）。`action:command` 类型成立（执行 `sqlite3` 外部命令，不经 `safe_remove`/`file_ops.sh:1816`），但 `command` 文本须改为 `sqlite3 <db> "DELETE FROM LSQuarantineEvent; VACUUM;"`。`needs_admin:false`（`:465-525` 无 `sudo`，只动 `$HOME`）、`risk:low` 口径待定（代码自带 `debug_risk_level "LOW" "Database is automatically recreated by macOS"`，`:471`；删跟踪记录不可恢复但库可再生，与 low 相符）。`in_app:unknown` 自洽：本条无 `in_app_evidence`，`paths` 亦为机制描述无字面路径；p1a 全文无 `QuarantineEventsV2`/`LaunchServices.Quarantine` 字符串。 | `lib/optimize/tasks.sh:465-525`（函数头 `:465`；sqlite3 门 `:474-478`；库路径 `:480`；`should_protect_path` `:488`；计数 `:497`；dry-run `:510`；DELETE+VACUUM `:512`；risk `:471`；尾宽 `:526-527`；catalog `lib/optimize/catalog.sh:76-78`；入口 `bin/optimize.sh:318-323`） |

### optimize-05

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| optimize-05 | 不一致（仅 `in_app`） | `paths` 为机制描述（非路径），两个 id 均在位：`opt_network_optimization`、`opt_network_stack_optimize`。`match` 成立：活动 VPN 时跳过（栈侧 `:725-734`；DNS 侧经 `:164` `flush_dns_cache` → `:166` `has_active_vpn_interface`，命中返回 2、`:446-448` 报 skipped），且先做 DNS 可用性探测 `:753-754` `dscacheutil -q host -a name "example.com"`。`source` 两起点均为函数头、无偏移，函数分别止 `:462`/`:822`，区间尾各多 2 行（`:463-464`、`:823-824`）。`default_selected:false` 按本 category 既有口径成立（`mo optimize` 在 `bin/optimize.sh:315-323` 串行跑全部目录项，catalog `lib/optimize/catalog.sh:40`/`:52` 末位 `true` 仅为自动执行安全值）。`action:command` 类型成立：实际执行 `sudo dscacheutil -flushcache`（`:191`，经 `:164`）、`sudo route -n flush`（`:773`）、`sudo arp -a -d`（`:777`）；`command` 文本只列探测命令，属粒度问题。`needs_admin:true` 成立（`:433-437`、`:770-774` 先过 `optimize_sudo_available`，未授权即 skipped）。`risk:medium` 口径待定：代码对 DNS 侧显式标 `debug_risk_level "LOW"`（`:429`），栈侧无标签但 flush 路由/ARP 需 sudo 且无回滚。`in_app:true` 不成立：无 `in_app_evidence`，p1a 仅有裸命令串 `dscacheutil`（`p1a-strings.json:624`，属 `/commands` 列表），非 `paths` 同路径/同后缀；`app/Sources` 亦无该命令——与 optimize-07/09 同类。 | `lib/optimize/tasks.sh:424-462,720-822`（rules 写 `424-464,720-824`，两处各尾多 2 行；tasks.sh 与 artifacts 字节相同，无偏移） |

### optimize-04

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| optimize-04 | OK（`risk`/`default_selected` 口径待定） | `paths` 为机制描述（非字面路径），对应 `opt_fix_broken_configs`，`tasks.sh:381` 函数签名在位。`match`①「只修可证明损坏」成立：`maintenance.sh:28-30` `/usr/bin/plutil -lint`，`:78-85` 批量 lint 失败才逐文件复核，`:86-92` 不可读文件一律保留（unknown 非 corrupt），`:96-101` 再过 `should_protect_path`/`is_path_whitelisted`。`match`②「写操作走闸门」成立：唯一写点 `maintenance.sh:102` `safe_remove "$candidate" true`，无裸 `rm`/`mv`；v5 等价闸门为 `file_ops.sh:1478` `safe_remove` 内 `:1520` `validate_path_for_deletion` + `:1538` 白名单 + `:1665` live-cache 复检，与前端 `ManualWriteGate` 的功能位一一对应（复刻时按其契约实现即可，静态无同名符号）。作用域 `maintenance.sh:113` `$HOME/Library/Preferences`、`:124` ByHost，`:118` 目录不存在即退。**`in_app`**：本 id 无 `in_app_evidence`，`in_app:unknown` 自洽；`p1a-strings.json` 偏好设置类 25 项均为 `/Library/Preferences*` 形式（App 拼在用户主目录后的后缀，等同 `~/Library/Preferences*`），与代码同 id 同后缀，故亦不构成冲突。`source:381-423` 起点正确、arts 与 engine 字节相同（2134 行）无偏移，实止 `:421`，`:422` 空行、`:423` 注释（尾宽 2 行，非偏移）。`default_selected:false` 按本 category 既定口径成立（clean 流程不含 optimize；`bin/optimize.sh:315-323` 串行跑全部目录项，catalog `catalog.sh:37-39` 末位 `true` 仅为自动执行安全值）。`action:command`、`needs_admin:false` 成立：全程无 `sudo`（`maintenance.sh:28-117`），自家 plist 用户可写。`risk:medium` 口径待定：`tasks.sh:385-386` 自带标签 `debug_risk_level "LOW"`，但 `safe_remove` 为永久删除、plist 偏好不可回滚，medium 偏保守可接受。 | `lib/optimize/tasks.sh:381-421`（rules 写 `381-423`；`catalog.sh:37-39`；`maintenance.sh:28-30,78-101,102,112-129`；sink `file_ops.sh:1478,1520,1538,1665`） |

### optimize-01

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| optimize-01 | 不一致（仅 `in_app`） | `paths` 为机制描述（非字面路径），对应 `opt_network_optimization`（`tasks.sh:424-462`）→ `flush_dns_cache`（`:164-206`），catalog `:40-42` 以 `network_optimization` 注册。`match` 成立：`:165-171` 先调 `has_active_vpn_interface`（`:97-155`，`scutil --nc list` 的 Connected 或默认路由 `utun*`），VPN 命中返回 2，`:445-447` 报 skipped；未知状态返回 3 也跳过（`:449-451`），macOS 拒绝信号返回 4 亦跳过（`:453-455`）。措辞偏差：VPN 下整段 flush 都在 `:167-171` 提前返回，跳过的不只是 SIGHUP。sudo 由 `:177` `optimize_sudo_available` 与 `:432-436` 预检，未授权即 skipped。`source` 起点 `:164` 精确、无偏移，实止 `:206`（`:207` 空行、`:208` 为下一函数注释，尾多 2 行）；「VPN 判定 97-163」实止 `:155`（`:156-163` 是 `flush_dns_cache` 的注释头，尾多 8 行），非行号漂移。`default_selected:false` 按本 category 口径成立（`bin/optimize.sh:315-323` 串行跑全部目录项，catalog 末位 `true` 仅为自动执行安全值）。`risk:medium` 口径待定：`:429` 自标 `debug_risk_level "LOW"`。`action:command` 成立，`command` 文本为简化写法：`:191` `sudo dscacheutil -flushcache`、`:193` `sudo /bin/launchctl kill SIGHUP system/$service_label`（label 读自 plist，可能是 `.reloaded`），另有 `:202` 的 `killall -HUP` 回退。`needs_admin:true` 成立。`in_app:true` 不成立：`p1a-strings.json:624` 只是 `commands` 数组中的裸命令 `dscacheutil`，不是路径、与 `paths` 无同路径关系；`app/Sources` 亦无该命令串。 | `lib/optimize/tasks.sh:164-206,424-462`（rules 写 `164-208`、`97-163`；分别尾多 2/8 行，无偏移；`catalog.sh:40-42`；`bin/optimize.sh:315-323`） |

### optimize-02

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| optimize-02 | 不一致（`match`「需 sudo」、`needs_admin`、`in_app`） | `paths` 为机制描述，命中 `opt_cache_refresh`（`:209`）。`match` 两条成立：`:217-221` 三个 Finder 缓存目标（QuickLook.thumbnailcache / iconservices.store / iconservices），逐项 `:251 should_protect_path` → `:281 safe_remove`（永久 rm，经 `file_ops.sh:1816`）；catalog `:31-33` 以 `cache_refresh` 注册，`bin/optimize.sh:318-323` 遍历全部目录项调用 `:2132 "$handler"`，`catalog.sh:144-145` 要求 safe 值 `true`。**「需 sudo」不成立**：`:209-309` 无 `sudo`、未调 `optimize_sudo_available`，`qlmanage -r cache`/`-r`（`:233`/`:238`）与 `safe_remove` 段均不提权；`bin/optimize.sh:303-312` 的 `ensure_sudo_session` 是 optimize 全局前置，非本任务要求，故 `needs_admin:true` 无代码支撑。`source:209-315` 起点即函数签名、无行号偏移；函数实止 `:309`，`:310` 空行、`:311-314` 两条 Removed 注释（尾宽 6 行；tasks.sh 与 artifacts 字节相同、2134 行）。`default_selected:false` 按本 category 既有口径成立（clean 不调 optimize，`mo optimize` 串行跑全部项）。`action:command`、`command:null` 成立（外部 `qlmanage`）。`risk:medium` 口径待定：代码自标 `debug_risk_level "LOW"`（`:226`），仅删可再生缓存。`in_app:true` 不成立：本 id 无 `in_app_evidence`；p1a `:83` 的 `/Library/Caches/com.apple.iconservices.store` 与 `~/Library/...` 同 id 同后缀成立，但只覆盖 3 个目标中的 1 个，不足以支撑整条 true。 | `engine/lib/optimize/tasks.sh:209-309`（目标表 `:217-221`；`should_protect_path` `:251`；`safe_remove` `:281`；`qlmanage` `:233`/`:238`；risk `:226`；catalog `lib/optimize/catalog.sh:31-33`、`:144-145`；入口 `bin/optimize.sh:318-323`、全局 sudo `:303-312`；sink `lib/core/file_ops.sh:1816`、`:1538`、`:1665`） |

### optimize-03

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| optimize-03 | 不一致（`match`「需 sudo」分支、`needs_admin`） | `paths` 命中 `$HOME/Library/Saved Application State`（`tasks.sh:325`，函数 `:316`，catalog 注册 `catalog.sh:34-36`）。`source:316-380` 与 artifacts 逐字节一致、起点精确，无行号偏移（函数实止 `:373`，尾宽为注释，不计偏移）。`match`「需 sudo 的分支与用户分支分开」不成立：段内无 `sudo`、未调 `optimize_sudo_available`，清理仅 `should_protect_path :349` → `safe_remove :353`（永久 rm，经 `file_ops.sh:1816`），故 `needs_admin:true` 无代码支撑；`bin/optimize.sh:303-312` 的 `ensure_sudo_session` 是 optimize 全局前置，非本任务要求。`default_selected:false`、`action:command`、`command:null` 成立（catalog safe=true 串行自动执行，`find` 为外部命令）。`risk:medium` 口径待定：代码自标 `LOW`（`:322`，删可再生旧 `*.savedState`）。`in_app:unknown` 成立：本条无 `in_app_evidence`，p1a 亦无同路径字符串。 | `engine/lib/optimize/tasks.sh:316-373`（`state_dir :325`、risk `:322`、`should_protect_path :349`、`safe_remove :353`；catalog `lib/optimize/catalog.sh:34-36`；入口 `bin/optimize.sh:318-323`、全局 sudo `:303-312`；sink `lib/core/file_ops.sh:1816`） |

<!-- optimize 追加点 -->

## category: homebrew（5 条）

### homebrew-01

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| homebrew-01 | OK | `paths` 精确命中：`dev.sh:6322` `safe_clean ~/Library/Caches/Homebrew/downloads/* "Homebrew cache"`。`match` 成立：`:6318-6320`/`:6323-6327` 注释明示只清 downloads，api/bootsnap/lock 明确不扫，全仓再无其他 Homebrew 缓存清扫（`:6328 clean_homebrew` 走 `brew cleanup --prune=30`，`brew.sh:357`）。`*.incomplete` 仍在该 glob 内，但由 OP-03 `_mole_is_incomplete_download_path`（`file_ops.sh:289-302`，`:297-298` 指 brew downloads）在 `:1325`/`:1429`/`:1714` 判定打开句柄，非结论性空闲即保留。`source:6318-6327` 与 engine 完全对齐（`dev.sh` 与 artifacts 字节相同、sha256 一致），无偏移。`default_selected:true`：`bin/clean.sh:2120` 在 `run_clean_sections`（`:2059`/`:2178`）内无条件调用，无 y/n；仅 `MOLE_SELECTION_FILE`（`base.sh:605-609`、`clean.sh:1178`）可外部收窄。`action:delete`：`safe_clean`→`safe_remove`→`file_ops.sh:1816` `rm -rf`，永久删除无回收站。`needs_admin:false`：`1478-1720` 段无 sudo（`safe_sudo_remove:2245` 不在此链）。`risk:low` 合理（纯可重下缓存，句柄保护在；口径待定）。`in_app:true`：`p1a:63` 为 `/Library/Caches/Homebrew/downloads`，与 `paths` 同 id 同后缀；`:286` `/usr/local/bin/brew` 佐证工具存在。 | `lib/clean/dev.sh:6318-6327`（`paths` `:6322`；注释 `:6318-6320`/`:6323-6327`；`default_selected` `bin/clean.sh:2120`；`action` `file_ops.sh:1816`；OP-03 `file_ops.sh:289-302`） |

### homebrew-02

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| homebrew-02 | OK | `brew.sh` 与 artifacts 字节相同（652 行），`source:99-116,295-416` 覆盖 `brew_cleanup_ran_recently`（99-115）与 `clean_homebrew`（295-415），行号无偏移；两段末行各多含 1 行（116 空行、416 属下一节 `clean_homebrew_service_logs` 注释），仅区间略宽。`match` 全部成立：白名单命中即跳过 `$HOME/Library/Caches/Homebrew`（:302 dry-run / :339 实跑），7 天窗口 `brew_cleanup_ran_recently` 跳过（:110，调用 :306/:345），超时/失败只提示手动执行（:316/:390/:404），dry-run 为 `brew cleanup --prune=30 --dry-run`（:49）。`action:command` 对应 :357 `brew cleanup --prune=30`；`paths` 的 Cellar/Caskroom/下载缓存由该命令自身覆盖，`/usr/local/*` 另见 homebrew-05（`file_ops.sh:1048-1053`）。`default_selected:true`：`clean_developer_tools`（`dev.sh:6281`）→ :6328 无条件调用，无 y/n。`needs_admin:false`：唯一 `sudo` 在 :151（仅恢复链接），cleanup 路径不经 sudo。`risk:low` 口径待定：永久删除 30 天以上旧版本，但无 sudo、不碰用户数据，可接受。`in_app:true`：p1a-strings:63 `/Library/Caches/Homebrew/downloads`、:286 `/usr/local/bin/brew` 与 `paths` 同后缀/同工具，按同路径口径算支持。 | `lib/clean/brew.sh:99-115`、`:295-415`（命令 :357；dry-run :49；白名单 :302/:339；7 天窗口 :110/:306/:345）；默认调用 `lib/clean/dev.sh:6328` ← `bin/clean.sh:2120` |

### homebrew-03

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| homebrew-03 | OK | `brew.sh` 与 artifacts 字节相同（652 行），`source:417-650` 起点为段注释，终点差末行 `}`（:651），行号无偏移。`paths` 成立：根 = `brew --prefix` 物理化 + `/var/log`（:444-461，根本身或其 `var` 为链接即返回），实际扫 `-mindepth 1 -maxdepth 2 -type f -links 1 -user` 且 `*.log`/`*.log.*`、`-mtime +7`（:603-606，保留期见 `base.sh:159`）；规则 `*.log` 略窄，实含 `.log.N(.gz)` 与一层子目录。`match` 成立：名字闸 `*.log`/`*.log.gz`/`.log.N(.gz)`（:434-441）、元数据复检 :465-497、句柄预过滤 :624-643，guard 在 sink 前再复检元数据与打开句柄并绑定身份（:552-583）；scan 失败（:607-613）与 open 态未知（:630-633）均整批保留。`default_selected:true`：`dev.sh:6330` 无条件调用 ← `clean.sh:2120`，无 y/n。`action:delete`：:647 `safe_clean_guarded`→`safe_remove`→`file_ops.sh:1816`。`needs_admin:false`：:588 `is_root_user && return 0`，全段无 `sudo`。`risk:low` 口径待定（7 天、单链接、用户属主，但永久删）。`in_app:unknown` 且无 `in_app_evidence`，p1a 无 `<prefix>/var/log` 同后缀串，unknown 成立。 | `lib/clean/brew.sh:417-650`（函数 :434-651，尾差 1 行 `}`）；调用 `lib/clean/dev.sh:6330` ← `bin/clean.sh:2120` |

### homebrew-04

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| homebrew-04 | OK | `lib/clean/brew.sh` 与 artifacts 字节相同（sha256 `80498cdd…`，652 行），行号无偏移。`source:11-40` 精确覆盖 `brew_autoremove_preview_has_items`（11-15）与 `show_brew_autoremove_preview`（20-40），即「候选识别 + 提示行」；`117-126` 起于 `run_brew_autoremove_preview`（117-123），124 空行、125-126 属下个函数注释，区间略宽。`match` 成立：唯一执行是 `brew autoremove --dry-run`（:122，调用 :327 dry-run / :397 实跑），只 `echo` 一行 `ICON_REVIEW`「remove with brew autoremove」（:39）；clean 路径无裸 `brew autoremove`（仅 uninstall/batch.sh:3652），且 cleanup 带 `HOMEBREW_NO_AUTOREMOVE=1`（:48/:356）抑制隐式 autoremove。`paths` 为描述性标签（与 homebrew-02 同风格），候选由 dry-run 输出 awk 取 formula 名（:26），无固定路径。`default_selected:false` 成立：只预览、不选中删除；`clean_homebrew` ← `dev.sh:6328` ← `clean.sh:2120`。`action:command` 与 `command`（仅提示）一致；`needs_admin:false`（:151 的 `sudo -u` 只用于恢复链接）。`risk:medium` 口径待定：引擎不删，真人执行 `brew autoremove` 不可逆。`in_app:unknown` 自洽：无 `in_app_evidence`，p1a 无 `unused dependencies` 串，`/opt/homebrew`、`/usr/local/bin/brew` 仅为工具路径。 | `lib/clean/brew.sh:11-40`（候选解析 `:22-26`、提示行 `:39`）；`:117-123`（`source` 尾 124-126 略宽）；预览调用 `:327`/`:397`；`HOMEBREW_NO_AUTOREMOVE` `:48`/`:356`；默认调用 `lib/clean/dev.sh:6328` ← `bin/clean.sh:2120` |

### homebrew-05

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| homebrew-05 | 不一致（`action` 与代码相反、`match` 与 `paths` 错配） | `source:1048-1053` 精确命中（1048-1050 注释、1051 豁免臂、1053 `;;`），`file_ops.sh` 该区间与 artifacts 字节相同，行号无偏移。但 `paths` 六条与 `match` 错配：`/usr/local/Caskroom`、`/usr/local/cellar`、`/usr/local/opt`、`/opt/homebrew/{Caskroom,cellar,opt}` 全部落在 `:1051 /usr/local/* \| /opt/homebrew/*` → `return 1`（可删）的正常臂内；真正「根不可删」的是 `/usr/local`（`:1058 /usr/*`）与 `/opt/homebrew`（`:1068` deny 臂 + `:1101 exact_roots` inode 比对），这两个根本身并不在 `paths` 里。`match` 后半「子项仅由 Homebrew 清理」亦不成立：全仓无针对这三目录的 `safe_clean`/`safe_remove`/`rm`，仅 `apps.sh:580-581` 把它们当已装应用扫描路径、`:1627` 把 `:/opt/homebrew/opt/*/bin` 当包管理路径豁免孤儿判定。`action:"delete"` 反向：`N-01` 只作为 `validate_path_for_deletion` 的拒删入口出现（`:1367-1369` `log_error` + `return 1`），引擎从不删除这些目录，应改 `protect`。`default_selected:false` 成立（无删除候选）；`needs_admin:false` 成立（纯字符串 + inode 判定，无 sudo）。`risk:high` 口径待定：条目本身无删除动作，但若按 `delete` 字面实现会破坏 brew 安装树。`in_app:true` 偏松：`p1a:421 /opt/homebrew/` → `:422 /opt/homebrew/Caskroom` 同 id 且末两段相同，按该口径可算支持；但 `:290` 为 `cellar/`（与 `cellar` 拼写不同），且这些是绝对系统路径、非 `~/Library` 式主目录后缀，严格按目录 id 应为 unknown。 | `lib/core/file_ops.sh:1048-1053`（豁免臂 `:1051`；根保护 `:1058`/`:1068`/`:1101`；拒删入口 `:1367-1369`）；`lib/clean/apps.sh:580-581`、`:1627`；`report/p1a-strings.json:421-422`、`:290` |

<!-- homebrew 追加点 -->

## category: system（10 条）

### system-01

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| system-01 | OK | `paths`：三条全中——`:281` 恒传 `*.cache` + `:276` 恒定 `*.tmp`；`*.log` 在 `MOLE_LOG_AGE_DAYS == MOLE_TEMP_FILE_AGE_DAYS`（`base.sh:154/159` 均 7）时由 `:277-278` 并入同一遍，否则 `:294-299` 单扫，与括注一致。`match`：`:281` 传 `"f" "5"`（type f、maxdepth 5）✅；年龄 7 天 ✅；`:272` 120s 段预算、`:314-317` 耗尽即 return ✅；超时 `file_ops.sh:3686/3702` 返回 124，`system.sh:283-285` 只报 incomplete，`file_ops.sh:3789` 注释明确“扫描未完成不进入删除循环”→未知即保留 ✅。`source:267-318` 起点即函数头 `:267`，`:318` 已是下一段注释（仅尾 +1 行，非漂移）。`default_selected:true` 受 `SYSTEM_CLEAN` 门控（`clean.sh:33` 初值 false、`:1867` 需 sudo、`:2069-2071` 调用），与 `needs_admin:true` 自洽。`action:delete`＝sudo 批删 `/bin/rm -f`（`file_ops.sh:4006`），非废纸篓；`needs_admin:true` 由 `file_ops.sh:3678` 的 `sudo -n true` 探测佐证。`risk:high` 口径待定（永久删但均为可再生缓存，偏高）。`in_app`：`p1a:45` 同 id 同后缀 `Library/Caches`，支持 true；`:52` ChatGPTHelper 不匹配 `*.cache`，仅弱证据。 | `lib/clean/system.sh:267-318`（无偏移；sink `:281`/`:297`；调用点 `clean.sh:2071`） |

### system-05

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| system-05 | 不一致（仅 `in_app`） | `paths` 命中 `system.sh:458` 的 `/Applications/Install\ macOS*.app`（glob 一级匹配）。`match` 五条均成立：`:236`/`:260` `pgrep -f "$path"` 判空闲；`:229` `(now-mtime)/86400 ≥ 14`；`:238-248` `DTPlatformVersion` 主版本 `!=` 当前 `sw_vers`（`:450-452`）；`:180-210` 校验 `CFBundleIdentifier` 为 `com.apple.InstallAssistant[.x]` 且 `codesign --verify -R='anchor apple'`；`:463` 版本读不出即 `break` 全保留。`:519-531` 在 size 探测后、`:534 safe_sudo_remove` 前以 `:261` 的 `stat -f%d:%i:%m` 复核身份。`source` 起点 `:150` 即 `macos_installer_candidate_identity` 函数头、`:549` 为 installer 循环 `done`，覆盖 `:434-549`，无偏移。`default_selected` 成立但受 `SYSTEM_CLEAN` 门控（`clean.sh:33` 初值 false；`:1854`/`:1867` 需 sudo 缓存；`:2069-2071` 调 `clean_deep_system`）。`risk:high` 口径待定（整包永久 `sudo rm -rf`）；`action:delete`、`needs_admin:true` 成立（`safe_sudo_remove` `file_ops.sh:2014`）。`in_app`：`in_app_evidence` 的 `/usr/sbin/installer` 是命令而非 `paths` 同路径（`p1a-strings.json` 无 `Install macOS`/`Applications/Install` 串），App 侧无 installer 清理实现，应改 `false`。 | `lib/clean/system.sh:150-266,434-549`（无偏移；sink `:534`→`file_ops.sh:2014`） |

### system-06

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| system-06 | OK | `paths` 唯一项 `/Library/Caches/com.apple.iconservices.store` 与 `system.sh:583-585` 数组元素逐字相同。`match` 三要素均成立：`:595-598` 先 `sudo -n test -e` 探测（`_mole_bounded_sudo`，`file_ops.sh:56-72`），rc≠0 时 `:607 continue` 跳过；`:609 safe_sudo_remove` 处理命中项；「仅 sudo 会话可用」由整段 `SYSTEM_CLEAN` 门控保证（`clean.sh:33` 初值 false，`:1854`/`:1867` 需 `adopt_sudo_session`，`:2069-2071` 才调 `clean_deep_system`）。`source:580-626` 起点即本块 `start_section_spinner`，覆盖数组、探测、删除与计数；尾端 627-632 的成功日志/状态上报未含，属区间偏窄非偏移。`default_selected:true` 成立（`:2071` 无条件 `_run_cleanup_step`，无 y/n）。`action:delete` 成立（`file_ops.sh:2245` `sudo -n rm -rf`，非废纸篓）；`needs_admin:true` 由 `:596`/`file_ops.sh:2029` 校验 + `:2245` sudo 佐证。`risk:medium` 口径待定（系统级不可恢复删除，但 iconservices 可再生）。`in_app:true` 成立：p1a 同行同 id 同后缀，`/Library/...` 即 App 拼在 `$HOME` 后的 `~/Library/...`。`protected_by` 为空可接受：仅过 `is_path_whitelisted`（`file_ops.sh:2048`）与 `holds_compiled_model_cache`（`:2056`）通用闸。 | `lib/clean/system.sh:580-626`（无偏移；paths `:583-585`、探测 `:595-598`、跳过 `:607`、sink `:609`→`lib/core/file_ops.sh:2014`/`:2245`；入口 `bin/clean.sh:2071`） |

### system-07

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| system-07 | 行号偏移（`source` 第二段） | `paths` 为判定面描述、无字面路径，实际目标由 `find /private/var/folders -maxdepth 8` 取 `*/C/*/{com.apple.gpuarchiver,com.apple.metal,com.apple.metalfe}`（`:651-658`；helper `:16-26` 另含 `/var/folders` 六条 glob），可接受但未列叶名。`match` 两段成立：`:666 is_rebuildable_gpu_cache_dir` 只认 `C/` 分片；`:673 gpu_cache_dir_is_stale` 以目录内文件 mtime 判陈旧、默认 1 天（`:32`、`base.sh:162`），符号链接或探测超时即保留（`:34-35`、`:46-49`）；`:669-671 is_endpoint_security_cache_path`（`app_protection.sh:271`）跳过 EDR，与 P-06 一致。`source` 首段 `9-57` 覆盖两个 helper（止 `:52`）；第二段声明 `627-700`，实际 GPU 块起于 `:638`（`:627` 仍是上一段 `fi`）、止于 `:710` 成功日志，首尾各偏约 10 行。`default_selected:true` 受 `SYSTEM_CLEAN` 门控（`clean.sh:33`/`:1854`/`:1867`/`:2071`），同 system-06。`action:delete`＝`:683 safe_sudo_remove`→`file_ops.sh:2014`/`:2245` 的 `sudo -n rm -rf`，非废纸篓；`needs_admin:true` 由 sudo 佐证；`risk:medium` 口径待定。`in_app:unknown` 自洽：无 `in_app_evidence`，p1a 全文无 gpuarchiver/metal 串，非「同 id 同后缀」。 | `lib/clean/system.sh:9-52,638-710`（无偏移；`paths`/`match` 见 `:16-26`/`:651-658`/`:666`/`:669-671`/`:673`；sink `:683`→`lib/core/file_ops.sh:2014`/`:2245`；入口 `bin/clean.sh:2071`） |

### system-08

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| system-08 | 不一致（仅 `needs_admin`） | `paths` 为判定面而非字面路径，与代码相符：目标是 `getconf DARWIN_USER_DIR` 下 `$root/<id>.code_sign_clone/code_sign_clone.XXXXXX`（`browser_clones.sh:4-12`、`:128`），故 `paths` 只能描述判定面，可接受。`match` 成立：固定 id 白名单 15 项只含 Chrome/Chromium/Helium/Brave/Edge/ego lite（`:124-127`），快照再校验叶子正则 `:71`、属主 `:79`、单一 app bundle 与 `lsof` 空闲；EDR/MDM 代理 clone 因不在 id 表首轮即被排除，P-06 在 sink 经 `should_protect_path`→`is_endpoint_security_cache_path`（`app_protection.sh:406`/`:523`）兜底。`source:561-574` 首尾精确（spinner→`log_success` 的 `fi`），`system.sh` 与 artifacts 字节相同，无偏移。`default_selected:true` 受 `SYSTEM_CLEAN` 门控（`clean.sh:33`/`:2069-2071`），无 y/n 询问。`action:delete` 成立：`safe_remove`→`rm -rf`（`file_ops.sh:1816/1818`，非废纸篓）；`risk:medium` 口径待定。**`needs_admin:true` 不成立**：本函数与 `safe_remove`（`file_ops.sh:1478-1869`）全段无 `sudo`，目标属当前 uid（`browser_clones.sh:79`），按 P1b「走 `safe_sudo_*`/`sudo`」口径应为 `false`；sudo 仅为 `SYSTEM_CLEAN` 的段级前置。`in_app:false` 成立：无 `in_app_evidence`，p1a 无同名同后缀项。 | `engine/lib/clean/system.sh:561-574`（无偏移；调用 `:564`；入口 `bin/clean.sh:2069-2071`）；实现 `lib/core/browser_clones.sh:117-148`（根 `:4-12`、白名单 `:124-127`、快照 `:41`/`:71`/`:79`、sink `:142`→`lib/core/file_ops.sh:1478`/`:1816-1818`、P-06 `lib/core/app_protection.sh:523`） |

### system-09

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| system-09 | 不一致（`in_app`；兼 `source` 头部偏移） | `paths` 与代码相符：`:747-748` 的模式即 `CFNetworkDownload_*.tmp`，目标取 `:730`/`:741`/`:747` 的 `idle_tmp_dir`。`match`：`:737` 以 `/private/var/folders -maxdepth 5 -type d -name com.apple.idleassetsd -path "*/T/*"` 定位；`:748` 传 `"f" "5"`（`file_ops.sh:3762` `-maxdepth 5`），年龄取 `MOLE_TEMP_FILE_AGE_DAYS`=7（`base.sh:154`，`-mtime +7`）；无进程级空闲判定，仅按 mtime 判「空闲」。`sudo` 成立：扫描 `:736`→`file_ops.sh:3574-3578` `sudo -n find`，删除走 `file_ops.sh:4006` 的 `/bin/rm -f`（前置 `:3995` 起 `_mole_bounded_sudo` 批删），故 `needs_admin:true`。`source` 声明 `701-770`，实际块起 `:716`（`:701-715` 仍是 system-07 的 GPU 收尾），起点偏 +15；尾 `:770` 只差成功日志 3 行（`:771-773`），可忽略。`default_selected:true` 受 `SYSTEM_CLEAN` 门控（`clean.sh:33`/`:1867`/`:2069-2071`），无 y/n。`action:delete` 为永久删、非废纸篓；`risk:medium` 口径待定。`in_app:true` 不成立：`in_app_evidence` 为 `/Library/Caches/com.apple.nsurlsessiond/Downloads/`，后缀是 nsurlsessiond 而非 idleassetsd/`CFNetworkDownload_*.tmp`，按「同 id 同后缀」即便读作 `~/Library/...` 也不支持。 | `lib/clean/system.sh:716-776`（与 artifacts 字节相同，无偏移；sink `:747-748`；入口 `bin/clean.sh:2071`） |

### system-11

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| system-11 | 行号偏移（`source`；其余 OK） | `paths` 与 `:827` 的 `safe_sudo_find_delete "/private/var/db/powerlog" "*"` 相符（`*` 走全名匹配，`-maxdepth 5 -type f`，实际递归到第 5 层，非仅一级）。`match` 成立：`:827` 传 `$MOLE_LOG_AGE_DAYS`（`base.sh:159`=7）→ `file_ops.sh:3786` `-mtime +7`；OP-02 由 `file_ops.sh:169-188` 的 `_mole_is_active_powerlog_database_path`（`<root>/*/Current*`，大小写折叠、per store 一层）落实，批删循环 `:3845` 与 `validate_path_for_deletion` `:1286` 双闸，全 engine 无 vacuum/truncate；Archived* 照常按龄入选。`source` 声明 `811-860`，但 `:811-812` 仍是 system-10 诊断段尾，`:825` 才起 `start_section_spinner "Cleaning power logs..."`，`:850` 已进 memory exception 段，实际块 `:825-849`。`default_selected:true` 受 `SYSTEM_CLEAN` 门控（`clean.sh:33`/`:1867`/`:2069-2071`），无 y/n。`needs_admin:true` 由 `:3679` `sudo -n true` 探测、`:3578` `sudo -n find` 与 `:4006` 的 `/bin/rm -f` 佐证；`action:delete` 为永久删、非废纸篓。`risk:high` 口径待定（同为 sudo 批删，system-10 标 medium）。`in_app:unknown` 自洽：p1a 只有 `/private/var/db/`（`:441`）等父前缀，无 powerlog 同 id 同后缀。 | `lib/clean/system.sh:825-849`（相对声明起点 +14、尾越 11 行；sink `:827`→`lib/core/file_ops.sh:3608`/`:3786`/`:3845`/`:4006`；OP-02 `:169-188`/`:1286`；入口 `bin/clean.sh:2071`） |

### system-12

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| system-12 | 行号偏移（仅 `source` 起点 +11；其余 OK） | `paths`：`:851` 即 `/private/var/db/reportmemoryexception/MemoryLimitViolations`，`:886` 以 `"*"` 全名匹配，与规则一致（`paths` 的 `/*` 为通配写法，实际 `-maxdepth 5` 递归）。`match`：`:886` 传 `"30" "f" "5"` → `file_ops.sh:3762` `-maxdepth 5`、`:3786` `-mtime +30`，两要素逐字成立；`:861` 起 120s 段预算，超时只在 `:888-891`/`:912-913` 报 incomplete 不删。`source` 声明 `861-920`，实际块首为 `:850`（spinner），且 `:851` 才是 paths 声明，起点 +11；尾 `:920` 是函数 `}`（`return 0` 在 `:919`），建议改 `850-919`。`default_selected:true` 受 `SYSTEM_CLEAN` 门控（`clean.sh:33` 初值 false、`:1867` 需 sudo 会话、`:2069-2071` 调用），无 y/n 询问，与 `needs_admin:true` 自洽。`action:delete` ＝ `:886` → `file_ops.sh:4006` `/bin/rm -f` 永久批删、非废纸篓；`needs_admin:true` 由 `file_ops.sh:3679` `sudo -n true` 探测、`:3578` `sudo -n find`、`:4006` sudo 批删佐证。`risk:low` 口径待定（同为 sudo 永久删，system-11 标 high；此处对象为可再生的内存异常报告，low 可接受）。`in_app:true` 成立：`p1a:446` 与 `paths` 同 id 同后缀（仅少 `/*`）。 | `lib/clean/system.sh:850-919`（声明 861-920，起点 +11；paths `:851`、sink `:886`→`lib/core/file_ops.sh:3608`/`:3762`/`:3786`/`:4006`；入口 `bin/clean.sh:2069-2071`） |

### system-13

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| system-13 | 不一致（`needs_admin`；`source` 尾段截断） | `paths` 是判定面描述，与实现吻合：`system.sh:1097-1105` 在 `/Volumes/*/Backups.backupdb` 下 `find -maxdepth 3 -type d -name "*.inProgress" -o -name "*.inprogress"`，`:1232` 起再扫 `.backupbundle`/`.sparsebundle`。`match` 三句全中：`:1123` 取 `stat -f%d:%i:%m` 身份、`:1187-1198` 在 `tmutil` 前用 `time_machine_candidate_still_eligible`（`:934`）复核身份+48h 窗口（`base.sh:163`）；`:1022-1028` `tm_is_running` 三态，running/unknown 一律跳过并打印 `:1032-1038`。`source` 起点精确（`:922`/`:934`/`:977`、`:1405`），但首段止于 `:1010`，函数实体实为 `:977-1401`，`:1017-1401`（tm_is_running 闸 + 删除循环）未覆盖，属区间截断而非位移（system.sh 与 artifacts 字节相同）。`default_selected:true` 成立且**不受** `SYSTEM_CLEAN` 门控（`clean.sh:2069-2074` 只含 deep_system/snapshots，`:2163-2165` 在门控外无条件调用）。`action:delete`＝`tmutil delete`（`:1204`、`:1356`），非 `rm`。`needs_admin:true` 无代码支撑：`:977-1401` 全段无 `sudo`，`tmutil` 以当前用户执行，失败仅提示「try manually with sudo」（`:1214`）。`risk:medium` 口径待定（仅删 48h 以上的中断备份，但备份数据不可恢复）。`in_app:true` 成立：`p1a:473` 同 id 同后缀 `com.apple.TimeMachine.plist`，引擎在同一函数 `:984` 读同串 `/Library/Preferences/com.apple.TimeMachine.plist`。 | `lib/clean/system.sh:922-976,977-1401,1405-1427`（无偏移；`source` 首段应改 `922-1401`；sink `:1204`/`:1356`；调用点 `bin/clean.sh:2164`） |

### system-15

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| system-15 | 不一致（`action` 应为 `protect`；其余 OK） | `paths` 两条在 `:427`/`:430` 各以绝对路径出现一次，`:424-426` 注释与 `match` 三句逐字对应（Software Update 拥有 + 年龄/进程/plist 无法证明 scan→delete 窗口内非活动）；`source:424-432` 正好覆盖注释 + 两个存在性守卫，system.sh 与 artifacts 字节相同、无偏移。`default_selected:false` 成立：两条从不进入候选，仅 `debug_log "Keeping ..."`。`needs_admin:false` 成立：块内无 `sudo`（仅所在 section 受 `SYSTEM_CLEAN` 门控，`bin/clean.sh:2069-2071`）。`risk:high` 口径待定：代码根本不删，属过度标注；但若真按 `action:delete` 实现则确为 high。`in_app:false` 成立：p1a 无同后缀串（仅 `UpdatesCoordinator`），且 `~/Library/Updates`（`user.sh:3328`）是另一对象。**`action:"delete"` 与代码相反：全段只做 `-d` 探测并记 "Keeping"，无 `rm`/`safe_remove`/`safe_sudo_find_delete`，应改 `protect`。** | `lib/clean/system.sh:424-432`（无偏移；paths `:427`/`:430`、函数 `clean_deep_system:267`、调用 `bin/clean.sh:2069-2071`） |

<!-- system 追加点 -->

## category: snapshots（1 条）

### system-14

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| system-14 | OK（`needs_admin` 仅模块级成立；`risk` 口径待定） | `paths` 是机制描述，命中 `system.sh:1466-1467` 的 `tmutil listlocalsnapshots /`；结果行交 `snapshots.sh:20-59` `mole_local_snapshot_rows`，`:52-58` 只 `mole_review_row` 输出，全文件无 `rm`/`safe_remove`/`safe_clean`/`unlink`/`sudo`（`:2-3` 注释「read-only: count and name, never size or delete」），`match`「只统计与提示、从不删除」成立。TM 行由 `:52` `include_tm` 门控，`system.sh:1441-1461` 仅在 `defaults read .../com.apple.TimeMachine AutoBackup` 命中 `^[01]$` 且 `tm_is_running`=1 时置 true（另要求备份未在跑，「确认配置」表述略窄，不单独改判）。网络卷：`snapshots.sh:77-100` 只读 `/sbin/mount`（`:63-65`），`system.sh:1434-1438` 非全 local 即 `return 0`，其前不调 tmutil，成立。`source:11-59`（头注释 `:12-19`+函数 `:20-59`）、`:63-100`（`_mole_mount_table:63-65`+`:77-100`）与 `secondary:1430-1479`（函数止 `:1479`）均精确；`snapshots.sh` 与 artifacts `diff` 退出 0、`system.sh`/`user.sh` `cmp` 相同，无行号偏移。`default_selected:false` 成立但需注：`bin/clean.sh:2069-2072` 在 System 段无条件调用、无 y/n，false 指「零删除、非默认删除项」（同 xcode-11 口径）；同一组行另见 `user.sh:3730-3759` 大文件报告。`action:command` 成立（`tmutil listlocalsnapshots`、`tmutil status` `:1413`、`defaults read` `:1442`）。`needs_admin:true` 仅模块级：`system.sh:2` 声明 requires sudo、`clean.sh:795-821` 先建 sudo 会话才置 `SYSTEM_CLEAN=true`，但快照两段本身零 `sudo`、不提权。`risk:high` 口径待定（纯只读报告，high 偏保守）。`in_app:unknown` 自洽：无 `in_app_evidence`，p1a 无同后缀快照路径串。 | `lib/clean/snapshots.sh:11-59,63-100`（无偏移；`mole_local_snapshot_rows:20-59`、输出 `:52-58`、`_mole_mount_table:63-65`、`mole_network_volume_mounted:77-100`）；`lib/clean/system.sh:1430-1479`（`clean_local_snapshots`；tmutil `:1466-1467`、`tmutil status` `:1413`、`defaults read` `:1442`、网络卷门 `:1434-1438`）；调用 `bin/clean.sh:2072`；同源行 `lib/clean/user.sh:3730-3759` |

<!-- snapshots 追加点 -->

## category: project（4 条）

### project-01

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| project-01 | 不一致（`match`：indicator 拼写、min_age 语义） | `paths` 34 项与 `MOLE_PURGE_TARGETS`（`purge_shared.sh:18-48`）逐条同序一致（`bin` 守卫 `:982-989`）。`match` 主体成立：项目根闸 `:1095`→`purge_shared.sh:163-180`、depth 1..6（`project.sh:19-20`/`:1158`）、剪枝 `.git/Library/.Trash/Applications`+dataless（`:1060`/`:1074`/`:1113`）、vendor/SwiftPM/占用判定（`:942-1031`，vendor `:990`、SwiftPM `:1018`）。两处不符：①indicator 表是 `build.zig.zon`（`purge_shared.sh:103`），`build.zig.build` 全 engine 0 命中；②`MIN_AGE_DAYS=7`（`project.sh:17`）只在 `classify_purge_activity`（`:1617`）把 7 天内改动判 recent，不是硬门槛，交互与非交互都仅排除 recent（`:1963-1964`/`:3533`），未见按天数过滤候选。`source` 17-105 精确覆盖 target/indicator 两表（`project.sh`、`purge_shared.sh` 与 artifacts 字节相同，无偏移）；`secondary` 942-1030 正落 `is_protected_purge_artifact`（942-1031），15-40 多为注释，1720-1754 偏早 1 行（实体止 `:1751`）。`default_selected:false` 成立（独立 `mo purge`，`bin/clean.sh` 不 source，且需 Enter 确认 `:2404`/`:2432`）；`action:delete`（`:3689 safe_remove`→`file_ops.sh:1816` 永久 rm）、`needs_admin:false`（`project.sh` 0 处 sudo）成立；`risk:high` 口径待定。`in_app:false` 自洽：p1a 仅 `/Library/Developer/Xcode/DerivedData`、`/Library/Caches/CocoaPods` 等库路径，无 `node_modules`/`target`/`Pods` 同 id 同后缀。 | `lib/clean/purge_shared.sh:17-105`（`MOLE_PURGE_TARGETS:18-48`、`MOLE_PURGE_PROJECT_INDICATORS:88-105`）；`lib/clean/project.sh:17`/`:19-20`、`:942-1031`、`:1060`/`:1074`/`:1113`、`:1095`、`:1963`/`:2404`、`:3689`（sink `lib/core/file_ops.sh:1816`） |

### project-02

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| project-02 | OK | `paths` 13 条与 `MOLE_PURGE_DEFAULT_SEARCH_PATHS`（`purge_shared.sh:55-75`）逐条同序一致（`$HOME` ≡ `~`，三条 agent 容器 `:72-74` 在列）。`match` 成立：可被 `~/.config/mole/purge_paths` 覆盖（`project.sh:25` 定义、`:207-281` 读取，`purge_shared.sh:326` 展开 `~`）；容器发现只 glob `"$HOME"/*/`（`project.sh:113`）、dot 目录由 `:48` 拒绝，故点目录只列三条 worktree 容器；worktree 本体不删见 `purge_shared.sh:71` 注释。`source` 恰为整个数组声明（`:55` 起、`:75` 为 `)`），与 artifacts 字节相同、无偏移；`secondary` `:98-148` 精确，`:207-283` 尾多 2 行（实体止 `:281`）。`default_selected:false` 成立：独立 `mo purge`（`clean.sh` 不 source），交互需 Enter 确认（`:2404`），非交互须 `--yes`（`:2430`）。`action:delete`（`:3689 safe_remove`→`file_ops.sh:1816` 永久 `rm -rf`）、`needs_admin:false`（两文件 0 处 `sudo`）成立；`risk:medium` 口径待定。`in_app:false` 成立：本规则无 `in_app_evidence` 字段（无锚点）；p1a:324 虽为 `/Library/CloudStorage` 同后缀，但该条是搜索根、非删除目标。 | `lib/clean/purge_shared.sh:55-75`（`:72-74` 容器）；`lib/clean/project.sh:25`、`:48`、`:98-148`、`:113`、`:207-283`、`:2404`/`:2430`、`:3689`（sink `lib/core/file_ops.sh:1816`）；`report/p1a-strings.json:324` |

### project-03

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| project-03 | 不一致（`match`：CACHEDIR.TAG 与 `.pytest_cache`/`.mypy_cache` 目标；另 `source` 区间偏差、`in_app` 无证据） | `paths` 两行是描述而非路径，实体为 `discover_project_cache_roots`（`caches.sh:254-345`：`$HOME/*/` 指示符 + `purge_paths`），可接受。`pycache_has_bytecode` 确认成立：`:373` 调用，`:348-363` 要求 `*.pyc/*.pyo`。但 `CACHEDIR.TAG`/`MOLE_CACHEDIR_TAG_SIGNATURE` 只在 `purge_shared.sh:107-108` 定义，`caches.sh` 0 处引用；`mole_dir_has_cachedir_tag` 仅服务 `project.sh:1222/1350` 的 purge 走查。清理面只有 `.next`/`__pycache__`/`.dart_tool`（`:419`），`.pytest_cache`/`.mypy_cache` 仅见于 `purge_shared.sh:25-26`。预算/prefetch/失败不删成立：`:401` 6s、`:440-450` 超时丢弃 scan+processed、`:1024-1080` 等 prefetch 或内联扫描、`:1313-1352` 非零 scan 只计 skipped 且释放临时文件。`source` 231-480 实止 `:477`，1024-1080 应为 1024-1081。`default_selected:true` 成立（`clean.sh:2120`→`dev.sh:6298`，无 y/n）；`action:delete`（`:970 safe_remove`→`file_ops.sh:1816` 永久 rm）、`needs_admin:false`（0 处 sudo）成立；`risk:medium` 口径待定。`in_app:unknown` 却无 `in_app_evidence`，无法按同 id 同后缀核对。 | `lib/clean/caches.sh:254-345`、`:348-363`、`:373`、`:401`、`:419`、`:440-450`、`:970`、`:1024-1081`、`:1313-1352`；`lib/clean/purge_shared.sh:25-26`、`:107-108`、`:276-284`；`lib/clean/project.sh:1222` |

### project-04

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| project-04 | 不一致（`match`：残留 purge 语义、受保护判定落在 scan 期；`in_app` 无证据） | `paths` 一行是描述，实体为 `clean_project_cache_target`（`caches.sh:765-807`）：先 `project_cache_has_tracked_files` 过滤（`:777`），再 `safe_clean_guarded _project_cache_final_guard`（`:791`），另有非 guarded 兜底 `safe_remove`（`:802`）。`match` 五项里只有「扫描根身份」真在 `:725-763` 内：`:730` 目标快照 + `:759-762` 绑定；`:729` 存在/非符号链；`:733-742` Git 祖先与 tracked 复核；`:743-749` 嵌套仓库。**残留 purge 语义**：`is_safe_configured_purge_artifact`（`project.sh:427`）在本 guard 内 0 处调用，实际挂在 purge 的 `_mole_purge_final_remove_guard`（`project.sh:1722-1725`）；`purge_target_activity_still_safe`（`:1726`）同理。本路径的受保护判定在 scan 期（`:930`/`:937`），`:957` 处只有身份，`source` 区间内无「未受保护」复检。`default_selected:false` 不成立：`dev.sh:6298` 无条件执行，`clean.sh:1883` 无 y/n → 实为 true。`action:delete`（`:970`→`file_ops.sh:1816` 永久 rm）、`needs_admin:false`（`caches.sh` 0 处 sudo）成立；`risk:high` 口径待定。`in_app:false` 无 `in_app_evidence` 可对；p1a 无 `.next`/`__pycache__`/`.dart_tool` 同 id 同后缀。 | `lib/clean/caches.sh:765-807`（`:777`/`:791`/`:802`、守卫 `:729-762`）、`:930`/`:937`/`:957`/`:970`；`lib/clean/project.sh:427`、`:1722-1726`；`lib/clean/dev.sh:6298`；`bin/clean.sh:1883`（sink `lib/core/file_ops.sh:1816`） |

<!-- project 追加点 -->

## category: installer（2 条）

### installer-01

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| installer-01 | 不一致（`paths` 范围与后缀不符、`source` 首段非代码、`in_app` 证据路径不存在） | `paths` 的 `~/Desktop/**`、`~/Documents/**` 不成立：`INSTALLER_SCAN_PATHS`（`:40-53`）虽含这两目录，但 `:143-155` 只收 `*.dmg/*.pkg/*.mpkg/*.iso/*.xip/*.zip` 且 `--max-depth 2`，并非任意文件；代码另扫 `~/Public`、`/Users/Shared(/Downloads)`、`~/Library/Downloads`、`~/Library/Caches/Homebrew`、iCloud/Mail Downloads/Telegram 共 7 处，`paths` 未列。`match`：zip 需 `is_installer_zip`（`:72-91`，前 50 项含 `.app\|pkg\|dmg\|xip`）成立；`mole_delete`+planned identity（`:719-733`、`:775`）成立；「按年龄与体积分类」不成立——`:309-352` 仅 `sort -zu` 去重排序、`:373` 仅取体积，全文无 mtime/年龄参与。`source`：`1-3` 是 shebang/注释；`134-227` 内 `:136-142` 为另一辅助函数，扫描函数实为 `:143-206`、`:208-210`，删除函数实为 `:719-735`（`execute_installer_delete_plan` 起于 `:737`）。`default_selected:false` 成立（`:468` 全不选，需勾选+`Enter` 确认）；`action:delete` 成立（`MOLE_DELETE_MODE` 默认 permanent）；`needs_admin:false` 成立（传 `false`，`:9-13` 禁 root）；`risk:medium` 口径待定（安装包可再生但为永久删除）。`in_app:true`：`p1a-strings.json:56-58` 实为 `/Library/Caches/*`，不存在 NS*FolderUsage 串；真实证据在 `P1a-inventory.md:56` 与 `app/scripts/build-app.sh:128-133`，非 p1a 同路径，故不支持。 | `engine/bin/installer.sh:40-53`（扫描根）、`:143-155`（后缀过滤）、`:309-352`（去重排序）、`:719-735`/`:775`（删除计划/mole_delete）、`:468`（默认不选）；`app/scripts/build-app.sh:128-133`；`report/P1a-inventory.md:56` |

### installer-02

| id | 结论 | 说明 | 实际源码位置 |
|---|---|---|---|
| installer-02 | 不一致（仅 `in_app` 无证据，其余 OK） | `paths` 不是文件路径而是流程描述，对应 `execute_installer_delete_plan`（`:737-795`），落在区间内。`match` 五项全中：逐文件 plan `:702-735`；plan identity 由 `mole_deletion_identity` 取得并存入数组 `:720-731`；删除时 `:775` `mole_delete "$file_path" false "$planned_identity"`（`file_ops.sh:2409/2412` 第三参即 expected_identity）；失败由 `:684-690` 记入数组并累加 `total_delete_failed`，各分支 `continue` 不中断（仅 timeout/signal 上抛）；dry-run 于 `:776-778` 仅记成功、`file_ops.sh:2575` 只记录不删。`default_selected:false` 成立（`:466-469` 全部不选、`:807-809` 无选中即返回，且删除还需 `Enter` 确认）。`action:delete` 成立（`file_ops.sh:2415` 默认 permanent）；`needs_admin:false` 成立（传 `false`，`:9-13` 禁 root）；`risk:medium` 口径待定（安装包可再生但为永久删除、无回收站）。`source` 无偏移：installer.sh 与 artifacts 字节相同；区间 671 起于 `reset_installer_delete_results`、止于 797 注释行，未含 798 起的调用方。`in_app`：该条无 `in_app_evidence` 键，`paths` 亦非路径，无 `/Library/...` 同 id 同后缀串可对应，故不支持。 | `engine/bin/installer.sh:671-797`（`:702-735`、`:737-795`）、`:684-690`、`:775`；`engine/lib/core/file_ops.sh:2409-2415`、`:2575` |

<!-- installer 追加点 -->

## 3. 进度（按 rules.json 出现顺序）

| # | category | 条数 | 状态 |
|---:|---|---:|---|
| 1 | trash | 2 | ✅ 已完成（2 / 2） |
| 2 | user_cache | 32 | ✅ 已完成（32 / 32） |
| 3 | logs | 7 | ✅ 已完成（7 / 7） |
| 4 | app_leftovers | 6 | ✅ 已完成（6 / 6） |
| 5 | browser | 20 | ✅ 已完成（20 / 20） |
| 6 | dev_tools | 30 | ✅ 已完成（30 / 30） |
| 7 | ai_tools | 20 | ✅ 已完成（20 / 20） |
| 8 | xcode | 11 | ✅ 已完成（11 / 11） |
| 9 | homebrew | 5 | ✅ 已完成（5 / 5） |
| 10 | system | 10 | ✅ 已完成（10 / 10） |
| 11 | snapshots | 1 | ✅ 已完成（1 / 1） |
| 12 | project | 4 | ✅ 已完成（4 / 4） |
| 13 | installer | 2 | ✅ 已完成（2 / 2） |
| 14 | optimize | 19 | ✅ 已完成（19 / 19） |
| | **合计** | **169** | 已完成 169 / 169 |

下一条：无，任务 A 完成
