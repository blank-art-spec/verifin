# 组件清单（Component Registry）

2026-10-29 基金收益归属：`FundAccrualRule` 在确认中保存 `dealNavDate` 或兼容的
`explicitStartDate`，默认省略旧规则字段。`supportsCmsDealNavAccrual` 严格限制已核实的
HK/USD 基金 B 类；`hongKongFundDayEnd` 提供纯日期的香港日报末截点，不代表实际收市时刻。
`fundSubscriptionEffectiveAt` 为所有投影、在途和界面状态的统一生效入口。
`FundReferenceDay.profitFromDate` 保存前一公开净值日期，`subscriptionAdjustment` 只解释
已包含的申购费用与结算差额。`FundReferenceHistorySection` 显示真实区间，不补周末或重复加减。
`FundEntryPage` 新 CMS 确认默认成交净值规则，旧订单明确重核后才能切换；其他基金沿用旧规则。

2026-10-28 基金诊断研究与参考历史：

- `StockSecurity.type` / `isFund` / `isStock` 明确股票、基金与期权边界；基金份额使用独立 `fund` 身份。`StockMarket.label(fund: true)` 使用基金地区称谓，交易编辑保留品种并拒绝未经支持的融券/拆股。
- `CmsFundQuoteAdapter` / `CmsFundHttpQuoteTransport` 固定匿名 POST 招商官方净值，只支持香港 USD 的 B 类 `HK0001039582`；20 身份、15 秒、512 KiB，最新摘要与完整历史一致性校验，保留 `approved: false` / `researchOnly: true`。沿用现有刷新、缓存与显式诊断构建门禁，见[基金研究](cms-fund-api-research.md)。
- `FundNavPoint` / `FundNavHistory` 保留有界、精确文本、真实净值日期的公开序列；`MarketQuote.dateOnly` 与 `InvestmentPriceFact.dateOnly` 区分纯日期和时刻，`formatQuoteTime(dateOnly: true)` 不换设备时区或补午夜。`InvestmentQuoteDetails(dateOnly: true)` 显示“净值日期”。
- `buildFundReferenceHistory` 是只读纯计算入口，按各净值日日末真实份额、现金和可用历史依据派生 `FundReferenceDay`；缺其他证券同日价不借今日价回填，首个基准或转移当期收益未知。Controller 公共读取 `fundReferenceHistoryFor` 不写流水或权威快照。
- `FundReferenceHistorySection` 接收账户、证券和派生序列，复用标准指标与交互折线展示基金市值/完整账户历史及净值日明细；默认最近 20 点，可展开全量。公开历史只随设备行情缓存保存，账务修改后重新计算。

2026-10-22 通用多币种主账户扩展：

| 组件/函数 | 入口与约定 |
| --- | --- |
| `AccountType.supportsCurrencyChildren` | 区分银行/证券/信用的父子能力与 `supportsCredit`；不能由主账户关系推导信用能力 |
| `accountParents` / `parentForAccount` / `accountParentsForType` | Controller 只读主账户入口；按账本与类型限定关联候选，`creditAccounts` 仍只列信用主体 |
| `accountsForParent` / `entriesForParent` | 读取真实币种账户和合并去重流水；父 id 不可直接记账 |
| `ensureCurrencyChild` / `enableCurrencyChildren` | 新增币种或显式为旧独立账户建主账户；原子保存，零新增流水；保留既有 id 与原币余额 |
| `saveAccountParentDraft` / `parentAccountBalances` | 保存公共资料、普通主体的展示币种并估值；普通主体不允许信用配置，缺率不显示部分合计 |
| `CreditAccountDetailPage` / `CreditAccountEditorPage` | 沿用既有页面骨架与历史类名，普通主体隐藏还款/额度/账期，展示主币种设置与币种子账户 |
| `showAccountPickerSheet(includeCreditParents: true)` | 历史参数名保持兼容；银行、证券与信用主账户均去重展示，记账按币种解析，转账仍选真实子账户 |

2026-10-18 父子账户与折算扩展：

| 组件/函数 | 入口与约定 |
| --- | --- |
| `VeriPage.missingCurrencies` | 统计页传入缺失币种时显示不完整汇总提示，布局仍沿用页面容器 |
| `showAccountPickerSheet(includeCreditParents: true)` | 普通记账每个信用主体只展示父账户，隐藏其币种子账户；父行复用 `_AccountPickerRow`，与无账户/普通账户对齐，当前子账户映射父行选中态。次级「入账账户」限定当前主体并传 `showCreditChildren: true`，可显式选币种或点父行恢复自动匹配。返回 `creditParentPickerPrefix` 哨兵后须解析真实子账户，不得把哨兵 ID 落账；默认的扣款/转账选择仍用具体账户 |
| `CreditAccountDetailPage` | 父账户统一估值；右上角「＋」选择未创建币种并复用 `ensureCreditCurrencyChild`；`VeriSegmentedControl` 互斥选择最近 20 条（默认）/全部/支出/收入 |
| `CreditRepaymentPage` | 父账户范围选择复用 `VeriAnchoredChoice<CreditRepaymentScope>`；原币分配、来源选择、补齐参考额、整批编辑/撤销；日期与时分保存到同批所有记录，编辑保留原精度 |
| `showEntryDatePicker` / `showEntryTimePicker` | `pages/sheets.dart`；记账与还款共用。改日期保留时分秒；确认时间精确到分钟；取消返回 null，不修改草稿 |
| `normalizeCreditHierarchy` | `app/credit_hierarchy.dart`；明确名称的历史子账户幂等归并；冲突 ID 返回供界面复核 |
| `creditExpenseBelongsToStatement` | `app/credit_card.dart`；部分还款验证遵循银行明确归期，否则复用本地周期，不按记账日自行跨期 |
| `creditStatementOverview` / `buildCreditCycleOverview` | `app/credit_card.dart`；主体内购汇按两端实际金额转移无正式账单覆盖的原币债务，避免归并后旧外币账重复待还；子账户概览传入 `internalAccountCurrencies`，未出账按账户原币计算 |
| `projectStatisticsCurrency` | `app/statistics_currency.dart`；明确参考额优先、否则最新汇率，重算退款净额并返回缺失币种；只读投影，不覆盖原始交易 |
| `FrankfurterClient` | `app/frankfurter_client.dart`；只发送币种/日期，校验日汇率响应、超时和体积；由 Controller 合并并落库 |

Veri Fin 已有的**可复用 widget / 弹窗 helper / 对话框 / 纯函数**目录。**写任何新组件、弹窗、格式化或计算之前，先在本表查一遍有没有现成的**：命中就复用或参数化扩展，不要新建变体、不要复制粘贴脚手架。规范见 `AGENTS.md` 的「代码规范 · 组件化」一节。

> 行号为编写时快照，可能随重构漂移；**以符号名为准**（IDE 里搜名字即可）。新增/重命名可复用件时，请同步更新本表。

调用约定速记：
- 底部弹窗一律经顶层 `show*Sheet(context, ...)` 函数打开（内部封 `showModalBottomSheet` + 统一 chrome），**不要**在页面里裸包 `showModalBottomSheet`。
- 「取消 / 未选」一律返回 `null`；账户「无账户」返回 **id 为空串的哨兵 `Account`**；分类特殊项用命名常量 `categoryPickerAll` / `categoryPickerTopLevel`。
- 需要触感（`hapticsEnabled`）的组件由 helper 内部从 `VeriFinScope` 取，调用方不手传。
- 应用内短反馈统一走 `VeriFeedbackHost.of(context)` / `VeriFeedbackController`；调用、队列和迁移规则见 `feedback-system.md`，新代码不得增加旧式 Material 横条。

---

## 族 1 — 布局脚手架 / 页面容器

`BudgetRingPainter` 仅保留 value/trackColor/progressColor，使用原常规渐变环；不再提供玻璃参数。

