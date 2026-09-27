/// 自动采集领域模型：原始事件、解析结果、置信度、处理状态、用户规则与设备配置。
///
/// 这里刻意不依赖 Flutter UI。通知、短信、分享文本等入口只负责产生 [CaptureEvent]，
/// 解析器和 Controller 再决定是否生成正式交易，避免外部文本越过审核边界直接写账。
library;

import 'dart:convert';

import 'currency.dart';
import 'ledger_entry.dart';

/// 原始事件的采集通道。通道只描述“从哪里收到”，不代表交易类型。
enum CaptureSourceKind {
  notification,
  sms,
  sharedText,
  manual;

  /// 从 SQLite/JSON 中恢复枚举；未知值安全回落到手动导入，避免误当作系统监听事件。
  static CaptureSourceKind fromStorage(String? value) =>
      CaptureSourceKind.values.firstWhere(
        (item) => item.name == value,
        orElse: () => CaptureSourceKind.manual,
      );
}

/// 自动识别出的业务语义。它比 [EntryType] 更细，便于区分还款、返现等高风险场景。
enum CaptureTransactionKind {
  expense,
  income,
  refund,
  transfer,
  creditRepayment,
  creditLineRepayment,
  cashback,
  unknown;

  /// 从持久化字符串恢复类型；未知值保持 [unknown]，绝不默认成收入或支出。
  static CaptureTransactionKind fromStorage(String? value) =>
      CaptureTransactionKind.values.firstWhere(
        (item) => item.name == value,
        orElse: () => CaptureTransactionKind.unknown,
      );

  /// 转换为正式账目的粗粒度类型。退款需要关联原支出，调用方不能只凭此值直接落账。
  EntryType? get entryType => switch (this) {
    CaptureTransactionKind.expense => EntryType.expense,
    CaptureTransactionKind.income ||
    CaptureTransactionKind.cashback => EntryType.income,
    CaptureTransactionKind.transfer ||
    CaptureTransactionKind.creditRepayment ||
    CaptureTransactionKind.creditLineRepayment => EntryType.transfer,
    CaptureTransactionKind.refund => EntryType.refund,
    CaptureTransactionKind.unknown => null,
  };
}

/// 解析置信度。只有 [high] 且关键字段完整时才允许自动生成正式交易。
enum CaptureConfidence {
  low,
  medium,
  high;

  /// 从数据库恢复置信度；损坏或未来版本值按最低档处理。
  static CaptureConfidence fromStorage(String? value) =>
      CaptureConfidence.values.firstWhere(
        (item) => item.name == value,
        orElse: () => CaptureConfidence.low,
      );
}

/// 原始事件在自动化流水线中的状态。
enum CaptureStatus {
  /// 已保存原文，尚未解析。
  raw,

  /// 关键信息不完整，等待用户确认或补充。
  pendingReview,

  /// 高置信度自动生成了交易。
  autoPosted,

  /// 与已有事件/交易高度相似，但证据不足以自动合并。
  duplicateSuspected,

  /// 已作为新交易由用户确认。
  confirmed,

  /// 已作为来源证据合并到既有交易。
  merged,

  /// 用户明确忽略。
  ignored,

  /// 用户标记为误识别；后续规则学习可把它作为负样本。
  misidentified,

  /// 解析或持久化失败，原文仍保留，可稍后重跑。
  failed;

  /// 从持久化字符串恢复状态；未知值回落为 [raw]，让新版本仍有机会重新处理。
  static CaptureStatus fromStorage(String? value) =>
      CaptureStatus.values.firstWhere(
        (item) => item.name == value,
        orElse: () => CaptureStatus.raw,
      );

  /// 是否仍需要用户在待处理页面关注。
  bool get needsAttention =>
      this == CaptureStatus.pendingReview ||
      this == CaptureStatus.duplicateSuspected ||
      this == CaptureStatus.failed;
}

