part of 'platform_bridge.dart';

/// 原生自动采集队列新增数据时的回调。只有 Flutter 引擎存活时原生才会通知；
/// 冷启动/进程被杀场景依靠回前台主动 drain，不会丢队列。
Future<void> Function()? _autoCaptureAvailableHandler;

/// 设置原生队列通知处理器。
void setAutoCaptureAvailableHandler(Future<void> Function()? handler) {
  _autoCaptureAvailableHandler = handler;
  _ensureInboundDispatcher();
}

/// 最近一条通知在 Android 原生采集管线中的处理结果。
///
/// 此实时快照只包含来源、时间和阶段状态。可回看的三天通知日志单独保存，
/// 允许来源的通知独立保存系统提供的文字，不受识别用金融过滤结果限制。
class NativeNotificationDiagnostic {
  const NativeNotificationDiagnostic({
    required this.occurredAt,
    required this.sourceId,
    required this.sourceLabel,
    required this.textExtraction,
    required this.financialFilter,
    required this.queueResult,
    required this.outcome,
  });

  final DateTime occurredAt;
  final String sourceId;
  final String sourceLabel;
  final String textExtraction;
  final String financialFilter;
  final String queueResult;
  final String outcome;

  /// 把 MethodChannel 返回的弱类型 Map 转成稳定模型；缺失时间时不生成误导性记录。
  static NativeNotificationDiagnostic? fromMap(Map<dynamic, dynamic>? raw) {
    if (raw == null) return null;
    final map = Map<String, Object?>.from(raw);
    final milliseconds = (map['occurredAt'] as num?)?.toInt() ?? 0;
    if (milliseconds <= 0) return null;
    return NativeNotificationDiagnostic(
      occurredAt: DateTime.fromMillisecondsSinceEpoch(milliseconds),
      sourceId: map['sourceId'] as String? ?? '',
      sourceLabel: map['sourceLabel'] as String? ?? '',
      textExtraction: map['textExtraction'] as String? ?? 'notRun',
      financialFilter: map['financialFilter'] as String? ?? 'notRun',
      queueResult: map['queueResult'] as String? ?? 'notRun',
      outcome: map['outcome'] as String? ?? 'none',
    );
  }
}

/// 设备本机通知捕获日志，与账本事件及正式交易分开保存。
///
/// [recordedAt] 是本次捕获时间，用于三天滚动保留；[occurredAt] 是系统通知时间。
/// [sourceEventId] 只用于关联当前账本已经存在的采集事件，不触发重新解析或入账。
class NotificationCaptureLogEntry {
  const NotificationCaptureLogEntry({
    required this.id,
    required this.recordedAt,
    required this.diagnostic,
    this.sourceEventId = '',
    this.rawText = '',
    this.textCompleteness = 'legacy',
  });

  final String id;
  final DateTime recordedAt;
  final NativeNotificationDiagnostic diagnostic;
  final String sourceEventId;
  final String rawText;

  /// captured 只表示已读取系统提供的文字，不承诺源应用提供了完整原始内容。
  final String textCompleteness;

  DateTime get occurredAt => diagnostic.occurredAt;
  String get sourceId => diagnostic.sourceId;
  String get sourceLabel => diagnostic.sourceLabel;
  String get textExtraction => diagnostic.textExtraction;
  String get financialFilter => diagnostic.financialFilter;
  String get queueResult => diagnostic.queueResult;
  String get outcome => diagnostic.outcome;