**表面材质（2026-09-10 起）**：`VeriGlassSurface` / `VeriGlassBackdrop` / `VeriMaterialScope` /
`VeriGlassLightPainter` / `VeriNavigationGlassLens` 与其 Shader 已全部删除。
卡片、导航、快捷按钮、菜单与弹层一律用不透明实色：
`VeriCard`（`common_widgets_scaffold.dart`）走 `veriContentSurfaceColor(brightness)` + 圆角 + 细描边；
页面背景取 `scaffoldBackgroundColor` 的画布纯色；弹层由 `sheets.dart` 的 `_showVeriModalSheet`
统一为实色表面 + 顶部圆角 + 内置拖拽把手，外部仍使用各领域 `show…Sheet`。
**禁止**为了「做质感」重新引入 `BackdropFilter`、`ImageFilter.blur`、片元着色器滤镜或整屏渐变。
历史实现与排查记录见 git 与 `docs/dev/glass-material-preview.md`。

`OnboardingGate`（`onboarding_page.dart`）位于 PrivacyConsentGate / AppLockGate 内部，完成引导前不构建首页。

`VeriPage`、`VeriHeader` / `PageHeader` 与 `VeriCard` 支持显式 `compact` 参数。
开启设计预览时所有公共骨架默认 compact=true：16dp 页边距、56dp Header、16dp 卡片圆角，默认内边距
横向 14dp、纵向 12dp；`VeriCard.padding` 显式传入时仍优先。默认构建仍保持已发布几何参数；候选构建的管理页、设置页和根页面不再分两套密度。

> **新建页面的标准骨架与头部对齐规则见 `docs/ui-guidelines.md`「顶部 Header 与页面骨架」**：`Scaffold > SafeArea > VeriPage > ListView(padding: fromLTRB(14,8,14,…))` + `VeriHeader`；`VeriHeader` 自身无横向内边距，头部缩进全靠外层 padding，带固定页脚的页面须单独给头部套 `Padding(fromLTRB(14,8,14,0))`。

| 名称 | 类型 | 位置 | 用途 |
|---|---|---|---|
| `VeriPage` | Widget | `common_widgets.dart` | 纯色背景 + 居中 + `maxWidth` 约束的页根容器 |
| `VeriCard` | Widget | `common_widgets.dart` | 统一圆角/描边/阴影卡片，可点击（`quietTap` 长按吞噬变体） |
| `VeriHeader` | Widget | `common_widgets.dart` | 页眉（标题+副标题+返回+actions，最小高度 52、候选构建 56；用最小高度而非固定高度，系统字号放大时两行标题不会被裁掉） |
| `PageHeader` | Widget | `common_widgets.dart` | `VeriHeader` 的薄封装（单 trailing）；`subtitle` 为 `String?`，`null` 时整行不渲染；副标题里带「单位：x」必须用 `currencyUnitSubtitle`（族 7）——隐藏单位且无上下文时它返回 `null`，直接传进去即可整段省略 |
| `VeriRootNavigation` / `VeriRootNavigationBody` / `VeriNavigationDestination` / `veriRootPageListPadding` | Widget / 值类 / 布局 helper | `root_navigation.dart` | 四个根页面的**停靠底栏**：整宽、不透明、贴底，底色铺到屏幕最底（含系统导航条背后，否则会分成两块）。条目由 `VeriBottomBar`（`veri_bottom_bar.dart`）绘制，**未选中用 `destination.icon`（线框）、选中用 `selectedIcon`（填充）**，中文标签常显。**记账按钮不在底栏内**——由 `shell.dart` 放在 body 右下角浮动（自绘 `Material`+`InkWell`，因为 `FloatingActionButton` 会吞掉长按，而长按要走 AI 记账）。**安全区**用 `SafeArea(minimum: 12, maintainBottomViewPadding: true)` 取 `max(系统留白, 12)`：系统留白可能是 0，不给下限条目会贴边；`maintainBottomViewPadding` 让键盘弹起时底栏不跳 |
| `VeriBottomBar` / `VeriBottomBarItem` | Widget / 值类 | `veri_bottom_bar.dart` | 底栏条目绘制：切换时两条圆弧扫过、两枚圆点飞过，图标由灰渐变为品牌色并轻微摆动。**抄写自 `bottom_bar_matu` 1.5.0 并在本项目内修复后自持**（依赖已移除）；原库的四处缺陷——父级每次重建都重置图标 State、进度 forward/reverse 往返断档、旋转方向判断恒为 false、延迟 200ms 才回调 `onSelect`——逐条记在源文件头注释里。选中态完全由 `selectedIndex` 驱动并同步更新，`onSelect` 每次点击恰好一次 |
| `VeriFeedbackHost` / `VeriFeedbackController` / `VeriFeedbackRequest` / `VeriFeedbackResult` | 根级 Widget / Controller / 模型 | `feedback.dart` | 跨路由应用内轻提示：内容自适应宽高与三行正文（`error` 六行）、四条可见栈、优先级等待队列、2/4/8 秒与常驻、单操作 Future 结果、显式去重、前后台暂停；完整规范见 `feedback-system.md` |
| `SectionTitle` | Widget | `common_widgets.dart` | 区块标题 + 可选 trailing |
| `EmptyState` | Widget | `common_widgets.dart` | 空状态（图标+标题+描述+可选 `action` 操作入口） |
| `HeaderAction` / `HeaderTextAction` / `HeaderInline` / `VeriSectionAction` | Widget | `common_widgets.dart` | 页眉动作族（图标钮/文字钮/宽度约束/填充色小图标钮）；需要弹出操作菜单时使用 `VeriAnchoredMenuButton` |
| `VeriAnchoredMenuAnchor` / `VeriAnchoredMenuButton` / `VeriAnchoredChoice<T>` / `VeriMenuItem` / `VeriMenuDivider` | Widget / 菜单模型 | `common_widgets.dart` | Veri Fin 锚点菜单：图标、标题、副标题、分割线、选中/禁用态、根/默认子菜单/单项子菜单独立宽度、从点击行原位展开的容器变换，以及缩放/压暗但不丢失的完整祖先卡片栈；任意触发器用 `Anchor`，Header 图标入口用 `Button`，2–8 项静态受控单选优先用 `Choice`；完整用法见 [anchored-menu.md](anchored-menu.md) |
| `SaveHeaderAction` | Widget | `common_widgets.dart` | 全屏编辑页统一保存动作；固定软碟语义的 `Icons.save_outlined` 和本地化 tooltip，支持禁用态 |
| `SortModeHeaderActions` | Widget | `common_widgets.dart` | 管理页显式排序模式的统一 Header 动作；普通态进入排序，排序态提供取消与软碟保存，未改动时禁用保存 |

## 族 2 — 图标渲染（统一入口，勿绕过）

| 名称 | 类型 | 位置 | 用途 |
|---|---|---|---|
| `CategoryIconBox` | Widget | `common_widgets.dart` | **分类图标带色块盒**（自动区分内置图标 / `emoji:` 前缀） |
| `CategoryGlyph` | Widget | `common_widgets.dart` | 分类裸字形（无背景，Chip/内联用） |
| `AccountIconBox` | Widget | `common_widgets.dart` | 账户图标统一渲染入口：通用/品牌均为 SVG，固定纯白底、10% 内边距与 8% 黑色描边；未知 code 回退钱包 SVG，不走 Material 图标分支 |
| `VeriIconBox` | Widget | `common_widgets.dart` | 通用色块图标盒（给定 `IconData`） |
| `iconForCode` | 纯函数 | `icon_catalog.dart` | code→`IconData`（**底层，渲染点勿直接调，走上面的盒子**，否则 emoji 会回退成钱包图标） |
| `isEmojiIconCode` / `emojiOfIconCode` / `emojiIconCode` | 纯函数 | `icon_catalog.dart` | emoji 图标编解码 |
| `iconLabelForCode` | 纯函数 | `icon_catalog.dart` | 图标 code→本地化名称 |