/// 一条持久化的原始采集事件及其当前解析快照。
///
/// [rawText] 永远保留原文；其余 parsed 字段只是可重跑的缓存，不是账务权威事实。
class CaptureEvent {
  const CaptureEvent({
    required this.id,
    required this.bookId,
    required this.sourceKind,
    required this.sourceId,
    required this.sourceEventId,
    required this.rawText,
    required this.receivedAt,
    required this.fingerprint,
    this.sourceLabel = '',
    this.parsedAmount,
    this.currencyCode = defaultCurrencyCode,
    this.merchant = '',
    this.cardLast4 = '',
    this.kind = CaptureTransactionKind.unknown,
    this.accountCandidateId,
    this.toAccountCandidateId,
    this.categoryCandidateId,
    this.tagCandidateIds = const <String>[],
    this.confidence = CaptureConfidence.low,
    this.confidenceScore = 0,
    this.status = CaptureStatus.raw,
    this.linkedEntryId,
    this.duplicateEntryId,
    this.appliedRuleIds = const <String>[],
    this.failureReason = '',
    this.processedAt,
  });

  final String id;
  final String bookId;
  final CaptureSourceKind sourceKind;
  final String sourceId;
  final String sourceLabel;
  final String sourceEventId;
  final String rawText;
  final DateTime receivedAt;
  final String fingerprint;
  final double? parsedAmount;
  final String currencyCode;
  final String merchant;
  final String cardLast4;
  final CaptureTransactionKind kind;
  final String? accountCandidateId;
  final String? toAccountCandidateId;
  final String? categoryCandidateId;
  final List<String> tagCandidateIds;
  final CaptureConfidence confidence;
  final double confidenceScore;
  final CaptureStatus status;
  final String? linkedEntryId;
  final String? duplicateEntryId;
  final List<String> appliedRuleIds;
  final String failureReason;
  final DateTime? processedAt;

  /// 复制事件并替换指定字段。`clearX` 参数用于显式清空可空关联，避免 null 被解释为“不改”。
  CaptureEvent copyWith({
    String? bookId,
    double? parsedAmount,
    bool clearParsedAmount = false,
    String? currencyCode,
    String? merchant,
    String? cardLast4,
    CaptureTransactionKind? kind,
    String? accountCandidateId,
    bool clearAccountCandidateId = false,
    String? toAccountCandidateId,
    bool clearToAccountCandidateId = false,
    String? categoryCandidateId,
    bool clearCategoryCandidateId = false,
    List<String>? tagCandidateIds,
    CaptureConfidence? confidence,
    double? confidenceScore,
    CaptureStatus? status,
    String? linkedEntryId,
    bool clearLinkedEntryId = false,
    String? duplicateEntryId,
    bool clearDuplicateEntryId = false,
    List<String>? appliedRuleIds,
    String? failureReason,
    DateTime? processedAt,
    bool clearProcessedAt = false,
  }) => CaptureEvent(
    id: id,
    bookId: bookId ?? this.bookId,
    sourceKind: sourceKind,
    sourceId: sourceId,
    sourceLabel: sourceLabel,
    sourceEventId: sourceEventId,
    rawText: rawText,
    receivedAt: receivedAt,
    fingerprint: fingerprint,
    parsedAmount: clearParsedAmount ? null : parsedAmount ?? this.parsedAmount,
    currencyCode: currencyCode ?? this.currencyCode,
    merchant: merchant ?? this.merchant,
    cardLast4: cardLast4 ?? this.cardLast4,
    kind: kind ?? this.kind,
    accountCandidateId: clearAccountCandidateId
        ? null
        : accountCandidateId ?? this.accountCandidateId,
    toAccountCandidateId: clearToAccountCandidateId
        ? null
        : toAccountCandidateId ?? this.toAccountCandidateId,
    categoryCandidateId: clearCategoryCandidateId
        ? null
        : categoryCandidateId ?? this.categoryCandidateId,
    tagCandidateIds: tagCandidateIds ?? this.tagCandidateIds,
    confidence: confidence ?? this.confidence,
    confidenceScore: confidenceScore ?? this.confidenceScore,
    status: status ?? this.status,
    linkedEntryId: clearLinkedEntryId
        ? null
        : linkedEntryId ?? this.linkedEntryId,
    duplicateEntryId: clearDuplicateEntryId
        ? null
        : duplicateEntryId ?? this.duplicateEntryId,
    appliedRuleIds: appliedRuleIds ?? this.appliedRuleIds,
    failureReason: failureReason ?? this.failureReason,
    processedAt: clearProcessedAt ? null : processedAt ?? this.processedAt,
  );

