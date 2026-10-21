import '../models.dart';
import '../../l10n/app_localizations.dart';
import 'china_workday_calendar.dart';

/// 重复日期的口径；旧配置始终保留自定义星期，不自动改成法定工作日。
enum AccountReminderRepeatMode {
  weekdays,
  chinaWorkdays;

  /// 使用 [l10n] 的当前应用语言展示规则名称，明确大陆范围和调休语义。
  String label(AppLocalizations l10n) => switch (this) {
    weekdays => l10n.accountEntryReminderCustomWeekdays,
    chinaWorkdays => l10n.accountEntryReminderChinaWorkdays,
  };
}

/// 年度日历缺失时的用户选择；默认暂停，只有显式选择才允许工作周降级。
enum MissingWorkdayCalendarPolicy {
  pause,
  weekdays;

  /// 使用 [l10n] 展示缺失日历时的处理方式，不暗示降级结果已包含调休。
  String label(AppLocalizations l10n) => switch (this) {
    pause => l10n.accountEntryReminderCalendarPause,
    weekdays => l10n.accountEntryReminderCalendarWeekdays,
  };
}

/// 单个账户的记账确认提醒；配置属于设备偏好，不会因切换账本而改变。
/// 金额使用账户币种，每天至多确认或取消一次，未响应不会产生交易。
class AccountEntryReminder {
  /// [id] 是本次配置的修订标识，用于拒绝编辑前的旧通知；其余字段描述预设交易、
  /// 本地提醒时刻、星期（1 为周一、7 为周日）和两个按钮文字。
  /// [handledDate] 保存最近处理的日历日期，防止取消后或删除交易后重复处理。
  /// [repeatMode] 决定使用星期还是大陆工作日；[missingCalendarPolicy] 仅用于缺失年度，
  /// 默认暂停，保留 [weekdays] 便于用户切回原规则。两种模式不会同时叠加。
  const AccountEntryReminder({
    required this.id,
    required this.accountId,
    required this.bookId,
    required this.currencyCode,
    this.enabled = false,
    this.name = '',
    this.type = EntryType.expense,
    this.amount = 0,
    this.categoryId = '',
    this.hour = 12,
    this.minute = 30,
    this.weekdays = const <int>[1, 2, 3, 4, 5],
    this.repeatMode = AccountReminderRepeatMode.weekdays,
    this.missingCalendarPolicy = MissingWorkdayCalendarPolicy.pause,
    this.confirmLabel = '',
    this.cancelLabel = '',
    this.handledDate = '',
  });

  final String id;
  final String accountId;
  final String bookId;
  final String currencyCode;
  final bool enabled;
  final String name;
  final EntryType type;
  final double amount;
  final String categoryId;
  final int hour;
  final int minute;
  final List<int> weekdays;
  final AccountReminderRepeatMode repeatMode;
  final MissingWorkdayCalendarPolicy missingCalendarPolicy;
  final String confirmLabel;
  final String cancelLabel;
  final String handledDate;

  /// 判断 [date] 是否属于本规则；原生排程与确认记账均须采用相同口径。
  /// 工作日模式不与自定义星期取交集，否则周末补班会被错误过滤。
  /// [calendar] 允许测试注入年度数据；生产默认使用核对后的内置离线日历。
  bool matchesDate(
    DateTime date, {
    ChinaWorkdayCalendar calendar = mainlandChinaWorkdayCalendar,
  }) => switch (repeatMode) {
    AccountReminderRepeatMode.weekdays => weekdays.contains(date.weekday),
    AccountReminderRepeatMode.chinaWorkdays =>
      calendar.isWorkday(date) ??
          (missingCalendarPolicy == MissingWorkdayCalendarPolicy.weekdays &&
              date.weekday <= DateTime.friday),
  };

  /// [date] 所在年份是否缺少本模式需要的日历；用于前台主动说明暂停或降级。
  bool hasMissingCalendar(DateTime date) =>
      repeatMode == AccountReminderRepeatMode.chinaWorkdays &&
      !mainlandChinaWorkdayCalendar.years.containsKey(date.year);