## 族 3 — 账户相关

| 名称 | 类型 | 位置 | 用途 / 关键点 |
|---|---|---|---|
| `showAccountPickerSheet` | Sheet 函数 | `sheets.dart` | 账户选择弹窗（图标+余额+卡号后四位）；**按当前资产视图模式分区**（类型视图=按 `AccountType`，分组视图=按分组+未分组，分区/区内顺序复用 `sortedAssetSections`/`sortedAccountsForAssetSection`，随备份还原）；`noneLabel` 非空时列首加「无账户」→ 返回 **id 为空串哨兵 `Account`**；`allLabel` 非空时列首加「全部」→ 返回 **id 为 `accountPickerAllId` 哨兵 `Account`**（筛选场景）；取消返回 `null` |
| `showAccountIconSheet` | Sheet 函数 | `sheets.dart` + `account_icon_picker.dart` | 账户图标选择；按通用、支付、信用、投资理财、卡组织、跨境与数字账户、银行分组网格浏览，支持中英文名、简称和机构缩写搜索 |
| `confirmDeleteAccount` | Dialog 函数 | `sheets.dart` | 删账户流程（有流水→隐藏/删除三选；级联提示停用周期规则）；返回命令是否完成，由带 Guard 的调用页统一退出 |
| `CardNumberFields` | Widget | `common_widgets.dart` | 完整卡号 + 后四位输入组，含「后四位跟随卡号」开关（信用卡/储蓄卡录入用）；**受控**：`follows`/`onFollowsChanged` 由调用方持久化（`Account.cardLast4Follows`），组件不自行反推 |
| `showCardNumberDialog` | Dialog 函数 | `sheets.dart` | 编辑完整卡号+后四位+跟随开关，返回 `({number, last4, follows})?`（内部用 `CardNumberFields`，后四位以 `cardLast4Of` 归一化） |
| `CreditRepaymentPage` | 页面 Widget | `credit_repayment_page.dart` | 信用卡/信用账户还款页；保留扣款账户选择（优先默认账户），选择器增加「无账户转账还款」，没有可用账户时默认无账户；排除本账户、隐藏账户及同信用主体的币种子账户。默认预填目标币种已出账待还，没有时为 0；跨币种按汇率预填转出额并可手填实际扣款。`recordCreditRepayment` 原子保存两端转账和正式账单分配，仅抵扣目标子账户的账单，其他币种待还独立；无账户不扣其他资产，未出账欠款保留 |
| `BillingStatementsPage` / `BillingStatementDetailPage` | 页面 Widget | `billing_statements_page.dart` | 正式信用账单列表、新增与详情；详情分别展示原账单金额、实际还款、出账后退款冲抵和当前待还，退款行可回到原消费，并可在不低于已有还款分配的前提下修正历史实际已还基线 |
| `resolveEntryFieldProvenance` | 纯函数 | `entry_provenance.dart` | 从同笔交易的多条来源证据分别解释发生时间、记账日、金额及商户；日期精度低的账单不能覆盖实时通知时分，金额冲突时不宣称已核准 |
| `CreditAccountEditorPage` | 页面 Widget | `credit_account_editor_page.dart` | 编辑信用主体名称、机构、共享额度、账单日、固定日/账单后天数还款规则与账期预算；账户详情的共享配置统一进入此页，保存时主体与子账户兼容镜像原子落库（外币子账户不复制无币种标识的旧额度字段） |
| `AutoCapturePage` / `AutoCaptureRulesPage` / `AutoCaptureRuleEditorPage` | 页面 Widget | `auto_capture_page.dart` | 自动采集权限与高置信度开关、原生链路诊断（系统授权 / NLS 实时连接 / 原生开关 / 最近通知提取·过滤·入队结果）、今日捕获/识别及最近捕获时间、最近未落账事件安全回放、待确认/疑似重复/自动入账纠错，以及本地确定性规则管理；系统通知/短信原文不直接写交易 |
| `NotificationTextExtractor` / `NotificationLogText` | Android 原生只读提取器 / 日志结果 | `android/app/src/main/kotlin/top/talyra42/verifin/NotificationTextExtractor.kt` | `extract()` 保留识别字段顺序及缺正文兜底行为；`extractForLog()` 独立合并标准字段、各自定义布局中包括按钮/时钟控件在内的可见文字与通知操作标题，提供长度/遍历受限或读取失败的完整性标记；来源许可后调用，日志补文不改变金融过滤、事件指纹、队列输入或入账规则 |
| `NotificationCaptureLogPage` / `NotificationCaptureLogEntry` / `NotificationCaptureLogBatch` | 页面 Widget / 诊断模型 | `notification_capture_log_page.dart` / `platform_bridge_auto_capture.dart` | 原生通知捕获日志的 3 天倒序分页、刷新/重试、正文展开选择及部分内容/旧记录提示、独立清空；经 Controller 读取，允许来源即使未通过金融过滤也保存最多 65,536 字符正文，未允许来源只存状态；仅展示原生阶段及日志完整性，已入队不表示解析或入账成功，不重跑解析或修改账目；入口位于自动采集页 |
| `notificationCaptureStageLabel` / `notificationCaptureOutcomeLabel` | 文案映射函数 | `notification_capture_log_page.dart` | 实时诊断与历史日志共用的原生阶段/结果本地化；未知代码不显示成功，不把原生入队结果当作最终入账结果 |
| `AttentionCenterPage` / `AttentionCenterSnapshot` | 页面 Widget / 纯投影 | `attention_center_page.dart` / `attention_center.dart` | 统一汇总对账冲突、疑似重复、未匹配退款、未关联还款、缺失汇率与低置信度采集；快照不持久化，处理后随权威数据自动消失；入口位于“我的 → 数据与工具” |
| `ReminderSettingsPage` / `CreditReminderSnapshot` | 页面 Widget / 纯投影 | `reminder_settings_page.dart` / `reminder/financial_reminder.dart` | 分别控制每日记账、账期预算、账单日和还款日提醒；实时投影信用主体的出账/到期倒计时、最近正式账单、待还与预算档位，UI 与系统通知共用同一口径；预算通知按账期跨重启去重 |
| `AccountEntryReminderPage` / `AccountEntryReminder` / `AppAccountReminderBridge` / `AccountReminderDeliveryStatus` | 页面 / 配置 / 原生桥 / 状态 | `account_entry_reminder_page.dart` / `reminder/account_entry_reminder.dart` / `platform_bridge_account_reminder.dart` | 所有账户通用的确认记账提醒；自定义星期或大陆工作日、未知年度处理及自定义按钮；跨账本、当天去重与应用锁守卫。`scheduleTest` 共用原生渠道、持久化恢复且不记账；`deliveryStatus` 读取实际系统条件和测试阶段，`openSettings` 仅按用户点击导航，省电豁免不等于厂商清理白名单；见 [账户提醒](account-entry-reminders.md) |
| `ChinaWorkdayCalendar` / `mainlandChinaWorkdayCalendar` / `AccountReminderSchedule` | 纯日期规则 / 离线数据 / 原生排程 | `reminder/china_workday_calendar.dart` / Android `AccountReminderSchedule.kt` | 全国放假与补班日历，内置 2026 年兜底；Controller 合并已校验下载年度，`toJson` 同步原生私有快照。未知年度返回未知，不假定工作周；原生按日历搜索下一次、送达前重查，支持跨长假与时区变化 |
| `WorkdayCalendarPage` / `WorkdayCalendarSettings` / `HolidayCalendarDocument` / `HolidayCalendarClient` | 全局工具页 / KV 配置 / 年度协议 / HTTPS 客户端 | `workday_calendar_page.dart` / `reminder/workday_calendar_sync.dart` / `reminder/workday_calendar_client.dart` | 显式授权后每天检查当前及下一年度，跨年重新检查；固定来源、分块体积限制、总超时、无重定向、空占位及七类节日覆盖校验。下载等待不占账目队列，成功落盘才更新独立通知源；关闭保留缓存，初始化撤权并清缓存 |
| `AppUnlockScope` | 状态作用域 | `app_lock_gate.dart` | 只公开应用锁当前是否解锁；账户提醒操作在解锁后消费，不提供绕过认证能力 |
| `CreditAccountCycleCard` | 首页展开详情 Widget | `home_page.dart` | 信用账户摘要点行后显示；按信用主体聚合币种子账户，分开显示本账期净消费、当前账期欠款、正式账单与到期流水待还、总欠款、出账/还款日和账期预算进度；日历结转只计算视图，正式快照优先 |
| `HomeTrendPanel` | 首页概览 Widget | `home_page.dart` | 按实际字体与金额宽度分配主金额和右侧胶囊；放不下时胶囊换行，金额不省略，三个指标方块随宽度和字体换行 |
| `AccountSectionCard` | Widget | `common_widgets.dart` | 资产页账户分区卡（可折叠 + 分区合计）；普通资产页折叠状态由 Controller 按账本/视图模式持久化，设置页可在草稿中调整；同时服务类型、文件夹分组和隐藏账户等分区，拖拽只由 `sectionDragIndex != null` 开启，`sectionDragImmediate` 控制即时/延迟拖拽 |
| `accountBalanceColor` | 纯函数 | `common_widgets.dart` | **账户余额上色**（不计入资产=弱化，负=红，正=青绿） |
| `accountDisplayName` | 纯函数 | `model_lookup.dart` | 按 id 取账户名，空 id→noneLabel（**展示层用它**，避免误回退首个账户） |
| `accountById` | 纯函数 | `model_lookup.dart` | 按 id 取账户（会回退首个，展示层慎用） |

