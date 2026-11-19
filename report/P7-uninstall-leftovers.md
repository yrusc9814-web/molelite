# 卸载残留复核

范围：`engine/lib/uninstall/` 与 `engine/lib/core/app_protection.sh` 的残留发现、分类、删除链路。只读核对，未改 `engine/`、`app/`、`rules.json`，未删文件、未跑测试。引用均为相对 `engine/` 的 `文件:行号`；`AP` = `lib/core/app_protection.sh`，`B` = `lib/uninstall/batch.sh`。

**判定口径（先说清，后文按此定级）**

- 残留发现分两条互不相通的链路：
  1. **可删链路**：`find_app_files`（`AP:1319-2270`）→ `related_files` → `review.sh` 分类 → `remove_file_list`（`B:770`（定义））。这是唯一会真正删除残留的路径。
  2. **只读链路**：`find_app_system_files`（`AP:2273-2554`，含 `/Library`、`/Users/Shared`、`/private/var/db/receipts`）与系统诊断报告。其产物在预览前被整批搬进 `review_only_system_files`，随后 `system_files`/`diag_system` 被清空（`B:2344-2353`），执行阶段拿空串（`B:2645`、`B:3082-3092`）。**本仓库 CLI 下这些路径只展示、不删除**。
- `related_files` 还会被 `review.sh` 再分两层：`~/Library/Caches/*`、`~/Library/Logs/*` 判为 disposable，**无需确认即自动删除**（`lib/uninstall/review.sh:13`、`:85-86`）；其余为 personal，默认**不选**，只有 `--with-data`（`bin/uninstall.sh:2430`，默认 0，`bin/uninstall.sh:2406`）预选或用户在 `D` 菜单手动勾选才进入删除（`lib/uninstall/review.sh:93-96`、`:110-135`）。
- 默认删除模式是 Trash（`bin/uninstall.sh:2404`，`MOLE_DELETE_MODE=trash`），`--permanent` 才不可恢复。
- 据此定级：
  - **高**：在常规流程（`--with-data` 预选即可，无需用户逐条辨认）会删到**别的应用/别的产品的真实用户数据**，且没有针对该误命中的归属检查；或落在 automatic 分支且内容是不可重建数据。
  - **中**：只删可重建缓存/日志；或路径被 holdback/需 `D` 菜单手动勾选；或存在守卫但守卫有明确缺口。
  - **低**：需要罕见命名/布局才可能发生；只影响预览误报；只导致漏删；或已被现有守卫实质挡住、仅剩理论缺口。

## 1. 搜索范围

| 目录 | 匹配依据 | 代码位置 | 是否需管理员 |
| --- | --- | --- | --- |
| `~/Library/{Application Support,Caches,Logs,Preferences}`、`Saved Application State`、`Services`、`QuickLook`、`Internet Plug-Ins`、`Audio/Plug-Ins/*`、`PreferencePanes`、`Input Methods`、`Screen Savers`、`Frameworks`、`Spotlight`、`Workflows`、`Mail/Bundles` 等 29 条 | **应用名**（磁盘 basename 去 `.app`，`B:2047-2048`）字面量 + 固定扩展名；门槛仅 `${#app_name}>=2`（`AP:1373`） | `AP:1374-1403` | 否 |
| `~/.config/<name>`、`~/.cache/<name>`、`~/.cache/<小写名>`、`~/.local/share/<name>` | **应用名**字面量/小写变体；无单独长度门槛，仅受 `AP:1373` 的 2 字符下限约束 | `AP:1397-1400` | 否 |
| `~/Library/{Application Support,Caches,Logs}/<bundle_id>`、`Containers/<id>`、`WebKit/<id>`、`HTTPStorages/<id>(.binarycookies)`、`Cookies/<id>.binarycookies`、`Application Scripts/<id>`、`Autosave Information/<id>`、`SyncedPreferences/<id>.plist`、`Caches/{com.plausiblelabs.crashreporter.data,com.crashlytics.data}/<id>`、`Caches/<id>.ShipIt`、`Application Support/com.bugsnag.Bugsnag/<id>`、`<darwin_user_cache_root>/<id>` | **bundle id** 字面量；必须先过反向 DNS 校验（`lib/core/base.sh:1227-1232`），`*`/`?`/`[`/空白/中文一律不生成 | `AP:1405-1438` | 否 |
| `~/Library/{Containers,Group Containers,Application Scripts,Application Support/FileProvider}` 的一级子目录 | **bundle id 点边界**：全等、`<id>.*` 前缀，或 `*.<id>`、`*.<id>.*` 后缀（`lib/core/base.sh:1242-1260`）。**不解析 Team ID**——`<TEAMID>.<id>` 只能靠后缀臂命中 | `AP:1661-1712` | 否 |
| `~/Library/Containers/<UUID>` | 目录名须为 UUID，且 `.com.apple.containermanagerd.metadata.plist` 的 `MCMMetadataIdentifier` **严格等于** bundle id | `AP:1714-1735`；删除前复检 `B:857-878` | 否 |
| `~/Library/Preferences/ByHost/*.plist` | **bundle id 前缀**：`<id>` 或 `<id>.*`，不校验后缀段是否为 UUID | `AP:1639-1657` | 否 |
| `~/Library/LaunchAgents/*.plist` | 先按 `<id>.plist`/`<id>.*.plist`；否则**应用名子串**（`>=5` 字符、非通用词），命中后必须由 `mole_uninstall_launch_agent_owned_by_app` 证明 plist 的 `Program`/`ProgramArguments.0` 落在所选 `.app` 内 | `AP:1827-1885`；归属 `AP:842-890` | 否 |
| `~/Library/{Application Support,Caches,Logs}/<vendor>/<product>` | **bundle id 倒数第二段**作 vendor（父目录必须严格相等），子目录按应用名变体/产品 token 边界匹配；应用名 `>=4`、非通用词 | `AP:1613-1630` → `AP:892-945`、`:776-793` | 否 |
| `~/Library/Application Support/CrashReporter/<name>_*.plist`、`<去空格名>_*.plist` | **应用名前缀 glob**（`_` 分隔），`nospace_name>=3` | `AP:2118-2131` | 否 |
| 工具链：`~/Library/Developer/Xcode/*`、`~/.Xcode`、`~/.android/{cache,build-cache,breakpad}`、`.../Google/AndroidStudio*`、`.../JetBrains/<name>*`、`Application Support/Godot`、`~/.vscode{,-insiders}`、`Application Support/Code{ - Insiders}`、`~/.docker/{buildx,scan}`、`~/.mobiledev`、`AnkiProgramFiles`、`Claude-3p`、`*raycast*` | **应用名/bundle id 子串正则**（多数未锚定）+ 固定字面路径；Xcode/Android/JetBrains 走前缀 glob + 版本叶校验；Raycast 走 `-iname "*raycast*"` 子串 | `AP:1894-2112`、`:1999-2028` | 否 |
| `~/Library/Logs/DiagnosticReports`（用户级） | 前缀 = `CFBundleExecutable`，读不到则去空格应用名；`>=3`；分隔符限 `.`/`_`/`-`，扩展名限 `.ips/.crash/.spin/.diag` | `AP:2203-2270` | 否 |
| `~/Applications/PlayCover/<alias>.app`、`<root>/{App Settings,Keymapping,Entitlements}/<id>*` | 精确 bundle id + 符号链接/Info.plist 归属核对 | `AP:2135-2156`、`:1197-1252` | 否 |
| `/Users/Shared/*`（仅一级） | **应用名变体前缀**（`<v>`、`<v> `、`<v>-`、`<v>_`、`<v>.`）或 bundle id 末段 product token；`/Users/Shared` 只经 `find_app_system_files`（`AP:2378`）→ **只读** | `AP:947-1024` | 否（个别目录可能属 root） |
| `/Library/{Application Support,Caches,Logs,Preferences,Frameworks,Internet Plug-Ins,Input Methods,Audio/Plug-Ins/*,QuickLook,PreferencePanes,Screen Savers,Extensions,StartupItems,Receipts,Logs}` + 应用名/bundle id；`/Library/{LaunchAgents,LaunchDaemons}/*<name>*.plist` | 字面量（无长度门槛）+ 系统 launchd **名字子串**（`>=5`、非通用词、跳过 `com.apple.*`）；只经 `find_app_system_files` → **只读** | `AP:2293-2356`、`:2394-2431` | 是（sudo），但本仓库不执行 |
| `/Library/PrivilegedHelperTools/*`、`/private/var/db/receipts/*`、`*.bom` 载荷 | bundle id 点边界 + 名字变体（每变体 `>=5`）；BOM 载荷再过 `receipt_payload_path_is_allowlisted` 四类白名单 → **只读** | `AP:2436-2525`、`:2560-2690` | 是（读取/删除），但本仓库只读 |
| `/opt/homebrew/Caskroom`、`/usr/local/Caskroom` | Caskroom 一级 token（`^[a-z0-9][a-z0-9-]*$`）+ `.app` basename **精确相等**；`brew info` 输出子串自证 | `lib/uninstall/brew.sh:68-74`、`:282-305`、`:354-414`、`:435-465` | 否（brew 自身可能要求权限） |
| Steam 启动器：`<app>.app/Contents/MacOS/*` | 首 2 字节 `#!`、脚本 ≤4096B、唯一有效行匹配 `open steam://run\|rungameid\|launch/<数字>`；**只影响展示，不删除** | `lib/uninstall/steam.sh:31-42`、`:61-93` | 否 |

