# P2 规格（用户 2026-11-14 01:14 拍板）
MVP 只做三项：
1. 清理（clean）：rules.json 169 条规则，默认 dry-run 预览 → 用户勾选 → 移废纸篓
2. 磁盘分析（analyze）：CLI 已有 --json
3. 卸载软件（uninstall）：应用 + 残留文件
明确不做：状态监控/菜单栏、系统优化(optimize)、风扇/电池(SMC)、AWDL、AI 月亮页、自动更新、许可证。
架构不变：引擎 = CLI@dc6605c 源码，桌面端 SwiftUI + JSON 薄适配层。
