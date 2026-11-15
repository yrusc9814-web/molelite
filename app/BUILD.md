# MoleLite 构建说明（macOS）

MoleLite 是 SwiftUI 桌面壳，底层调用 Mole CLI（`engine/`）干活。**只能在 macOS 上构建**，Linux/沙盒里编不了 Swift，所以本仓库里的 Swift 代码都是"以 macOS 14 + Xcode 15 能 `swift build` 通过为准"写的，尚未在 Mac 上编译验证过。

## 前置条件

| 项目 | 要求 | 说明 |
| --- | --- | --- |
| 系统 | macOS 14 (Sonoma) 或更高 | `Package.swift` 里 `platforms: [.macOS(.v14)]` |
| Xcode | Xcode 15 或更高 | 需要完整 Xcode，只有 Command Line Tools 不够（SwiftUI 预览/编译） |
| Swift | 5.9+ | 随 Xcode 15 提供，无需单独装 |
| Go | 可选，1.26+ | 只有要打磁盘分析用的 `analyze-go` 才需要（`engine/go.mod` 写的是 `go 1.26.0`） |
| rsync / codesign / plutil | 系统自带 | `build-app.sh` 用它们拷引擎、签名、校验 plist |

第一次用前确认工具链指向完整 Xcode：

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -version     # 应显示 Xcode 15.x
swift --version
```

## 构建命令

在仓库根目录（`mole-re/`）：

```bash
# 一键打包：编译 → 组装 build/MoleLite.app → 拷引擎与规则 → ad-hoc 签名
./app/scripts/build-app.sh

# 产物
open app/build/MoleLite.app
```

脚本做的事，按顺序：

1. `swift build -c release`（在 `app/` 下）；
2. 组装 `app/build/MoleLite.app`，`Contents/MacOS/MoleLite` + 自写 `Info.plist`（`CFBundleIdentifier = local.vanta.molelite`，`LSMinimumSystemVersion = 14.0`，显示名 `MoleLite`）；
3. 用 `rsync` 把 `../engine` 拷到 `Contents/Resources/engine`，排除 `.git`、`tests/` 和旧的 analyze 二进制；
4. 有 `go` 时在包内 `engine/` 里编 `bin/analyze-go`（`bin/analyze.sh` 找的就是这个文件名；直接 `go build ./cmd/analyze`，失败才退回 `make build`）；
5. 拷 `../report/rules.json` 到 `Contents/Resources/rules.json`；
6. `codesign --force --deep --sign -` 做 ad-hoc 签名，并 `codesign --verify --deep --strict` 自检。

可选开关：

```bash
# 没装 Go，且不想看到"跳过 analyze"的警告时显式跳过（磁盘分析页会提示找不到 analyze-go）
MOLE_SKIP_ANALYZE=1 ./app/scripts/build-app.sh

# 指定某个 go
GO=/usr/local/go/bin/go ./app/scripts/build-app.sh
```

ad-hoc 签名（`-s -`）只够本机自用：拷到别的机器会被 Gatekeeper 拦，需要右键 → 打开，或自己重新签名。

## 开发时直接跑（不打包）

不用每次打包，用环境变量把引擎目录指过去即可：

```bash
cd app
MOLE_ENGINE_DIR="$(cd ../engine && pwd)" swift run MoleLite
```

`EngineRunner` 找引擎的顺序是：`MOLE_ENGINE_DIR` → `Bundle.main.resourceURL/engine` → 可执行文件旁边的 `engine/`。`swift run` 时没有 bundle，所以**必须**设 `MOLE_ENGINE_DIR`。

同理，规则文件也可以临时指定：

```bash
MOLE_ENGINE_DIR="$(cd ../engine && pwd)" \
MOLE_RULES_JSON="$(cd ../report && pwd)/rules.json" \
swift run MoleLite
```

## 首次运行：给"完全磁盘访问"

清理、磁盘分析、卸载都要读别的 App 的目录（`~/Library`、`/Applications` 等），macOS 会拦。首次运行前：

1. 打开 **系统设置 → 隐私与安全性 → 完全磁盘访问权限**；
2. 点 `+`，选中 `app/build/MoleLite.app`（开发时选 `.build/release/MoleLite` 或你的终端 App）；
3. 打开开关，然后**完全退出并重启 MoleLite**。

没给权限时，扫描结果会偏小、部分目录报"权限不足"，属预期行为，不会崩。

## 单元测试

```bash
cd app
swift test
```

覆盖：Fixtures 里每个 JSON 的解码（字段缺失/未知字段容忍）、`RulesCatalog` 的按 `rule_id` 覆盖逻辑、"未预览不得执行"的安全约束（用 `FakeEngines` 假引擎，不碰真引擎、不碰真实 HOME）。

沙盒里另外用两个 Python 脚本做静态核对（不需要 Swift 工具链）：

```bash
python3 app/scripts/check_models.py --root .          # Fixtures 键 vs Models.swift CodingKeys
python3 app/scripts/check_test_assertions.py --root . # 测试里写死的数值 vs Fixture 真实值
```

## 在 Mac 上补跑引擎测试

引擎是 bash + Go，测试必须在 Mac 上补跑（Linux 上 uninstall 相关用例会卡住）。

```bash
cd engine