## 2. 风险一：误删其他应用文件

只列**可删链路**（`find_app_files` → `related_files`）里能落到别的应用/别的产品数据的项。`find_app_system_files` 的 `/Library`、`/Users/Shared`、回执三类全部只读（`B:2344-2353`），统一收在 B1-21，不重复计风险。

| 编号 | 严重度 | 代码位置 | 例子：应用名 → 会命中的路径 | 有无后续守卫拦住（位置） | 建议 |
| --- | --- | --- | --- | --- | --- |
| B1-01 | 高 | 后缀表 `AP:1351-1352`；base 派生 `AP:1533-1544`；名字来源 `B:2047-2048`；删除过滤 `B:2338` | `Microsoft Edge.app`（`com.microsoft.edgemac`）→ base 被剥成 `Microsoft`，命中 `~/Library/Application Support/Microsoft`（Office/Teams/OneDrive 共享根）、`~/Library/Caches/Microsoft`、`~/Library/Logs/Microsoft`、`~/Library/Preferences/Microsoft.plist`、`~/.config/microsoft`、`~/.cache/microsoft`、`~/.local/share/microsoft` | **拦不住。** `should_protect_path` 无厂商根规则（`AP:406-683`）；`review.sh:44` 的 holdback 只覆盖 `$support/microsoft edge*`，不含 `microsoft`；`Caches/Logs` 走自动分支（`review.sh:13`）根本不过 holdback；`_mole_app_family_shared_leaves` 也因 `Edge Beta` 不在后缀表（`AP:1291-1302`）不生效 | 后缀表移出 `Edge/Dev/RC/Stable/Release/LTS` 这类产品词；base 派生加厂商根黑名单；`Application Support/<厂商>` 一律 holdback |
| B1-02 | 高 | `AP:1999-2001`；开关 `AP:1886-1890` | `Godot.app`（`org.godotengine.godot`）→ 整棵 `~/Library/Application Support/Godot`（`app_userdata/<project>` 是所有 Godot 游戏的存档、`export_templates`）；`MyGodotGame.app`（`com.example.mygodotgame`）也因 `=~ Godot\|godot` 未锚定而触发 | **无。** 只有 `[[ -d ]]`；family leaves 只处理同名兄弟（`AP:1291-1318`）；`should_protect_path` 无此路径；注释 `AP:1997-1998` 自己说 Unity/Epic 是共享根不能由单个 app 认领，Godot 自相矛盾 | 删除整根逻辑；若必须清，只收 `app_userdata/<与 bundle id/项目名对应>` 并读 `project.godot` 证明归属 |
| B1-03 | 高 | `AP:1661-1674`、`AP:1676-1712`；边界判定 `base.sh:1242-1260`；删除前只对 UUID 容器复检 `B:857-878` | 卸载 `Foo.app`（`com.acme.Foo`）→ 前缀臂 `<id>.*` 命中 `~/Library/Containers/com.acme.Foo.Bar`（同厂商另一个 `Foo Bar.app` 的沙盒数据）、`~/Library/Application Scripts/com.acme.Foo.helper`。`Com.apple.Foo` 的容器名不是 UUID，不走 MCM 复检 | **拦不住。** UUID 容器有 `MCMMetadataIdentifier` 校验（`AP:1083-1096`、`B:857-878`），bundle-id 命名的容器/脚本目录没有；`should_protect_path` 在 uninstall 模式跳过 `should_protect_data`（`AP:508`）；`review.sh` 的 holdback 只含 Whisky/UTM（`review.sh:34-36`），这类容器在 `--with-data` 下被预选 | `Containers`/`Application Scripts` 的 `<id>.*` 命中也要读容器 metadata；或要求下一段不能是另一个已安装 bundle 的独立段 |
| B1-04 | 中 | `AP:1661-1674`；holdback `review.sh:33` | 卸载 `Foo.app`（`com.acme.Foo`）→ `~/Library/Group Containers/ABCD1234.com.acme.Foo.shared`（`Foo Sync.app` 共用的 App Group）被后缀臂 `*.<id>.*` 命中 | **部分。** `review.sh:33` 把 `~/Library/Group Containers/*` 全部 holdback，`--with-data` 也不预选，只有用户在 `D` 菜单手动勾选才会删；但没有 group owner / entitlements 校验 | 读 App Group 的 `com.apple.security.application-groups` 或容器 metadata；Team ID 段必须与签名团队一致 |
| B1-05 | 高 | `AP:1374-1403`、`AP:1397-1400`；删除 `B:2338` | 名为 `Code.app`（`com.example.code`）的应用 → `~/Library/Application Support/Code`（Visual Studio Code 的 profile、snippets、globalStorage、workspaceStorage）、`~/Library/Caches/Code`、`~/Library/Preferences/Code.plist`；同理名为 `Microsoft.app`/`Adobe.app`/`Google.app` 的旧组件会整棵认领厂商根 | **拦不住。** 名字模板是字面拼接，没有“该目录是否属于别的 bundle”校验；`_path_belongs_to_independent_cli` 只有 4 个名字（`AP:1038-1066`）；`_mole_is_shared_home_state_root` 只挡 `.cache`/`.config` 根（`AP:347-364`）；`Application Support/Code` 不在 `review.sh` 的 holdback 里 | 对 `Application Support/<name>`、`Preferences/<name>.plist` 增加“是否被其他已装 bundle 声明”的核对；厂商根/常见产品目录加 holdback |
| B1-06 | 中 | `AP:1373`（`>=2`）、`AP:1375-1400` | `Go.app` → `~/.cache/go`、`~/.config/go`、`~/.local/share/go`（Go 工具链缓存/`go env` 配置）；`R.app` → `~/Library/Caches/R`（自动删）、`~/Library/Application Support/R`、`Preferences/R.plist`；`QQ.app` → `~/Library/Caches/QQ` | **部分。** `_mole_uninstall_is_common_app_name`（`AP:747-760`）不含 go/r/qq，且只用于 SentryCrash/updater 分支；CLI 白名单只 4 名；XDG 守卫只挡根。`~/Library/Caches/R` 走 `review.sh:13` 自动删，其余 personal 需 `--with-data` | 名字模板加 `>=3` 下限，短名必须由 bundle id 交叉证明；CLI 白名单改为按目录内容探测 |
| B1-07 | 中 | `AP:1504-1530`；系统侧同类 `AP:2322-2339`（只读） | `Foo Bar.app`（`com.vendor.foobar`）→ 追加 `~/Library/Application Support/FooBar`、`Foo_Bar`、`Foo-Bar`、`~/Library/Preferences/FooBar.plist`、`~/.config/foobar`；若独立产品 `FooBar.app` 存在，其数据被一并删除 | **只有同名家族守卫。** `_mole_app_family_shared_leaves`（`AP:1291-1318`）只在装了 `Foo Bar Nightly` 这类可识别频道版时剔除同名叶；对“另一个叫 FooBar 的独立产品”不判断；`_path_belongs_to_independent_cli` 只 4 名 | 折叠变体启用前检查是否存在另一已装 bundle 的精确名；或要求 bundle id 末段与折叠名一致 |
| B1-08 | 中 | `AP:1472-1499` | 显示名 `Code` + bundle `com.acme.CodeRunner` → leaf `CodeRunner` 以 `code` 开头、余部 `R` 大写，派生 `~/Library/Application Support/CodeRunner`、`Caches/CodeRunner`、`Preferences/CodeRunner.plist`、`Saved Application State/CodeRunner.savedState`；同厂商 `CodeRunner.app` 的数据被删。真实形态：`Notion` + `com.notion.NotionCalendar` | **拦不住。** family leaves 只输出 base 的 4 种变体（`code`），`coderunner` 不在其中（`AP:1291-1302`），`AP:2168-2183` 的叶过滤不匹配；`should_protect_path` 无此规则 | 派生 leaf 前要求“磁盘上没有同名 .app”，或要求 leaf 与 bundle id 末段完全一致 |
| B1-09 | 中 | `AP:1443-1458`；`review.sh:13` | `Arc.app` → `~/Library/Caches/Arc-updater`、`~/Library/Application Support/Caches/Arc-updater`；`Zoom.app` → `Zoom-updater`；`Code.app` → `Code-updater`。同 productName 的另一 Electron 产品共用同一目录 | **无。** 门槛只排 `/`、控制符、通用词、`electron`；`Caches/*` 自动删，无 `D` 菜单；`Caches/X-updater` 不在根塌缩名单（`AP:1573`） | 读 Squirrel/ShipIt 的 update 配置或 bundle id；读不到就不收 |
| B1-10 | 中 | `AP:2057-2112`；系统侧 `AP:2503-2517`（只读） | 卸载 `Raycast.app`（`com.raycast.macos`）→ `~/Library/Containers/com.thirdparty.raycast-helper`、`~/Library/Application Support/RaycastBeta`、`~/Library/Application Scripts/com.example.raycast-bridge`、`~/Library/Caches/com.example.raycast-bridge`（`Caches` 下探 2 层） | **部分。** 只排 `*raycast-x*`（v2）；`should_protect_path` 在 uninstall 模式对容器跳过 bundle id 保护（`AP:508`）；`Containers`/`Application Support` 项需 `--with-data`，`Caches` 项自动删 | 改为精确 `com.raycast.macos*` + bundle id 边界；容器读 metadata；`Caches` 下探限制在 Raycast 自有目录 |
| B1-11 | 中 | `AP:1934-1952`；sibling 开关 `AP:1886-1890`、`B:2113-2129` | `XcodeBuild Helper.app`（`com.acme.xcodehelper`）或 `Xcode Clean.app` → `~/Library/Developer/Xcode/DerivedData`（该用户全部工程构建产物）、`iOS/macOS/... DeviceSupport`、`~/Library/Developer/CoreSimulator/Caches`、`~/.Xcode` | **半守卫。** `MOLE_UNINSTALL_SIBLING_SURVIVES` 只在同 bundle id 有存活副本时置 1，跨 id 的同名前缀 app 不触发；family leaves 不含 `DerivedData`（`AP:1291-1318`） | 触发条件加 `bundle_id =~ ^com\.apple\.dt\.Xcode` 或 `CFBundleExecutable == Xcode` |
| B1-12 | 中 | `AP:1908-1917` | `NotAndroid Studio.app`、`Android Paint Studio.app` → `~/.android/build-cache`（Gradle 跨工程共享）、`~/.android/cache`、`~/.android/breakpad` | **无。** `~/.android` 不在根塌缩/共享根名单（`AP:1573`、`AP:347-364`）；sibling 只挡同 bundle id 家族 | 触发条件加 `com.google.android.studio*` 或 `CFBundleExecutable == studio`；至少不要删 `build-cache` |
| B1-13 | 中 | `AP:1954-1971`；selector 分支 `AP:1975-1995` | `Rider.app`（`com.acme.rider`，与 JetBrains 无关）→ `~/Library/Application Support/JetBrains/Rider2024.1`（keymap、插件、license 状态）、`Caches/JetBrains/Rider2024.1`、`Logs/JetBrains/Rider2024.1` | **无。** 版本叶校验只验形状（`AP:797-804`）；selector 分支要求 `com.jetbrains.*`，对非 JetBrains id 不生效 | 名字分支也要求 `com.jetbrains.*`；否则只收 bundle id 精确路径 |
| B1-14 | 中 | `AP:2009-2021`；保护表跳过 `AP:672-680` | 任一 `com.microsoft.*vscode*` 辅助组件 → 删 `~/.vscode`、`~/Library/Application Support/Code`（稳定版全部扩展/设置/globalStorage）；卸载稳定版时 `AP:2009-2011` 无条件同时收 `com.microsoft.VSCodeInsiders.ShipIt` | **无。** `app_protection_data.sh` 里的 `com.microsoft.VSCode` 条目在 uninstall 模式被 `AP:672-680` 跳过；正则两端未锚定 | 锚定 `^com\.microsoft\.VSCode(Insiders)?$`；ShipIt 按 channel 分支 |
| B1-15 | 中 | `AP:1639-1657`；边界 `base.sh:1242-1249` | 卸载 `com.acme.Foo` → `~/Library/Preferences/ByHost/com.acme.Foo.Bar.<UUID>.plist`（`Foo Bar.app` 的偏好）。正常 `Preferences/com.acme.Foo.plist` 是精确匹配，没这个问题 | **无。** 只做字符串前缀，不校验点后是否为 UUID 段；personal 项需 `--with-data` | 要求 `<id>.` 后是 UUID（或已知后缀）；否则不收 |
| B1-16 | 中 | `AP:2253-2265`；`review.sh:13` | `Foo.app`（`CFBundleExecutable=Foo`）→ `~/Library/Logs/DiagnosticReports/Foo 2-2024-...ips`（属于 `Foo 2.app`），因落在 `Logs/` 下被自动删除 | **无。** sibling guard 只按同 bundle id（`B:2065`、`B:2116`），不同 id 的 `Foo 2` 不受保护；`Logs` 自动分支无 `D` 菜单 | 解析 `.ips` 里的 `bundleID`/`procPath` 核对；或前缀后要求明确的日期模式 |
| B1-17 | 中 | `AP:892-945`、`AP:776-793`（`"$variant "*`）、`AP:1613-1630` | `FooBar.app`（`com.acme.foobar`）→ `~/Library/Application Support/Acme/FooBar 2`（`FooBar 2.app` 的数据）；vendor 父目录 `acme` 相等，子目录 `"foobar "*` 前缀命中 | **无。** 判共享只比 id 点续接与剥后缀名（`B:1047-1085`），`foobar` vs `foobar2` 既不点续接也不剥数字；`--with-data` 预选 | 子目录前缀臂要求后接版本号或频道词；或把 `FooBar 2` 纳入家族识别 |
| B1-18 | 中 | `brew.sh:354-356`（basename 精确）、`:384-392`（唯一 token）、`:408-414`（`grep -qF` 子串自证）、`:396-403`（`-ef` 仅 fallback） | 非 Homebrew 的 `Chat.app`（`com.acme.chat`）→ Caskroom 里同名 `Chat.app` 的 cask 被选中，执行 `brew uninstall --cask`，删掉该 cask 的 artifact（可能是另一个应用），用户选的 app 反而没动 | **部分。** token 必须已装（`grep -qxF`）、有 `-ef` inode 校验但只在 `brew info` 失败时采用、生产调用传 `nozap`（`B:2878-2880`）、预览后重验身份（`B:2856-2863`） | 把 `-ef` 设为必经；`brew info` 改为解析 artifact 路径做精确相等，不用子串 |
| B1-19 | 低 | `AP:854-857`；删除前 `B:886-930` 调同一函数 | 某 app 冒用/继承 `com.vendor.legacy` 这个 label → `~/Library/LaunchAgents/com.vendor.legacy.plist` 被删，而其 `Program` 实际指向另一个仍在装的 `Bar.app` | **部分。** 精确 `<id>.plist` 分支直接 `return 0`，不读 `Program`；只有 `<id>.*.plist` 与非精确名才走归属校验（`AP:858-889`） | 精确名分支也校验 `Program`（label 复用并不罕见） |
| B1-20 | 低 | `AP:2119-2126`；门槛 `AP:2119` | `Foo.app` 与 `Foo_Bar.app` 并存 → `Foo_Bar_<UUID>.plist` 被 `Foo_*` 命中并删除；`Foo_Insiders.app` 同理 | **无。** 前缀 glob 不做边界二次校验（对比 `AP:1643-1652` 的 ByHost 会再过 bundle id）；但 `Application Support/CrashReporter` 是 personal 项，需 `--with-data` | 增加 bundle id 边界或读 plist 的 `CFBundleIdentifier` |
| B1-21 | 低 | `AP:2293-2320`、`AP:2415-2431`、`AP:2378-2386`、`AP:947-1024`；清空 `B:2344-2353` | 卸载 `ClashX.app` → `/Library/LaunchDaemons/com.west2online.ClashXPro.ProxyConfigHelper.plist`（ClashX Pro）被列；卸载 `Steam.app` → `/Library/Application Support/Steam`（共享游戏库）被列；`Ableton Live.app` → `/Users/Shared/Live Recording Session` 被列 | **有，且是硬守卫。** `find_app_system_files` 的产物全部进 `review_only_system_files`，`system_files`/`diag_system` 在预览前被清空（`B:2344-2353`），执行阶段拿空串（`B:2645`、`B:3082-3092`），只展示不删。本条因此只算误报，不算误删 | 收紧名字子串/`/Users/Shared` 前缀臂，避免预览误导；若将来放开 review-only，必须先把 B1-21 的系统级归属校验补齐 |