## 族 4 — 分类相关

| 名称 | 类型 | 位置 | 用途 / 关键点 |
|---|---|---|---|
| `showCategoryPickerSheet` | Sheet 函数 | `sheets.dart` | **多级分类选择弹窗**（展开/收起层级树，**按 支出/收入/转账 分区并各带类型标题**，图标按 `colorForType` 上色，区内保持列表顺序）；`allLabel` 非空加「全部」→ 返回 `categoryPickerAll`；`topLevelLabel` 加「移到顶级」→ 返回 `categoryPickerTopLevel`（「全部」「移到顶级」用中性主题色）。**选分类一律用它**，不要裸包 `showModalBottomSheet` |
| `CategoryPickerSheet` | Widget | `entry_sheets.dart` | 上面 helper 的内部 widget（一般经 `showCategoryPickerSheet`）；`categoryPickerAll` / `categoryPickerTopLevel` 哨兵常量在此 |
| `showCategoryIconPickerSheet` | Sheet 函数 | `sheets.dart` | 分类图标（内置网格 + emoji 快选 + 自由输入） |
| `categoryById` / `categoryByIdFrom` / `categoriesFor` | 纯函数 | `model_lookup.dart` | 取分类 / 按类型过滤 |
| 分类树工具集 | 纯函数 | `category_tree.dart` | `categoryIndex` `rootCategories` `childrenOf` `hasChildren` `ancestorIds` `rootIdOf` `descendantIds` `isDescendantOf` `depthOf` `pathLabel` `flattenTree`（均带环检测）；`CategoryNode` 携带 depth |

## 族 5 — 金额输入 / 计算

| 名称 | 类型 | 位置 | 用途 / 关键点 |
|---|---|---|---|
| `showNumberPadSheet` | Sheet 函数 | `sheets.dart` | **数字键盘弹窗**（四则算式 + 结果预览）；数字区支持设置中的标准（7 8 9 / 4 5 6 / 1 2 3）与电话（1 2 3 / 4 5 6 / 7 8 9）布局，默认标准；货币金额传 `currencyCode` 自动遵循 ISO minor unit，汇率输入才显式用 `maxFractionDigits:10`；`maxAmount` 的展示/比较也随币种精度，JPY 自动禁用小数点。触感偏好内部自取。**输金额一律用它**，不要弹系统 TextField、不要裸包 `showModalBottomSheet` |
| `NumberPadSheet` | Widget | `entry_sheets.dart` | 上面 helper 的内部 widget（一般经 `showNumberPadSheet`） |

允许负数的金额键盘（`allowNegative:true`）可首按减号直接录入负值，供负余额等字段复用；非负金额仍拒绝首位运算符，四则算式和币种精度保持一致。
| `showCurrencyPickerSheet` | Sheet 函数 | `sheets.dart` | 可搜索的离线 ISO 4217 法定货币选择器（代码/中英文名/符号，支持常用/业务优先币种与排除项）；取消返回 `null` |
| `evaluateAmountExpression` / `amountExpressionHasOperator` | 纯函数 | `calc_expression.dart` | 算式求值（不完整返回 null，结果已规整到分）/ 是否含运算符 |
| `CurrencyCatalog` | 静态目录 | `currency_catalog.dart` | 离线 ISO 4217 法定货币定义、常用币种排序与中英文搜索；业务层不得另建货币清单 |
| `normalizeCurrencyAmount` / `formatCurrencyNumber` / `formatMoney` / `formatUserMoney` / `formatSignedUserMoney` / `formatRateValue` / `formatRateValueExact` | 纯函数 | `currency_math.dart` | 按币种 minor unit 规整与格式化；**用户界面一律用 `formatUserMoney` 族**，它自动遵循符号/代码与单币种隐藏偏好；`formatMoney` 的 `display` 默认 `MoneyCodeDisplay.code`（恒带单位），界面金额不得吃这个默认值——AI 工具摘要也已改走 `AiToolContext.currencyDisplay`（见族 10）。`formatRateValue` 是 4/6/8 位自适应的界面文本，CSV 等精确往返必须用 `formatRateValueExact` |
| `textCurrencyUnitHidden` / `optionalCurrencyUnit` | getter / 纯函数 | `currency_math.dart` | **单位文字的闸门读取入口**：闸门是 `amount_format.activeMoneyCodeDisplay`（`none` 即隐藏），单币种账本 + 开启隐藏时返回 `true` / `null`。`displayCurrencyUnit` 不读闸门（它只解析符号/代码样式），只允许在币种选择器、汇率等式这类「界面主题就是币种」的地方直接用；页头/卡片副标题走 `currencyUnitSubtitle`、卡片角标走 `MoneyUnitLabel`（族 7）。**唯一例外**：「我的」→「货币与汇率」入口用 `optionalCurrencyUnit(...) ?? ''` 占位保宫格行高（`profile_pages.dart`）；别处拿到 null 一律整段省略，不要渲染空串 |
| `exchangeRateAt` / `rateToBaseAt` / `convertCurrencyAmount` | 纯函数 | `currency_math.dart` | 按交易日取最近历史汇率（不使用未来值）/ 经本位币交叉换算；缺汇率返回强类型结果 |
| `convertAccountBalancesToBase` / `ConvertedAccountBalances` | 纯函数 / 结果类型 | `currency_math.dart` | 把账户原币余额完整折算到本位币；任一账户缺率时 `completeTotal == null`，并返回缺失币种和受影响账户，禁止展示部分总额 |

## 族 6 — 交易展示

