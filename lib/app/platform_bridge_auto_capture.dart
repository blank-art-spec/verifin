part of 'platform_bridge.dart';

/// 原生自动采集队列新增数据时的回调。只有 Flutter 引擎存活时原生才会通知；
/// 冷启动/进程被杀场景依靠回前台主动 drain，不会丢队列。
Future<void> Function()? _autoCaptureAvailableHandler;

/// 设置原生队列通知处理器。
void setAutoCaptureAvailableHandler(Future<void> Function()? handler) {
  _autoCaptureAvailableHandler = handler;
  _ensureInboundDispatcher();
}

/// Android 通知/短信监听桥。原生层只捕获并持久化原文，解析与正式落账全部在 Dart 层。
class AppAutoCaptureBridge {
  AppAutoCaptureBridge._();

  /// 同一 Flutter 引擎内的原生队列消费链。启动、回前台、原生回调和手动刷新
  /// 可能几乎同时发生，必须串行化以避免同一队列被并发解析两次。
  static Future<void> _queueDrain = Future<void>.value();

  /// 把用户配置同步到原生 SharedPreferences。非 Android/测试宿主静默忽略。
  static Future<void> syncConfig(AutoCaptureSettings settings) async {
    try {
      await _channel
          .invokeMethod<void>('setAutoCaptureConfig', <String, Object?>{
            'notificationEnabled': settings.notificationEnabled,
            'smsEnabled': settings.smsEnabled,
            'listenAll': settings.listenAllNotificationSources,
            'packages': settings.sourcePackages,
          });
    } on MissingPluginException {
      // 桌面测试没有原生实现。
    } on PlatformException {
      // 配置仍已保存在 Dart KV；下次应用恢复时会再次同步。
    }
  }

  /// 查询系统是否已授予通知使用权。
  static Future<bool> notificationAccessGranted() async {
    try {
      return await _channel.invokeMethod<bool>(
            'isNotificationListenerEnabled',
          ) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 打开 Android“通知使用权”设置页，由用户亲自授权/撤销。
  static Future<void> openNotificationAccessSettings() async {
    try {
      await _channel.invokeMethod<void>('openNotificationListenerSettings');
    } on MissingPluginException {
      // 非 Android 环境无动作。
    } on PlatformException {
      // 系统设置不可用时由页面重新查询并保持关闭。
    }
  }

  /// 查询 RECEIVE_SMS 是否已授权。该权限只接收开启后的新短信，不读取历史短信。
  static Future<bool> smsPermissionGranted() async {
    try {
      return await _channel.invokeMethod<bool>('isSmsPermissionGranted') ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 当前渠道是否包含短信采集能力。Play 渠道因商店政策移除了权限与接收器。
  static Future<bool> smsCaptureSupported() async {
    try {
      return await _channel.invokeMethod<bool>('isSmsCaptureSupported') ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 发起系统短信接收权限请求，返回最终授权结果。
  static Future<bool> requestSmsPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestSmsPermission') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 读取原生持久队列但不清空。调用方确认 SQLite 已保存后再调用 [acknowledgeQueue]。
  static Future<List<RawCaptureInput>> readQueue() async {
    try {
      final raw = await _channel.invokeMethod<List<Object?>>(
        'readAutoCaptureQueue',
      );
      if (raw == null) return const <RawCaptureInput>[];
      return raw
          .whereType<Map>()
          .map((item) {
            final map = Map<String, Object?>.from(item);
            return RawCaptureInput(
              sourceKind: CaptureSourceKind.fromStorage(
                map['sourceKind'] as String?,
              ),
              sourceId: map['sourceId'] as String? ?? '',
              sourceLabel: map['sourceLabel'] as String? ?? '',
              sourceEventId: map['sourceEventId'] as String? ?? '',
              rawText: map['rawText'] as String? ?? '',
              receivedAt: DateTime.fromMillisecondsSinceEpoch(
                (map['receivedAt'] as num?)?.toInt() ?? 0,
              ),
              nativeQueueId: map['queueId'] as String? ?? '',
            );
          })
          .toList(growable: false);
    } on MissingPluginException {
      return const <RawCaptureInput>[];
    } on PlatformException {
      return const <RawCaptureInput>[];
    }
  }

  /// 确认删除已经写入 SQLite 的原生队列项；读取后新到达的事件不会被清除。
  static Future<void> acknowledgeQueue(List<RawCaptureInput> inputs) async {
    final ids = inputs
        .map((input) => input.nativeQueueId)
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    if (ids.isEmpty) return;
    try {
      await _channel.invokeMethod<void>(
        'ackAutoCaptureQueue',
        <String, Object?>{'queueIds': ids},
      );
    } on MissingPluginException {
      // 桌面测试没有原生队列。
    } on PlatformException {
      // 未确认的事件会在下次启动再次读取，并由 SQLite 指纹幂等挡住重复。
    }
  }

  /// 串行执行一次“读取 → SQLite 落库/解析 → 按已存储项回执”。
  ///
  /// [ingest] 必须先把原文可靠存入 Controller/SQLite；[isStored] 随后逐条复核。
  /// 上一次执行即使意外失败也不会卡死队列，但当次错误仍原样传给调用方。
  static Future<void> drainQueue({
    required Future<void> Function(List<RawCaptureInput> inputs) ingest,
    required bool Function(RawCaptureInput input) isStored,
  }) {
    final operation = _queueDrain.then((_) async {
      final inputs = await readQueue();
      if (inputs.isEmpty) return;
      await ingest(inputs);
      final stored = inputs.where(isStored).toList(growable: false);
      await acknowledgeQueue(stored);
    });
    _queueDrain = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {
        // 仅修复后续串行链；operation 本身仍会向当次调用方报错。
      },
    );
    return operation;
  }
}
