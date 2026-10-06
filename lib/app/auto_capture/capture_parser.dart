import 'dart:math' as math;

import '../ai/ai_entry_parser.dart';
import '../category_suggest.dart';
import '../currency_math.dart';
import '../ledger_math.dart';
import '../models.dart';

/// 原生队列传给 Flutter 的一条未经信任的输入。构造 [CaptureEvent] 前统一做长度限制、
/// 指纹与幂等判断，原生与 Dart 两侧都不能把它直接解释成正式账目。
class RawCaptureInput {
  const RawCaptureInput({
    required this.sourceKind,
    required this.sourceId,
    required this.sourceEventId,
    required this.rawText,
    required this.receivedAt,
    this.sourceLabel = '',
    this.nativeQueueId = '',
  });

  final CaptureSourceKind sourceKind;
  final String sourceId;
  final String sourceLabel;
  final String sourceEventId;
  final String rawText;
  final DateTime receivedAt;

  /// 原生持久队列的确认 id。SQLite 已保存或确认是幂等重复后，Flutter 才回执删除。
  final String nativeQueueId;
}

/// 纯解析器所需的当前账本快照。所有集合由调用方传入，使解析逻辑可单测、无数据库副作用。
class CaptureParseContext {
  const CaptureParseContext({
    required this.book,
    required this.accounts,
    required this.creditAccounts,
    required this.categories,
    required this.tags,
    this.tagGroups = defaultTagGroups,
    required this.entries,
    required this.rules,
    this.notificationAccountTypes = const <String, AccountType>{},
  });

  final LedgerBook book;
  final List<Account> accounts;
  final List<CreditAccount> creditAccounts;
  final List<Category> categories;
  final List<Tag> tags;
  final List<TagGroup> tagGroups;
  final List<LedgerEntry> entries;
  final List<AutoCaptureRule> rules;
  final Map<String, AccountType> notificationAccountTypes;

  AccountType? notificationAccountType(CaptureEvent event) =>
      event.sourceKind == CaptureSourceKind.notification
      ? notificationAccountTypes[event.sourceId]
      : null;

  /// 类型映射只缩小当前账本的可见账户范围，不跨账本、不选择列表首项。
  List<Account> accountsFor(CaptureEvent event) {
    final type = notificationAccountType(event);
    return accounts
        .where(
          (account) =>
              account.bookId == event.bookId &&
              !account.hidden &&
              (type == null || account.type == type),
        )
        .toList();
  }
}

/// 跨来源去重的候选结果。只有 [safeToMerge] 为 true 时才可自动追加来源证据；
/// 否则只能在 UI 标成“疑似重复”，交给用户判断。
class CaptureDuplicateMatch {
  const CaptureDuplicateMatch({
    required this.entryId,
    required this.score,
    required this.safeToMerge,
  });

  final String entryId;
  final double score;
  final bool safeToMerge;
}

final RegExp _amountPattern = RegExp(
  r'(?:人民币|RMB|CNY|￥|¥|USD|US\$|美元|EUR|欧元|JPY|日元|HKD|港币)?\s*'
  r'([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]{1,3})?|[0-9]+(?:\.[0-9]{1,3})?)\s*'
  r'(?:元|人民币|RMB|CNY|美元|USD|US\$|欧元|EUR|日元|JPY|港币|HKD)',
  caseSensitive: false,
);
final RegExp _fallbackAmountPattern = RegExp(
  r'(?:金额|消费|支付|付款|扣款|收款|入账|到账|退款|还款|转账)[^0-9]{0,10}'
  r'([0-9]+(?:\.[0-9]{1,3})?)',
  caseSensitive: false,
);
final RegExp _cardLast4Pattern = RegExp(
  r'(?:尾号|尾数|末四位|卡号)[^0-9]{0,5}([0-9]{4})',
  caseSensitive: false,
);
final RegExp _whitespace = RegExp(r'\s+');
final RegExp _merchantAfterPattern = RegExp(
  r'(?:商户|交易对方|收款方|付款给|向)[：:\s]*([^，,。；;\n]{2,32})',
  caseSensitive: false,
);

