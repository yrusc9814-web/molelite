#!/bin/bash
# 在 macOS 上把 MoleLite 打包成 build/MoleLite.app。
#
# 做的事：
#   1. swift build -c release
#   2. 组装 MoleLite.app（Contents/MacOS/MoleLite + 自写 Info.plist）
#   3. 把 ../engine 拷进 Contents/Resources/engine（排除 .git 与 tests）
#   4. 有 go 时在 engine 里编出 bin/analyze-go（bin/analyze.sh 就找这个名字）
#   5. 把 ../report/rules.json 拷进 Contents/Resources/rules.json
#   6. codesign --force --deep -s - 做 ad-hoc 签名
#
# 用法：
#   app/scripts/build-app.sh              # 正常打包
#   MOLE_SKIP_ANALYZE=1 app/scripts/build-app.sh   # 没装 Go 且不想让打包失败
#
# 环境变量：
#   MOLE_SKIP_ANALYZE=1  跳过 analyze 二进制构建（磁盘分析页会提示找不到二进制）
#   GO                   go 可执行文件路径，默认 PATH 里的 go

set -euo pipefail

# 解析脚本自身位置（允许从任意目录调用，允许软链接）
SCRIPT_PATH="${BASH_SOURCE[0]}"
while [ -L "$SCRIPT_PATH" ]; do
    LINK_DIR="$(cd -P "$(dirname "$SCRIPT_PATH")" && pwd)"
    SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
    case "$SCRIPT_PATH" in
        /*) ;;
        *) SCRIPT_PATH="$LINK_DIR/$SCRIPT_PATH" ;;
    esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_PATH")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$APP_DIR/.." && pwd)"

ENGINE_SRC="$REPO_DIR/engine"
RULES_SRC="$REPO_DIR/report/rules.json"

APP_NAME="MoleLite"
BUNDLE_ID="local.vanta.molelite"
VERSION="0.1.0"
BUILD_NUMBER="1"
MIN_MACOS="14.0"

BUILD_DIR="$APP_DIR/build"
BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
ENGINE_DEST="$RESOURCES_DIR/engine"

GO_BIN="${GO:-go}"

log() { printf '==> %s\n' "$*"; }
warn() { printf '警告: %s\n' "$*" >&2; }
die() { printf '错误: %s\n' "$*" >&2; exit 1; }

# ---------- 0. 环境检查 ----------

[ "$(uname -s)" = "Darwin" ] || die "这个脚本只能在 macOS 上跑（当前系统：$(uname -s)）。"

command -v swift >/dev/null 2>&1 || die "找不到 swift，请先装 Xcode 15+ 并执行 xcode-select --install 或选中 Xcode。"
command -v rsync >/dev/null 2>&1 || die "找不到 rsync（macOS 自带，请检查 PATH）。"
command -v codesign >/dev/null 2>&1 || die "找不到 codesign（随 Xcode 命令行工具提供）。"

[ -d "$ENGINE_SRC" ] || die "找不到引擎目录：$ENGINE_SRC"
[ -x "$ENGINE_SRC/bin/clean.sh" ] || warn "引擎里没有可执行的 bin/clean.sh，打包后清理页可能不可用。"
[ -x "$ENGINE_SRC/bin/uninstall.sh" ] || warn "引擎里没有可执行的 bin/uninstall.sh，打包后卸载页可能不可用。"
[ -f "$RULES_SRC" ] || die "找不到规则文件：$RULES_SRC"

# ---------- 1. 编译 ----------

log "swift build -c release（${APP_DIR}）"
( cd "$APP_DIR" && swift build -c release )

BIN_PATH="$( cd "$APP_DIR" && swift build -c release --show-bin-path )"
EXECUTABLE="$BIN_PATH/$APP_NAME"
[ -x "$EXECUTABLE" ] || die "编译产物不存在：$EXECUTABLE"

# ---------- 2. 组装 .app ----------

log "清理旧包：$BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

log "拷入可执行文件"
cp -p "$EXECUTABLE" "$MACOS_DIR/$APP_NAME"
chmod 755 "$MACOS_DIR/$APP_NAME"

log "写 Info.plist"
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh_CN</string>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_NUMBER</string>
	<key>LSMinimumSystemVersion</key>
	<string>$MIN_MACOS</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSSupportsAutomaticTermination</key>
	<true/>
	<key>NSSupportsSuddenTermination</key>
	<false/>
	<key>NSHumanReadableCopyright</key>
	<string>个人自用构建。引擎来自 tw93/Mole（GPL-3.0）。</string>
	<key>NSDesktopFolderUsageDescription</key>
	<string>清理与磁盘分析需要读取桌面里的文件大小信息。</string>
	<key>NSDocumentsFolderUsageDescription</key>
	<string>清理与磁盘分析需要读取文稿里的文件大小信息。</string>
	<key>NSDownloadsFolderUsageDescription</key>
	<string>清理与磁盘分析需要读取下载目录里的文件大小信息。</string>
	<key>NSRemovableVolumesUsageDescription</key>
	<string>磁盘分析需要读取外接卷的文件大小信息。</string>
</dict>
</plist>
PLIST

plutil -lint "$CONTENTS/Info.plist" >/dev/null || die "Info.plist 格式不合法"

# ---------- 3. 拷引擎 ----------

log "拷入引擎：$ENGINE_SRC -> $ENGINE_DEST"
mkdir -p "$ENGINE_DEST"
# 排除：git 元数据、bats 测试、以及仓库里可能残留的旧二进制（架构可能不对，下面重编）。
rsync -a \
    --exclude='.git' \
    --exclude='.git/' \
    --exclude='.gitignore' \
    --exclude='tests/' \
    --exclude='bin/analyze-go' \
    --exclude='bin/analyze-go.*' \
    --exclude='bin/analyze-darwin-*' \
    "$ENGINE_SRC/" "$ENGINE_DEST/"

chmod +x "$ENGINE_DEST"/bin/*.sh 2>/dev/null || true
[ -x "$ENGINE_DEST/bin/clean.sh" ] || die "引擎副本里没有 bin/clean.sh"
[ -x "$ENGINE_DEST/bin/uninstall.sh" ] || die "引擎副本里没有 bin/uninstall.sh"

# ---------- 4. analyze 二进制 ----------

# bin/analyze.sh 找的是同目录下的 analyze-go，所以编到 engine/bin/analyze-go。
if [ "${MOLE_SKIP_ANALYZE:-0}" = "1" ]; then
    warn "MOLE_SKIP_ANALYZE=1，跳过 analyze 二进制；磁盘分析页会报“找不到 analyze-go”。"
elif command -v "$GO_BIN" >/dev/null 2>&1; then
    log "编译 analyze：$("$GO_BIN" version)"
    (
        cd "$ENGINE_DEST"
        # 先直接 go build（不依赖网络拉 status 等其它目标），失败再退回 Makefile。
        if ! CGO_ENABLED=0 "$GO_BIN" build -trimpath -ldflags='-s -w' -o bin/analyze-go ./cmd/analyze; then
            warn "直接 go build 失败，改试 make build。"
            make build
        fi
    )
    [ -x "$ENGINE_DEST/bin/analyze-go" ] || die "go 构建结束但没有生成 bin/analyze-go"
else
    warn "PATH 里没有 go，跳过 analyze 二进制；磁盘分析页会提示找不到 analyze-go。"
    warn "装好 Go 后重跑本脚本，或设 MOLE_SKIP_ANALYZE=1 显式跳过。"
fi

# ---------- 5. 拷规则 ----------

log "拷入 rules.json"
cp -p "$RULES_SRC" "$RESOURCES_DIR/rules.json"

# 顺手带上许可证，别让 GPL 二进制裸奔。
if [ -f "$ENGINE_SRC/LICENSE" ]; then
    cp -p "$ENGINE_SRC/LICENSE" "$RESOURCES_DIR/engine/LICENSE" 2>/dev/null || true
fi

# ---------- 6. 签名 ----------

log "清扩展属性并做 ad-hoc 签名"
xattr -cr "$BUNDLE" 2>/dev/null || true
codesign --force --deep --sign - --timestamp=none "$BUNDLE"
codesign --verify --deep --strict "$BUNDLE" || die "签名校验失败"

# ---------- 7. 收尾 ----------

SIZE="$(du -sh "$BUNDLE" | cut -f1)"
log "完成：${BUNDLE}（${SIZE}）"
log "试运行：open \"$BUNDLE\""
if [ ! -x "$ENGINE_DEST/bin/analyze-go" ]; then
    warn "包内没有 analyze-go，磁盘分析页不可用（清理/卸载不受影响）。"
fi