**合并与判定说明（读源码定）**

- `/Users/Shared` 在 U08 被记为“中-高”，理由是 `find_shared_app_paths` 的前缀臂过宽；但该函数全仓库只有一个调用点 `AP:2378`，位于 `find_app_system_files` 内，产物随后被 `B:2344-2353` 清空。**本仓库 CLI 下不会删除**，故统一降为 B1-21 的低风险“误报”，并把 U08 的 `Blender 4.2 → /Users/Shared/Blender Projects`、`Ableton Live → /Users/Shared/Live*` 例子并入该条。
- Godot 在 U05 与 Docker 合并评为“中”，U04 单列为“高”。源码 `AP:2001` 是整根 `files_to_clean+=`，且 `app_userdata` 是全部游戏的 `user://` 存档，不是缓存；U05 的合并低估了后果，本文取**高**。
- `Group Containers` 在 U03 记“中-高”、U10 记“中”。源码上它确实无 owner 校验，但 `review.sh:33` 把它整体 holdback，`--with-data` 也不预选；按“需 `D` 手动勾选”定为**中**（B1-04）。`Containers`/`Application Scripts` 没有这条 holdback，`--with-data` 会预选，故单列为**高**（B1-03）。
- `Code.app → Application Support/Code` 在 U10 记“高”，U02 把“显示名=厂商名”记“中”。`Code` 是现实存在的目录名（VS Code），且 `review.sh` 的 holdback 只列 Chrome/Firefox 等浏览器根，不含 `code`；本文取**高**（B1-05）。
- CrashReporter 前缀在 U01a 记“中”，U05 记“低”。它位于 `Application Support`（personal，需 `--with-data`），且只涉及崩溃报告，取**低**（B1-20）。
- 系统级 `/Library`/回执/`/Users/Shared` 的“误删”在 U06/U07 已被证明是 review-only；U01b/U08 的相应高风险按源码降级，不重复计入。