  /// 原生记录字段缺失时跳过该行，不用当前时间伪造捕获记录。
  static NotificationCaptureLogEntry? fromMap(Map<dynamic, dynamic> raw) {
    String text(String key, [String fallback = '']) =>
        raw[key] is String ? raw[key] as String : fallback;
    final rawId = raw['id'];
    final id = rawId is String || rawId is int ? '$rawId' : '';
    final recorded = raw['recordedAt'];
    final occurred = raw['occurredAt'];
    if ((int.tryParse(id) ?? 0) <= 0 ||
        recorded is! int ||
        recorded <= 0 ||
        occurred is! int ||
        occurred <= 0 ||
        recorded > 8640000000000000 ||
        occurred > 8640000000000000) {
      return null;
    }
    final diagnostic = NativeNotificationDiagnostic(
      occurredAt: DateTime.fromMillisecondsSinceEpoch(occurred),
      sourceId: text('sourceId'),
      sourceLabel: text('sourceLabel'),
      textExtraction: text('textExtraction', 'notRun'),
      financialFilter: text('financialFilter', 'notRun'),
      queueResult: text('queueResult', 'notRun'),
      outcome: text('outcome', 'none'),
    );
    // 日志正文独立于识别结果；仍拒绝被屏蔽、关闭采集和异常阶段组合的正文。
    final status = text('textCompleteness', 'legacy');
    final completeness =
        const <String>{
          'captured',
          'partial',
          'legacy',
          'unavailable',
          'notStored',
        }.contains(status)
        ? status
        : 'legacy';
    final eligibleOutcome = switch (diagnostic.outcome) {
      'queued' || 'duplicate' || 'queueWriteFailed' =>
        diagnostic.textExtraction == 'success' &&
            diagnostic.financialFilter == 'passed',
      'financialRejected' =>
        diagnostic.textExtraction == 'success' &&
            diagnostic.financialFilter == 'rejected' &&
            diagnostic.queueResult == 'notRun',
      'textUnavailable' =>
        diagnostic.textExtraction == 'failed' &&
            diagnostic.financialFilter == 'notRun' &&
            diagnostic.queueResult == 'notRun',
      _ => false,
    };
    final eligibleSource =
        diagnostic.sourceId.trim().isNotEmpty && eligibleOutcome;
    final retainBody =
        eligibleSource &&
        completeness != 'notStored' &&
        completeness != 'unavailable';
    final body = retainBody ? text('rawText') : '';
    const maxTextLength = 65536;
    final truncated = body.length > maxTextLength;
    var bodyEnd = maxTextLength;
    if (truncated &&
        body.codeUnitAt(bodyEnd - 1) >= 0xd800 &&
        body.codeUnitAt(bodyEnd - 1) <= 0xdbff &&
        body.codeUnitAt(bodyEnd) >= 0xdc00 &&
        body.codeUnitAt(bodyEnd) <= 0xdfff) {
      bodyEnd--;
    }
    return NotificationCaptureLogEntry(
      id: id,
      recordedAt: DateTime.fromMillisecondsSinceEpoch(recorded),
      diagnostic: diagnostic,
      sourceEventId: retainBody ? text('sourceEventId') : '',
      rawText: truncated ? body.substring(0, bodyEnd) : body,
      textCompleteness: !eligibleSource || completeness == 'notStored'
          ? 'notStored'
          : truncated
          ? 'partial'
          : completeness,
    );
  }
}

/// 原生日志按稳定自增 id 倒序分页，新通知插入不会改变后续页面的游标边界。
class NotificationCaptureLogBatch {
  const NotificationCaptureLogBatch({
    required this.entries,
    required this.hasMore,
    this.nextBeforeId,
  });

  final List<NotificationCaptureLogEntry> entries;
  final bool hasMore;
  final String? nextBeforeId;

  factory NotificationCaptureLogBatch.fromMap(Map<dynamic, dynamic> raw) {
    final values = raw['entries'];
    final entries = <NotificationCaptureLogEntry>[];
    final ids = <String>{};
    if (values is List) {
      for (final value in values.whereType<Map>()) {
        final entry = NotificationCaptureLogEntry.fromMap(value);
        if (entry != null && ids.add(entry.id)) entries.add(entry);
      }
    }
    final cursor = raw['nextBeforeId'];
    final next = cursor is String && (int.tryParse(cursor) ?? 0) > 0
        ? cursor
        : entries.lastOrNull?.id;
    final hasMore =
        raw['hasMore'] == true && entries.isNotEmpty && next != null;
    return NotificationCaptureLogBatch(
      entries: List<NotificationCaptureLogEntry>.unmodifiable(entries),
      hasMore: hasMore,
      nextBeforeId: hasMore ? next : null,
    );
  }
}