  /// 生成可导出的调试 JSON。正式备份当前不包含原始事件，避免扩大敏感数据范围。
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'bookId': bookId,
    'sourceKind': sourceKind.name,
    'sourceId': sourceId,
    'sourceLabel': sourceLabel,
    'sourceEventId': sourceEventId,
    'rawText': rawText,
    'receivedAt': receivedAt.toIso8601String(),
    'fingerprint': fingerprint,
    if (parsedAmount != null) 'parsedAmount': parsedAmount,
    'currencyCode': currencyCode,
    'merchant': merchant,
    'cardLast4': cardLast4,
    'kind': kind.name,
    if (accountCandidateId != null) 'accountCandidateId': accountCandidateId,
    if (toAccountCandidateId != null)
      'toAccountCandidateId': toAccountCandidateId,
    if (categoryCandidateId != null) 'categoryCandidateId': categoryCandidateId,
    'tagCandidateIds': tagCandidateIds,
    'confidence': confidence.name,
    'confidenceScore': confidenceScore,
    'status': status.name,
    if (linkedEntryId != null) 'linkedEntryId': linkedEntryId,
    if (duplicateEntryId != null) 'duplicateEntryId': duplicateEntryId,
    'appliedRuleIds': appliedRuleIds,
    'failureReason': failureReason,
    if (processedAt != null) 'processedAt': processedAt!.toIso8601String(),
  };

  /// 从调试 JSON 恢复事件。缺失字段按最保守状态回落，不会把未知事件提升为可自动入账。
  static CaptureEvent fromJson(Map<String, Object?> json) => CaptureEvent(
    id: json['id'] as String? ?? '',
    bookId: json['bookId'] as String? ?? '',
    sourceKind: CaptureSourceKind.fromStorage(json['sourceKind'] as String?),
    sourceId: json['sourceId'] as String? ?? '',
    sourceLabel: json['sourceLabel'] as String? ?? '',
    sourceEventId: json['sourceEventId'] as String? ?? '',
    rawText: json['rawText'] as String? ?? '',
    receivedAt:
        DateTime.tryParse(json['receivedAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    fingerprint: json['fingerprint'] as String? ?? '',
    parsedAmount: (json['parsedAmount'] as num?)?.toDouble(),
    currencyCode: (json['currencyCode'] as String? ?? defaultCurrencyCode)
        .toUpperCase(),
    merchant: json['merchant'] as String? ?? '',
    cardLast4: json['cardLast4'] as String? ?? '',
    kind: CaptureTransactionKind.fromStorage(json['kind'] as String?),
    accountCandidateId: json['accountCandidateId'] as String?,
    toAccountCandidateId: json['toAccountCandidateId'] as String?,
    categoryCandidateId: json['categoryCandidateId'] as String?,
    tagCandidateIds: _captureStringList(json['tagCandidateIds']),
    confidence: CaptureConfidence.fromStorage(json['confidence'] as String?),
    confidenceScore: (json['confidenceScore'] as num?)?.toDouble() ?? 0,
    status: CaptureStatus.fromStorage(json['status'] as String?),
    linkedEntryId: json['linkedEntryId'] as String?,
    duplicateEntryId: json['duplicateEntryId'] as String?,
    appliedRuleIds: _captureStringList(json['appliedRuleIds']),
    failureReason: json['failureReason'] as String? ?? '',
    processedAt: DateTime.tryParse(json['processedAt'] as String? ?? ''),
  );
}

/// 用户可配置的本地确定性规则。非空条件之间是 AND；规则按 [priority] 从大到小执行。
class AutoCaptureRule {
  const AutoCaptureRule({
    required this.id,
    required this.bookId,
    required this.name,
    required this.priority,
    this.enabled = true,
    this.sourceKind,
    this.sourceId = '',
    this.textContains = '',
    this.cardLast4 = '',
    this.exactAmount,
    this.matchKind,
    this.setKind,
    this.setAccountId,
    this.setToAccountId,
    this.setCategoryId,
    this.setTagIds = const <String>[],
    this.setMerchant = '',
  });

  final String id;
  final String bookId;
  final String name;
  final int priority;
  final bool enabled;
  final CaptureSourceKind? sourceKind;
  final String sourceId;
  final String textContains;
  final String cardLast4;
  final double? exactAmount;
  final CaptureTransactionKind? matchKind;
  final CaptureTransactionKind? setKind;
  final String? setAccountId;
  final String? setToAccountId;
  final String? setCategoryId;
  final List<String> setTagIds;
  final String setMerchant;

  /// 复制规则并替换字段；可空动作使用 `clearX` 显式清除。
  AutoCaptureRule copyWith({
    String? name,
    int? priority,
    bool? enabled,
    CaptureSourceKind? sourceKind,
    bool clearSourceKind = false,
    String? sourceId,
    String? textContains,
    String? cardLast4,
    double? exactAmount,
    bool clearExactAmount = false,
    CaptureTransactionKind? matchKind,
    bool clearMatchKind = false,
    CaptureTransactionKind? setKind,
    bool clearSetKind = false,
    String? setAccountId,
    bool clearSetAccountId = false,
    String? setToAccountId,
    bool clearSetToAccountId = false,
    String? setCategoryId,
    bool clearSetCategoryId = false,
    List<String>? setTagIds,
    String? setMerchant,
  }) => AutoCaptureRule(
    id: id,
    bookId: bookId,
    name: name ?? this.name,
    priority: priority ?? this.priority,
    enabled: enabled ?? this.enabled,
    sourceKind: clearSourceKind ? null : sourceKind ?? this.sourceKind,
    sourceId: sourceId ?? this.sourceId,
    textContains: textContains ?? this.textContains,
    cardLast4: cardLast4 ?? this.cardLast4,
    exactAmount: clearExactAmount ? null : exactAmount ?? this.exactAmount,
    matchKind: clearMatchKind ? null : matchKind ?? this.matchKind,
    setKind: clearSetKind ? null : setKind ?? this.setKind,
    setAccountId: clearSetAccountId ? null : setAccountId ?? this.setAccountId,
    setToAccountId: clearSetToAccountId
        ? null
        : setToAccountId ?? this.setToAccountId,
    setCategoryId: clearSetCategoryId
        ? null
        : setCategoryId ?? this.setCategoryId,
    setTagIds: setTagIds ?? this.setTagIds,
    setMerchant: setMerchant ?? this.setMerchant,
  );

  /// 编码为结构化 JSON，供模型回环测试与未来规则备份版本使用。
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'bookId': bookId,
    'name': name,
    'priority': priority,
    'enabled': enabled,
    if (sourceKind != null) 'sourceKind': sourceKind!.name,
    'sourceId': sourceId,
    'textContains': textContains,
    'cardLast4': cardLast4,
    if (exactAmount != null) 'exactAmount': exactAmount,
    if (matchKind != null) 'matchKind': matchKind!.name,
    if (setKind != null) 'setKind': setKind!.name,
    if (setAccountId != null) 'setAccountId': setAccountId,
    if (setToAccountId != null) 'setToAccountId': setToAccountId,
    if (setCategoryId != null) 'setCategoryId': setCategoryId,
    'setTagIds': setTagIds,
    'setMerchant': setMerchant,
  };

  /// 从结构化 JSON 恢复规则；未知枚举条件按 null 处理，使规则不因未来值误命中。
  static AutoCaptureRule fromJson(Map<String, Object?> json) => AutoCaptureRule(
    id: json['id'] as String? ?? '',
    bookId: json['bookId'] as String? ?? '',
    name: json['name'] as String? ?? '',
    priority: (json['priority'] as num?)?.toInt() ?? 0,
    enabled: json['enabled'] as bool? ?? true,
    sourceKind: json['sourceKind'] == null
        ? null
        : CaptureSourceKind.fromStorage(json['sourceKind'] as String?),
    sourceId: json['sourceId'] as String? ?? '',
    textContains: json['textContains'] as String? ?? '',
    cardLast4: json['cardLast4'] as String? ?? '',
    exactAmount: (json['exactAmount'] as num?)?.toDouble(),
    matchKind: json['matchKind'] == null
        ? null
        : CaptureTransactionKind.fromStorage(json['matchKind'] as String?),
    setKind: json['setKind'] == null
        ? null
        : CaptureTransactionKind.fromStorage(json['setKind'] as String?),
    setAccountId: json['setAccountId'] as String?,
    setToAccountId: json['setToAccountId'] as String?,
    setCategoryId: json['setCategoryId'] as String?,
    setTagIds: _captureStringList(json['setTagIds']),
    setMerchant: json['setMerchant'] as String? ?? '',
  );
}