const Map<String, String> _sourceLabels = <String, String>{
  'com.eg.android.AlipayGphone': '支付宝',
  'com.tencent.mm': '微信',
  'com.unionpay': '云闪付',
  'com.sankuai.meituan': '美团',
  'com.jingdong.app.mall': '京东',
};

/// 对原始文本生成稳定、非加密的本地指纹。
///
/// [sourceId] 区分来源 App/短信号码。有 [sourceEventId] 时以系统事件号为主，
/// 允许同一分钟内两笔同额同文交易分别进入去重层；只在缺少事件号时才将
/// [text] 统一空白/大小写并把 [receivedAt] 折算到分钟，作为稳定回退指纹。
String captureFingerprint({
  required String sourceId,
  required String text,
  required DateTime receivedAt,
  String sourceEventId = '',
}) {
  final minute = receivedAt.millisecondsSinceEpoch ~/ 60000;
  final normalizedEventId = sourceEventId.trim();
  final normalized = normalizedEventId.isNotEmpty
      ? '${sourceId.trim().toLowerCase()}|event|$normalizedEventId'
      : '${sourceId.trim().toLowerCase()}|$minute|'
            '${text.trim().toLowerCase().replaceAll(_whitespace, ' ')}';
  // 64 位 FNV-1a：仅用于本地幂等键，不承担密码学安全用途。
  var hash = 0xcbf29ce484222325;
  for (final byte in normalized.codeUnits) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0x7fffffffffffffff;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

/// 将原生输入安全封装为 [CaptureEvent]。
///
/// [id] 与 [bookId] 由 Controller 生成/选择；原文最多保留 8000 字符，避免恶意或异常
/// 通知无限放大数据库。解析字段保持空白，稍后由 [parseCaptureEvent] 填充。
CaptureEvent captureEventFromInput({
  required String id,
  required String bookId,
  required RawCaptureInput input,
}) {
  final text = input.rawText.trim();
  final bounded = text.length <= 8000 ? text : text.substring(0, 8000);
  return CaptureEvent(
    id: id,
    bookId: bookId,
    sourceKind: input.sourceKind,
    sourceId: input.sourceId.trim(),
    sourceLabel: input.sourceLabel.trim().isNotEmpty
        ? input.sourceLabel.trim()
        : _sourceLabels[input.sourceId] ?? input.sourceId.trim(),
    sourceEventId: input.sourceEventId.trim(),
    rawText: bounded,
    receivedAt: input.receivedAt,
    fingerprint: captureFingerprint(
      sourceId: input.sourceId,
      text: bounded,
      receivedAt: input.receivedAt,
      sourceEventId: input.sourceEventId,
    ),
  );
}

/// 使用本地规则、账户元数据与历史交易解析一条原始事件。
///
/// 规则动作优先，历史学习只补规则未指定的分类/标签。金额、账户、类型等关键字段不完整
/// 时会降低置信度；解析器宁可留待确认，也不会把未知还款当收入或未知支付瞎绑账户。
CaptureEvent parseCaptureEvent(
  CaptureEvent event,
  CaptureParseContext context, {
  DateTime? processedAt,
}) {
  final text = event.rawText.trim();
  final amount = _extractAmount(text);
  var currencyCode = _extractCurrencyCode(text, context.book.baseCurrencyCode);
  var kind = _detectKind(text);
  var cardLast4 = _cardLast4Pattern.firstMatch(text)?.group(1) ?? '';
  var merchant = _extractMerchant(text, event.sourceLabel);
  final mappedType = context.notificationAccountType(event);
  var candidates = context.accountsFor(event);
  if (mappedType != null && cardLast4.isNotEmpty) {
    // 映射存在时，卡尾号是硬条件；未知卡不能仅凭 APP 类型绑定唯一账户。
    final creditIds = context.creditAccounts
        .where(
          (credit) =>
              credit.bookId == event.bookId &&
              credit.cardLast4 == cardLast4 &&
              (credit.institution.isEmpty || text.contains(credit.institution)),
        )
        .map((credit) => credit.id)
        .toSet();
    candidates = candidates
        .where(
          (account) =>
              (account.type.supportsCardLast4 &&
                  account.cardLast4 == cardLast4) ||
              creditIds.contains(account.creditAccountId),
        )
        .toList();
  }
  String? accountId = _matchAccount(
    text: text,
    cardLast4: cardLast4,
    currencyCode: currencyCode,
    sourceId: event.sourceId,
    accounts: candidates,
    creditAccounts: context.creditAccounts,
  );
  if (accountId == null && mappedType != null && cardLast4.isEmpty) {
    final unique = candidates
        .where((account) => account.currencyCode == currencyCode)
        .toList();
    if (unique.length == 1) accountId = unique.single.id;
  }
  String? toAccountId;
  String? categoryId;
  List<String> tagIds = const <String>[];
  final appliedRuleIds = <String>[];

  final sortedRules =
      context.rules
          .where((rule) => rule.bookId == event.bookId && rule.enabled)
          .toList()
        ..sort((a, b) => b.priority.compareTo(a.priority));
  for (final rule in sortedRules) {
    if (!_ruleMatches(
      rule,
      event: event,
      text: text,
      amount: amount,
      kind: kind,
      cardLast4: cardLast4,
    )) {
      continue;
    }
    appliedRuleIds.add(rule.id);
    kind = rule.setKind ?? kind;
    accountId = rule.setAccountId ?? accountId;
    toAccountId = rule.setToAccountId ?? toAccountId;
    categoryId = rule.setCategoryId ?? categoryId;
    if (rule.setTagIds.isNotEmpty) {
      tagIds = <String>[...tagIds, ...rule.setTagIds];
    }
    if (rule.setMerchant.trim().isNotEmpty) merchant = rule.setMerchant.trim();
  }

  // APP 类型是用户指定的候选范围，冲突规则不能绕过它绑定其他类型。
  if (mappedType != null &&
      !context.accountsFor(event).any((account) => account.id == accountId)) {
    accountId = null;
  }

  // 若规则指定的账户币种与文本未明确币种一致，以账户币种为准；文本明确写了币种时
  // _extractCurrencyCode 已返回对应代码，不再偷偷改写。
  final matchedAccount = context.accounts
      .where((account) => account.id == accountId)
      .firstOrNull;
  if (!_textHasExplicitCurrency(text) && matchedAccount != null) {
    currencyCode = matchedAccount.currencyCode;
  }

  final entryType = kind.entryType;
  var refundOriginalMatched = false;
  if (kind == CaptureTransactionKind.refund &&
      amount != null &&
      accountId != null) {
    final originals = context.entries
        .where(
          (entry) =>
              entry.bookId == event.bookId &&
              entry.type == EntryType.expense &&
              entry.currencyCode == currencyCode &&
              entry.accountId == accountId &&
              (entry.amount - amount).abs() <
                  currencyAmountTolerance(currencyCode) &&
              !entry.occurredAt.isAfter(event.receivedAt) &&
              calendarDaysBetween(entry.occurredAt, event.receivedAt) <= 90,
        )
        .toList();
    if (originals.length == 1) {
      categoryId ??= originals.single.categoryId;
      refundOriginalMatched = true;
    }
  }
  if (amount != null &&
      entryType != null &&
      entryType != EntryType.transfer &&
      entryType != EntryType.refund) {
    final suggestion = suggestEntry(
      history: context.entries,
      expenseCategoryIds: context.categories
          .where((category) => category.type == EntryType.expense)
          .map((category) => category.id)
          .toSet(),
      incomeCategoryIds: context.categories
          .where((category) => category.type == EntryType.income)
          .map((category) => category.id)
          .toSet(),
      note: merchant,
      amount: amount,
      currencyCode: currencyCode,
      hour: event.receivedAt.hour,
      forcedType: entryType,
    );
    categoryId ??= suggestion.categoryId;
    if (tagIds.isEmpty && suggestion.tagIds != null) {
      tagIds = suggestion.tagIds!;
    }
  }

  // 防止规则残留引用到已删除实体。失效动作不能增加置信度。
  if (accountId != null &&
      !context.accounts.any((account) => account.id == accountId)) {
    accountId = null;
  }
  if (toAccountId != null &&
      !context.accounts.any((account) => account.id == toAccountId)) {
    toAccountId = null;
  }
  final expectedCategoryType = kind == CaptureTransactionKind.refund
      ? EntryType.expense
      : entryType;
  if (categoryId != null &&
      !context.categories.any(
        (category) =>
            category.id == categoryId && category.type == expectedCategoryType,
      )) {
    categoryId = null;
  }
  final selectedTagIds = <String>[];
  for (final id in tagIds) {
    final tag = canonicalTagOf(id, context.tags);
    if (tag == null || tag.archived) continue;
    if (context.tagGroups
            .where((group) => group.id == tag.groupId)
            .firstOrNull
            ?.selectionMode ==
        TagSelectionMode.single) {
      selectedTagIds.removeWhere(
        (existing) =>
            canonicalTagOf(existing, context.tags)?.groupId == tag.groupId,
      );
    }
    if (!selectedTagIds.contains(tag.id)) selectedTagIds.add(tag.id);
  }
  tagIds = selectedTagIds;

  final score = _confidenceScore(
    amount: amount,
    kind: kind,
    accountId: accountId,
    toAccountId: toAccountId,
    categoryId: categoryId,
    merchant: merchant,
    appliedRuleCount: appliedRuleIds.length,
    refundOriginalMatched: refundOriginalMatched,
  );
  final confidence = score >= 0.85
      ? CaptureConfidence.high
      : score >= 0.55
      ? CaptureConfidence.medium
      : CaptureConfidence.low;
  return event.copyWith(
    parsedAmount: amount,
    clearParsedAmount: amount == null,
    currencyCode: currencyCode,
    merchant: merchant,
    cardLast4: cardLast4,
    kind: kind,
    accountCandidateId: accountId,
    clearAccountCandidateId: accountId == null,
    toAccountCandidateId: toAccountId,
    clearToAccountCandidateId: toAccountId == null,
    categoryCandidateId: categoryId,
    clearCategoryCandidateId: categoryId == null,
    tagCandidateIds: tagIds,
    confidence: confidence,
    confidenceScore: score,
    status: CaptureStatus.pendingReview,
    appliedRuleIds: appliedRuleIds,
    failureReason: '',
    processedAt: processedAt ?? DateTime.now(),
  );
}

/// 用 AI 草稿补充本地解析仍缺失的候选字段。
///
/// [event] 必须先经过 [parseCaptureEvent]。本方法坚持三条安全边界：本地规则已有的
/// 结果不被覆盖；金额或类型冲突时整份 AI 草稿作废；AI 参与后的置信度最高为中等，
/// 因而只能进入待确认队列，绝不能触发高置信度自动入账。
CaptureEvent applyAiCaptureSupplement(
  CaptureEvent event,
  AiEntryDraft draft,
  CaptureParseContext context,
) {
  if (event.confidence == CaptureConfidence.high ||
      event.kind == CaptureTransactionKind.refund ||
      event.kind == CaptureTransactionKind.transfer ||
      event.kind == CaptureTransactionKind.creditRepayment ||
      event.kind == CaptureTransactionKind.creditLineRepayment ||
      draft.type == EntryType.transfer) {
    return event;
  }

  final localAmount = event.parsedAmount;
  if (localAmount != null &&
      (localAmount - draft.amount).abs() >=
          currencyAmountTolerance(event.currencyCode)) {
    return event;
  }
  final draftKind = draft.type == EntryType.income
      ? CaptureTransactionKind.income
      : CaptureTransactionKind.expense;
  if (event.kind != CaptureTransactionKind.unknown &&
      event.kind.entryType != draft.type) {
    return event;
  }

  final amount = localAmount ?? draft.amount;
  final kind = event.kind == CaptureTransactionKind.unknown
      ? draftKind
      : event.kind;
  // 已指定 APP 类型但本地无法唯一匹配时，AI 不能在多个同类账户中猜一个。
  final accountId =
      event.accountCandidateId ??
      (context.notificationAccountType(event) != null
          ? null
          : context
                .accountsFor(event)
                .where(
                  (account) =>
                      account.id == draft.accountId &&
                      account.currencyCode == event.currencyCode,
                )
                .firstOrNull
                ?.id);
  final expectedCategoryType = kind.entryType;
  final aiCategoryReliable = !draft.warnings.contains(
    AiDraftWarning.categoryUnmatched,
  );
  final categoryId =
      event.categoryCandidateId ??
      (aiCategoryReliable
          ? context.categories
                .where(
                  (category) =>
                      category.id == draft.categoryId &&
                      category.type == expectedCategoryType,
                )
                .firstOrNull
                ?.id
          : null);
  final merchant = event.merchant.isNotEmpty
      ? event.merchant
      : draft.note.trim();
  final changed =
      localAmount == null ||
      event.kind == CaptureTransactionKind.unknown ||
      event.accountCandidateId != accountId ||
      event.categoryCandidateId != categoryId ||
      event.merchant != merchant;
  if (!changed) return event;

  final score = _confidenceScore(
    amount: amount,
    kind: kind,
    accountId: accountId,
    toAccountId: null,
    categoryId: categoryId,
    merchant: merchant,
    appliedRuleCount: event.appliedRuleIds.length,
    refundOriginalMatched: false,
  ).clamp(0.0, 0.84).toDouble();
  return event.copyWith(
    parsedAmount: amount,
    kind: kind,
    accountCandidateId: accountId,
    clearAccountCandidateId: accountId == null,
    categoryCandidateId: categoryId,
    clearCategoryCandidateId: categoryId == null,
    merchant: merchant,
    confidence: score >= 0.55
        ? CaptureConfidence.medium
        : CaptureConfidence.low,
    confidenceScore: score,
    status: CaptureStatus.pendingReview,
    aiAssisted: true,
  );
}

/// 在已有正式交易中寻找同一真实交易。
///
/// [event] 必须已经解析。金额是硬条件；账户/卡尾号、时间、商户与不同来源共同加权。
/// 单一弱命中只返回疑似重复，达到高阈值且没有并列候选才允许自动合并。
CaptureDuplicateMatch? findCaptureDuplicate(
  CaptureEvent event,
  List<LedgerEntry> entries, {
  bool requireMatchedAccount = false,
}) {
  // 显式 APP 类型映射下，去重合并也必须遵循已唯一匹配的账户。
  if (requireMatchedAccount && event.accountCandidateId == null) return null;
  final amount = event.parsedAmount;
  if (amount == null || amount <= 0) return null;
  final candidates = <(LedgerEntry, double)>[];
  for (final entry in entries) {
    if (requireMatchedAccount && entry.accountId != event.accountCandidateId) {
      continue;
    }
    final expectedType = event.kind.entryType;
    if (expectedType == null ||
        entry.bookId != event.bookId ||
        entry.type != expectedType) {
      continue;
    }
    if (entry.currencyCode != event.currencyCode ||
        (entry.amount - amount).abs() >=
            currencyAmountTolerance(event.currencyCode)) {
      continue;
    }
    final minutes = entry.occurredAt
        .difference(event.receivedAt)
        .abs()
        .inMinutes;
    if (minutes > 24 * 60) continue;
    var score = 0.45; // 同币种同金额是必要基础。
    if (minutes <= 10) {
      score += 0.25;
    } else if (minutes <= 120) {
      score += 0.12;
    } else {
      score += 0.04;
    }
    if (event.accountCandidateId != null &&
        event.accountCandidateId == entry.accountId) {
      score += 0.2;
    }
    final merchant = _normalizeEvidence(event.merchant);
    final local = _normalizeEvidence(entry.note);
    if (merchant.isNotEmpty && local.isNotEmpty) {
      if (merchant == local) {
        score += 0.18;
      } else if (merchant.contains(local) || local.contains(merchant)) {
        score += 0.1;
      }
    }
    if (entry.sourceRecords.any(
      (record) => record.fingerprint == event.fingerprint,
    )) {
      score = 1;
    }
    candidates.add((entry, score.clamp(0.0, 1.0).toDouble()));
  }
  if (candidates.isEmpty) return null;
  candidates.sort((a, b) => b.$2.compareTo(a.$2));
  final best = candidates.first;
  final ambiguous = candidates.length > 1 && best.$2 - candidates[1].$2 < 0.08;
  return CaptureDuplicateMatch(
    entryId: best.$1.id,
    score: best.$2,
    safeToMerge: best.$2 >= 0.88 && !ambiguous,
  );
}

/// 将解析事件转换为可追溯的交易来源证据。
EntrySourceRecord sourceRecordForCapture(
  CaptureEvent event, {
  DateTime? importedAt,
}) => EntrySourceRecord(
  id: 'capture_source_${event.fingerprint}',
  sourceId: 'capture:${event.sourceKind.name}:${event.sourceId}',
  sourceTransactionId: event.sourceEventId,
  fingerprint: event.fingerprint,
  importedAt: importedAt ?? DateTime.now(),
  transactionDate: event.receivedAt,
  transactionDatePrecision: OccurredAtPrecision.minute,
  amount: event.parsedAmount ?? 0,
  currencyCode: event.currencyCode,
  merchant: event.merchant,
  // 完整原文只保存在设备本地的 CaptureEvent 表，不跟随账本备份扩散；
  // 正式交易仅保存足够对账的商户摘要和稳定指纹。
  rawDescription: event.merchant,
);

/// 判断规则的所有非空条件是否同时命中。
bool _ruleMatches(
  AutoCaptureRule rule, {
  required CaptureEvent event,
  required String text,
  required double? amount,
  required CaptureTransactionKind kind,
  required String cardLast4,
}) {
  if (rule.sourceKind != null && rule.sourceKind != event.sourceKind) {
    return false;
  }
  if (rule.sourceId.isNotEmpty && rule.sourceId != event.sourceId) return false;
  if (rule.textContains.isNotEmpty &&
      !text.toLowerCase().contains(rule.textContains.toLowerCase())) {
    return false;
  }
  if (rule.placeContains.isNotEmpty &&
      !text.toLowerCase().contains(rule.placeContains.toLowerCase())) {
    return false;
  }
  final eventDate = DateTime(
    event.receivedAt.year,
    event.receivedAt.month,
    event.receivedAt.day,
  );
  if (rule.startDate != null &&
      eventDate.isBefore(
        DateTime(
          rule.startDate!.year,
          rule.startDate!.month,
          rule.startDate!.day,
        ),
      )) {
    return false;
  }
  if (rule.endDate != null &&
      eventDate.isAfter(
        DateTime(rule.endDate!.year, rule.endDate!.month, rule.endDate!.day),
      )) {
    return false;
  }
  if (rule.cardLast4.isNotEmpty && rule.cardLast4 != cardLast4) return false;
  if (rule.exactAmount != null &&
      (amount == null ||
          (rule.exactAmount! - amount).abs() >=
              currencyAmountTolerance(event.currencyCode))) {
    return false;
  }
  if (rule.matchKind != null && rule.matchKind != kind) return false;
  return true;
}

/// 提取最可信的金额。带货币单位的数字优先，避免把卡尾号或短信验证码当金额。
double? _extractAmount(String text) {
  final matches = _amountPattern.allMatches(text).toList();
  RegExpMatch? match;
  var bestScore = -100;
  for (final candidate in matches) {
    final start = math.max(0, candidate.start - 18);
    final end = math.min(text.length, candidate.end + 8);
    final context = text.substring(start, end).toLowerCase();
    var score = 0;
    if (<String>[
      '消费',
      '支付',
      '付款',
      '扣款',
      '收款',
      '入账',
      '到账',
      '退款',
      '还款',
      '转账',
      '金额',
    ].any(context.contains)) {
      score += 5;
    }
    if (<String>['余额', '可用额度', '信用额度', '最低还款', '积分'].any(context.contains)) {
      score -= 6;
    }
    if (score > bestScore) {
      bestScore = score;
      match = candidate;
    }
  }
  match ??= _fallbackAmountPattern.firstMatch(text);
  final raw = match?.group(1)?.replaceAll(',', '');
  final amount = raw == null ? null : double.tryParse(raw);
  return amount == null || !amount.isFinite || amount <= 0 ? null : amount;
}

/// 从原文识别 ISO 4217 币种；没有明确线索时使用当前账本本位币。
String _extractCurrencyCode(String text, String fallback) {
  final upper = text.toUpperCase();
  if (upper.contains('USD') || upper.contains('US\$') || text.contains('美元')) {
    return 'USD';
  }
  if (upper.contains('EUR') || text.contains('欧元')) return 'EUR';
  if (upper.contains('JPY') || text.contains('日元')) return 'JPY';
  if (upper.contains('HKD') || text.contains('港币')) return 'HKD';
  return fallback.toUpperCase();
}

/// 判断原文是否明确带出币种；用于决定能否用账户币种补充。
bool _textHasExplicitCurrency(String text) => RegExp(
  r'USD|US\$|美元|EUR|欧元|JPY|日元|HKD|港币|CNY|RMB|人民币',
  caseSensitive: false,
).hasMatch(text);

/// 识别交易业务类型。还款/转账/退款优先于宽泛的“到账/收入”，防止还款污染收入统计。
CaptureTransactionKind _detectKind(String text) {
  final normalized = text.toLowerCase();
  bool hasAny(List<String> words) => words.any(normalized.contains);
  if (hasAny(<String>['退款', '退回', '退货', '冲正'])) {
    return CaptureTransactionKind.refund;
  }
  if (hasAny(<String>['信用卡还款', '信用卡已还', '贷记卡还款'])) {
    return CaptureTransactionKind.creditRepayment;
  }
  if (hasAny(<String>['花呗还款', '白条还款', '信用付还款'])) {
    return CaptureTransactionKind.creditLineRepayment;
  }
  if (hasAny(<String>['转账', '转入', '转出', '跨行汇款'])) {
    return CaptureTransactionKind.transfer;
  }
  if (hasAny(<String>['返现', '返利', '红包到账', '奖励金'])) {
    return CaptureTransactionKind.cashback;
  }
  if (hasAny(<String>['收入', '收款', '入账', '到账', '工资'])) {
    return CaptureTransactionKind.income;
  }
  if (hasAny(<String>['消费', '支付', '付款', '扣款', '支出', '交易成功'])) {
    return CaptureTransactionKind.expense;
  }
  return CaptureTransactionKind.unknown;
}

/// 提取商户/对方。优先取显式字段；否则删除金额、卡号等结构词后保留一段短文本。
String _extractMerchant(String text, String sourceLabel) {
  final explicit = _merchantAfterPattern.firstMatch(text)?.group(1)?.trim();
  if (explicit != null && explicit.isNotEmpty) return explicit;
  final lines = text
      .split(RegExp(r'[\n。；;]'))
      .map((line) => line.trim())
      .where((line) => line.length >= 2)
      .where((line) => !_amountPattern.hasMatch(line))
      .where((line) => !_cardLast4Pattern.hasMatch(line))
      .where((line) => line != sourceLabel)
      .toList();
  if (lines.isEmpty) return '';
  final candidate = lines.first;
  return candidate.length <= 32 ? candidate : candidate.substring(0, 32);
}

/// 用卡尾号、机构名、账户名和支付来源匹配账户。多候选时返回 null，拒绝“列表第一项”回退。
String? _matchAccount({
  required String text,
  required String cardLast4,
  required String currencyCode,
  required String sourceId,
  required List<Account> accounts,
  required List<CreditAccount> creditAccounts,
}) {
  final visible = accounts.where((account) => !account.hidden).toList();
  if (cardLast4.isNotEmpty) {
    final direct = visible
        .where(
          (account) =>
              account.currencyCode == currencyCode &&
              account.type.supportsCardLast4 &&
              account.cardLast4 == cardLast4,
        )
        .toList();
    if (direct.length == 1) return direct.single.id;
    final creditIds = creditAccounts
        .where(
          (credit) =>
              credit.cardLast4 == cardLast4 &&
              (credit.institution.isEmpty || text.contains(credit.institution)),
        )
        .map((credit) => credit.id)
        .toSet();
    final children = visible
        .where(
          (account) =>
              creditIds.contains(account.creditAccountId) &&
              account.currencyCode == currencyCode,
        )
        .toList();
    if (children.length == 1) return children.single.id;
  }
  final named = visible
      .where(
        (account) =>
            account.currencyCode == currencyCode &&
            account.name.trim().length >= 2 &&
            text.toLowerCase().contains(account.name.trim().toLowerCase()),
      )
      .toList();
  if (named.length == 1) return named.single.id;
  final sourceLabel = _sourceLabels[sourceId];
  if (sourceLabel != null) {
    final sourceAccounts = visible
        .where(
          (account) =>
              account.currencyCode == currencyCode &&
              account.name.toLowerCase().contains(sourceLabel.toLowerCase()),
        )
        .toList();
    if (sourceAccounts.length == 1) return sourceAccounts.single.id;
  }
  return null;
}

/// 计算 0–1 置信分。关键字段是硬门槛，规则与商户只提供有限加分。
double _confidenceScore({
  required double? amount,
  required CaptureTransactionKind kind,
  required String? accountId,
  required String? toAccountId,
  required String? categoryId,
  required String merchant,
  required int appliedRuleCount,
  required bool refundOriginalMatched,
}) {
  var score = 0.0;
  if (amount != null) score += 0.3;
  if (kind != CaptureTransactionKind.unknown) score += 0.2;
  if (accountId != null) score += 0.2;
  if (merchant.isNotEmpty) score += 0.08;
  if (categoryId != null) score += 0.12;
  if (appliedRuleCount > 0) score += math.min(0.15, appliedRuleCount * 0.08);
  if ((kind == CaptureTransactionKind.transfer ||
          kind == CaptureTransactionKind.creditRepayment ||
          kind == CaptureTransactionKind.creditLineRepayment) &&
      toAccountId == null) {
    score = math.min(score, 0.74);
  }
  if (kind == CaptureTransactionKind.refund && !refundOriginalMatched) {
    // 退款还需关联原支出；解析阶段只到中置信度，由 Controller 找到唯一原支出后再升级。
    score = math.min(score, 0.74);
  }
  return score.clamp(0.0, 1.0).toDouble();
}

/// 归一化商户证据，供跨来源模糊比较。
String _normalizeEvidence(String value) => value.toLowerCase().replaceAll(
  RegExp(r'[\s\p{P}\p{S}]', unicode: true),
  '',
);