/// Android 自动采集的实时诊断快照.
///
/// [notificationAccessGranted] 是系统授权，[listenerConnected] 是当前进程实际收到的
/// NLS 连接回调；两者必须分开显示，才能识别“设置页显示已授权但服务并未工作”的情况。
class AutoCaptureNativeDiagnostics {
  const AutoCaptureNativeDiagnostics({
    required this.available,
    required this.notificationAccessGranted,
    required this.listenerConnected,
    required this.nativeNotificationEnabled,
    required this.nativeListenAll,
    required this.pendingQueueCount,
    required this.listenerConnectedAt,
    required this.listenerDisconnectedAt,
    required this.lastNotification,
  });

  /// 非 Android 或原生插件不可用时的安全默认值。
  static const unavailable = AutoCaptureNativeDiagnostics(
    available: false,
    notificationAccessGranted: false,
    listenerConnected: false,
    nativeNotificationEnabled: false,
    nativeListenAll: false,
    pendingQueueCount: 0,
    listenerConnectedAt: null,
    listenerDisconnectedAt: null,
    lastNotification: null,
  );

  final bool available;
  final bool notificationAccessGranted;
  final bool listenerConnected;
  final bool nativeNotificationEnabled;
  final bool nativeListenAll;
  final int pendingQueueCount;
  final DateTime? listenerConnectedAt;
  final DateTime? listenerDisconnectedAt;
  final NativeNotificationDiagnostic? lastNotification;

  /// 把原生毫秒时间戳转成本地 [DateTime]；0 或缺失表示从未发生。
  static DateTime? _timeOf(Object? raw) {
    final milliseconds = (raw as num?)?.toInt() ?? 0;
    return milliseconds <= 0
        ? null
        : DateTime.fromMillisecondsSinceEpoch(milliseconds);
  }

  /// 从 MethodChannel 的弱类型结果构建快照，未知字段按“未启用/未连接”保守处理。
  factory AutoCaptureNativeDiagnostics.fromMap(Map<dynamic, dynamic> raw) {
    final map = Map<String, Object?>.from(raw);
    final lastNotification = map['lastNotification'];
    return AutoCaptureNativeDiagnostics(
      available: map['available'] as bool? ?? true,
      notificationAccessGranted:
          map['notificationAccessGranted'] as bool? ?? false,
      listenerConnected: map['listenerConnected'] as bool? ?? false,
      nativeNotificationEnabled:
          map['nativeNotificationEnabled'] as bool? ?? false,
      nativeListenAll: map['nativeListenAll'] as bool? ?? false,
      pendingQueueCount: (map['pendingQueueCount'] as num?)?.toInt() ?? 0,
      listenerConnectedAt: _timeOf(map['listenerConnectedAt']),
      listenerDisconnectedAt: _timeOf(map['listenerDisconnectedAt']),
      lastNotification: NativeNotificationDiagnostic.fromMap(
        lastNotification is Map ? lastNotification : null,
      ),
    );
  }
}

/// Android 可见的已安装应用（桌面入口及已知通知来源）。不读取通知正文。
class InstalledNotificationApp {
  const InstalledNotificationApp({
    required this.packageName,
    required this.label,
  });
  final String packageName;
  final String label;
}

/// Android 通知/短信监听桥。原生层只捕获并持久化原文，解析与正式落账全部在 Dart 层。
class AppAutoCaptureBridge {
  AppAutoCaptureBridge._();