/// 自动采集设备配置。权限属于设备能力，因此不进入账本备份。
class AutoCaptureSettings {
  const AutoCaptureSettings({
    this.notificationEnabled = false,
    this.smsEnabled = false,
    this.listenAllNotificationSources = false,
    this.autoPostHighConfidence = true,
    this.sourcePackages = const <String>[],
  });

  final bool notificationEnabled;
  final bool smsEnabled;
  final bool listenAllNotificationSources;
  final bool autoPostHighConfidence;
  final List<String> sourcePackages;

  static const AutoCaptureSettings disabled = AutoCaptureSettings();

  /// 复制配置并替换指定开关或来源列表。
  AutoCaptureSettings copyWith({
    bool? notificationEnabled,
    bool? smsEnabled,
    bool? listenAllNotificationSources,
    bool? autoPostHighConfidence,
    List<String>? sourcePackages,
  }) => AutoCaptureSettings(
    notificationEnabled: notificationEnabled ?? this.notificationEnabled,
    smsEnabled: smsEnabled ?? this.smsEnabled,
    listenAllNotificationSources:
        listenAllNotificationSources ?? this.listenAllNotificationSources,
    autoPostHighConfidence:
        autoPostHighConfidence ?? this.autoPostHighConfidence,
    sourcePackages: sourcePackages ?? this.sourcePackages,
  );

