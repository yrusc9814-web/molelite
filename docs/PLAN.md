# Mole 逆向 + 自用重写 计划（Hark 拆解/监督，dsh 执行）

目标：用 REA 摸清 Mole Mac 版（mole.fit，v1.20.1 dmg）的功能、结构、清理规则，然后写一个自用版。
分工：dsh（deepseek-v4.1-flash，REA MCP）做分析/测试/重写；Hark 拆任务、验收、汇报。

## 红线
- 不分析、不绕过、不复刻许可证/激活/付费校验（只记录"存在"）。
- 不拷贝 Mole 的图片、文案、星球素材；自用版界面自己设计。
- CLI 版 GPL-3.0：可参考/复用，只自用不分发。
- 任何删除逻辑默认 dry-run；测试只在假目录（fixtures）里跑，绝不碰真实 HOME。

## 阶段
- P1a 取证：下 dmg、解包、clone CLI；Info.plist/entitlements/helper/Sparkle/框架清单/Swift 类型/字符串 → report/P1a-inventory.md
- P1b 规则提取：从 App 字符串 + CLI 源码整理清理规则表（路径、分类、默认勾选、风险、AI 工具）→ report/rules.json + P1b-rules.md
- P2 规格：功能清单 + 架构 + MVP 范围 → SPEC.md（Hark 审，用户拍板一次）
- 架构决策（2026-11-13，用户要求“源码要和他一致”）：引擎直接用开源 CLI 源码，锁定 commit dc6605c（artifacts/mole-cli），不重写清理逻辑；桌面端只做 GUI + 给 CLI 加结构化(JSON)输出的薄适配层。CLI 自带 tests/ 必须全过。只有 App 独有、无源码的功能（AI 清理月亮页、风扇/电池 SMC、菜单栏等）才按行为自己实现，并标注来源。
- P3 引擎适配：vendor CLI@dc6605c；补 clean/uninstall 的 --json 预览与执行结果输出（最小改动，diff 可审）；analyze 已有 --json 只做核对；optimize 不做（SPEC.md）
- P4 测试验证：单元 + fixture 集成，Hark 独立复核
- P5 Mac 桌面端（用户 2026-11-13 确认要桌面端；SwiftUI 原生，用户 Mac 上编译）— 沙盒无法构建，交付源码 + 构建说明
- 素材：仿照 Mole 的风格（星球主题、布局、动效思路），图标/星球图/文案自己生成，不从 Mole.app 提取（2026-11-13 定）

## 状态
见 report/ 和 STATUS.md

## 测试节奏（用户 2026-11-13 13:43 定）
- 每次改动后只跑受影响模块的局部测试（对应的 tests/ 子集 + 相关 fixtures），并回传结果。
- 全部改完后跑一次全量测试（CLI 原 tests/ 全部 + 全部 fixtures），Hark 验收全量报告。
- 不允许每个小改动都跑全量，避免浪费时间和 token。
- dsh 跑命令需 export DSH_PERMISSION_MODE=danger-full-access；中转站有并发上限，同一时间只跑一个 dsh 任务。
