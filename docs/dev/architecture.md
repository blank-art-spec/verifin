# 架构导览

2026-10-22：多币种主体扩展至银行储蓄与证券投资账户，复用已有主体表和关联字段；公共读取 `accountParents`，信用专用读取 `creditAccounts`，禁止普通主体进入信用投影。详情见 [父子账户与币种](credit-hierarchy-currency.md)。

执行规则以 [AGENTS.md](../../AGENTS.md) 为准；这里仅提供源码导航，不重复维护规则。

股票阶段现已实现精确持仓、独立事件和手填估值，早期博通来源验证见 [阶段 0–2 历史记录](securities-stage02-implementation.md)。当前持久化为 SQLite v28 投资聚合及 JSON v14 完整备份，普通证券命令入口为 `veri_fin_controller_investments.dart`，基金逐笔结算入口为 `veri_fin_controller_funds.dart`。v13 增加真实基金品种与净值日期精度；v14 增加金额申购阶段、确认关联与已有持仓基准，继续兼容 v1–v13，旧股票/期权默认字段的 JSON 保持原形状。两个金额入口、实际扣款与净在途、逐笔收益起算及实际时刻基准见[基金金额与结算](fund-amount-settlement.md)。期权生命周期见 [阶段 3](securities-stage03-implementation.md)；参考行情机制及门禁见 [阶段 4](securities-stage04-implementation.md)，仅诊断包可显式装配的腾讯股票来源见 [公开股票研究](public-quote-research.md)，招商官方基金净值及参考历史见 [基金研究](cms-fund-api-research.md)。旧 Yahoo/Nasdaq 验证页、查询客户端和待核对来源配置已移除。资产分解、主动保存依据与恢复见 [阶段 5](securities-stage05-implementation.md)；未准入的生产自动行情仍待后续验证，见 [总体方案](securities-trading-plan.md) 与 [验收操作](securities-trading-acceptance.md)。

Veri Fin 仅交付 Android，权威账目在本机 SQLite，无账号或自有服务端。
正式入口为 `lib/main.dart`；UI 通过 `VeriFinScope` 读取 `VeriFinController`，
Controller 经 repository 写库。`VeriFinController.create()` 是生产初始化入口；
主题、语言等设备偏好通过 KV 和独立 ValueNotifier 驱动。

参考行情自动调度由 `InvestmentQuoteSession` 负责，根级 `MarketQuoteSessionGate`
在隐私同意、应用锁及首次引导通过后连接应用生命周期。已开启联网和自动刷新时，
开屏/回前台/解锁检查当前账本全部证券账户的已支持持仓，前台按账户自己的到期时间续刷；
不必打开参考行情页。退后台、锁屏或退出停止后续请求，页面只承担显示和手动刷新。

| 领域 | 源码与维护文档 |
| --- | --- |
| 根初始化、生命周期 | `lib/main.dart`；备份、周期补记、提醒、小组件与应用锁挂钩 |
| Controller | 核心 `veri_fin_controller.dart` / `state` / `ops`；领域 part：`veri_fin_controller_account_reminders.dart`、`veri_fin_controller_workday_calendar.dart`、`veri_fin_controller_credit_hierarchy.dart`；生产 `create` 异步载入本地状态，日历客户端可注入测试 |
| 证券参考行情会话 | `investments/investment_quote_sync.dart` 保存逐账户状态/缓存，`investments/investment_quote_session.dart` 负责当前账本到期调度，`pages/market_quote_session_gate.dart` 连接根级前台、隐私/引导及解锁状态；[当前范围](public-quote-research.md) |
| 基金净值与参考历史 | `investments/cms_fund_quote_adapter.dart` 匿名查询固定基金；`market_quote.dart` 的有界 `FundNavHistory` 留设备缓存；`fund_reference_history.dart` 按各日真实份额/现金重算参考收益与资产，Controller 公共读取 `fundReferenceHistoryFor`，`pages/fund_reference_history_section.dart` 展示。缺其他证券当日历史价不回填，无收入流水或自动权威快照；[研究边界](cms-fund-api-research.md) |
| 基金金额与逐笔结算 | `pages/fund_entry_page.dart` 共用金额买入/已有持仓入口；`investments/fund_amount_math.dart` 计算参考份额和精确差额；`models/fund_subscription.dart` 保存申请、实际付款、确认及收益起算事实，`investments/fund_workflow_math.dart` 派生资金腿与净在途；`veri_fin_controller_funds.dart` 原子保存。`fundAcquire` 零现金增份额，`fundHoldingBaseline` 在实际核对时刻替换持仓，净在途进入统一资产估值；[口径与验收](fund-amount-settlement.md) |
| 父子账户与汇率 | Controller part `veri_fin_controller_credit_hierarchy.dart`；纯归并 `credit_hierarchy.dart`、只读统计 `statistics_currency.dart`、联网 `frankfurter_client.dart`；[当前金额及统一还款口径](credit-hierarchy-currency.md) |
| SQLite 与持久化 | `lib/data/`；[技术决策](tech-decisions.md)、repository contract 与 migration matrix 测试 |
| 模型 | `lib/app/models/`，`models.dart` 稳定导出；信用主体在 `credit_account.dart`，具体币种子账户仍是 `Account`；JSON/SQLite 映射须同步 |
| 结构化标签与项目 | `lib/app/models/tag.dart` 定义维度、标签、项目及模板；`pages/tag_management_page.dart`、`pages/project_pages.dart` 管理，`app/entry_sheets.dart` 选择和套用模板；SQLite v24–v26 迁移旧标签并保存项目元数据，v26 将存量「项目类型:…」迁入独立维度 |
| 页面与弹窗 | `lib/pages/`、`pages/sheets.dart`、`app/entry_sheets.dart`；[组件目录](components.md) |
| 共享绘制、菜单、图表 | `common_widgets.dart`、`chart_painters.dart`、`root_navigation.dart`、`veri_bottom_bar.dart`；[统一设计](../design-system.md) |
| 多币种、预算、退款 | [多币种](multi-currency-design.md)、[单期预算](category-budget-override-design.md)、[退款](refund-design.md) |
| 导入、备份 | `lib/app/backup/import/`、`lib/app/backup/`；只在预览确认后落库，字节格式仅由 BackupService 编解码 |
| AI | `lib/app/ai/`；[只读查询工具](ai-tools.md)、[主动采集](auto-capture-plan.md) |
| Android 系统能力 | `platform_bridge*.dart`、`android/`；单一 MethodChannel 分发，真实权限与冷启动验收 |
| 账户记账提醒 | `reminder/account_entry_reminder.dart`、`reminder/china_workday_calendar.dart`、`veri_fin_controller_account_reminders.dart`、`account_entry_reminder_page.dart`、原生 `AccountEntryReminderReceiver` / `AccountReminderSchedule`；全部账本投影、自定义星期或大陆工作日（含调休）、用户确认才落账；[设计与验收](account-entry-reminders.md) |
| 工作日日历联网更新 | `reminder/workday_calendar_client.dart` / `workday_calendar_sync.dart`、`veri_fin_controller_workday_calendar.dart`、`workday_calendar_page.dart`；默认关闭，只请求公共年份文件，校验后落设备 KV，独立通知源驱动原生提醒重排；网络不占账目写队列 |
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