  /// 编码为 KV 字符串；仅保存非敏感开关与包名，不包含通知/短信原文。
  String encode() => jsonEncode(<String, Object?>{
    'notificationEnabled': notificationEnabled,
    'smsEnabled': smsEnabled,
    'listenAllNotificationSources': listenAllNotificationSources,
    'autoPostHighConfidence': autoPostHighConfidence,
    'sourcePackages': sourcePackages,
  });

  /// 从 KV 字符串恢复配置；损坏配置回落为全关，避免后台能力被意外开启。
  static AutoCaptureSettings decode(String? raw) {
    if (raw == null || raw.isEmpty) return disabled;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return disabled;
      final json = Map<String, Object?>.from(decoded);
      return AutoCaptureSettings(
        notificationEnabled: json['notificationEnabled'] as bool? ?? false,
        smsEnabled: json['smsEnabled'] as bool? ?? false,
        listenAllNotificationSources:
            json['listenAllNotificationSources'] as bool? ?? false,
        autoPostHighConfidence: json['autoPostHighConfidence'] as bool? ?? true,
        sourcePackages:
            (json['sourcePackages'] as List?)?.whereType<String>().toList() ??
            const <String>[],
      );
    } on Object {
      return disabled;
    }
  }
}

/// 状态面板使用的聚合统计，只统计当前账本。
class AutoCaptureStats {
  const AutoCaptureStats({
    required this.todayRecognized,
    required this.autoPosted,
    required this.pendingReview,
    required this.duplicateSuspected,
    required this.unrecognized,
  });

  final int todayRecognized;
  final int autoPosted;
  final int pendingReview;
  final int duplicateSuspected;
  final int unrecognized;
}

List<String> _captureStringList(Object? value) => value is List
    ? value.map((item) => item.toString()).toList(growable: false)
    : const <String>[];