## 3. 风险二：空格/中文/点号/版本后缀

核心事实：**残留匹配用的名字不是显示名，而是磁盘 bundle basename 去 `.app`**（`B:2047-2048`）。因此空格、中文、点号、括号、`Foo 2` 都是真实输入。删除层按行 `IFS= read -r` 读候选、路径全程加引号（`B:827-828`、`B:833-837`），这些字符本身不会造成误删；风险集中在**上游的派生规则**：要么变体造不出真实目录名（漏找），要么折叠/剥后缀造出了别家的名字（误删，已并入第 2 节）。

| 编号 | 严重度 | 代码位置 | 例子：应用名 → 会命中的路径 | 有无后续守卫拦住（位置） | 建议 |
| --- | --- | --- | --- | --- | --- |
| B2-01 | 中 | 后缀表 `AP:1351-1352`；派生 `AP:1533-1544`；镜像表 `B:1875-1883` | `Foo 2.app`（`com.acme.foo2`）→ 只找 `Application Support/Foo 2`、`Foo2`、`Foo-2`、`Foo_2`，**漏掉**旧版仍在用的 `~/Library/Application Support/Foo`、`Caches/Foo`、`Preferences/Foo.plist`、`~/.config/foo`。`Foo-2.app`/`Foo.2.app`/`Foo 2.0.app` 同理（无空格连变体都不生成） | **方向是漏删，无需守卫。** 但 `_mole_app_family_shared_leaves`（`AP:1291-1302`）复用同一张表，也剥不掉数字，导致家族保留失效；bundle id 分支仍能收 `Containers/<id>` 等 | 后缀表增加 `[[:space:]]+[0-9]+(\.[0-9]+)*` 与 `[-._]?(Beta\|RC\|…)`；剥离后要求基名 `>=3` 且能对上已存在的目录 |
| B2-02 | 中 | `AP:1955-1969`；selector 兜底 `AP:1975-1995`、`AP:1068-1081` | `IntelliJ IDEA.app`（`com.jetbrains.intellij`）→ `-name "IntelliJ IDEA*"` 在 `.../JetBrains` 下**恒不命中**（真实目录 `IntelliJIdea2024.1`、`IdeaIC2024.1` 无空格且大小写不同）；`IntelliJ IDEA CE.app` 同理。若 Info.plist 缺 `idea.paths.selector`（CE/EAP/改包常见），`Application Support/JetBrains/IntelliJIdea2024.1` 整段漏找 | **部分。** selector 分支是唯一兜底，依赖 plist 键；`_mole_uninstall_versioned_product_matches`（`AP:797-804`）只收窄不补偿；无空格的 `PyCharm`/`GoLand`/`CLion`/`WebStorm`/`Rider`/`DataGrip` 正常 | 为 JetBrains 建立产品名→紧凑目录名映射，或直接扫描 `JetBrains/*` 后读 `product-info.json` 核对 |
| B2-03 | 中 | `AP:1504`（`[[:space:]]` 只认 ASCII 空白）；`AP:1340-1346`（`tr` 只折 ASCII） | `Foo　Bar.app`（全角空格）→ 不触发折叠变体，只找含全角空格的路径，与 `Foo Bar` **不匹配** → 漏找；`微信.app`（`com.tencent.xinWeChat`）→ 只找 `Application Support/微信`，真实数据在 `Containers/com.tencent.xinWeChat`（靠 `AP:1405` 的 bundle 分支兜住）或英文 `WeChat`（漏） | **无（方向为漏删）。** 中文名的 `nospace/hyphen/underscore` 变体是恒等变换，等于没加；`AP:1373` 的 `${#app_name}` 在 UTF-8 locale 按字符计，两个汉字过门槛 | 空白判定改为 `[[:space:]]` + 全角空格（U+3000）；中文名增加拼音/英文别名表或只依赖 bundle id |
| B2-04 | 低 | `AP:1375-1403`（字面拼接）、`AP:1397-1400` | `Foo.Bar.app`（`com.acme.foobar`）→ 只找 `Application Support/Foo.Bar`、`Preferences/Foo.Bar.plist`；真实目录常是 `FooBar`（`AP:1504` 的折叠只在含空格时生成，点号不触发）→ 漏找。反向已有误删风险：`Preferences/Foo.Bar.plist` 与另一 `com.other.Foo.Bar` 同路径（与第 2 节 B1-05/B1-15 同源：按名字拼出的偏好路径不核归属） | **无（漏删侧）。** 点号不触发任何变体；`AP:1472-1499` 的 leaf 派生要求 `<display><Camel>`，`Foo.Bar` 的 `.` 使前缀比较失败 | 点号也生成去点/连字符/下划线变体；`Preferences/<name>.plist` 命中前核对 `defaults` 的 domain 归属 |
| B2-05 | 低 | `AP:2119-2126`（CrashReporter glob）；`AP:2253-2265`（诊断报告前缀） | `Foo Bar.app` → 设备端报告常写作 `Foo Bar_<UUID>.plist`，但 `nospace_name=FooBar` 造出 `FooBar_*.plist`，与带空格名**不匹配** → 漏找；`Foo 2.app` 的 `CFBundleExecutable` 读不到时前缀退化为 `Foo2`，真实报告 `Foo 2-....ips` 漏找 | **无（漏删侧）。** 只有 `${#nospace_name}>=3` 与 `electron` 白名单；没有“原名 + 去空格名”双模式 | CrashReporter/诊断报告同时用原名与去空格名两个前缀 |
| B2-06 | 低 | `AP:2135-2137`；别名校验 `AP:1211-1252` | `原神.app`、`Genshin Impact.app`、小写 `foo.app` 的 PlayCover 包 → `[[ "${app_path##*/}" == "$bundle_id.app" ]]` 为假，整段跳过：`App Settings/<id>.plist`、`Keymapping/<id>`、`Entitlements/<id>.plist`、`~/Applications/PlayCover/<alias>.app` 全部漏找 | **有（方向安全）。** 条件是“确属 PlayCover 布局”的证据；`mole_is_playcover_app`（`AP:1197-1205`）已校验根与 Info.plist。漏删非误删 | 改为“PlayCover 根 + Info.plist 的 id 等于目录名或已知别名”，不强求 basename 字面相等 |
| B2-07 | 低 | `AP:2151-2155`；`AP:1211-1252` | 新版 PlayCover 在别名目录写入真实图标或 `iTunesMetadata.plist` → `mole_playcover_alias_target` 要求每项都是同指符号链接/`.DS_Store`/id 一致的 `Info.plist` 副本，否则返回 1，别名漏收 | **有（保守校验）。** 返回 1 时不加入任何路径，方向安全 | 放宽为“除白名单外无其他常规文件”，或按 `Contents/Info.plist` 的 id 判定 |
| B2-08 | 低 | `AP:1961`（`-name "${app_name}*"` 未转义）；`AP:2123`（CrashReporter glob） | `GoLand [EAP].app` → `[EAP]` 被 find 当字符类，匹配 `GoLand E2024.1` 一类，反而匹配不到字面 `GoLand [EAP]2024.1`；`Foo[1].app` 的 CrashReporter 模式 `Foo[1]_*.plist` 命中 `Foo1_<UUID>.plist`（别家报告）并漏掉自己的 | **部分。** JetBrains 侧有 `_mole_uninstall_versioned_product_matches`（`AP:797-804`）收窄；CrashReporter 无元字符转义 | 拼 `find -name` 前转义 `[`/`]`/`*`/`?`，或改用 `-print0` + bash 字面比较 |
| B2-09 | 低 | `AP:1327-1330`；`AP:1373` | 单字符名 `X.app` → `find_app_files` 在“bundle id 无效且名字 <2”时整体返回；名字模板 `-ge 2` 也不生成，只剩 bundle id 路径。`X` 的 `Application Support/X` 漏找 | **有（刻意保守）。** `B:1079-1082` 的共享判定也要求剥后缀后 `>=2` | 可接受；若要收，至少要求名字模板命中项再由 bundle id 佐证 |
| B2-10 | 低 | `brew.sh:298`（token 正则 `^[a-z0-9][a-z0-9-]*$`）；`brew.sh:450`（`grep -Fix` 整行） | `Foo 2.app`、`Foo.Bar.app`、`Foo（Beta）.app` → Stage 4 要求 app 名小写后与 `brew list --cask` 某行**整行相等**，cask 名不含空格/点号/中文，必然落空；Stage 1/2/3 又因 token 字符集或 Caskroom 深度失效 → 该 Homebrew 应用被当普通应用删除 | **有（不会漏删文件）。** 后果是绕过 brew：cask 未注销、`brew list --cask` 仍报已装、不走 cask 的 artifact/uninstall 逻辑（`B:2986-2996`、`B:3015-3018`） | 用 `brew info --cask` 的 artifact 路径反查 token，而不是拿 app 名去整行匹配 |
| B2-11 | 低 | `lib/uninstall/config_refs.sh:48` | 只读提示：`Foo` 的 needle 会命中配置行里的 `.../Foo 2`（右边界允许空格）；`Foo 2` 的 needle 遇到 `Foo\ 2`（反斜杠转义空格）或 `file:///.../Foo 2`（左边界排除 `/`）则漏报；`微信` 后接全角 `）`/汉字时漏报 | **有（只读）。** 只打印 `~/<relative>:<line>`，不打印内容、不改配置（`config_refs.sh:49-51`、`:66`） | 右边界扩展到全角标点；needle 预处理 `\ ` 与 `file://` 前缀 |
| B2-12 | 低 | `review.sh:43-44` | `Chrome Remote Desktop.app` → `Application Support/Google/Chrome Remote Desktop` 被 `"$support/google/chrome"*` 无分隔符前缀误判为 Chrome 家族 → `--with-data` **不预选**（漏删） | **有（方向安全）。** `D` 菜单可手动选（`review.sh:164`） | 前缀匹配加 `/` 边界（`google/chrome/` 或 `google/chrome` 精确） |
| B2-13 | 低 | `AP:1504-1530`、`AP:1343-1354` | `Foo (Beta).app` → 折叠成 `Foo(Beta)`、`Foo-(Beta)`、`Foo_(Beta)`（后两者几乎不存在），后缀表也剥不掉 `(Beta)`；真实目录 `Foo Beta`/`Foo-Beta` 全漏 | **无（漏删侧）。** 括号在 `find -name` 里是字面量，不放大匹配 | 后缀表支持 `(<channel>)` 与 `-<channel>`；折叠时先剥括号再替换空格 |