| 名称 | 类型 | 位置 | 用途 |
|---|---|---|---|
| `TransactionTile` | Widget | `common_widgets.dart` | 单条交易行（图标+分类+时间/备注+金额+账户 pill+待报销/已退款徽标，多选态内建）；跨账户已到账退款显示「退款」与正向金额。副行的跨币种换算**只在两端币种不同时**渲染（同币种两端的换算整条是重复信息），`forceUnit: true` 只留给真正同屏出现第二个币种的换算字段，「显示逐笔结余」的余额走 `formatUserMoney` 不带单位 |
| `TransactionListCard` | Widget | `common_widgets.dart` | 交易列表卡（多条 `TransactionTile` + 分隔线） |
| `showEntrySourceEvidenceSheet` | Sheet helper | `sheets.dart` | 交易详情的只读来源证据弹层：来源、交易号、可信时间精度、记账日、金额和商户；使用统一实色弹层外壳 |
| `DateGroupHeader` | Widget | `common_widgets.dart` | 日期分组小标题（日期+今天/昨天+当日合计） |
| `groupEntriesByDate` / `relativeDay` | 纯函数 | `common_widgets.dart` | 按日分组、日期倒序 / 相对今天；`DateEntryGroup` 分组模型 |
| `CalendarPreview` | Widget | `common_widgets.dart` | 月历预览（内建月份切换 + 日收支）；必传 `currencyCode`；单币种账本隐藏单位时右下角不再显示轻量单位提示，并**连同前置 6dp 间距整块不构建**（`if (!textCurrencyUnitHidden)`，见维护约定），多币种账本照常显示 |
| `EntryTagField` | Widget | `common_widgets.dart` | 记账表单标签行 |
| `AttachmentsEditor` | Widget | `attachments_editor.dart` | 多图片附件横向缩略图、全屏查看和逐张删除；默认自带标题与拍照/相册添加入口，记账页的轻量元数据布局通过 `showHeader:false` / `showAddButton:false` 只复用缩略图条，添加入口由页面标签触发 |
| `TagSelectorSheet` / `pickEntryTags` | Widget / Sheet 函数 | `entry_sheets.dart` / `sheets.dart` | 交易按维度选标签、即时在指定维度创建；单选维度只保留一个，多选维度可同时勾选。`groupId` 聚焦一个维度，`templatesOnly` 供独立模板入口使用；支持保存、套用和删除当前账本标签模板 |
| `ProjectManagementPage` / `ProjectDetailPage` / `ProjectEditorPage` | 页面 | `project_pages.dart` | 项目元数据、预算进度、分类构成和关联交易入口；保存由 Controller 原子写项目及关联标签 |
| `tagGroupDisplayName` | 纯展示函数 | `tag_group_labels.dart` | 系统维度按当前语言显示；自定义维度保留用户名称 |
| `RefundSection` / `showRefundSheet` | Widget / Sheet 函数 | `refund_editor.dart` | 支出详情页的受控「退款」草稿区（列退款明细+净支出+添加）/ 添加·编辑退款弹窗（金额截剩余可退、到账账户、已到账开关+到账日期、发起日期、备注、删除）；Sheet 保存只回传父交易草稿，交易页最终与本体、附件原子保存。待退款清单独立编辑时由调用方在 Sheet 确认后提交 |
| `PendingRefundsPage` | Widget | `pending_refunds_page.dart` | 「待退款」清单页（汇总当前账本所有待到账退款、一键标记已到账核销）；入口在交易列表页头 |

## 族 7 — 表单 / 设置行 / 通用列表行

| 名称 | 类型 | 位置 | 用途 |
|---|---|---|---|
| `SelectField` | Widget | `common_widgets.dart` | 下拉选择字段；`leading` 可传自定义前置（如账户图标），`suffixIcon` 可替换默认箭头提供清除等局部操作 |
| `SectionLabel` | Widget | `common_widgets.dart` | 分组小标题（分区 `VeriCard` 上方的灰色标签，设置页/账户详情页分模块用） |
| `SettingsRow` | Widget | `common_widgets.dart` | 设置行（图标+标题+trailing 文本+chevron）；`leading` 可传账户图标等自定义前置，`contentColor` 可上色（如危险操作红色）；`trailingMaxLines` 默认 1，长规则名称传 null 完整换行 |
| `CompactSwitchRow` | Widget | `common_widgets.dart` | 紧凑开关行（整行可点，不只点开关）；`onChanged:null` 保留原生禁用语义，表示当前平台/状态不可用 |
| `VeriSegmentedControl<T>` | Widget | `common_widgets.dart` | **统一分段控件**（文字标签 + 滑动胶囊指示，基于 `animated_toggle_switch`）。所有「N 选一的横向口径切换」一律用它，不要再手写 Row+InkWell 分段条或裸用 Material `SegmentedButton`。颜色只走设计令牌，调用方仅可通过 `accentOf` 指定选中项的语义强调色；`compact: true` 用于卡片标题行内的小切换；`onChanged: null` 整组禁用；自带 `Semantics`（第三方控件本身无语义）。**不用它**：图标型开关（走 `CompactSwitchRow`）、超过 4 项或需要分区的单选（走 `showOptionSheet` / `VeriAnchoredChoice`）、菜单触发器（走 `FilterPill`）、左右步进器（走 `MonthSwitcher`；非月份范围须传 `previousTooltip` / `nextTooltip`） |
| `DetailInfoRow` | Widget | `common_widgets.dart` | 详情页 label/value 行；默认纵排。`inline: true` 为标签/数值左右分列并按文字基线对齐，宽度不足 280dp 或正文缩放超过约 1.4 倍时改为上下排；完整换行不省略金额。`valueColor` 接受调用方解析后的语义色 |
| `CurrencyAmountField` | Widget | `common_widgets.dart` | 交易/退款/周期编辑器统一的货币金额行；按 ISO minor unit 格式化；`amount == null` 时显示明确缺失态。`forceUnit` **默认 `true` 且不要改**：编辑器允许临时选一个账本里还没有的币种，那一刻闸门还关着但同屏已出现两个币种，单位必须保留。只有两端币种被锁死、不可能出现第二币种的地方（退款表单）才显式传 `false` |
| `MoneyUnitLabel` | Widget | `common_widgets.dart` | 聚合卡片的轻量「单位：¥/CNY」提示（首页支出走势卡——**仅未开启 `UNIFIED_DESIGN_PREVIEW` 的旧外观**，正式外观这里渲染的是「周／月／季／年」标签、首页预算卡、日历卡、AI 结果卡；走势设置页预览复用同一张卡）；单币种账本隐藏单位时组件自身返回 `SizedBox.shrink`——**只表示看不见，不能拿它判断单位是否显示**；把容器一起收掉的调用点（日历卡）隐藏时根本不构建，`find.byType` 是 `findsNothing`。要断言隐藏用 `find.textContaining('单位：')` |
| `currencyUnitSubtitle` | 纯函数 | `common_widgets.dart` | **页头 / 卡片副标题拼「单位：x」的唯一入口**：传 `l10n`、上下文前缀（书名/账户类型/日期范围，可空）与币种代码。隐藏单位时返回前缀本身（**不会把书名一起丢掉**），无前缀时返回 `null`——调用方必须据此整段省略副标题，不要渲染只剩分隔符的残句 |
| `SummaryMetric` | Widget | `common_widgets.dart` | **指标块**（label+value+color+detail）。各类统计小块一律用它，勿新造 `_XxxMetric`/`_XxxTile`。`allowValueWrap` 默认 false；证券概览显式设 true，让标签、金额、说明居中完整换行，其他调用保留默认显示方式 |
| `FilterPill` | Widget | `common_widgets.dart` | 筛选胶囊（标签+可选图标+chevron） |
| `ToolEntry` | Widget | `common_widgets.dart` | 工具入口图标块 |

## 族 8 — 对话框 / 弹窗 helper

