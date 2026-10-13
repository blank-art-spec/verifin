part of 'platform_bridge.dart';

/// 账户提醒原生桥；所有通知操作在通过隐私同意和应用锁后由页面消费。
class AppAccountReminderBridge {
  AppAccountReminderBridge._();

  /// 原生队列变化信号；不携带账户名称、金额等敏感数据。
  static final ValueNotifier<int> pendingActions = ValueNotifier<int>(0);

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
