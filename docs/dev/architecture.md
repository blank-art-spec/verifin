# 架构导览

执行规则以 [AGENTS.md](../../AGENTS.md) 为准；这里仅提供源码导航，不重复维护规则。

Veri Fin 仅交付 Android，权威账目在本机 SQLite，无账号或自有服务端。
正式入口为 `lib/main.dart`；UI 通过 `VeriFinScope` 读取 `VeriFinController`，
Controller 经 repository 写库。`VeriFinController.create()` 是生产初始化入口；
主题、语言等设备偏好通过 KV 和独立 ValueNotifier 驱动。

| 领域 | 源码与维护文档 |
| --- | --- |
| 根初始化、生命周期 | `lib/main.dart`；备份、周期补记、提醒、小组件与应用锁挂钩 |
| Controller | `veri_fin_controller.dart`、`veri_fin_controller_state.dart`、`veri_fin_controller_ops.dart` |
| SQLite 与持久化 | `lib/data/`；[技术决策](tech-decisions.md)、repository contract 与 migration matrix 测试 |
| 模型 | `lib/app/models/`，`models.dart` 稳定导出；信用主体在 `credit_account.dart`，具体币种子账户仍是 `Account`；JSON/SQLite 映射须同步 |
| 结构化标签与项目 | `lib/app/models/tag.dart` 定义维度、标签、项目及模板；`pages/tag_management_page.dart`、`pages/project_pages.dart` 管理，`app/entry_sheets.dart` 选择和套用模板；SQLite v24/v25 迁移旧标签并保存项目元数据 |
| 页面与弹窗 | `lib/pages/`、`pages/sheets.dart`、`app/entry_sheets.dart`；[组件目录](components.md) |
| 共享绘制、菜单、图表 | `common_widgets.dart`、`chart_painters.dart`、`root_navigation.dart`、`veri_bottom_bar.dart`；[统一设计](../design-system.md) |
| 多币种、预算、退款 | [多币种](multi-currency-design.md)、[单期预算](category-budget-override-design.md)、[退款](refund-design.md) |
| 导入、备份 | `lib/app/backup/import/`、`lib/app/backup/`；只在预览确认后落库，字节格式仅由 BackupService 编解码 |
| AI | `lib/app/ai/`；[只读查询工具](ai-tools.md)、[主动采集](auto-capture-plan.md) |
| Android 系统能力 | `platform_bridge*.dart`、`android/`；单一 MethodChannel 分发，真实权限与冷启动验收 |
| 自动采集 | `models/auto_capture.dart`、`auto_capture/capture_parser.dart`、`platform_bridge_auto_capture.dart`、原生 `AutoCaptureBridge` / `PaymentNotificationListenerService` / `SmsCaptureReceiver`；原始事件先落 SQLite，再解析、去重和置信度分流 |
| 异常治理 | `attention_center.dart` 纯投影 + `attention_center_page.dart`；从交易对账状态、自动采集、退款关系、还款分配与缺失汇率实时汇总，不另建异常状态表 |
| 交易审计 | `entry_audit.dart` 比较提交前后字段；`LedgerEntry.auditHistory` 经 SQLite v23 `entries.audit_history` 保存并纳入备份 v8，交易详情只读展示；旧交易不补造历史 |
| 国际化 | `lib/l10n/*.arb` 与 gen-l10n 输出；[国际化验收](i18n-verification.md) |
| 本地调试、发版 | [Android 开发](android-development.md)、`scripts/publish.*` |

内存仓储、插件 stub 和 ffi factory 用于测试，不能替代生产持久化。
历史设计稿中的旧行为需要用当前源码复核；Web 预览已移除，历史记录不再代表支持范围。

## 文档权威顺序

判断「当前实现事实」时按以下顺序取信，冲突时前者覆盖后者：

1. **源码、测试、Gradle、CI 工作流与发布脚本**——唯一事实来源。
2. [AGENTS.md](../../AGENTS.md)——执行规范：改动流程与必须遵守的规则。
3. [design-system.md](../design-system.md)——界面与交互规范。
4. [ui-guidelines.md](../ui-guidelines.md)——页面骨架与交互细则。
5. [components.md](components.md)——可复用组件 / 弹窗 / 纯函数注册表。
6. [tech-decisions.md](tech-decisions.md)（已决策取舍）与 [known-limitations.md](known-limitations.md)（已接受债与整改阈值）。
7. **历史记录**：`docs/reviews/`、`docs/dev/*-design.md`、`code-review-*.md`、`*-research.md`、`*-investigation.md`——只解释背景与决策过程，**不代表当前实现**。

文档与实现不一致时，以第 1 条为准，核实 git 历史后同步修正文档。
