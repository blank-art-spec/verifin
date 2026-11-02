# 投资账本与证券账户交互实施记录

更新日期：2026-11-02。状态：功能代码已实现，主要自动检查及 Android 模拟器验证已完成；下文单列未执行项，不代表所有发布验收通过。

对应[开发方案](investment-ledger-interaction-plan.md)和[开发任务与验收清单](investment-ledger-interaction-acceptance.md)。当前 SQLite 为 v29，完整备份为 JSON v16。金额、份额、期权结算及基金收益计算沿用原有领域命令，本轮调整账本类型、导航、表单组合和保存边界。

## 账本类型与数据兼容

`LedgerBookType.normal / investment` 保存于 `LedgerBook.bookType`，SQLite 列为 `ledger_books.book_type`，JSON 字段为 `ledgerBooks[].bookType`。新建默认普通；SQLite v29 迁移与旧备份缺字段均填普通，名称叫“投资账本”或已有证券持仓也不改变此规则。显式非法备份类型在预览/正式导入前拒绝，不静默改成另一类型。

账本类型只影响通用手动新增入口，不限制已有账户和记录。`changeLedgerBookType` 不转换币种、清理证券记录或开启行情。默认账本、初始化和无类型历史数据均保持普通；新版样例明确将 `book_investment` 标为投资，日常和旅行仍为普通，这不是旧备份的自动识别规则。

| API | 当前职责 |
| --- | --- |
| `createLedgerBook(name, {baseCurrencyCode, bookType})` | 串行准备候选账本，落库后提交内存；创建失败返回 false |
| `changeLedgerBookType(bookId, bookType)` | 显式修改类型，成功后更新内存，失败保留原值 |
| 旧 `addLedgerBook` | 保留历史同步调用语义；生产新建表单使用可等待的创建 API |
| `showLedgerBookEditorSheet` | 同时收集名称、本位币和类型；`onSave` 失败保留弹层和草稿 |
| `showLedgerBookTypeEditorSheet` | 统一类型编辑、影响范围说明和显式保存；取消不落库 |

账本数据与设备当前账本指针不是同一存储事务。账本保存成功但指针保存失败时保留新账本、保持原活动账本，并明确反馈切换失败，不能把已创建实体当作未创建再重试。

## 新增入口与领域表单

`pages/quick_entry.dart` 的 `startQuickEntry(context:, longPress:)` 为首页、普通交易列表和 Android 通用快捷调用共享流程。先应用用户的手动/AI/长按 AI 偏好；手动动作再按目标账本类型处理：普通账本维持计算器 → `EntryDetailPage`，投资账本进入 `TransactionEntryPage`，默认“投资交易”。数字键盘仍用于明细内金额及其他原有用途。

双页签仅用于手动新建。既有普通记录、股票/期权事件、基金订单以及 AI、采集和导入草稿继续使用原专用编辑/复核流程，不通过页签将已有记录转换到另一个领域。

投资页签选择真实币种证券账户，展示主账户名和币种；明确上下文优先，其次合格默认账户，只有一个候选时才自动选择。多个账户需明确选择；无合格账户显示新建证券账户及初始化已有投资账户入口，不回退到首个普通账户或“无账户”。隐藏账户不进入新建候选。

投资操作提供股票、期权、基金按金额买入和基金已有持仓四个入口，分别复用 `StockEditorPage`、`OptionEditorPage`、`FundEntryPage`。期权规格确认、资金/持仓预览和基金申请、付款、确认、退款及收益起算的校验继续由原 Controller 命令完成。

## 草稿与保存边界

`EntryEditorSession` 只在当前页面内维护修改状态、可保存状态及领域保存回调；`EntryEditorSurface` 使原表单既能独立打开，也能嵌入双页签，不嵌套第二个完整页面外壳。普通草稿一份，投资草稿按账户和业务操作分开，切换时保留输入，不跨币种重解释数字。

保存只提交当前记录，其他隐藏草稿有改动时留页提示；成功会话更新基线并只读展示，不能再次新建相同记录。退出保护检查所有会话；仅隐藏草稿有改动时不提供无效的“保存当前”。Header、系统及预测性返回共用 `UnsavedChangesGuard`。

保存中断开输入连接并禁止聚焦、编辑及返回丢弃，避免用户选择离页后事务仍成功。失败保留草稿，稳定 ID 与现有原子命令用于防重。会话退出和控件释放不自动落账；首版不提供进程终止后的未提交草稿恢复，也不新增最近投资账户的设备偏好。

普通页签中已经选择的转账目标若被隐藏或删除，保留失效引用并禁用保存，必须由用户明确重选；不能自动把 A→B 改为 A→C。普通独立记账的原始预选规则保持。

空白普通草稿可能先于后续新建的证券账户存在。仅在嵌入草稿仍无修改、尚未手选日期时间且首次自动补入新账户时，将默认发生时间刷新为当下并重建清洁基线，避免随后录入的资金流水误落在证券期初之前。已有输入、明确日期时间及外部草稿保持原时刻；不改变期初锚点或现金重放规则。