# 全部 bats：tests/ 下有 103 个 .bats 文件，串行跑非常久（先 brew install bats-core）
bats tests/

# 只想先跑和本次改动相关的
bats tests/selection.bats
bats tests/clean_core.bats
bats tests/uninstall.bats

# 想并行走仓库自带的 test.sh：它会给 bats 加 --jobs / --formatter tap，
# 处理临时 HOME 和 sudo 桩，并把 TAP 落到指定目录
MOLE_TEST_REPORT_DIR=../report/logs/P5-mac MOLE_TEST_NO_AUTH=1 ./scripts/test.sh

# Go 侧（analyze 的 JSON 输出、过滤、缓存等）
go test ./cmd/analyze/...

# 或者用仓库自带入口（会顺带跑 lint/format 检查）
MOLE_TEST_NO_AUTH=1 ./scripts/test.sh
```

跑完把结果和 `report/logs/P3-full-new/` 里的同名 TAP 对比：**不允许出现新的失败**。P3 基线里已知的环境性失败（mail/downloads 权限、Time Machine 卷、Caskroom 等）在 Mac 上可能会变少，属正常。

`bats` 不在系统里，装法：`brew install bats-core`。

## 已知未验证项

以下都**没有在真 Mac 上跑过**，第一次构建时请重点看：

1. **Swift 编译本身**：沙盒无 Swift 工具链，全部 Swift 代码只做了静态核对（括号、类型签名、API 名、单文件 <300 行），没编译过。可能出现小的编译错误（比如某个 SwiftUI 修饰符在 macOS 14 上的确切签名）。
2. **`build-app.sh` 未实跑**：`bash -n` 通过，但 `swift build`、`rsync` 排除规则、`codesign --deep` 在真实 `.app` 上的行为都没验证。
3. **Go 构建路径**：脚本假设 `go build -o bin/analyze-go ./cmd/analyze` 能直接成功；`engine/go.mod` 的依赖需要能联网拉取。若失败会退回 `make build`，但 `make build` 会同时编 `status` 且先跑 `go mod download`，可能更慢。
4. **引擎调用契约**：`clean`/`uninstall` 的 JSON 字段按 `report/P3-summary.md` 实现，Fixtures 是**手写**的，不是引擎真实输出；真实引擎输出若有出入，解码会走"缺字段不崩"的兜底但显示会缺项。
5. **`MOLE_SELECTION_FILE`**：engine 侧已加（engine 提交 `21166d0` + 回归 `978bade`），但只在 Linux 沙盒里用假 HOME 验过，没在真 Mac 上跑过完整 UI → 引擎链路。
6. **完全磁盘访问**：没验证过 TCC 授权后子进程（`/bin/bash` 调引擎）是否继承权限；若扫描结果仍偏小，需要在终端里也授权。
7. **卸载的"移到废纸篓"**：依赖引擎走 Finder/AppleScript 回收站，沙盒里没跑过；`trashed` 与 `removed` 的区分只在 Fixtures 层面验证过。
8. **签名与 Gatekeeper**：ad-hoc 签名在 Apple Silicon 上首次打开可能仍需右键 → 打开。
