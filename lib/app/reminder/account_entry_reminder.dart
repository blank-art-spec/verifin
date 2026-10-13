import '../models.dart';

/// 单个账户的记账确认提醒；配置属于设备偏好，不会因切换账本而改变。
/// 金额使用账户币种，每天至多确认或取消一次，未响应不会产生交易。
class AccountEntryReminder {
  /// [id] 是本次配置的修订标识，用于拒绝编辑前的旧通知；其余字段描述预设交易、
  /// 本地提醒时刻、星期（1 为周一、7 为周日）和两个按钮文字。
  /// [handledDate] 保存最近处理的日历日期，防止取消后或删除交易后重复处理。
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
  final String confirmLabel;
  final String cancelLabel;
  final String handledDate;

  /// 复制草稿；未提供的字段保持原值，星期列表转成不可变集合以免被页面原地修改。
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
    'confirmLabel': confirmLabel,
    'cancelLabel': cancelLabel,
    'handledDate': handledDate,
  };

  /// 读取本机配置；缺字段采用关闭状态，不把旧数据解释成用户已授权的提醒。
  factory AccountEntryReminder.fromJson(Map<String, Object?> json) =>
      AccountEntryReminder(
        id: json['id'] as String? ?? '',
        accountId: json['accountId'] as String? ?? '',
        bookId: json['bookId'] as String? ?? '',
        currencyCode: json['currencyCode'] as String? ?? '',
        enabled: json['enabled'] == true,
        name: json['name'] as String? ?? '',
        type: json['type'] == 'income' ? EntryType.income : EntryType.expense,
        amount: (json['amount'] as num?)?.toDouble() ?? 0,
        categoryId: json['categoryId'] as String? ?? '',
        hour: (json['hour'] as num?)?.toInt() ?? 12,
        minute: (json['minute'] as num?)?.toInt() ?? 30,
        weekdays: List<int>.unmodifiable(
          (json['weekdays'] as List? ?? const <int>[]).whereType<int>(),
        ),
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