**合并与判定说明（读源码定）**

- 空格折叠的**误删**面（`Foo Bar.app` 删到 `FooBar.app`）放第 2 节 B1-07；本节只保留其**漏找**面与无法生成变体的情形，避免同一机制重复计数。
- `Foo 2`（数字版本后缀）在 U01a/U01b/U02/U03/U05/U09a/U09b 共 7 份报告里重复出现。统一为 B2-01：**名字派生漏找为主**；其误删变体（卸载 `Foo` 删掉 `Foo 2` 仍在用的 `Application Support/Foo`）本质是“家族识别失效”，已并入 B1-17 的判共享缺口，不另开条目。
- `IntelliJ IDEA`（U04 R6、U05 R2）与 JetBrains 紧凑目录名是同一缺陷，合并为 B2-02；U04 另提的“名字含 `[`/`*` 使 find glob 变形”拆到 B2-08（与 CrashReporter 的同类元字符问题合并）。
- 中文名：U01a 认为“不受影响但拿不到产品段派生”，U03/U04 认为“只走字面、英文别名漏”。源码上中文名确实不触发折叠（`AP:1504` 的 `[[:space:]]` 对中文名多为假），也不会误删；合并为 B2-03 的漏找。
- PlayCover 两条（U05 R9/R10）都是“校验过严导致漏收”，且失败方向安全，合并为 B2-06/B2-07 两条低风险。
- Homebrew 的版本后缀/空格问题（U11 R2/R3）不改删除面，只影响下架通道，保留为 B2-10；`--zap` 默认值见第 4 节守卫 G-17。



## 4. 已有守卫清单