新股票事件在保存时通过公共只读 `nextInvestmentEventSequenceFor(accountId)` 读取最新可用序号；编辑已有事件保留原序号。期权每次预览使用最新序号，并冻结组合和现金依据；其他草稿或资金变化使旧预览失效，必须重新预览确认，防止同账户多个草稿缓存同一序号。

账本新建和类型编辑的异步提交弹层关闭下拉关闭并隐藏拖拽把手，防止拖拽直接退出绕过保存期间的返回保护；未保存时仍可通过返回或遮罩取消。其他弹层保留原拖拽行为。

## 证券账户详情与开户

`openAccountDetails(context:, accountId:/parentId:)` 集中资产、分组及父账户币种子账户导航。父账户继续打开汇总；实际账户已有投资组合时直达 `InvestmentPage`，空持仓/清仓仍为证券账户；历史未初始化的投资类账户继续普通详情。此判断与账本类型相互独立，不把所有投资类余额账户自动转为证券组合。

证券页保留资产分解、现金、持仓、基金在途、投资记录、历史和参考行情，追加两个共享区域：

- `AccountInformationSection` 展示基本信息、分组、所属主账户、计入资产、隐藏/默认状态和提醒入口。“编辑资料”复用 `AccountDetailPage(editingOnly: true)`，不复制保存逻辑。
- `AccountFundingSection` 展示同账户普通资金流水及完整列表，可按当前账户新增普通记账。股票、期权和基金资金腿不复制为普通流水；现金核对仍使用原现金锚点。

证券账户内新增预填实际币种账户；持仓专属操作保留证券及方向上下文；主账户顶部“＋”仍新增币种子账户。普通支付、现金、银行卡及信用页面保留各自余额、流水或账单能力。

`AddAccountPage(securities: true, bookId: ...)` 从专用入口收集资料和明确期初现金。留空不能保存，零现金必须实际输入零；原普通新建入口保留原含义。`createSecuritiesAccount` 在同一串行命令中检查账本、账户 ID、币种及主账户关联，归零普通初始余额后，以核对现金创建空投资组合。

`LedgerRepository.saveSecuritiesAccountAggregate` 让主账户、实际账户和组合共同提交，SQLite 事务成功后才更新行基线与 Controller 内存。已有主账户下失败不删除原主账户；重复 ID 或同主账户重复币种不创建第二份实体。该流程不伪造普通入金，不重复计算期初现金，不默认开启联网。

## 验证进度与证据

自动验证覆盖账本模型/行映射、历史迁移矩阵、仓储契约及开户回滚、备份与导入、冷启动、双页签及多草稿、股票/期权/基金原编辑行为和证券详情导航。新增开户 UI 验证包含慢磁盘期间返回与输入保护、显式零现金及取消零落库。

### 自动检查结果

- 最终 `dart format lib test scripts` 检查 471 个文件，无需再格式化；`flutter analyze lib test scripts` 无问题。
- 全量测试最终一轮为 **1982 通过、6 跳过、1 项超时**。唯一超时是 `migration_matrix_test.dart` 的 v27 手填/导入参考额语义用例，在默认 30 秒限制下超时；该项随后按 2 分钟限制单独重跑，19 秒通过。不能把这次全量执行写成一次全部通过。
- SQLite 历史版本 v1–v28 升级至 v29 的矩阵、模型往返、仓储契约、完整备份及旧版本导入均已通过。证券开户验证覆盖事务失败回滚、重复 ID、已有主账户保留和显式零现金。
- 采用实际预览参数 `UNIFIED_DESIGN_PREVIEW=true` 的布局和导航检查 **61 项通过**，涵盖双页签、窄屏、大字号、深浅色及原有统一设计行为。
- 原生实测发现并修复空白普通草稿早于随后开户的默认时间边界后，重新执行普通记账、双页签、账户失效、事件顺序、新增路由、开户与布局相关检查，**64 项全部通过**，其中包含三项确定时钟用例；修改已有输入或手选时间的行为没有扩大。

日志位于本机忽略目录 `build/validation/investment-ledger-20261102/`：`full-tests-final.log`、`migration-timeout-recheck.log`、`release-layout-tests.log`、`after-time-fix-tests.log`、`analyze-after-time-fix.log`。该目录含设备私有数据备份，仅留本机，不加入 Git。

### 手动构建与模拟器

本次明确手动触发构建，无监听或自动构建任务。工具链为 Flutter 3.47.2 / Dart 3.13.2、Java 17、Android SDK 36；验证设备为 API 35 的 `verifin_x300_lite`（`emulator-5556`，x86_64，608×1320 / 248 dpi，约 393×852 逻辑尺寸）。使用正式 `lib/main.dart` 与独立 `diagnostic` 包，不覆盖正式应用。

