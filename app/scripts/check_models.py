#!/usr/bin/env python3
"""校验 app/Tests/MoleLiteTests/Fixtures/*.json 的键都被 Models.swift 的 CodingKeys 覆盖。

做法：
1. 从 Swift 源码里按 struct 抓出 `private enum CodingKeys: String, CodingKey { ... }`
   的每个 case，`case foo = "bar"` 取 "bar"，`case foo` 取 foo —— 即该结构体接受的 JSON 键。
2. 按 FIXTURE_TYPES 映射，逐个 fixture 取顶层（以及 analyze 的 entries/large_files 子数组）
   的键，检查是否都落在对应结构体的键集合里；不在集合里就是"未覆盖"，报错。
3. 同时报告 CodingKeys 里 fixture 未出现的键（仅提示，不算失败）。

只读文件，不依赖网络/第三方库。用法：
    python3 app/scripts/check_models.py [--root .]
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# fixture 文件 -> [(JSON 里的数组路径, Swift 结构体名)]
# 路径 () 表示顶层数组/对象本身；("entries",) 表示 obj["entries"] 的每个元素。
FIXTURE_TYPES: dict[str, list[tuple[tuple[str, ...], str]]] = {
    "clean-preview.json": [((), "CleanPreviewItem")],
    "clean-execute.json": [((), "CleanExecutionRecord")],
    "uninstall-preview.json": [((), "UninstallPreviewItem")],
    "uninstall-execute.json": [((), "UninstallExecutionRecord")],
    "rules-sample.json": [((), "RuleOverride")],
    "analyze.json": [
        ((), "AnalyzeOutput"),
        (("entries",), "AnalyzeEntry"),
        (("large_files",), "AnalyzeFileEntry"),
    ],
}

# rules.json 里 RuleOverride 有意不解析的键：RulesCatalog 只取覆盖用的 4 个字段，
# 其余字段靠 Codable 对未知键的容忍忽略。这里显式登记，避免"看起来没校验"。
KNOWN_EXTRAS: dict[str, set[str]] = {
    "rules-sample.json": {
        "category",
        "paths",
        "match",
        "action",
        "command",
        "protected_by",
        "source",
        "in_app",
        "in_app_evidence",
    },
}

# 结构体可能不在 Models.swift（RuleOverride 在 RulesCatalog.swift），按目录整体扫描。
DEFAULT_SOURCES = [
    "app/Sources/MoleLite/Engine/Models.swift",
    "app/Sources/MoleLite/Engine/RulesCatalog.swift",
]

CASE_RE = re.compile(r'^\s*case\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:=\s*"([^"]*)")?\s*$')
STRUCT_RE = re.compile(r'\bstruct\s+([A-Za-z_][A-Za-z0-9_]*)[^{]*\{')


def strip_line_comments(text: str) -> str:
    """去掉 // 注释，避免被引号里的内容干扰。"""
    out = []
    for line in text.splitlines():
        idx = line.find("//")
        out.append(line if idx < 0 else line[:idx])
    return "\n".join(out)


def parse_structs(text: str) -> dict[str, str]:
    """返回 {结构体名: 结构体源码块}，用大括号配平切块。"""
    text = strip_line_comments(text)
    blocks: dict[str, str] = {}
    for match in STRUCT_RE.finditer(text):
        name = match.group(1)
        start = match.end() - 1  # 指向 '{'
        depth = 0
        for pos in range(start, len(text)):
            ch = text[pos]
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    blocks[name] = text[start + 1 : pos]
                    break
    return blocks


def coding_keys(struct_body: str) -> list[str] | None:
    """抓出结构体内 CodingKeys 的 JSON 键；没有 CodingKeys 返回 None。"""
    match = re.search(r"enum\s+CodingKeys\s*:\s*String\s*,\s*CodingKey\s*\{", struct_body)
    if not match:
        return None
    depth = 0
    start = match.end() - 1
    end = None
    for pos in range(start, len(struct_body)):
        ch = struct_body[pos]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                end = pos
                break
    if end is None:
        return None
    keys: list[str] = []
    for line in struct_body[start + 1 : end].splitlines():
        m = CASE_RE.match(line)
        if not m:
            continue
        keys.append(m.group(2) if m.group(2) is not None else m.group(1))
    return keys