按“发现 → 分类 → 删除”的先后排列。**结论先行**：能挡住“路径本身危险”（系统根、共享根、容器/launchd 归属）的守卫比较完整；挡不住“这个目录到底属于哪个应用”（同名/短名/基名派生）的守卫几乎为空。

| 编号 | 守卫 | 防的是什么 | 代码位置 | 有效性 / 缺口 |
| --- | --- | --- | --- | --- |
| G-01 | 双标识前置校验：bundle id 无效**且**名字 <2 才整体返回 | 空名/空 id 把 `Application Support/` 等根目录当候选 | `AP:1327-1330` | 有效；但名字 ≥2 即放行，短名问题见 B1-06 |
| G-02 | bundle id 反向 DNS 校验（`[A-Za-z0-9.-]`、必须含点、排除 `unknown`） | `*`/`?`/`[`/空白/中文/`/` 进入字面路径或 `find -name` | `lib/core/base.sh:1227-1232`；调用 `AP:1362-1365`、`:2394`、`:2568-2571` | 有效；`unknown` 会静默降级为纯名字扫描（`B:2127`、`:2172`） |
| G-03 | 根塌缩名单：路径若**等于** `.../Library/{Application Support,Caches,Logs,Preferences,ByHost,Containers,WebKit,HTTPStorages,Application Scripts,Autosave Information,Group Containers}`、`~/.config`、`~/.cache`、`~/.local/share`、`$HOME` 则跳过 | 空名/空 id 导致的整根删除 | `AP:1573-1589`（用户级）、`AP:2345-2353`（系统级） | 有效；只匹配“父目录本身”，对 `<根>/<短名>` 无效（B1-06） |
| G-04 | 共享 home 状态根：`~/.cache`、`~/.config`、`~/.local`、`~/.local/{bin,lib,share,state}`、`~/Library/Unity`、`~/Library/Application Support/Epic` | 应用名恰好叫 `Local`/`Config`/`Cache` 时删掉共享根 | `AP:347-364`；调用 `AP:1592-1598`、`:1566-1609`、`should_protect_path` `AP:425-431` | 有效但清单很短；不含 `Application Support/Microsoft\|Adobe\|Google\|Godot`（B1-01/B1-02/B1-05） |
| G-05 | Steam 库根：`~/Library/Application Support/Steam` 及其全部后代 | 任何应用把 Steam 游戏库当残留 | `AP:370-383`；调用 `AP:1599-1602`、`AP:429-431` | 有效，但只覆盖默认根；外置 `SteamLibrary` 不匹配（B1-21 的同类，且只读） |
| G-06 | 独立 CLI dotdir 白名单：叶子属于 `claude\|opencode\|codex\|gemini` 且父目录 ∈ `$HOME`、`~/.config`、`~/.local/share`、`~/.cache` | 卸载同名 GUI 应用时删掉 CLI 的状态目录（#993） | `AP:1038-1066`；调用 `AP:1604-1607` | 有效但只有 4 个名字；`~/.zed`、`~/.cursor`、`~/.ollama` 等不在名单（B1-06 的同源缺口） |
| G-07 | 同 bundle id 存活副本扫描：`uninstall_live_bundle_has_other_install`（多根 + `/Volumes`）与 `uninstall_bundle_id_has_surviving_sibling`（`apps_data` 行内） | 另一个共享同一 id 的安装仍在时，整批保留残留；后者还区分 `guard`/`guard_login`，必要时清空 `discovery_app_name` 并把 id 降级为 `unknown` | `B:1090-1101`（根清单）、`B:1405`、`B:1788`、`B:1828`、`B:2113-2173` | 有效，但**只认同一 bundle id / 点续接**；不同 id 的同名产品（`Foo 2`、`Code`、`FooBar`）不受保护（B1-05/B1-17） |
| G-08 | 名字碰撞抑制：发现名或剥后缀名与幸存者名**互为子串**时清空 `discovery_app_name` | 卸载 `Foo.app` 时误伤 `Foo Beta.app` 的登录项/名字路径 | `B:2135-2165` | 有效但方向保守（会漏删）；`2136-2138` 的 `survivor_name == *discovery*` 是双向子串，`FooBar` 存活会让 `Foo` 整段跳过 |
| G-09 | 家族叶过滤：同族兄弟（`/Applications`、`~/Applications`）仍安装时，丢弃仅由 base 名派生的叶子 | `Zed`/`Zed Nightly` 互相删对方的名字目录 | `AP:1254-1283`、`AP:1286-1318`、`AP:2159-2197`、`AP:2527-2554` | 有效；只认 `/Applications` 与 `~/Applications` 两个根，兄弟放桌面/Utilities 就失效；后缀表不认数字（B2-01） |
| G-10 | UUID 容器 owner 校验：目录名为 UUID 且 `MCMMetadataIdentifier` 严格等于 bundle id，发现时与删除前各一次 | 误删别家沙盒容器的真实数据 | `AP:1083-1096`；发现 `AP:1714-1735`；删除前 `B:857-878` | **最扎实的一条**；只覆盖 `~/Library/Containers`，不覆盖 `Group Containers`/`Application Scripts`（B1-03/B1-04） |
| G-11 | LaunchAgent / NativeMessagingHosts 归属校验：`Program`/`ProgramArguments.0` 必须在所选 `.app` 内（realpath 前缀 + 非符号链接 + 无 `..`/控制符）；JSON 的 `path` 同理 | 按名字子串命中的别人的启动项/浏览器清单 | `AP:842-890`；发现 `AP:1827-1885`、`AP:1737-1759`；删除前 `B:886-930` | 有效；**精确 `<bundle_id>.plist` 分支直接放行、不读 Program**（`AP:854-857`，B1-19）；系统级 `/Library` 分支没有这道校验，但只读（B1-21） |
| G-12 | 删除层 `validate_path_for_deletion`：绝对路径、拒绝 `..` 组件/控制字符/换行、符号链接目标与祖先检查、`_mole_is_critical_deletion_path`、`should_protect_path` | 系统关键路径、`/System`、`/usr`、`/Library` 根、`~/Library/Accounts` 等 | `B:839-845`；实现在 `lib/core/file_ops.sh:1160-1385`（critical 表 `:1044` 起，保护判断 `:1366-1385`） | 有效；**是路径黑名单，不是应用归属校验**——普通 `Application Support/<name>` 一律放行（B1-01~B1-08） |
| G-13 | 删除前 `should_protect_path`（uninstall 模式）：系统关键组件、`com.apple.*` 容器、OrbStack、Steam 根、共享 home 根 | 系统 UI 缓存、系统设置、容器内关键数据 | `AP:401-683`；调用 `B:2336-2343` | 有效但覆盖面窄；uninstall 模式**跳过**按文件名匹配的 `should_protect_data`（`AP:672-680`）、跳过沙盒 bundle id 保护（`AP:508`） |
| G-14 | System Integrity 扫描：容器内 `restricted`/`sunlnk` flag、`com.apple.rootless` xattr、`Operation not permitted` 视为受保护 | 把 SIP 保护的目录移进 Trash 导致 Empty Trash 永久失败 | `B:730-761`；实现 `B:724-733` | 部分有效；`-maxdepth 4`、无 FDA 直接 `return 1`（不保护）、扫描超时也 `return 1`（B1-21 相关，见 U10 R5） |
| G-15 | 删除模式默认 Trash + `MOLE_SELECTION_FILE` 窄化 + 应用身份绑定（inode/Info.plist/selector 在预览与执行间复验） | 误删不可恢复；预览后路径被替换 | `bin/uninstall.sh:2404`；`B:833-837`、`B:2645-2662`、`B:2856-2863` | 有效；`--permanent` 下 B1-01~B1-08 不可逆 |
| G-16 | `review.sh` 个人数据两层：`Caches`/`Logs` 自动删、其余默认不选、`--with-data` 才预选、`Group Containers`/Whisky/UTM/浏览器 profile/游戏库 holdback | 未经确认删个人数据 | `lib/uninstall/review.sh:4-16`、`:26-64`、`:85-96`、`:110-135` | 有效；**holdback 是 deny-list**，没列到的（`Application Support/Microsoft`、`Code`、`JetBrains`、`Godot`）照常预选；`Caches` 自动分支不过 holdback |
| G-17 | Homebrew 侧：token 必须已安装（`grep -qxF`）、唯一 token、`-ef` inode 校验、生产调用 `nozap` | 误把非 cask 应用交给 brew；`--zap` 删未审数据 | `brew.sh:384-392`、`:358-360`、`:396-403`；`B:2878-2880` | 部分有效；`-ef` 只在 `brew info` 失败时采用，`brew info` 子串自证必然通过（B1-18）；`--zap` 仍是函数默认值（`brew.sh:521-527`） |
| G-18 | PlayCover 归属：扁平包校验 + 别名内每项同指一个包 + Info.plist id 相同 | 把普通目录当 PlayCover 别名删除 | `AP:1197-1252`、`AP:2135-2156` | 有效（偏保守，失败即不收）；漏删见 B2-06/B2-07 |
| G-19 | 系统级残留 review-only：`system_files`/`diag_system` 在预览前清空 | `/Library`、回执、`/Users/Shared` 被实际删除 | `B:2344-2353`；执行期 `B:2645`、`B:3082-3092`；JSON `action:"skipped"`（`bin/uninstall.sh:2015-2024` 一带） | **有效且关键**；注释明确写着“Do NOT remove this blanking”。B1-21 因此只算误报 |
| G-20 | 回执载荷白名单：只放行 `/Library/{LaunchAgents,LaunchDaemons}/*.plist`、`/Library/PrivilegedHelperTools/*`、`/private/var/db/receipts/*` | `.bom` 里的任意路径被当删除候选 | `AP:2665-2690`；调用 `AP:2640-2650` | 有效（宁漏勿错）；BOM 里的 `Application Support`/`/usr/local` 载荷全部丢弃（漏找） |
| G-21 | 删除前 owner 复验：`app_path` 重现 → 整批保留；`uninstall_live_bundle_has_other_install` 返回“未知”也整批保留 | 预览后另一份安装出现/路径被替换 | `B:788-818` | 有效；只认同一 bundle id，且 `bundle_id` 非 reverse-DNS 时连这项也不做（`B:794`） |
| G-22 | 诊断报告前缀：共享运行时 `electron` 视为无名、`>=3` 字符、扩展名白名单 | 把 Electron 全家的崩溃报告算给一个应用 | `AP:2226-2234`、`:2253-2265`、`lib/core/base.sh:1234-1238` | 有效；白名单只有 `electron`，`JavaApplicationStub`/`nwjs`/`QtWebEngineProcess` 之类共享进程名会重演误收（B1-16 的同类） |
| G-23 | 配置引用只读：固定 14 个文件、regular file、≤1 MiB、realpath 在 `$HOME` 下、`O_NOFOLLOW`、前后 stat 一致、只输出 `~/<relative>:<line>` | 改坏用户配置/泄露内容 | `lib/uninstall/config_refs.sh:24-36`、`:49-51`、`:66` | 有效；只影响提示准确度（B2-11） |



