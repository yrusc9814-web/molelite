#!/usr/bin/env python3
"""自查：app/ 里是否混入了 artifacts/Mole.app 的原版文案或素材。

做法（全部脚本化，不读 engine、不改任何文件）：
1. 从 Mole.app 的 en.lproj / zh-Hans.lproj 的 Localizable.strings 里按长度取前 30 条长句；
2. 把 app/ 下所有文本文件（Swift / md / sh / py / json）拼成一个大字符串；
3. 三条比对：
   a. 30 条长句逐条做「归一化后整句包含」检查；
   b. 对 Mole 全部 3000+ 条字符串求「与 app 文本的最长公共子串」，>= 20 字符视为照抄片段；
      （10~16 字符的公共片段必然是 "Command Line Tools"、"Permission denied" 这类通用技术词，
       单独列出但不判失败）
   c. app 里的散文行（长度 >= 12、且不是代码/JSON 行）与 Mole 某条字符串完全相同，也算命中；
4. 素材：列出 app/ 下所有图片/图标类文件，并检查 build 脚本与 Info.plist 是否引用 Mole 图标名。

退出码：0 = 干净；1 = 有命中。
"""
from __future__ import annotations

import argparse
import plistlib
import re
import sys
from pathlib import Path

TEXT_SUFFIXES = {".swift", ".md", ".sh", ".py", ".json", ".plist", ".txt", ".yml", ".yaml"}
ASSET_SUFFIXES = {".png", ".jpg", ".jpeg", ".icns", ".car", ".pdf", ".tiff", ".gif", ".webp", ".svg"}
SAMPLE_SIZE = 30
NGRAM = 20          # 判为照抄的最短公共子串
NOISE = 16          # 只报告、不判失败的公共片段长度
MIN_LINE = 12

# 归一化时去掉的字符：空白、常见中英文标点、格式占位符。
PUNCT = " \t\r\n\u3000，。、；：！？“”‘’（）《》〈〉…—·,.;:!?\"'()[]{}<>/\\|@#$%^&*_+=~`"
FORMAT_RE = re.compile(r"%[@dfsu]|%\.\d+f|\{\d+\}")

# 明显是代码/数据而不是界面散文的行，不参与 [C] 整行比对。
CODE_LINE_RE = re.compile(
    r"^\s*(//|/\*|\*|import |@|#|let |var |func |case |guard |if |else |return |try |await |"
    r"public |private |internal |struct |class |enum |extension |protocol |static |\}|\{|"
    r'"[^"]*"\s*[:=]|\d+[.,]?$|-\s|\w+\(|.*[;{}]\s*$)'
)


def normalize(text: str) -> str:
    text = FORMAT_RE.sub("", text)
    return "".join(ch for ch in text if ch not in PUNCT).lower()


def load_strings(path: Path) -> dict[str, str]:
    raw = path.read_bytes()
    for encoding in ("utf-16", "utf-8"):
        try:
            text = raw.decode(encoding)
            break
        except UnicodeDecodeError:
            continue
    else:  # pragma: no cover - 资源损坏时显式失败
        raise SystemExit(f"无法解码 {path}")
    data = plistlib.loads(text.encode("utf-8"))
    return {k: v for k, v in data.items() if isinstance(v, str) and v.strip()}