def load_key_index(root: Path, sources: list[str]) -> tuple[dict[str, list[str]], list[str]]:
    index: dict[str, list[str]] = {}
    missing_files: list[str] = []
    for rel in sources:
        path = root / rel
        if not path.is_file():
            missing_files.append(rel)
            continue
        blocks = parse_structs(path.read_text(encoding="utf-8"))
        for name, body in blocks.items():
            keys = coding_keys(body)
            if keys is not None:
                index.setdefault(name, keys)
    return index, missing_files


def walk_objects(payload, path: tuple[str, ...]):
    """按路径取出待检查的对象列表。"""
    node = payload
    for key in path:
        if not isinstance(node, dict) or key not in node:
            return []
        node = node[key]
    if isinstance(node, dict):
        return [node]
    if isinstance(node, list):
        return [item for item in node if isinstance(item, dict)]
    return []


def main() -> int:
    ap = argparse.ArgumentParser(description="校验 fixtures 的 JSON 键是否被 CodingKeys 覆盖")
    ap.add_argument("--root", default=".", help="仓库根目录（默认当前目录）")
    ap.add_argument("--fixtures", default="app/Tests/MoleLiteTests/Fixtures")
    args = ap.parse_args()

    root = Path(args.root).resolve()
    fixtures_dir = root / args.fixtures
    index, missing_files = load_key_index(root, DEFAULT_SOURCES)

    errors: list[str] = []
    warnings: list[str] = []
    rows: list[tuple[str, str, int, int, str]] = []

    if missing_files:
        for rel in missing_files:
            errors.append(f"源文件不存在: {rel}")
    if not index:
        errors.append("没有从 Swift 源码里解析到任何 CodingKeys")

    for fixture, targets in FIXTURE_TYPES.items():
        path = fixtures_dir / fixture
        if not path.is_file():
            errors.append(f"fixture 不存在: {fixture}")
            continue
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            errors.append(f"{fixture}: JSON 解析失败: {exc}")
            continue

        for json_path, type_name in targets:
            keys = index.get(type_name)
            label = type_name if not json_path else f"{type_name}<-{'.'.join(json_path)}"
            if keys is None:
                errors.append(f"{fixture}: 在 Swift 源码里找不到 {type_name} 的 CodingKeys")
                continue
            allowed = set(keys)
            extras = KNOWN_EXTRAS.get(fixture, set())
            objects = walk_objects(payload, json_path)
            if not objects:
                errors.append(f"{fixture}: {label} 没有对象可校验（路径为空）")
                continue

            used: set[str] = set()
            unknown: set[str] = set()
            for obj in objects:
                for key in obj:
                    if key in allowed:
                        used.add(key)
                    elif key in extras:
                        continue  # 已登记的非覆盖字段
                    else:
                        unknown.add(key)
            for key in sorted(unknown):
                errors.append(f"{fixture}: {label} 出现未覆盖的键 {key!r}")
            for key in keys:
                if key not in used:
                    warnings.append(f"{fixture}: {label} 未覆盖 CodingKeys.{key}")

            rows.append(
                (
                    fixture,
                    label,
                    len(objects),
                    len(used),
                    "OK" if not unknown else "FAIL",
                )
            )

    print("Fixtures 键覆盖检查（Models.swift / RulesCatalog.swift 的 CodingKeys）")
    print(f"根目录: {root}")
    print("源文件: " + ", ".join(s for s in DEFAULT_SOURCES if s not in missing_files))
    print()
    print(f"{'fixture':<24}{'结构体':<28}{'对象':>4}{'命中键':>6}  结果")
    print("-" * 78)
    for fixture, label, count, hits, status in rows:
        print(f"{fixture:<24}{label:<28}{count:>4}{hits:>6}  {status}")

    total_keys = sum(len(v) for v in index.values())
    print("-" * 78)
    print(f"解析到 {len(index)} 个 CodingKeys 枚举，共 {total_keys} 个 JSON 键。")

    if warnings:
        print()
        print("提示（不算失败）：")
        for item in warnings:
            print(f"  - {item}")

    if errors:
        print()
        print("失败：")
        for item in errors:
            print(f"  - {item}")
        print()
        print(f"结论: FAIL（{len(errors)} 项）")
        return 1

    print()
    print(f"结论: PASS（{len(rows)} 组键全部被 CodingKeys 覆盖）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