## 汇总

### 严重度条数

| 严重度 | 风险一（B1） | 风险二（B2） | 合计 |
| --- | --- | --- | --- |
| 高 | 4（B1-01、B1-02、B1-03、B1-05） | 0 | **4** |
| 中 | 14（B1-04、B1-06～B1-18） | 3（B2-01、B2-02、B2-03） | **17** |
| 低 | 3（B1-19、B1-20、B1-21） | 10（B2-04～B2-13） | **13** |
| 合计 | 21 | 13 | **34** |

输入：`report/p7b/` 下 13 份单元报告（U01a、U01b、U02、U03、U04、U05、U06、U07、U08、U09a、U09b、U10、U11；`U01-entry.md`、`U09-helpers.md` 是被拆分前的旧稿，内容已被 U01a/U01b、U09a/U09b 覆盖，未单独计数）。13 份现行报告共标记 107 条风险（U01a 9、U01b 7、U02 7、U03 9、U04 11、U05 12、U06 10、U07 4、U08 8、U09a 6、U09b 12、U10 6、U11 6），按“同一代码位置 + 同一机制”合并、并按上面的判定口径重新定级后为 34 条。

### 需要改引擎的条目（只列，不改）

按修复收益排序；每条给最小改动点。

1. **B1-01 / B2-01｜版本后缀表**：`lib/core/app_protection.sh:1351-1352` 与 `lib/uninstall/batch.sh:1875-1883` 的 `Edge|Dev|RC|Stable|Release|LTS` 是产品词，不应作为频道后缀；同时补数字版本（`[[:space:]]+[0-9]+(\.[0-9]+)*`、`[-._](Beta|RC|…)`）。这是唯一一条“一条改动同时消掉一个高危 + 一个中危漏找”的项。
2. **B1-02｜Godot 整根**：`app_protection.sh:1999-2001` 删除整根 `Application Support/Godot`；至少改为不删 `app_userdata`。
3. **B1-03 / B1-04 / B1-15｜bundle id 边界**：`lib/core/base.sh:1242-1260` 的前缀臂 `<id>.*` 让 `com.acme.Foo` 吃掉 `com.acme.Foo.Bar` 的容器/脚本目录；`app_protection.sh:1661-1712` 未读容器 owner（对比 `:1714-1735` 的 UUID 分支），`:1639-1657` 的 ByHost 未校验 UUID 段。
4. **B1-05 / B1-06｜名字模板宽度**：`app_protection.sh:1373` 的 `>=2` 与 `:1397-1400` 的 XDG 直拼；`app_protection.sh:1038-1066` 的 CLI 白名单只有 4 个名字。建议名字模板下限提到 3，且 `Application Support/<name>`/`Preferences/<name>.plist` 命中时要求 bundle id 或已装应用交叉证明。
5. **B1-07 / B1-08｜折叠变体与 leaf 派生**：`app_protection.sh:1504-1530`、`:1472-1499`，启用前检查是否存在同名独立 `.app`，或要求派生名与 bundle id 末段一致。
6. **B1-09｜updater 目录**：`app_protection.sh:1443-1458` 只由名字派生 `<v>-updater`，无 owner；建议读 Squirrel/ShipIt 配置或直接放弃该分支。
7. **B1-10｜Raycast 子串**：`app_protection.sh:2057-2112`（`-iname "*raycast*"`，`Caches` 还下探 2 层）与系统侧 `:2503-2517`；改为 `com.raycast.macos*` 边界 + 容器 metadata。
8. **B1-11 / B1-12 / B1-13 / B1-14｜工具链正则未锚定**：`app_protection.sh:1936`（Xcode）、`:1910`（Android Studio）、`:1956`（JetBrains）、`:1896`（DevEco）、`:2009`（VS Code）、`:2025`（Docker）都应按 bundle id 锚定，而不是 `app_name =~` 子串。
9. **B1-16 / B1-20 / B2-05 / B2-08｜诊断报告与 CrashReporter 前缀**：`app_protection.sh:2119-2126`（未转义 `[`/`]`/`*`/`?`）、`:2253-2265`（只认 `.`/`_`/`-` 分隔、无原名+去空格名双前缀）、`lib/core/base.sh:1234-1238`（共享运行时白名单只有 `electron`）。建议解析 `.ips` 的 `bundleID`/`procPath` 核对归属。
10. **B1-18｜Homebrew**：`lib/uninstall/brew.sh:396-414` 的 `-ef` 只在 `brew info` 失败时采用，`:408-414`/`:453-465` 用 `grep -qF` 子串自证；建议 `-ef` 设为必经、`brew info` 改为解析 artifact 路径精确相等。
11. **B1-19｜LaunchAgent 精确名捷径**：`app_protection.sh:854-857` 对 `<bundle_id>.plist` 直接放行，不读 `Program`；建议所有分支统一走归属校验。
12. **B2-02｜JetBrains 紧凑目录名**：`app_protection.sh:1955-1969` 的 `-name "${app_name}*"` 对 `IntelliJ IDEA` 恒不命中；建议建立产品名→目录名映射或读 `product-info.json`。
13. **B2-10｜cask token 字符集**：`lib/uninstall/brew.sh:298` 的 `^[a-z0-9][a-z0-9-]*$` 与 `:450` 的整行相等，使带空格/点号/中文的应用无法被识别为 cask；建议用 `brew info --cask` 的 artifact 路径反查。
14. **B1-21（预防性）｜系统级名字子串**：`app_protection.sh:2415-2431` 的 `*$app_name*.plist` 无归属校验、`:2293-2320` 的 24 条字面量无长度/厂商门槛、`:947-1024` 的 `/Users/Shared` 前缀臂过宽。当前被 `B:2344-2353` 的 review-only 挡住；若将来放开系统级删除，必须先补这一组。
15. **B2-03 / B2-04 / B2-11 / B2-12 / B2-13（低优先）｜字符与边界**：`app_protection.sh:1504` 只认 ASCII 空白、点号不生成变体；`lib/uninstall/config_refs.sh:48` 的左右边界不含全角标点/`\ `；`lib/uninstall/review.sh:43-44` 的 `google/chrome*` 缺 `/` 边界；`app_protection.sh:2135-2137` 的 PlayCover basename 字面相等。