| 名称 | 类型 | 位置 | 用途 / 返回约定 |
|---|---|---|---|
| `showConfirmDialog` | Dialog 函数 | `common_widgets.dart` | **统一确认框**；`destructive` 红色；返回 `bool`（取消/点外=false）。**禁止内联两按钮 `AlertDialog`** |
| `showInfoDialog` | Dialog 函数 | `common_widgets.dart` | 统一只读说明框（标题、正文、单个“知道了”按钮）；新调用使用具名 `context:` |
| `showUnsavedChangesDialog` / `EditorExitDecision` | Dialog 函数 / 枚举 | `common_widgets.dart` | 未保存修改的“保存 / 不保存 / 取消”三操作对话框；点遮罩或系统返回视为取消 |
| `UnsavedChangesGuard` / `EditorExitController` | Widget / Controller | `common_widgets.dart` | 统一拦截编辑页 Header、系统与预测性返回；仅 `onSave` 成功后放行，未修改时不拦截；显式保存成功后用 `EditorExitController.exit()` 走同一受控退出路径，避免同帧旧 dirty 状态拦截程序化返回 |
| `showTextInputDialog` | Dialog 函数 | `sheets.dart` | **统一文本输入**；`allowEmpty`、`keyboardType`；返回 trim 后 `String?` |
| `showOptionSheet<T>` | Sheet 函数 | `sheets.dart` | 动态、较长或需 `sectionOf` 分区的通用单选底部弹窗；2–8 项静态受控单选优先用 `VeriAnchoredChoice<T>`；返回 `T?` |
| `showVeriContentSheet<T>` | Sheet 函数 | `sheets.dart` | 自定义业务内容的统一底部弹层外壳，集中提供不透明表面、顶部圆角和拖拽把手；简单单选仍走 `showOptionSheet` |
| `showLedgerBookEditorSheet` | Sheet 函数 | `sheets.dart` | 新建账本统一表单，同时收集名称与本位币，返回命名 record；取消返回 `null` |
| `showLedgerBookPickerSheet` | Sheet 函数 | `sheets.dart` | 自动识别收支/转账复核和退款确认共用的动态账本选择器，复用 `showOptionSheet`；只返回选择，取消返回 `null`，调用方决定何时切换当前账本 |
| `showRefundExpensePickerSheet` | Sheet 函数 | `sheets.dart` | 自动采集退款复核的原消费选择器；候选由 `captureRefundCandidates` 按目标账本筛选并排序，跨账本账户通过 `accountsForBook` 只读获取，列表复用 `TransactionTile`；返回所选 `LedgerEntry?`，取消返回 `null`，选择过程不写入交易 |
| `confirmLegacyLedgerCurrency` | Sheet/Dialog 流程 | `sheets.dart` | 旧单币种账本的一次性确认/重解释流程：选币、展示影响数量、二次确认，并调用 Controller 原子迁移；取消或失败返回 `false` |
| `showMonthlyBudgetOverrideSheet` | Sheet 函数 | `sheets.dart` | 总预算的单期覆盖管理；按自然月/自定义周期显示“本月/本期”，可设置或调整所选期额度，有覆盖时可清除并恢复默认；内部复用 `showOptionSheet` + `showNumberPadSheet` |
| `runWithLoadingDialog<T>` | Dialog 函数 | `common_widgets.dart` | 不可关闭加载态，任务完成自动关并返回结果 |
| `confirmCleartextIfRisky` | Dialog 函数 | `sheets.dart` | 明文 http 凭证风险确认 |

## 族 9 — 图表（全部必须支持点击气泡，见 `docs/ui-guidelines.md`）

| 名称 | 类型 | 位置 | 用途 |
|---|---|---|---|
| `InteractiveTrendChart` | Widget | `chart_painters.dart` | 可交互折线图；`values, xLabels, yLabels, glow, tooltipOf`。点击或**横向拖动**选中数据点，再点同一点或点图表外取消；自带 `Semantics` 摘要；位于可跳转卡片内时拦截点击 |
| `InteractiveBarChart` | Widget | `chart_painters.dart` | 可交互柱状图；`values, xLabels, yLabels, tooltipOf`。交互与无障碍同上 |
| `TrendLinePainter` / `BarChartPainter` | CustomPainter | `chart_painters.dart` | 上面两个控件的绘制实现。**自绘保留**：曾评估改用 `fl_chart`，实测其坐标轴刻度与既有内边距约定对不齐（出现重复刻度与刻度/线错位），故维持自绘；不要为「换库」而替换，除非同时解决刻度对齐 |
| `BudgetRingPainter` | CustomPainter | `chart_painters.dart` | 预算进度圆环，**保持自研**：`SweepGradient` + `GradientRotation(-π/2)` 的接缝处理是规范硬要求，有像素级回归测试（`budget_ring_test.dart`）。不要换成通用进度环组件 |
| `trendChartRect` / `barChartRect` / `chartNearestIndex` / `chartSlotIndex` / `drawChartTooltip` | 纯函数 | `chart_painters.dart` | 预算趋势组合图（`budget_trend_chart.dart`，自绘画布）仍在用的几何与命中计算；气泡标题与内容按可用宽度及系统字号换行，圆点宽度单独预留，绘制限制在画布与气泡内。`chart_hit_test.dart` 覆盖命中及 360dp 英文大字号长提示的实际像素边界 |
| `ChartTooltip` / `ChartTooltipLine` | 值类 | `chart_painters.dart` | 气泡数据模型 |

## 族 10 — 纯计算（领域逻辑，无 Flutter 依赖或仅叶子级）

