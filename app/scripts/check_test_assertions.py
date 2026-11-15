#!/usr/bin/env python3
"""核对 Tests/MoleLiteTests/DecodingTests.swift 里写死的数值/取值断言与 Fixtures 是否一致。

做法：
  1. 按 Models.swift 的解码语义（flex 转换、默认值、isAppBundle 判定、分组派生属性）
     在 Python 侧重算每条断言的真实值；
  2. 与测试源码里写死的期望值逐条比对。

只覆盖依赖 fixture 的断言；testUnknownAndMissingFieldsAreTolerated 用的是内联 JSON，
不依赖 fixture，脚本只做计数说明。

用法：python3 app/scripts/check_test_assertions.py [--root <repo root>]
退出码：0 = 全部一致；1 = 存在不一致（会逐条列出）。
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

FIXTURES = Path("app/Tests/MoleLiteTests/Fixtures")
TESTS = Path("app/Tests/MoleLiteTests/DecodingTests.swift")


# ---------- Models.swift 的 flex 语义 ----------

def flex_str(value):
    if value is None:
        return None
    if isinstance(value, str):
        return value
    return str(value)


def flex_int(value):
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    if isinstance(value, str):
        try:
            return int(value.strip())
        except ValueError:
            try:
                return int(float(value.strip()))
            except ValueError:
                return None
    return None


def flex_bool(value):
    if value is None:
        return None
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in ("true", "yes", "1"):
            return True
        if normalized in ("false", "no", "0"):
            return False
    return None


def risk_level(raw):
    normalized = (raw or "").strip().lower()
    return normalized if normalized in ("low", "medium", "high") else "unknown"


def execution_action(raw):
    normalized = (raw or "").lower()
    return normalized if normalized in ("removed", "trashed", "skipped", "failed") else "unknown"


# ---------- 条目构造 ----------

def clean_item(obj):
    size = flex_int(obj.get("size_bytes"))
    size_known = flex_bool(obj.get("size_known"))
    return {
        "rule_id": flex_str(obj.get("rule_id")),
        "section": flex_str(obj.get("section")),
        "path": flex_str(obj.get("path")) or "",
        "size_bytes": size if size is not None else 0,
        "default_selected": flex_bool(obj.get("default_selected")) is True,
        "needs_admin": flex_bool(obj.get("needs_admin")) is True,
        "risk": flex_str(obj.get("risk")),
        "risk_level": risk_level(flex_str(obj.get("risk"))),
        "items": flex_int(obj.get("items")),
        "size_known": size_known if size_known is not None else (size is not None),
        "covered_by": flex_str(obj.get("covered_by")),
    }


def clean_item_id(item):
    return f'{item["rule_id"] or "rule"}|{item["path"]}'


def clean_display_name(item):
    return item["path"].rstrip("/").rsplit("/", 1)[-1] or item["path"]


def clean_record(obj):
    return {
        "path": flex_str(obj.get("path")) or "",
        "section": flex_str(obj.get("section")),
        "action": flex_str(obj.get("action")),
        "action_kind": execution_action(flex_str(obj.get("action"))),
        "reason": flex_str(obj.get("reason")),
        "size_bytes": flex_int(obj.get("size_bytes")) or 0,
    }


def uninstall_preview_item(obj):
    kind = flex_str(obj.get("kind"))
    path = flex_str(obj.get("path")) or ""
    normalized = (kind or "").strip().lower()
    if normalized:
        is_app_bundle = normalized == "app"
    else:
        is_app_bundle = path.lower().endswith(".app")
    name = path.rstrip("/").rsplit("/", 1)[-1]
    return {
        "app": flex_str(obj.get("app")),
        "bundle_id": flex_str(obj.get("bundle_id")),
        "path": path,
        "kind": kind,
        "size_bytes": flex_int(obj.get("size_bytes")) or 0,
        "default_selected": flex_bool(obj.get("default_selected")) is True,
        "needs_admin": flex_bool(obj.get("needs_admin")) is True,
        "risk": flex_str(obj.get("risk")),
        "risk_level": risk_level(flex_str(obj.get("risk"))),
        "action": flex_str(obj.get("action")),
        "mode": flex_str(obj.get("mode")),
        "is_app_bundle": is_app_bundle,
        "display_name": name if name else (flex_str(obj.get("app")) or path),
    }


def uninstall_record(obj):
    return {
        "app": flex_str(obj.get("app")),
        "path": flex_str(obj.get("path")) or "",
        "kind": flex_str(obj.get("kind")),
        "action": flex_str(obj.get("action")),
        "action_kind": execution_action(flex_str(obj.get("action"))),
        "reason": flex_str(obj.get("reason")),
        "size_bytes": flex_int(obj.get("size_bytes")) or 0,
    }


def analyze_entry(obj):
    return {
        "scan_status": flex_str(obj.get("scan_status")),
        "name": flex_str(obj.get("name")) or "",
        "path": flex_str(obj.get("path")) or "",
        "size": flex_int(obj.get("size")) or 0,
        "is_dir": flex_bool(obj.get("is_dir")) is True,
        "insight": flex_bool(obj.get("insight")) is True,
        "cleanable": flex_bool(obj.get("cleanable")) is True,
        "last_access": flex_str(obj.get("last_access")),
    }


def analyze_file_entry(obj):
    return {
        "name": flex_str(obj.get("name")) or "",
        "path": flex_str(obj.get("path")) or "",
        "size": flex_int(obj.get("size")) or 0,
    }


# ---------- 断言核对 ----------

class Checker:
    def __init__(self):
        self.rows = []
        self.failures = []

    def check(self, line, expr, actual, expected):
        ok = actual == expected
        self.rows.append((line, expr, actual, expected, ok))
        if not ok:
            self.failures.append((line, expr, actual, expected))
        return ok

    def report(self):
        print(f'{"行":>5}  {"断言":<62} {"fixture 实算":>22}  {"测试期望":>22}  结果')
        print("-" * 124)
        for line, expr, actual, expected, ok in self.rows:
            print(f"{line:>5}  {expr:<62} {str(actual):>22}  {str(expected):>22}  {'OK' if ok else 'MISMATCH'}")
        print("-" * 124)
        print(f"共核对 {len(self.rows)} 条，不一致 {len(self.failures)} 条")
        for line, expr, actual, expected in self.failures:
            print(f"  MISMATCH 第 {line} 行: {expr}  fixture={actual!r}  测试写死={expected!r}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".", help="仓库根目录（包含 app/）")
    args = parser.parse_args()
    root = Path(args.root).resolve()

    def load(name):
        with open(root / FIXTURES / f"{name}.json", encoding="utf-8") as handle:
            return json.load(handle)

    clean_preview_raw = load("clean-preview")
    clean_execute_raw = load("clean-execute")
    uninstall_preview_raw = load("uninstall-preview")
    uninstall_execute_raw = load("uninstall-execute")
    analyze_raw = load("analyze")
    rules_raw = load("rules-sample")

    cp = [clean_item(o) for o in clean_preview_raw]
    ce = [clean_record(o) for o in clean_execute_raw]
    up = [uninstall_preview_item(o) for o in uninstall_preview_raw]
    ue = [uninstall_record(o) for o in uninstall_execute_raw]
    an_entries = [analyze_entry(o) for o in analyze_raw.get("entries") or []]
    an_files = [analyze_file_entry(o) for o in analyze_raw.get("large_files") or []]

    c = Checker()

    # testAllFixturesDecode
    c.check(10, "Fixture.names.count", 6, 6)
    c.check(13, "cleanPreview.items.count", len(cp), 9)
    c.check(16, "cleanExecution.records.count", len(ce), 6)
    c.check(19, "uninstallPreview.items.count", len(up), 5)
    c.check(22, "uninstallExecution.records.count", len(ue), 5)
    c.check(25, "rules.count", len(rules_raw), 3)
    c.check(28, "analyze.entries.count", len(an_entries), 4)
    c.check(29, "analyze.largeFiles.count", len(an_files), 2)

    # testCleanPreviewFields
    c.check(38, "items.count", len(cp), 9)
    c.check(39, "preview.totalBytes", sum(i["size_bytes"] for i in cp), 3_879_731_200)
    c.check(40, "Set(items.id).count", len({clean_item_id(i) for i in cp}), 9)
    c.check(43, "Set(items.section).count", len({i["section"] for i in cp if i["section"] is not None}), 6)
    c.check(
        44,
        "Set(items.section)",
        sorted({i["section"] for i in cp if i["section"] is not None}),
        sorted(["user_cache", "logs", "trash", "system_cache", "dev_cache", "downloads"]),
    )

    safari = next(i for i in cp if i["path"].endswith("/Caches/com.apple.Safari"))
    c.check(48, "safari.ruleID", safari["rule_id"], "user_cache-01")
    c.check(49, "safari.section", safari["section"], "user_cache")
    c.check(50, "safari.sizeBytes", safari["size_bytes"], 52_428_800)
    c.check(51, "safari.itemCount", safari["items"], 12)
    c.check(52, "safari.defaultSelected", safari["default_selected"], True)
    c.check(53, "safari.needsAdmin", safari["needs_admin"], False)
    c.check(54, "safari.riskLevel", safari["risk_level"], "low")
    c.check(55, "safari.sizeKnown", safari["size_known"], True)
    c.check(56, "safari.coveredBy", safari["covered_by"], None)
    c.check(57, "safari.displayName", clean_display_name(safari), "com.apple.Safari")

    chrome = next(i for i in cp if "/Google/Chrome/" in i["path"])
    c.check(60, "chrome.defaultSelected", chrome["default_selected"], False)
    c.check(61, "chrome.riskLevel", chrome["risk_level"], "medium")
    c.check(62, "chrome.itemCount", chrome["items"], 214)

    webkit = next(i for i in cp if i["path"].endswith("/com.apple.Safari/WebKit"))
    c.check(66, "webkit.sizeBytes", webkit["size_bytes"], 0)
    c.check(67, "webkit.sizeKnown", webkit["size_known"], False)
    c.check(
        68,
        "webkit.coveredBy",
        webkit["covered_by"],
        "user_cache-01:/Users/demo/Library/Caches/com.apple.Safari",
    )

    admin_item = next(i for i in cp if i["needs_admin"])
    c.check(72, "adminItem.path.hasSuffix(/com.apple.dyld)", admin_item["path"].endswith("/com.apple.dyld"), True)
    c.check(73, "adminItem.defaultSelected", admin_item["default_selected"], False)
    c.check(74, "adminItem.riskLevel", admin_item["risk_level"], "high")

    risks = {i["risk_level"] for i in cp}
    c.check(78, "risks ⊇ {low,medium,high}", {"low", "medium", "high"} <= risks, True)
    c.check(79, "risks ∌ unknown", "unknown" not in risks, True)

    c.check(81, "items.defaultSelected.count", sum(1 for i in cp if i["default_selected"]), 5)
    c.check(82, "items.needsAdmin.count", sum(1 for i in cp if i["needs_admin"]), 1)
    c.check(83, "items.!sizeKnown.count", sum(1 for i in cp if not i["size_known"]), 2)
    c.check(84, "items.coveredBy!=nil.count", sum(1 for i in cp if i["covered_by"] is not None), 1)

    # testCleanExecutionFields
    removed = [r for r in ce if r["action_kind"] == "removed"]
    skipped = [r for r in ce if r["action_kind"] == "skipped"]
    failed = [r for r in ce if r["action_kind"] == "failed"]
    c.check(96, "report.records.count", len(ce), 6)
    c.check(97, "report.removed.count", len(removed), 2)
    c.check(98, "report.skipped.count", len(skipped), 3)
    c.check(99, "report.failed.count", len(failed), 1)
    c.check(100, "report.removedBytes", sum(r["size_bytes"] for r in removed), 1_089_470_464)

    first = ce[0]
    c.check(103, "first.path", first["path"], "/Users/demo/Library/Caches/pip")
    c.check(104, "first.section", first["section"], "dev_cache")
    c.check(105, "first.actionKind", first["action_kind"], "removed")
    c.check(106, "first.succeeded", first["action_kind"] == "removed", True)
    c.check(107, "first.reason", first["reason"], None)
    c.check(109, "skipped.map(reason)", [r["reason"] for r in skipped], ["not_selected", "not_selected", "needs_admin"])
    c.check(110, "failed.first.reason", failed[0]["reason"] if failed else None, "permission denied")

    # testUninstallPreviewFields
    c.check(122, "preview.items.count", len(up), 5)
    c.check(123, "preview.totalBytes", sum(i["size_bytes"] for i in up), 1_609_363_660)

    app_item = next((i for i in up if i["is_app_bundle"]), None)
    c.check(125, "preview.appBundle != nil", app_item is not None, True)
    app_item = app_item or {}
    c.check(126, "app.app", app_item.get("app"), "Slack")
    c.check(127, "app.bundleID", app_item.get("bundle_id"), "com.tinyspeck.slackmacgap")
    c.check(128, "app.path", app_item.get("path"), "/Users/demo/Applications/Slack.app")
    c.check(129, "app.kind", app_item.get("kind"), "app")
    c.check(130, "app.sizeBytes", app_item.get("size_bytes"), 268_435_456)
    c.check(131, "app.defaultSelected", app_item.get("default_selected"), True)
    c.check(132, "app.needsAdmin", app_item.get("needs_admin"), False)
    c.check(133, "app.riskLevel", app_item.get("risk_level"), "low")
    c.check(134, "app.mode", app_item.get("mode"), "trash")
    c.check(135, "app.displayName", app_item.get("display_name"), "Slack.app")

    leftovers = [i for i in up if not i["is_app_bundle"]]
    c.check(137, "preview.leftovers.count", len(leftovers), 4)
    c.check(
        138,
        "Set(leftovers.kind)",
        sorted({i["kind"] for i in leftovers if i["kind"] is not None}),
        sorted(["app_support", "caches", "preferences", "launch_agent"]),
    )

    launch_agent = next(i for i in up if i["kind"] == "launch_agent")
    c.check(143, "launchAgent.needsAdmin", launch_agent["needs_admin"], True)
    c.check(144, "launchAgent.defaultSelected", launch_agent["default_selected"], False)
    c.check(145, "launchAgent.riskLevel", launch_agent["risk_level"], "high")
    c.check(146, "launchAgent.isAppBundle", launch_agent["is_app_bundle"], False)

    # testUninstallExecutionFields
    u_trashed = [r for r in ue if r["action_kind"] == "trashed"]
    u_removed = [r for r in ue if r["action_kind"] == "removed"]
    u_skipped = [r for r in ue if r["action_kind"] == "skipped"]
    u_failed = [r for r in ue if r["action_kind"] == "failed"]
    c.check(154, "report.records.count", len(ue), 5)
    c.check(155, "report.trashed.count", len(u_trashed), 2)
    c.check(156, "report.removed.count", len(u_removed), 1)
    c.check(157, "report.skipped.count", len(u_skipped), 1)
    c.check(158, "report.failed.count", len(u_failed), 1)
    c.check(159, "report.hasPermanentRemoval", bool(u_removed), True)
    c.check(160, "report.trashedBytes", sum(r["size_bytes"] for r in u_trashed), 1_556_925_644)

    permanent = u_removed[0] if u_removed else None
    c.check(162, "permanent != nil", permanent is not None, True)
    permanent = permanent or {}
    c.check(163, "permanent.isPermanentRemoval", permanent.get("action_kind") == "removed", True)
    c.check(164, "permanent.path", permanent.get("path"), "/Users/demo/Library/Caches/com.tinyspeck.slackmacgap")
    c.check(165, "permanent.reason", permanent.get("reason"), "trash unavailable, removed permanently")
    c.check(167, "skipped.first.reason", u_skipped[0]["reason"] if u_skipped else None, "not_selected")
    c.check(168, "failed.first.reason", u_failed[0]["reason"] if u_failed else None, "operation not permitted")
    c.check(169, "records.first.isPermanentRemoval", ue[0]["action_kind"] == "removed", False)

    # testAnalyzeFields
    c.check(177, "output.scanStatus", flex_str(analyze_raw.get("scan_status")), "complete")
    c.check(178, "output.path", flex_str(analyze_raw.get("path")), "/Users/demo")
    c.check(179, "output.overview", flex_bool(analyze_raw.get("overview")) is True, True)
    c.check(180, "output.totalSize", flex_int(analyze_raw.get("total_size")) or 0, 59_055_800_320)
    c.check(181, "output.totalFiles", flex_int(analyze_raw.get("total_files")), 184_320)
    c.check(183, "output.entries.count", len(an_entries), 4)

    library = next(i for i in an_entries if i["name"] == "Library")
    c.check(185, "library.path", library["path"], "/Users/demo/Library")
    c.check(186, "library.size", library["size"], 42_949_672_960)
    c.check(187, "library.isDir", library["is_dir"], True)
    c.check(188, "library.insight", library["insight"], True)
    c.check(189, "library.cleanable", library["cleanable"], False)
    c.check(190, "library.lastAccess", library["last_access"], "2026-11-13")

    downloads = next(i for i in an_entries if i["name"] == "Downloads")
    c.check(193, "downloads.cleanable", downloads["cleanable"], True)

    photos = next(i for i in an_entries if i["name"].endswith(".photoslibrary"))
    c.check(197, "photos.scanStatus", photos["scan_status"], "unavailable")
    c.check(198, "photos.size", photos["size"], 0)
    c.check(199, "photos.lastAccess", photos["last_access"], None)

    sorted_entries = sorted(an_entries, key=lambda i: -i["size"])
    c.check(202, "output.sortedEntries.first", sorted_entries[0]["name"], "Library")
    c.check(203, "output.sortedEntries.last", sorted_entries[-1]["name"], "Photos Library.photoslibrary")

    c.check(205, "output.largeFiles.count", len(an_files), 2)
    c.check(207, "backup.name", an_files[0]["name"], "backup-2026.tar.zst")
    c.check(208, "backup.size", an_files[0]["size"], 8_589_934_592)
    c.check(209, "largeFiles.last.path", an_files[-1]["path"], "/Users/demo/Downloads/Xcode_15.4.xip")

    c.report()

    # 内联 JSON 用例的说明
    tests_path = root / TESTS
    if tests_path.exists():
        source_lines = tests_path.read_text(encoding="utf-8").splitlines()
        inline = [i for i, line in enumerate(source_lines, 1) if "testUnknownAndMissingFieldsAreTolerated" in line]
        print(
            f"\n另: testUnknownAndMissingFieldsAreTolerated（第 {inline[0] if inline else '?'} 行起）"
            "用的是内联 JSON，不依赖 Fixtures，不在本脚本核对范围内。"
        )

    if c.failures:
        print("\n结论: FAIL（测试写死的期望值与 Fixture 不一致）")
        return 1
    print("\n结论: PASS（DecodingTests 中依赖 Fixture 的断言与 Fixture 全部一致）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