### 复核结论

1. **误删面的真正入口是“名字派生”，不是通配。** `find_app_files` 里几乎全是字面路径 + `[[ -e ]]`；唯一的通配是 Zed 的 `dev.zed.Zed-*`（`AP:1547-1563`，前缀足够窄）。误删来自“字面路径恰好是共享目录/别家目录”，所以收紧 glob 元字符解决不了 B1-01～B1-18。
2. **守卫的结构性缺口是“没有应用归属校验”。** 现有守卫能证明“这是不是系统路径/共享根/同 id 存活副本/容器 owner/launchd program”，但不能证明“`Application Support/<X>` 属于当前这个 bundle”。凡是按名字拼出来的目录，只要名字撞上，就会一路走到 `mole_delete`。
3. **review-only 是当前最大的安全垫。** `/Library`、`/Users/Shared`、回执、系统诊断报告全部只展示不删（`B:2344-2353`），所以 U06/U07/U08 里一批“高/中-高”在本仓库 CLI 下退化为误报。这条不能被移除；一旦移除，第 4 节 G-19 之外的系统级归属校验必须先补齐。
4. **`--with-data` 会放大 personal 项。** 默认不选（`bin/uninstall.sh:2406`），但预选表是 deny-list（`review.sh:26-64`），`Application Support/Microsoft`、`Code`、`JetBrains`、`Godot`、`Acme/FooBar 2` 都不在表里，一旦用户加 `--with-data`，B1-01/B1-03/B1-05/B1-17 都会默认进入删除。
5. **空格/中文/点号本身不产生误删。** 删除层按行读、全程引号（`B:827-828`、`B:833-837`），`validate_path_for_deletion` 还会拒绝换行/控制符（`lib/core/file_ops.sh:1184-1188`）。这些字符的风险是“变体造不出真实名 → 漏找”（B2 全部），以及折叠变体撞上独立产品（已并入 B1-07）。
6. **`Foo 2` 是贯穿 7 份单元报告的系统性缺口。** 后缀表只认英文频道词（`AP:1351-1352`），导致：名字派生漏找（B2-01）、家族识别失效（B1-17）、共享判定失效（`B:1079-1082`）、Homebrew 识别失效（B2-10）。这是投入产出比最高的一处修复。


## 修复状态

2026-11-19 完成（集成分支 p7b-fix，已合入 engine main）。口径见 P7b-fix-policy.md：宁可漏删，不可误删。

| 编号 | 状态 | 改法 | 提交 |
|---|---|---|---|
| B1-01 | fixed | 渠道后缀表去掉 Edge，派生基名是厂商根（Microsoft/Google/Adobe…）时不派生，卸 Edge 不再碰 Microsoft 共享目录 | bf2494a |
| B1-02 | fixed | Godot 根目录列入共享保护，编辑器和导出的游戏都不再整棵收 Application Support/Godot | 3ce7282 |
| B1-03 | fixed | <bundle id>.* 前缀命中的容器/脚本目录必须是本 app 内嵌组件的 id 才收 | a241aa2 |
| B1-04 | fixed | Group Containers 只收 app 自己声明的，不收同 Team 共享的 App Group | 1490023 |
| B1-05 | fixed | 名字是产品/厂商词（Code、Microsoft 等）时不按名字收共享数据目录 | 11a4d01 |
| B1-06 | fixed | 按名字收数据叶子的门槛从 2 个字符提到 3 个（Go.app 不再收 ~/.config/go 等） | 06858e4 |
| B1-07 | fixed | 折叠名（Foo Bar→FooBar）若属于另一个已安装应用就不收 | b7f18c5 |
| B1-08 | fixed | bundle 末段派生的叶子若属于另一个已安装产品就不收 | ba86f2d |
| B1-09 | fixed | electron-updater 缓存只在 app 自己声明且无其他安装共用时才收 | 81f08e8 |
| B1-10 | fixed | Raycast 残留只按 bundle id 边界认，不再按名字子串 | 1e55cf9 |
| B1-11 | fixed | Xcode 缓存只对 Apple 的 Xcode 清，名字含 Xcode 的第三方不再触发 | 2394ed3 |
| B1-12 | fixed | ~/.android 缓存只对 Google 的 Android Studio 收 | 8c62c94 |
| B1-13 | fixed | JetBrains IDE 残留只对 com.jetbrains.* 收 | 37d6515 |
| B1-14 | fixed | VS Code 残留规则锚定到两个官方 bundle id | 80d8d26 |
| B1-15 | fixed | ByHost 偏好只认 <id>.<UUID>.plist 精确形状 | 10f45cd |
| B1-16 | fixed | 崩溃报告头部写的是别的 bundle 时不收 | 99d4a13 |
| B1-17 | fixed | 名字边界收紧，FooBar 不再吃 Foo 开头的其他产品目录 | e963092 |
| B1-18 | fixed | 认定 Homebrew cask 必须核对 cask 的 app 文件就是用户选的那个（-ef），不靠子串 | 6f7345d |
| B1-19 | fixed | 精确 label 的 LaunchAgent 删除前核对其程序路径属于本 app | 17f007d |
| B1-20 | fixed | CrashReporter 名字匹配在 UUID 边界截止，Foo 不再吃 Foo_Bar | b50b64d |
| B1-21 | fixed | 系统 LaunchDaemon 按 label 组件边界认、Steam 共享库与通用 Live 目录不进系统残留预览 | e7f6519 |
| B2-01 | kept | 保持现状：给 Foo 2 收 Foo 的目录会误删仍在用的旧版数据，宁可漏删 | — |
| B2-02 | fixed | IntelliJ IDEA 补收 JetBrains 紧凑产品码目录（IU/IC） | 835ddbd |
| B2-03 | fixed | 全角空格当作词间空格生成折叠变体，已装同名应用时不收 | 8e2f9a9 |
| B2-04 | fixed | 带点的显示名补收去点后的数据目录 | df529fa |
| B2-05 | fixed | 诊断报告前缀同时试带空格/不带空格两种写法 | 2e9b6ce |
| B2-06 | fixed | PlayCover 包在 Finder 改名后，凭其 Info.plist id 校验后补收 | e67b6d4 |
| B2-07 | fixed | PlayCover 别名目录里与包内文件字节一致的文件视为本包的，可收 | 69c6270 |
| B2-08 | fixed | find -name 里转义应用名，[EAP] 等方括号按字面匹配 | 24b4224 |
| B2-09 | kept | 保持现状：单字符名刻意不按名字找，宁可漏删 | — |
| B2-10 | fixed | Homebrew cask 改按 Caskroom 链接归属反查，不靠名字猜 token | e2e9a8d |
| B2-11 | fixed | 配置引用提示加锚定：Foo 不再命中 Foo 2，转义空格和 file:// 路径能命中（只读提示） | f483966 |
| B2-12 | kept | 保持现状：只是不预选（方向安全），用户可在 D 菜单手动选 | — |
| B2-13 | fixed | 带括号的渠道名（Foo (Beta)）先折叠再生成变体 | 7cd5697 |