| 模块 | 位置 | 关键函数 |
|---|---|---|
| 日历日算术 | `calendar_days.dart`（经 `ledger_math.dart` re-export） | `calendarDaysBetween` `addCalendarDays`——**「相隔几天」「往后推 N 天」一律走这两个，禁止裸用 `difference().inDays` / `add(Duration(days:))`**：那是绝对时间，跨夏令时会差一小时→错一天（CI 在 UTC 恒绿，只在欧美时区暴露） |
| 账目数学 | `ledger_math.dart` | `signedAmount` `accountDeltaForEntry` `entryTouchesAccount` `colorForType` `sumByType` `isZeroAmount` `normalizeAmount`（金额按分规整）；`dateOnly` `cumulativeWeekWindowFor` `monthWindowFor` `weekWindowFor` `quarterWindowFor` `quarterOfMonth` `entriesInWindow` `valuesForTypeInWindow` `dailyExpenseValues` `dayExpenseTotal` `monthlyExpenseValues` `monthlyNetValuesForType`；`DateWindow` |
| 金额/时间格式化 | `ledger_math.dart` | `formatAmount` `formatExpenseAmount` `formatIncomeAmount` `formatSignedAmount` `formatCompactAmount` `formatTime`（**金额文本只走这些**，勿内联手拼） |
| 全局金额偏好 | `amount_format.dart` | 顶层量 `currencyFractionStyle`（紧凑/货币标准小数位）、`moneyUnitStyle`（符号后置/代码前置）、`hideUnitInSingleCurrency` 与 `activeBookUsesMultipleCurrencies`；**派生闸门 `activeMoneyCodeDisplay`（`none` 即隐藏单位）是唯一判断依据**，`formatUserMoney` 族与 `textCurrencyUnitHidden`（族 5）都读它，界面不要另写判断条件；Controller 单向同步，界面不直接修改顶层状态；`amountForceTwoDecimals` 仅为旧设置兼容入口 |
| 序列/坐标轴 | `series_math.dart` | `isInMonth` `monthAxisLabels` `reportAxisLabels` `isoWeekNumber` `accountBalanceSeries` `accountMonthlyBalanceSeries` `accountMonthlyBalanceSeriesBatch` `monthlyNetAssetSeries` `balanceAxisLabels` `bookkeepingDays` |
| 统计分析 | `report_analysis.dart` | `reportSummary` `reportMonthlyComparison` `reportPeriodComparison` `formatChangeRatio` `reportCategoryStats` `reportCategoryStatsByOwn` `reportCategoryChildStats` `reportTagStats` `reportAccountStats` `reportMerchantStats` `reportTrend`；`ReportRange`（账期/月/季/年/自定义）`ReportSummary` `ReportComparison` `ReportCategoryStat` `ReportTagStat` `ReportAccountStat` `ReportMerchantStat` `ReportTrend`。信用币种子账户在账户排行中按主体合并；商户只认来源证据，账期趋势可覆盖绘图分桶日期但不改交易日期；账期同比/环比由页面先按正式账单边界和 `billingCycleId` 筛好三个周期，再交给通用对比汇总。 |
| 首页指标 | `home_metrics.dart` | `computeHomeMetric` `homeMetricLabel` `homeMetricGroups` `formatHomeMetric` `homeMetricColor`；`HomeMetric` `HomeMetricContext` `HomeTrendConfig` |
| 周期记账 | `recurring.dart` | `advanceRecurring` `dueDatesFor` |
| 信用类账户 | `credit_card.dart` | `nextDueDate` `daysUntilDue` `nextStatementDate` `billingStatementDateForExpense` `currentBillingCycle` `billingCycleIdFor` `billingCycleIdForWindow` `creditDueDate` `usedCredit` `availableCredit` `billingCycleExpense` `creditStatementOverview` `buildCreditCycleOverview` `normalizedStatementStatus`；`billingStatementDateForExpense` 将出账日当天消费归入下一期，`currentBillingCycle` 为出账日至次月出账日前一天的闭区间，`billingCycleIdForWindow` 以区间结束日的次日编码目标出账日；`billingCycleIdFor` 保留显式账期优先，不改交易日期；卡号 `cardLast4Of`（在 `models.dart`） |
| 记账自动识别 | `category_suggest.dart` | `suggestEntry`（推断类型/分类/标签/备注）；`EntrySuggestion`；`lastUsedAccountIdForCategory`（该分类上次用过的账户，记账页在自动识别开启时用它预选账户） |
| 多币种草稿缩放 | `entry_currency_draft.dart` | `scaleDependentCurrencyAmount`——手工/导入/旧数据或固定周期规则改原币金额时保持既有结算比例，并按目标币种规整 |
| 账目数据校验 | `ledger_data_validation.dart` | `validateLedgerEntries` `LedgerDataValidationIssue`——交易聚合、账单导入和备份恢复共用的三层金额/退款/引用校验 |
| AI 对话查询工具 | `ai/ledger_query.dart`、`ai/ai_query_tool.dart`、`ai/ai_tool_schema.dart` | 通用交易筛选 `queryLedgerEntries`（`LedgerQuery`）；只读工具协议 `AiQueryTool` + `AiToolContext`（含 `currencyDisplay`：单位口径由聊天页注入，**工具层不读 `amount_format` 全局闸门**）+ `AiToolResult` + `AiResultDisplay`（sealed）+ typed Schema + 注册表 `buildAiQueryTools`（**新增分析工具在此登记，并更新 `ai-tools.md`**） |
| AI Agent 引擎 | `ai/ai_agent_engine.dart`、`ai/ai_native_tool_protocol.dart`、`ai/ai_prompt_tool_protocol.dart` | 双协议只读 Agent 状态机（结构化 `AiAgentMessage` / `AiAgentEvent`）；原生 Tool Calls 与兼容标记协议共用工具执行、轮次和重试边界；结构化传输入口为 `aiAgentStream` / `aiAgentComplete` |
| 设计令牌 | `app_theme.dart` | 色 `veriRoyal`(主 #346edb) `veriBlue` `veriIncome` `veriExpense` `veriWarning` 等；圆角 `veriRadiusSm/Md/Lg/Xl`；`veriHeaderHeight` `veriPageMaxWidth` |

## 族 11 — AI 对话查询 UI

桌面小组件只提供四个固定模板。`WidgetGalleryPage` 经 `AppWidgetBridge.renderPreview` 请求 Android `FixedWidgetPreviewRenderer`，直接展示 Provider 的 `createViews` 渲染图；已删除独立的 Flutter `WidgetDesignPreview` 与闲置自定义编辑页，禁止重新手绘一套近似预览。实际桌面、应用内预览和 Android 15+ 系统预览共用 RemoteViews 布局。旧版启动器的中英文、深浅色 PNG 由 `scripts/export-widget-previews.ps1` 从同一 Provider 导出。`widget_presentation.dart` 仅负责真实指标与净资产序列；资产曲线不得复用支出数据。原生渲染与导出验收见 `docs/dev/widget-preview-parity.md`。

| 名称 | 类型 | 位置 | 用途 |
|---|---|---|---|
| `AiChatPage` | 页面 Widget | `ai_chat_page.dart` | 全屏 AI 财务 Agent 对话页（气泡 + 工具步骤 + 输入框 + 清空历史，未配置引导去设置）；`debugTransport` / `debugCompleteTransport` 供测试注入结构化传输 |
| `AiAgentStepView` | Widget | `ai_agent_step_view.dart` | Agent 工具调用与重试的紧凑可折叠步骤卡；只展示本地化参数与结果摘要，不展示协议 JSON / reasoning / 底层异常 |
| `AiResultView` | Widget | `ai_result_view.dart` | 把 `AiResultDisplay` 渲染成统计卡 / 柱状排行 / 折线趋势 / **可点击交易列表** / 表格（新增展示类型在此加一支） |

---

## 维护约定

- 股票投资：`models/investment.dart` 定义不可变账户聚合；`investments/investment_decimal.dart` 提供八位精确量价和现金舍入，`stock_projection.dart` 的 `projectStocks` / `valueStocks` / `compareStockEvents` 统一重放、排序与估值，`stock_cash_math.dart` 的 `investmentCashBalance` 合并普通转账和投资现金腿。每股报价使用 `currency_math.dart` 的 `formatUserSecurityPrice` 保留八位精度并遵守单位偏好。页面为 `InvestmentPage` / `StockEditorPage`（`pages/investment_page.dart`），顶部行情入口直接进入 `MarketQuotesPage`；旧博通来源验证页与查询客户端已移除。只通过 Controller 写入，复用既有卡片、指标、菜单、输入和确认入口。详见 [阶段 0–2 实现](securities-stage02-implementation.md)。

- `app_theme.dart` 维护内容表面令牌与纯函数 `veriContentSurfaceColor(Brightness)`，供 `VeriCard` 和资产封面共用；`veriUnifiedDesignPreview` 默认关闭，只控制布局密度与排版。既有组件的布局分支见 [统一设计候选方案](unified-design-preview.md)。

- 新增可复用件 → 归入对应族、加进本表、放对的文件（通用叶子组件→`common_widgets.dart`，跨路由反馈 Host→`feedback.dart`，弹窗 helper→`sheets.dart`，记账相关 widget→`entry_sheets.dart`，纯计算→对应 `*_math`/`*_tree` 模块）。
- **收起单位要连间距一起收**：调用方为「单位：x」单独加的 `SizedBox`／`Padding` 必须与单位同时消失。只让组件自己渲染为空会把那段间距留在版面里，看起来像空了一块（2026-09-10 日历卡底部就是这个症状）。判断条件用 `textCurrencyUnitHidden`。
- **新增任何显示货币的位置**：先判断它是「金额自带单位」（走 `formatUserMoney` 族，已自动跟随偏好）还是「单位单独占位」（走 `currencyUnitSubtitle` / `MoneyUnitLabel`）。不要直接调 `displayCurrencyUnit` 或裸拼 model 的 `currencyCode`——那是 2026-09-10 那轮 17 处泄漏里 14 处的成因（其余 3 处是 `forceUnit: true` 误用与漏币种守卫），见 [单币种隐藏单位失效点审查](../reviews/2026-09-10-single-currency-unit-leak-audit.md)。
- **改货币显示口径要补双向测试**：单币种 + 开关打开断言该处不出现单位（`find.textContaining('单位：')`），多币种账本断言单位仍在，见 `test/single_currency_unit_test.dart`；只测一侧会把收口做成隐藏过度。
- 同一 UI 片段或逻辑在 **≥2 个文件**出现 → 立即抽共享件，变体用参数表达。
- 删除/重命名可复用件 → 同步改本表与所有调用点。

- 期权投资：`models/option_contract.dart` 定义独立的权利金乘数、交割股数与每张行权现金；`stock_projection.dart` 的 part `option_projection.dart` 重放开平仓/到期/交割及保证金，`securityPositionValue` 统一股数/张数估值、`optionExpired` 只判断待确认。`OptionEditorPage` 复用现有组件并要求预览，Controller 的 `previewOptionEvent` 零写入，`saveOptionEvent` / `saveOptionSpecification` 原子校验提交。详见 [期权阶段](securities-stage03-implementation.md)。

- 参考行情：`investments/market_quote.dart` 定义字段/时间/单位与来源门禁；`MarketQuoteClient.allowsAdapter` 统一来源、请求和缓存判断，`hasApprovedSources` 与 `hasAvailableSources`/`hasResearchSources` 区分正式准入和显式诊断研究。`InvestmentQuoteSync.refresh` 区分手动和自动：手动不受本地五分钟等待限制，自动按账本及币种账户独立计时，取默认五分钟与来源更严格间隔；请求中仍防重复。状态、尝试时间及下次自动刷新时间随当前账户切换，设备缓存 v2 保存账户计时，兼容 v1 报价但不沿用旧全局冷却。`MarketQuotesPage` 只负责当前账户显示和手动操作，不再拥有应用级自动调度。`formatQuoteTime(includeSeconds: true)` 在行情页显示到秒，便于辨别同一分钟内的手动抓取；持仓信息区传 `compact: true`，以应用语言的带年份短日期代替完整日期和星期，时间精度及设备时区仍保留。两参数默认均为 false，历史等既有调用保持完整日期及分钟级时间。普通构建仍无已准入来源，不能将测试夹具当作真实行情。详见 [阶段 4](securities-stage04-implementation.md)。

- 公开股票研究：`investments/tencent_quote_adapter.dart` 的 `TencentQuoteAdapter` / `TencentHttpQuoteTransport` 实现固定 HTTPS、每批 20 个身份/15 秒/512 KiB、GBK 及源时间校验；支持沪深 CNY、港股 HKD 及首批 AVGO/GOOG，期权和 TEST 代码不查询，`approved: false`/`researchOnly: true`。`production_market_quotes.dart` 的 `permitsQuoteResearch` / `buildProductionMarketQuoteClient` 由 `main.dart` 在 debug + diagnostic + 显式 `PUBLIC_QUOTE_RESEARCH=true` 时装配，通用 Controller 默认空客户端。技术/发布边界见[诊断研究记录](public-quote-research.md)。

- 证券行情前台会话：`investments/investment_quote_session.dart` 的 `InvestmentQuoteSession` 负责当前账本全部证券账户已支持持仓的到期检查与自动排程，沿用 `InvestmentQuoteSync` 的逐账户计时、缓存、请求防重及旧结果校验；不依赖详情页可见，不在构造时发请求。`pages/market_quote_session_gate.dart` 的 `MarketQuoteSessionGate` 将根级前后台、应用锁及通过隐私同意/首次引导后的可用状态连接到会话。打开软件、回前台及解锁时检查，到期才查询；退后台、锁屏、退出、关闭授权或切换账本会停止旧会话的后续请求。联网和自动开关仍为设备全局偏好且默认关闭，不注册后台服务。

- 共享时区数据库：`timezone_database.dart` 的 `ensureTimezoneDatabase()` 共用既有完整 `latest_all.tzf.gz` 资产；提醒调度与美股报价源时间解析等待同一次初始化，失败允许重试，不修改设备时区、不联网。纽约源时间使用 IANA `America/New_York`，不固定减四/五小时，也不重复打包时区表。

- 香港基金录入与结算：`fund_amount_math.dart` 的 `calculateFundPurchaseByAmount` 提供新申购参考份额与金额残差；`calculateFundOpeningByQuantity` / `FundHoldingAmountResult` 按已有实际份额、总成本及 NAV 计算市值和未实现盈亏。`calculateFundOpeningByUnrealized` / `FundOpeningAmountResult` 仅保留旧账目与算法兼容，新界面不提供报告浮盈输入，不借旧浮盈重推已存份额。`fund_workflow_math.dart` 的 `fundSubscriptionEffectiveAt` / `fundSubscriptionCashLegs` / `fundSubscriptionPendingValue` / `validateFundSubscriptions` 统一起算、资金腿、在途和校验。`models/fund_subscription.dart` 保存实际时刻与香港纯日期；`veri_fin_controller_funds.dart` 原子处理申购、确认、取消退款及持仓基准。共享 `FundOperationsButton`、`FundSubscriptionCard`、`fundSubscriptionStatusLabel` 和专用 `FundEntryPage` 位于 `pages/fund_entry_page.dart`，证券页/基金卡复用。详见[录入与结算](fund-amount-settlement.md)。
- 基金资金核对与操作模式：`stock_cash_math.dart` 对基金资金腿沿用毫秒锚点和稳定 ID 边界，同刻实际退款先供款，原普通/股票/期权排序不变；Controller 保存锚点时记录同毫秒已包含资金事实。`FundEntryPage` 切换申请、确认、取消时保留各自草稿，取消页付款字段只读；`saveFundHoldingBaseline` 只在缺当前参考价时初始化后备价，历史核对不覆盖现价。
- 证券资产与历史：`investment_valuation.dart` 的 `valueInvestmentAccount` / `valueLedgerAccounts` / `accountCashAt` / `investmentRevision` / `investmentSnapshotAt` 是纯计算入口，历史显式传 `at`，统一资产及占比包含基金在途款；`currency_math.dart` 的 `AccountAssetAmounts` 和 `ConvertedAccountBalances` 保留总资产/负债分解。`models/investment_valuation_snapshot.dart` 保存实际观察点依据，`InvestmentHistoryPage` 复用 `InteractiveTrendChart`。详见 [阶段 5](securities-stage05-implementation.md)。
- 证券资产占比：`InvestmentAccountValuation.cashShare` / `holdingsShare` / `shortObligationShare` 与 `shareOfAssets(value)` 统一以本币种账户的正现金加多头市值为分母；分母为零、估值不完整或输入无效时返回 null。概览复用 `SummaryMetric.detail`，持仓卡复用 `DetailInfoRow`；空头义务独立标注且允许超过 100%，冻结不重复扣减。百分比经 l10n `investAllocationPercent` 按语言显示一位小数。

- 证券展示组合：`app/investments/investment_widgets.dart` 的 `InvestmentSection` 复用 `VeriCard`，统一分组标题、内容伸展和内部 Material 墨水层；`InvestmentHint` 统一次级说明的图标、行距和主题颜色。`InvestmentInputField` 令标签独立占位、随字号换行，并为输入框保留可访问性名称；`investmentInputDecoration` 只提供实色底色，不添加浮动标签。`investmentOutlineButtonStyle` 对齐次要按钮与主按钮的圆角、间距和触控高度。均只负责展示，不访问 Controller。
- 证券概览排版：同文件 `InvestmentMetricPair(first, second, filled)` 只排列两个 `SummaryMetric`。普通宽度等宽双列，内容宽度小于 300dp 或 13sp 文字缩放后超过 18dp 时改单列；`filled` 用实色画布色与统一圆角突出现金/持仓，false 用于次级资产与盈亏。内部 Row 保持标准指标 Expanded 关系合法，仅对这两个静态项测量等高；不读取或计算账务。
- 持仓报价依据：同文件 `InvestmentQuoteDetails(source, quoteTime)` 接收公开来源名称及调用方已格式化的来源报价时间，仅在已采用的有效报价存在时展示。使用主题画布实色与 `veriRadiusSm`、装饰性云图标，来源为 `bodySmall`/w600，时间标签和内容为 `labelMedium`，复用 `marketQuoteTime` 本地化标签；长来源和时间完整换行，不设固定高度、不省略时区。持仓卡将其放在数量、成本、参考价、占比与盈亏之后、操作区之前；组件只负责排版，不访问 Controller、缓存或估值。
