part of 'platform_bridge.dart';

/// 系统实际可读的提醒条件；省电豁免不代表已取得厂商自启动或划卡清理白名单。
@immutable
class AccountReminderDeliveryStatus {
  const AccountReminderDeliveryStatus({
    required this.notificationsEnabled,
    required this.channelEnabled,
    required this.exactAlarmsAllowed,
    required this.batteryExempt,
    required this.backgroundRestricted,
    required this.testState,
  });

  factory AccountReminderDeliveryStatus.fromMap(Map<String, Object?> map) {
    for (final key in const [
      'notificationsEnabled',
      'channelEnabled',
      'exactAlarmsAllowed',
      'batteryExempt',
      'backgroundRestricted',
    ]) {
      if (map[key] is! bool) throw FormatException('提醒状态缺少 $key');
    }
    return AccountReminderDeliveryStatus(
      notificationsEnabled: map['notificationsEnabled']! as bool,
      channelEnabled: map['channelEnabled']! as bool,
      exactAlarmsAllowed: map['exactAlarmsAllowed']! as bool,
      batteryExempt: map['batteryExempt']! as bool,
      backgroundRestricted: map['backgroundRestricted']! as bool,
      testState: map['testState'] as String? ?? 'unknown',
    );
  }

  final bool notificationsEnabled;
  final bool channelEnabled;
  final bool exactAlarmsAllowed;
  final bool batteryExempt;
  final bool backgroundRestricted;
  final String testState;
}

/// 账户提醒原生桥；所有通知操作在通过隐私同意和应用锁后由页面消费。
class AppAccountReminderBridge {
  AppAccountReminderBridge._();

  /// 原生队列变化信号；不携带账户名称、金额等敏感数据。
  static final ValueNotifier<int> pendingActions = ValueNotifier<int>(0);

  /// 只读通知、精确闹钟、省电条件与最近测试结果；无插件时不伪造正常状态。
  static Future<AccountReminderDeliveryStatus?> deliveryStatus() async {
    try {
      final map = await _channel.invokeMapMethod<String, Object?>(
        'getAccountReminderDeliveryStatus',
      );
      return map == null ? null : AccountReminderDeliveryStatus.fromMap(map);
    } on MissingPluginException {
      return null;
    }
  }

  /// 按用户点击打开通知类别、精确闹钟或应用后台设置，不代替用户改权限。
  static Future<void> openSettings(String kind) => _channel.invokeMethod<void>(
    'openAccountReminderSettings',
    {'kind': kind},
  );

  /// 安排一分钟后的一次性测试通知，复用正式账户提醒的 Android 闹钟与通知渠道。
  /// [title]、[body] 是已本地化的测试文案，[channelName] 是通知渠道显示名。
  /// 返回 true 表示使用精确闹钟，false 表示降级为可能延迟的非精确闹钟。
  /// 测试不保存账户配置或产生记账操作；缺少插件或排程失败时抛错，由页面反馈。
  static Future<bool> scheduleTest({
    required String title,
    required String body,
    required String channelName,
  }) async {
    final exact = await _channel.invokeMethod<bool>(
      'scheduleAccountEntryReminderTest',
      {'title': title, 'body': body, 'channelName': channelName},
    );
    if (exact == null) {
      throw StateError('系统未返回账户提醒测试的排程结果');
    }
    return exact;
  }

  /// 同步全部账本的有效提醒；原生持久化后安排下一次闹钟，空列表会撤销所有提醒。
  /// 非 Android 测试宿主没有该能力，可接受地保持无操作；平台失败交给调用方反馈。
  static Future<void> sync(List<Map<String, Object?>> reminders) async {
    _ensureInboundDispatcher();
    try {
      await _channel.invokeMethod<void>('syncAccountEntryReminders', {
        'reminders': reminders,
      });
    } on MissingPluginException {
      // 测试宿主没有 Android 闹钟，不伪造通知成功或账户交易。
    }
  }

  /// 读取持久队列首项但不删除；[acknowledge] 在业务处理完成后才确认消费。
  static Future<Map<String, Object?>?> consume() async {
    try {
      return await _channel.invokeMapMethod<String, Object?>(
        'consumeAccountReminderAction',
      );
    } on MissingPluginException {
      return null; // 测试宿主没有原生通知操作。
    }
  }

  /// 完成队列项 [key]；记账失败时不确认，从而保留下一次进入应用重试的机会。
  static Future<void> acknowledge(String key) async {
    await _channel.invokeMethod<void>('acknowledgeAccountReminderAction', {
      'key': key,
    });
  }
}