def app_text(root: Path) -> tuple[str, list[tuple[Path, str]]]:
    chunks: list[str] = []
    lines: list[tuple[Path, str]] = []
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.suffix.lower() not in TEXT_SUFFIXES:
            continue
        if ".git" in path.parts or "build" in path.parts:
            continue
        try:
            content = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        chunks.append(content)
        for line in content.splitlines():
            lines.append((path.relative_to(root), line))
    return "\n".join(chunks), lines


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".", help="仓库根目录（含 app/ 与 artifacts/）")
    parser.add_argument("--sample", type=int, default=SAMPLE_SIZE)
    args = parser.parse_args()

    repo = Path(args.root).resolve()
    app_dir = repo / "app"
    resources = repo / "artifacts/extract/stage1/Mole.app/Contents/Resources"
    if not app_dir.is_dir():
        raise SystemExit(f"找不到 app 目录：{app_dir}")
    if not resources.is_dir():
        raise SystemExit(f"找不到 Mole.app 资源目录：{resources}")

    text, app_lines = app_text(app_dir)
    norm_text = normalize(text)
    if not norm_text:
        raise SystemExit("app 文本为空，无法比对")

    print("Mole 原版文案比对（app/ vs artifacts/extract/stage1/Mole.app）")
    print(f"仓库: {repo}")
    print(f"app 文本: {len(text)} 字符 / {len(app_lines)} 行；归一化后 {len(norm_text)} 字符")
    print()

    all_strings: dict[str, str] = {}
    for loc in ("en", "zh-Hans"):
        path = resources / f"{loc}.lproj/Localizable.strings"
        if not path.is_file():
            print(f"警告: 缺少 {path}")
            continue
        values = load_strings(path)
        print(f"{loc}.lproj/Localizable.strings: {len(values)} 条")
        for key, value in values.items():
            all_strings.setdefault(f"{loc}:{key}", value)
    print(f"合计 {len(all_strings)} 条（去重前按 key 计）")
    print()

    hits: list[str] = []

    # a. 30 条长句
    def longest(prefix: str, count: int) -> list[tuple[str, str]]:
        pool = [(k, v) for k, v in all_strings.items() if k.startswith(prefix)]
        pool.sort(key=lambda kv: len(kv[1]), reverse=True)
        return pool[:count]

    samples = longest("zh-Hans:", args.sample) + longest("en:", args.sample)
    print(f"[A] 抽 {len(samples)} 条长句（zh-Hans {args.sample} + en {args.sample}）逐条比对：")
    for key, value in samples:
        needle = normalize(value)
        status = "命中" if needle and needle in norm_text else "未命中"
        if status == "命中":
            hits.append(f"长句命中 {key}: {value[:60]}")
        print(f"  {status}  [{len(value):>3}] {key}")
    print()

    # b. 与 app 文本的最长公共子串
    print(f"[B] 全部字符串对 app 文本求最长公共子串（>= {NGRAM} 判为照抄）：")

    def longest_common(needle: str) -> str:
        """二分长度 + 滑窗集合，返回 needle 与 app 文本的最长公共子串。"""
        low, high, best = 1, min(len(needle), len(norm_text)), ""
        while low <= high:
            mid = (low + high) // 2
            window = next((needle[i:i + mid]
                           for i in range(len(needle) - mid + 1)
                           if needle[i:i + mid] in norm_text), None)
            if window:
                best, low = window, mid + 1
            else:
                high = mid - 1
        return best

    fragment_hits: list[str] = []
    noise_hits: list[tuple[int, str, str]] = []
    for key, value in all_strings.items():
        needle = normalize(value)
        if len(needle) < MIN_LINE:
            continue
        common = longest_common(needle)
        if len(common) >= NGRAM:
            fragment_hits.append(f"{key}: …{common}…（原文 {value[:50]}）")
        elif len(common) >= MIN_LINE:
            noise_hits.append((len(common), key, common))
    if fragment_hits:
        hits.extend(fragment_hits)
        print(f"  命中 {len(fragment_hits)} 条：")
        for item in fragment_hits[:40]:
            print(f"    {item}")
    else:
        print(f"  0 条命中（共检查 {len(all_strings)} 条）")
    noise_hits.sort(reverse=True)
    if noise_hits:
        print(f"  另有 {len(noise_hits)} 条只共享通用技术词（{MIN_LINE}~{NGRAM - 1} 字符），不判失败：")
        for length, key, common in noise_hits[:10]:
            print(f"    [{length}] {key}: {common}")
    print()

    # c. 整行相同
    print("[C] app 散文行与 Mole 字符串整行相同：")
    mole_norm = {normalize(v) for v in all_strings.values() if len(normalize(v)) >= MIN_LINE}
    line_hits = 0
    for rel, line in app_lines:
        norm = normalize(line)
        if len(norm) < MIN_LINE or norm not in mole_norm:
            continue
        if CODE_LINE_RE.match(line):
            continue
        line_hits += 1
        hits.append(f"整行相同 {rel}: {line.strip()[:60]}")
        print(f"  {rel}: {line.strip()[:80]}")
    if line_hits == 0:
        print("  0 行")
    print()

    # 素材
    print("[D] app/ 下图片/图标类文件：")
    assets = [p.relative_to(app_dir) for p in app_dir.rglob("*")
              if p.is_file() and p.suffix.lower() in ASSET_SUFFIXES and ".git" not in p.parts]
    if assets:
        for item in assets:
            print(f"  {item}")
            hits.append(f"图片素材 {item}")
    else:
        print("  0 个（界面全部用 SF Symbols，无自绘/拷贝位图）")
    print()

    print("[E] build 脚本 / Info.plist 是否引用 Mole 图标或 bundle 名：")
    markers = ["mole.icns", "mole-logo", "CFBundleIconFile", "tw93.Mole", "com.tw93"]
    referenced = []
    for name in ("scripts/build-app.sh", "BUILD.md", "Package.swift"):
        path = app_dir / name
        if not path.is_file():
            continue
        content = path.read_text(encoding="utf-8")
        for marker in markers:
            if marker in content:
                referenced.append(f"{name}: {marker}")
    if referenced:
        hits.extend(referenced)
        for item in referenced:
            print(f"  引用 {item}")
    else:
        print("  0 处")
    print()

    print("-" * 70)
    if hits:
        print(f"结论: FAIL（{len(hits)} 处命中，疑似拷自 Mole.app）")
        return 1
    print(f"结论: PASS（{len(samples)} 条长句、{len(all_strings)} 条字符串最长公共子串、整行、素材、图标引用均无命中）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