  /// 复制草稿；未提供的字段保持原值，星期列表转成不可变集合以免被页面原地修改。
  /// 切换 [repeatMode] 不清空星期；[missingCalendarPolicy] 保留用户的明确选择。
  AccountEntryReminder copyWith({
    String? id,
    bool? enabled,
    String? name,
    EntryType? type,
    double? amount,
    String? categoryId,
    int? hour,
    int? minute,
    List<int>? weekdays,
    AccountReminderRepeatMode? repeatMode,
    MissingWorkdayCalendarPolicy? missingCalendarPolicy,
    String? confirmLabel,
    String? cancelLabel,
    String? handledDate,
  }) => AccountEntryReminder(
    id: id ?? this.id,
    accountId: accountId,
    bookId: bookId,
    currencyCode: currencyCode,
    enabled: enabled ?? this.enabled,
    name: name ?? this.name,
    type: type ?? this.type,
    amount: amount ?? this.amount,
    categoryId: categoryId ?? this.categoryId,
    hour: hour ?? this.hour,
    minute: minute ?? this.minute,
    weekdays: List<int>.unmodifiable(weekdays ?? this.weekdays),
    repeatMode: repeatMode ?? this.repeatMode,
    missingCalendarPolicy: missingCalendarPolicy ?? this.missingCalendarPolicy,
    confirmLabel: confirmLabel ?? this.confirmLabel,
    cancelLabel: cancelLabel ?? this.cancelLabel,
    handledDate: handledDate ?? this.handledDate,
  );

  /// 将配置编码为设备 KV 的 JSON；不包含通知权限或账目原文。
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'accountId': accountId,
    'bookId': bookId,
    'currencyCode': currencyCode,
    'enabled': enabled,
    'name': name,
    'type': type.name,
    'amount': amount,
    'categoryId': categoryId,
    'hour': hour,
    'minute': minute,
    'weekdays': weekdays,
    'repeatMode': repeatMode.name,
    'missingCalendarPolicy': missingCalendarPolicy.name,
    'confirmLabel': confirmLabel,
    'cancelLabel': cancelLabel,
    'handledDate': handledDate,
  };

  /// 读取本机配置 [json]；缺启用字段默认关闭，缺模式字段保留旧星期规则。
  /// 未知模式停用，未知日历缺失策略默认暂停，不扩大用户授权的提醒日期。
  factory AccountEntryReminder.fromJson(Map<String, Object?> json) =>
      AccountEntryReminder(
        id: json['id'] as String? ?? '',
        accountId: json['accountId'] as String? ?? '',
        bookId: json['bookId'] as String? ?? '',
        currencyCode: json['currencyCode'] as String? ?? '',
        // 缺字段兼容旧版；未知模式不能偷偷降级并发送用户未授权的提醒。
        enabled:
            json['enabled'] == true &&
            (json['repeatMode'] == null ||
                AccountReminderRepeatMode.values.any(
                  (mode) => mode.name == json['repeatMode'],
                )),
        name: json['name'] as String? ?? '',
        type: json['type'] == 'income' ? EntryType.income : EntryType.expense,
        amount: (json['amount'] as num?)?.toDouble() ?? 0,
        categoryId: json['categoryId'] as String? ?? '',
        hour: (json['hour'] as num?)?.toInt() ?? 12,
        minute: (json['minute'] as num?)?.toInt() ?? 30,
        weekdays: List<int>.unmodifiable(
          (json['weekdays'] as List? ?? const <int>[]).whereType<int>(),
        ),
        repeatMode:
            AccountReminderRepeatMode.values
                .where((mode) => mode.name == json['repeatMode'])
                .firstOrNull ??
            AccountReminderRepeatMode.weekdays,
        missingCalendarPolicy: json['missingCalendarPolicy'] == 'weekdays'
            ? MissingWorkdayCalendarPolicy.weekdays
            : MissingWorkdayCalendarPolicy.pause,
        confirmLabel: json['confirmLabel'] as String? ?? '',
        cancelLabel: json['cancelLabel'] as String? ?? '',
        handledDate: json['handledDate'] as String? ?? '',
      );
}

/// 提醒处理结果；已处理和过期都不新增交易，失败允许用户重试。
enum AccountReminderResult {
  recorded,
  cancelled,
  alreadyHandled,
  expired,
  missingRate,
  failed,
}