  /// null 表示读取失败或旧原生桥不支持，不能把它显示成“没有通知日志”。
  static Future<NotificationCaptureLogBatch?> notificationLogs({
    String? beforeId,
    int limit = 50,
  }) async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'readNotificationCaptureLogs',
        <String, Object?>{'beforeId': ?beforeId, 'limit': limit.clamp(1, 100)},
      );
      return raw == null ? null : NotificationCaptureLogBatch.fromMap(raw);
    } on MissingPluginException {
      return null; // 非 Android 或旧安装包，由页面显示不可用和重试入口。
    } on PlatformException {
      return null; // 原生存储读取失败，由页面保留已有结果并提供重试。
    }
  }

  /// 仅删除本机诊断日志；不消费原生队列，也不修改 CaptureEvent 或正式交易。
  static Future<bool> clearNotificationLogs() async {
    try {
      return await _channel.invokeMethod<bool>(
            'clearNotificationCaptureLogs',
          ) ??
          false;
    } on MissingPluginException {
      return false; // 旧桥不可用时不报告清空成功。
    } on PlatformException {
      return false; // 删除失败时保留页面内容并反馈失败。
    }
  }

  /// 显式初始化应用数据时清除设备诊断历史；旧桥或非 Android 宿主没有该数据。
  static Future<void> resetNotificationLogsAfterDataReset() async {
    try {
      final cleared = await _channel.invokeMethod<bool>(
        'resetNotificationCaptureLogs',
      );
      if (cleared != true) {
        throw PlatformException(code: 'NOTIFICATION_LOG_RESET_FAILED');
      }
    } on MissingPluginException {
      // 桌面测试和旧原生桥不存在这份独立日志，不阻止原有账本初始化。
    }
  }

  /// null 表示原生读取不可用，调用方必须显示失败与重试入口。
  static Future<List<InstalledNotificationApp>?> installedNotificationApps({
    List<String> knownPackages = const <String>[],
  }) async {
    try {
      final result = await _channel.invokeListMethod<Object?>(
        'getInstalledNotificationApps',
        <String, Object?>{'knownPackages': knownPackages},
      );
      if (result == null) return null;
      return <InstalledNotificationApp>[
        for (final value in result)
          if (value is Map &&
              value['packageName'] is String &&
              (value['packageName'] as String).isNotEmpty)
            InstalledNotificationApp(
              packageName: value['packageName'] as String,
              label:
                  value['label'] as String? ?? value['packageName'] as String,
            ),
      ];
    } on MissingPluginException {
      return null; // 测试或旧原生桥不可用，由页面明确显示读取失败。
    } on PlatformException {
      return null; // Android 读取失败，由页面给出可重试的反馈。
    }
  }

  /// 同一 Flutter 引擎内的原生队列消费链。启动、回前台、原生回调和手动刷新
  /// 可能几乎同时发生，必须串行化以避免同一队列被并发解析两次。
  static Future<void> _queueDrain = Future<void>.value();

  /// 把用户配置同步到原生 SharedPreferences。
  ///
  /// 返回 true 表示原生已同步提交；非 Android、插件异常或磁盘提交失败返回 false，
  /// 调用页可据此展示配置不同步，而不是继续假装后台监听已开启。
  static Future<bool> syncConfig(AutoCaptureSettings settings) async {
    try {
      return await _channel
              .invokeMethod<bool>('setAutoCaptureConfig', <String, Object?>{
                'notificationEnabled': settings.notificationEnabled,
                'smsEnabled': settings.smsEnabled,
                'listenAll': settings.listenAllNotificationSources,
                'packages': settings.sourcePackages,
                'excludedPackages': settings.excludedSourcePackages,
              }) ??
          false;
    } on MissingPluginException {
      // 桌面测试没有原生实现。
      return false;
    } on PlatformException {
      // 配置仍已保存在 Dart KV；下次应用恢复时会再次同步。
      return false;
    }
  }

  /// 读取系统授权、NLS 实际连接、原生开关、待消费队列和最近通知阶段结果。
  static Future<AutoCaptureNativeDiagnostics> diagnostics() async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getAutoCaptureDiagnostics',
      );
      return raw == null
          ? AutoCaptureNativeDiagnostics.unavailable
          : AutoCaptureNativeDiagnostics.fromMap(raw);
    } on MissingPluginException {
      return AutoCaptureNativeDiagnostics.unavailable;
    } on PlatformException {
      return AutoCaptureNativeDiagnostics.unavailable;
    }
  }

  /// 请求 Android 重新绑定已授权的 NotificationListenerService。
  ///
  /// 该操作不会打开设置、不会代替用户授权；Android 7.0 以下或请求失败返回 false。
  static Future<bool> requestNotificationListenerReconnect() async {
    try {
      return await _channel.invokeMethod<bool>(
            'requestNotificationListenerReconnect',
          ) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
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