保留 `UNIFIED_DESIGN_PREVIEW=true` 和设备原有诊断行情研究开关 `PUBLIC_QUOTE_RESEARCH=true`。本机 Windows 批处理启动器受运行权限限制，因此使用本地 Flutter SDK 同一 `assemble` 规则直接生成内核和资源，再由 Java 启动项目 Gradle Wrapper 完成资源复制、原生编译、签名和打包；只跳过已执行的 `compileFlutterBuildDiagnosticDebug`，未修改 SDK、Android 工程或系统策略。具体可复现调用保留在本机 `build-manual.ps1` 和构建日志。

首次原生构建成功（1 分 33 秒），默认时间修复后再次构建成功（Gradle 阶段 17 秒）。最终 APK 为 `build/app/outputs/flutter-apk/app-diagnostic-debug.apk`，127,494,866 字节，SHA-256 为 `7CD1D0A048A00D87DC12CAFCABF91B08E14FC606A1F162D06AF599F0327CCA1F`；已检查 x86_64 引擎、debug 内核和时区资源，覆盖安装成功。包名为 `top.talyra42.verifin.graphicsdiagnostic`。没有卸载或清除应用数据。

### Android 实测项目

| 项目 | 实际结果与本机截图 |
| --- | --- |
| 历史升级与普通入口 | 原数据库 v28 升为 v29，三个历史账本均为普通；原“投资账本”名称未被用于推断类型。该账本加号仍打开原计算器，见 `normal-ledger-calculator.png` |
| 显式修改与新建类型 | 通过账本管理将原“投资账本”改为投资；加号直接进入默认投资的双页签。新建临时账本可同时保存名称、本位币和投资类型，见 `ledger-type-investment.png`、`investment-entry-tabs.png`、`new-investment-ledger-form.png` |
| 账户选择与多草稿 | 能区分两个主账户的 CNY / USD / HKD 六个真实币种账户；页签切换保留输入。保存普通收入后只读显示，提示仍有投资草稿；返回可取消或明确丢弃，见 `ordinary-draft-retained.png`、`stock-draft-retained.png` |
| 证券开户 | 无账户时显示新建引导；期初现金留空被拒绝，显式输入 0 后账户、主账户和空投资组合共同创建，普通初始余额为 0，没有伪造入金，见 `securities-account-empty-opening.png`、`zero-cash-account-created.png` |
| 真实保存与资产 | 在临时账本保存开户后的 1000 收入及买入 10 股、单价 10 的测试交易，证券页显示现金 900、持仓价值 100、净值 1000；买入只在投资记录出现，见 `native-stock-trade-saved.png` |
| 详情与基本信息整合 | 资产进入父账户汇总，点实际币种账户直接进入证券页，空持仓也如此；账户内新增预填本账户。基本信息的“编辑资料”进入原资料表单；资金流水“记一笔”仍打开普通金额键盘，见 `empty-securities-page.png`、`securities-context-prefilled.png`、`securities-integrated-information.png`、`securities-account-edit-information.png` |
| 开户时间边界复测 | 最新包重新按“先开录入页→零现金开户→同一会话普通收入 1000”操作，入库发生时刻晚于期初，证券现金为 1000，普通流水仅一笔、投资事件为零，见 `time-fix-native-cash1000.png` |
| 冷启动与清理 | 强制关闭再打开，账本类型、开户及已保存交易保留；前后数据库记录一致。两次隔离验证只删除本轮创建的临时账本，保留原账本、账户和持仓 |

升级前保存了完整私有数据备份和数据库只读副本。升级及清理后按原有列比较全部 22 张业务表：原账户 11 个、投资组合 7 个和普通交易 1 笔均原样保留；21 张表记录完全一致。既有自动汇率设置在启动时使汇率表从 8 行增至 10 行，原 8 行仍保留；这不是全表完全不变的证据。新 `book_type` 列只有通过界面显式修改的原投资账本为投资，其余历史账本仍普通。比较证据见 `upgrade-preservation.json` 和 `final-preservation.json`。

最终验证停留在原“投资账户二.CNY”证券页面，截图为 `final-securities-account.png`；应用进程日志未发现 Flutter 未处理异常或布局溢出。模拟器采用软件图形后运行稳定。桌面窗口控制接口曾返回 `failed to activate captured window`，因此后续以 Android 自身页面、截图和实际交互核验运行，未声称桌面窗口激活成功。

### 尚未执行的发布验收

未执行真实手机、Release/R8 构建、桌面快捷方式/指定账本小组件的完整原生场景，以及所有期权结算和基金状态组合的逐项 Android 复测。本次没有修改这些领域计算，自动测试覆盖原有行为，但不能以此替代全部设备场景。本轮不发布、不推送标签；正式包仍由 CI 在明确授权后构建。

## 保留边界

- SQLite v29 与 JSON v16 继续读取 v1–v15 旧备份；不提供数据库降级或要求清除应用数据。
- 未提交草稿只留本次编辑会话，不进入完整备份或设备缓存。
- 行情来源准入、授权、逐账户刷新与后台停止规则保持原样；本轮不增加期权持续行情、券商下单或后台服务。
- 原开发方案保留设计依据，当前事实以源码、相应验证和本记录为准。发布仍由 CI 与明确授权执行，本地模拟器包仅作验证。
