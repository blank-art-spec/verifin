part of 'veri_fin_controller.dart';

/// 控制器的「领域操作」层：交易/账户/分组/账本/分类/标签/预算/偏好/备份/
/// 导入导出等所有对外方法。字段与持久化在 [_ControllerState]。
mixin _ControllerOps on ChangeNotifier, _ControllerState {
  /// 设备级自动采集配置落盘后的原生同步钩子。
  ///
  /// 根组件用它把开关同步给 NotificationListenerService/短信接收器；
  /// 测试与非 Android 宿主可保持 null。
  ValueChanged<AutoCaptureSettings>? onAutoCaptureSettingsChanged;

  /// 当前账本的原始采集事件，按收到时间倒序返回不可变视图。
  List<CaptureEvent> get captureEvents =>
      _captureEventsView ??= List<CaptureEvent>.unmodifiable(
        _captureEvents.where((event) => event.bookId == _activeBookId).toList()
          ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt)),
      );

  /// 当前账本的自动识别规则，优先级高的排在前面。
  List<AutoCaptureRule> get autoCaptureRules =>
      _autoCaptureRulesView ??= List<AutoCaptureRule>.unmodifiable(
        _autoCaptureRules.where((rule) => rule.bookId == _activeBookId).toList()
          ..sort((a, b) => b.priority.compareTo(a.priority)),
      );

  /// 设备级自动采集配置；默认所有监听关闭。
  AutoCaptureSettings get autoCaptureSettings => _autoCaptureSettings;

  /// 当前账本的自动化状态统计。
  ///
  /// [now] 可由测试注入；“今日”按本地日历日比较，不用绝对 24 小时，避免跨时区/DST 错位。
  AutoCaptureStats autoCaptureStats({DateTime? now}) {
    final today = now ?? DateTime.now();
    final events = captureEvents;
    bool isToday(DateTime value) =>
        value.year == today.year &&
        value.month == today.month &&
        value.day == today.day;
    final todayEvents = events.where((event) => isToday(event.receivedAt));
    return AutoCaptureStats(
      todayRecognized: todayEvents
          .where(
            (event) =>
                event.kind != CaptureTransactionKind.unknown &&
                event.parsedAmount != null,
          )
          .length,
      autoPosted: todayEvents
          .where((event) => event.status == CaptureStatus.autoPosted)
          .length,
      pendingReview: events
          .where((event) => event.status.needsAttention)
          .length,
      duplicateSuspected: events
          .where((event) => event.status == CaptureStatus.duplicateSuspected)
          .length,
      unrecognized: todayEvents
          .where(
            (event) =>
                event.kind == CaptureTransactionKind.unknown ||
                event.confidence == CaptureConfidence.low,
          )
          .length,
    );
  }

  /// 构建当前账本的异常处理中心快照。
  ///
  /// [now] 允许测试固定时间；生产环境默认使用当前本地时间。快照只从
  /// 权威账务数据投影，不写库、不修改任何异常状态。
  AttentionCenterSnapshot attentionCenterSnapshot({DateTime? now}) {
    final asOf = now ?? DateTime.now();
    return buildAttentionCenterSnapshot(
      accounts: accounts,
      entries: entries,
      captureEvents: captureEvents,
      billingStatements: billingStatements,
      repaymentAllocations: statementRepaymentAllocations,
      recurringMissingRates: dueRecurringMissingRates(asOf),
      accountValuation: accountBalancesInBase(date: asOf),
      now: asOf,
    );
  }

  /// 显式保存设备级自动采集配置。
  ///
  /// 只有 KV 真正刷盘成功后才替换内存快照；原生权限与服务配置由 UI/平台桥在成功后同步。
  Future<bool> saveAutoCaptureSettingsDraft(
    AutoCaptureSettings settings,
  ) async {
    try {
      await _store.writeAndFlush(_autoCaptureSettingsKey, settings.encode());
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return false;
    }
    _autoCaptureSettings = settings;
    onAutoCaptureSettingsChanged?.call(settings);
    notifyListeners();
    return true;
  }

  /// 新增或更新一条自动识别规则。
  ///
  /// 规则必须属于当前账本，且至少包含一个匹配条件和一个动作；否则返回 false。
  Future<bool> saveAutoCaptureRule(AutoCaptureRule rule) async {
    final hasCondition =
        rule.sourceKind != null ||
        rule.sourceId.trim().isNotEmpty ||
        rule.textContains.trim().isNotEmpty ||
        rule.cardLast4.trim().isNotEmpty ||
        rule.exactAmount != null ||
        rule.matchKind != null;
    final hasAction =
        rule.setKind != null ||
        rule.setAccountId != null ||
        rule.setToAccountId != null ||
        rule.setCategoryId != null ||
        rule.setTagIds.isNotEmpty ||
        rule.setMerchant.trim().isNotEmpty;
    final currentAccountIds = _accounts
        .where((account) => account.bookId == _activeBookId)
        .map((account) => account.id)
        .toSet();
    final currentCategoryIds = _categories
        .map((category) => category.id)
        .toSet();
    final currentTagIds = _tags.map((tag) => tag.id).toSet();
    final ruleCategoryType = rule.setKind == CaptureTransactionKind.refund
        ? EntryType.expense
        : rule.setKind?.entryType;
    final categoryTypeMatches =
        rule.setCategoryId == null ||
        ruleCategoryType == null ||
        _categories.any(
          (category) =>
              category.id == rule.setCategoryId &&
              category.type == ruleCategoryType,
        );
    final referencesExist =
        (rule.setAccountId == null ||
            currentAccountIds.contains(rule.setAccountId)) &&
        (rule.setToAccountId == null ||
            currentAccountIds.contains(rule.setToAccountId)) &&
        (rule.setCategoryId == null ||
            currentCategoryIds.contains(rule.setCategoryId)) &&
        currentTagIds.containsAll(rule.setTagIds);
    if (rule.bookId != _activeBookId ||
        rule.name.trim().isEmpty ||
        !hasCondition ||
        !hasAction ||
        !referencesExist ||
        !categoryTypeMatches ||
        (rule.setAccountId != null &&
            rule.setAccountId == rule.setToAccountId) ||
        rule.exactAmount != null &&
            (!rule.exactAmount!.isFinite || rule.exactAmount! <= 0)) {
      return false;
    }
    final next = List<AutoCaptureRule>.of(_autoCaptureRules);
    final index = next.indexWhere((item) => item.id == rule.id);
    final normalized = rule.copyWith(
      name: rule.name.trim(),
      sourceId: rule.sourceId.trim(),
      textContains: rule.textContains.trim(),
      cardLast4: rule.cardLast4.replaceAll(RegExp(r'\D'), ''),
      setMerchant: rule.setMerchant.trim(),
    );
    if (index == -1) {
      next.add(normalized);
    } else {
      next[index] = normalized;
    }
    try {
      await _repository.saveAutoCaptureRules(next);
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return false;
    }
    _autoCaptureRules
      ..clear()
      ..addAll(next);
    notifyListeners();
    return true;
  }

  /// 删除一条当前账本规则。规则删除不改写已处理事件，历史仍保留 appliedRuleIds 便于追溯。
  Future<bool> deleteAutoCaptureRule(String ruleId) async {
    final next = List<AutoCaptureRule>.of(_autoCaptureRules);
    final removed = next.where(
      (rule) => rule.id == ruleId && rule.bookId == _activeBookId,
    );
    if (removed.isEmpty) return false;
    next.removeWhere((rule) => rule.id == ruleId);
    try {
      await _repository.saveAutoCaptureRules(next);
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return false;
    }
    _autoCaptureRules
      ..clear()
      ..addAll(next);
    notifyListeners();
    return true;
  }

  /// 清理自动采集数据中已失效的实体引用。
  ///
  /// [removedEntryIds] 用于正式交易删除；[removedAccountIds]、
  /// [removedCategoryIds]、[removedTagIds] 用于对应实体删除；分类合并则通过
  /// [categoryRemap] 把候选和规则动作迁移到目标分类；[removedBookIds]
  /// 则整体移除已不存在账本的设备本地事件与规则。事件与规则在同一事务落库，
  /// 保存失败时不替换内存快照，由持久化错误入口提示用户。
  Future<bool> _sanitizeAutoCaptureReferences({
    Set<String> removedBookIds = const <String>{},
    Set<String> removedEntryIds = const <String>{},
    Set<String> removedAccountIds = const <String>{},
    Set<String> removedCategoryIds = const <String>{},
    Set<String> removedTagIds = const <String>{},
    Map<String, String> categoryRemap = const <String, String>{},
  }) async {
    var eventChanged = false;
    final nextEvents = <CaptureEvent>[];
    for (final event in _captureEvents) {
      if (removedBookIds.contains(event.bookId)) {
        eventChanged = true;
        continue;
      }
      var next = event;
      var candidateInvalidated = false;
      if (event.accountCandidateId != null &&
          removedAccountIds.contains(event.accountCandidateId)) {
        next = next.copyWith(clearAccountCandidateId: true);
        candidateInvalidated = true;
      }
      if (event.toAccountCandidateId != null &&
          removedAccountIds.contains(event.toAccountCandidateId)) {
        next = next.copyWith(clearToAccountCandidateId: true);
        candidateInvalidated = true;
      }
      final categoryId = event.categoryCandidateId;
      if (categoryId != null && categoryRemap.containsKey(categoryId)) {
        next = next.copyWith(categoryCandidateId: categoryRemap[categoryId]);
      } else if (categoryId != null &&
          removedCategoryIds.contains(categoryId)) {
        next = next.copyWith(clearCategoryCandidateId: true);
        candidateInvalidated = true;
      }
      final nextTagIds = event.tagCandidateIds
          .where((id) => !removedTagIds.contains(id))
          .toList(growable: false);
      if (nextTagIds.length != event.tagCandidateIds.length) {
        next = next.copyWith(tagCandidateIds: nextTagIds);
        candidateInvalidated = true;
      }
      final linkedRemoved =
          event.linkedEntryId != null &&
          removedEntryIds.contains(event.linkedEntryId);
      final duplicateRemoved =
          event.duplicateEntryId != null &&
          removedEntryIds.contains(event.duplicateEntryId);
      if (linkedRemoved || duplicateRemoved) {
        next = next.copyWith(
          status: CaptureStatus.pendingReview,
          clearLinkedEntryId: linkedRemoved,
          clearDuplicateEntryId: duplicateRemoved,
        );
      } else if (candidateInvalidated && event.status.needsAttention) {
        next = next.copyWith(status: CaptureStatus.pendingReview);
      }
      if (!identical(next, event)) eventChanged = true;
      nextEvents.add(next);
    }

    var ruleChanged = false;
    final nextRules = <AutoCaptureRule>[];
    for (final rule in _autoCaptureRules) {
      if (removedBookIds.contains(rule.bookId)) {
        ruleChanged = true;
        continue;
      }
      var next = rule;
      if (rule.setAccountId != null &&
          removedAccountIds.contains(rule.setAccountId)) {
        next = next.copyWith(clearSetAccountId: true);
      }
      if (rule.setToAccountId != null &&
          removedAccountIds.contains(rule.setToAccountId)) {
        next = next.copyWith(clearSetToAccountId: true);
      }
      final categoryId = rule.setCategoryId;
      if (categoryId != null && categoryRemap.containsKey(categoryId)) {
        next = next.copyWith(setCategoryId: categoryRemap[categoryId]);
      } else if (categoryId != null &&
          removedCategoryIds.contains(categoryId)) {
        next = next.copyWith(clearSetCategoryId: true);
      }
      final nextTagIds = rule.setTagIds
          .where((id) => !removedTagIds.contains(id))
          .toList(growable: false);
      if (nextTagIds.length != rule.setTagIds.length) {
        next = next.copyWith(setTagIds: nextTagIds);
      }
      final hasAction =
          next.setKind != null ||
          next.setAccountId != null ||
          next.setToAccountId != null ||
          next.setCategoryId != null ||
          next.setTagIds.isNotEmpty ||
          next.setMerchant.trim().isNotEmpty;
      if (!hasAction && next.enabled) next = next.copyWith(enabled: false);
      if (!identical(next, rule)) ruleChanged = true;
      nextRules.add(next);
    }
    if (!eventChanged && !ruleChanged) return true;
    try {
      await _repository.saveAutoCaptureMetadata(
        captureEvents: nextEvents,
        rules: nextRules,
      );
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return false;
    }
    _captureEvents
      ..clear()
      ..addAll(nextEvents);
    _autoCaptureRules
      ..clear()
      ..addAll(nextRules);
    return true;
  }

  /// 按当前账目快照清理所有悬空自动采集引用。
  ///
  /// 备份恢复会整体替换账目表，但原始事件与规则按隐私约定保持设备本地；因此恢复后
  /// 必须重新核对它们的账户、分类、标签与交易关联。
  Future<bool> _healAutoCaptureReferences() {
    final bookIds = _ledgerBooks.map((book) => book.id).toSet();
    final entryIds = _entries.map((entry) => entry.id).toSet();
    final accountIds = _accounts.map((account) => account.id).toSet();
    final categoryIds = _categories.map((category) => category.id).toSet();
    final tagIds = _tags.map((tag) => tag.id).toSet();
    final referencedEntryIds = <String>{
      for (final event in _captureEvents)
        if (event.linkedEntryId != null) event.linkedEntryId!,
      for (final event in _captureEvents)
        if (event.duplicateEntryId != null) event.duplicateEntryId!,
    };
    final referencedAccountIds = <String>{
      for (final event in _captureEvents)
        if (event.accountCandidateId != null) event.accountCandidateId!,
      for (final event in _captureEvents)
        if (event.toAccountCandidateId != null) event.toAccountCandidateId!,
      for (final rule in _autoCaptureRules)
        if (rule.setAccountId != null) rule.setAccountId!,
      for (final rule in _autoCaptureRules)
        if (rule.setToAccountId != null) rule.setToAccountId!,
    };
    final referencedCategoryIds = <String>{
      for (final event in _captureEvents)
        if (event.categoryCandidateId != null) event.categoryCandidateId!,
      for (final rule in _autoCaptureRules)
        if (rule.setCategoryId != null) rule.setCategoryId!,
    };
    final referencedTagIds = <String>{
      for (final event in _captureEvents) ...event.tagCandidateIds,
      for (final rule in _autoCaptureRules) ...rule.setTagIds,
    };
    final referencedBookIds = <String>{
      for (final event in _captureEvents) event.bookId,
      for (final rule in _autoCaptureRules) rule.bookId,
    };
    return _sanitizeAutoCaptureReferences(
      removedBookIds: referencedBookIds.difference(bookIds),
      removedEntryIds: referencedEntryIds.difference(entryIds),
      removedAccountIds: referencedAccountIds.difference(accountIds),
      removedCategoryIds: referencedCategoryIds.difference(categoryIds),
      removedTagIds: referencedTagIds.difference(tagIds),
    );
  }

  /// 将原生通知/短信队列写入 SQLite 原始事件表。
  ///
  /// [inputs] 中空文本会跳过；相同 sourceEventId 或稳定 fingerprint 只保留一条。
  /// 方法先完成原文落库，再调用解析流程，保证解析崩溃/网络失败也不会丢原始证据。
  Future<int> ingestCaptureInputs(List<RawCaptureInput> inputs) async {
    final next = List<CaptureEvent>.of(_captureEvents);
    var added = 0;
    for (final input in inputs) {
      if (input.rawText.trim().isEmpty) continue;
      final candidate = captureEventFromInput(
        id: _generateId('capture'),
        bookId: _activeBookId,
        input: input,
      );
      final duplicate = next.any(
        (event) =>
            event.fingerprint == candidate.fingerprint ||
            candidate.sourceEventId.isNotEmpty &&
                event.sourceId == candidate.sourceId &&
                event.sourceEventId == candidate.sourceEventId,
      );
      if (duplicate) continue;
      next.add(candidate);
      added++;
    }
    if (added == 0) return 0;
    next.sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
    try {
      await _repository.saveCaptureEvents(next);
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return 0;
    }
    _captureEvents
      ..clear()
      ..addAll(next);
    notifyListeners();
    await processPendingCaptureEvents();
    return added;
  }

  /// 判断原生输入是否已经可靠存在于 SQLite 对应的内存快照。
  ///
  /// 原生队列只有在本方法返回 true 后才可确认删除；稳定指纹与来源事件号两种幂等键
  /// 任一命中即可，避免 Flutter 在落库前崩溃导致原文丢失。
  bool captureInputIsStored(RawCaptureInput input) {
    final trimmed = input.rawText.trim();
    final bounded = trimmed.length <= 8000
        ? trimmed
        : trimmed.substring(0, 8000);
    final fingerprint = captureFingerprint(
      sourceId: input.sourceId,
      text: bounded,
      receivedAt: input.receivedAt,
      sourceEventId: input.sourceEventId,
    );
    return _captureEvents.any(
      (event) =>
          event.fingerprint == fingerprint ||
          input.sourceEventId.isNotEmpty &&
              event.sourceId == input.sourceId.trim() &&
              event.sourceEventId == input.sourceEventId.trim(),
    );
  }

  /// 解析所有尚未处理的原始事件，并执行去重、合并与高置信度自动入账。
  ///
  /// [allowAutomaticActions] 为 false 时只用本地规则更新候选与疑似重复状态，
  /// 不请求 AI、不自动合并来源或新建交易，供规则变更后的批量回放使用。
  ///
  /// 正式交易与事件状态在一个 SQLite 事务提交；任何一步失败都保持旧内存快照并返回 0。
  Future<int> processPendingCaptureEvents({
    bool allowAutomaticActions = true,
  }) async {
    var nextEntries = List<LedgerEntry>.of(_entries);
    final nextEvents = List<CaptureEvent>.of(_captureEvents);
    var processed = 0;
    var createdEntries = 0;
    for (var i = 0; i < nextEvents.length; i++) {
      final original = nextEvents[i];
      if (original.status != CaptureStatus.raw ||
          original.processedAt != null) {
        continue;
      }
      final book = _ledgerBooks
          .where((item) => item.id == original.bookId)
          .firstOrNull;
      if (book == null) {
        nextEvents[i] = original.copyWith(
          status: CaptureStatus.failed,
          failureReason: '账本不存在',
          processedAt: DateTime.now(),
        );
        processed++;
        continue;
      }
      try {
        final parseContext = CaptureParseContext(
          book: book,
          accounts: _accounts
              .where((account) => account.bookId == book.id)
              .toList(),
          creditAccounts: _creditAccounts
              .where((credit) => credit.bookId == book.id)
              .toList(),
          categories: _categories,
          tags: _tags,
          entries: nextEntries
              .where((entry) => entry.bookId == book.id)
              .toList(),
          rules: _autoCaptureRules,
        );
        var parsed = parseCaptureEvent(original, parseContext);

        // AI 只补充本地规则仍不完整的普通收支候选。开关默认关闭；请求失败时保留
        // 本地解析结果继续走待确认/原文保留，不让外部服务可用性阻断采集队列。
        final aiEligibleKind =
            parsed.kind == CaptureTransactionKind.unknown ||
            parsed.kind == CaptureTransactionKind.expense ||
            parsed.kind == CaptureTransactionKind.income ||
            parsed.kind == CaptureTransactionKind.cashback;
        if (allowAutomaticActions &&
            _autoCaptureSettings.aiAssistEnabled &&
            _aiSettings.isConfigured &&
            parsed.confidence != CaptureConfidence.high &&
            aiEligibleKind) {
          try {
            final draft = await requestCapturedEntryDraft(
              settings: _aiSettings,
              capturedText: original.rawText,
              context: AiEntryContext(
                expenseCategories: _categories
                    .where((category) => category.type == EntryType.expense)
                    .map(
                      (category) =>
                          AiOption(id: category.id, label: category.label),
                    )
                    .toList(),
                incomeCategories: _categories
                    .where((category) => category.type == EntryType.income)
                    .map(
                      (category) =>
                          AiOption(id: category.id, label: category.label),
                    )
                    .toList(),
                accounts: parseContext.accounts
                    .where((account) => !account.hidden)
                    .map(
                      (account) => AiOption(
                        id: account.id,
                        label: account.name,
                        currencyCode: account.currencyCode,
                      ),
                    )
                    .toList(),
                today: original.receivedAt,
                bookId: book.id,
                baseCurrencyCode: book.baseCurrencyCode,
              ),
            );
            parsed = applyAiCaptureSupplement(parsed, draft, parseContext);
          } on Object catch (error) {
            // 原文不得进入日志；只记录异常类型，供用户判断端点或网络是否异常。
            _logger?.warning(
              '自动采集的 AI 补充识别失败，已保留本地解析结果（${error.runtimeType}）',
              source: 'auto_capture',
            );
          }
        }

        final duplicate = findCaptureDuplicate(parsed, nextEntries);
        if (allowAutomaticActions && duplicate?.safeToMerge == true) {
          final entryIndex = nextEntries.indexWhere(
            (entry) => entry.id == duplicate!.entryId,
          );
          if (entryIndex != -1) {
            final record = sourceRecordForCapture(parsed);
            final current = nextEntries[entryIndex];
            if (!current.sourceRecords.any(
              (source) => source.fingerprint == record.fingerprint,
            )) {
              nextEntries[entryIndex] = current.copyWith(
                sourceRecords: <EntrySourceRecord>[
                  ...current.sourceRecords,
                  record,
                ],
              );
            }
            parsed = parsed.copyWith(
              status: CaptureStatus.merged,
              linkedEntryId: current.id,
              duplicateEntryId: current.id,
            );
          }
        } else if (duplicate != null && duplicate.score >= 0.65) {
          parsed = parsed.copyWith(
            status: CaptureStatus.duplicateSuspected,
            duplicateEntryId: duplicate.entryId,
          );
        } else if (allowAutomaticActions &&
            _autoCaptureSettings.autoPostHighConfidence &&
            parsed.confidence == CaptureConfidence.high) {
          final entry = _buildAutomaticCaptureEntry(parsed, nextEntries, book);
          if (entry != null) {
            nextEntries.add(entry);
            nextEntries = _entriesWithSyncedRefundCache(nextEntries)
              ..sort(_compareEntriesLatestFirst);
            parsed = parsed.copyWith(
              status: CaptureStatus.autoPosted,
              linkedEntryId: entry.id,
            );
            createdEntries++;
          }
        }
        if (parsed.status == CaptureStatus.pendingReview &&
            parsed.confidence == CaptureConfidence.low) {
          // 低置信度只保留原始事件，不混入待确认数字；processedAt 防止每次回前台重跑。
          parsed = parsed.copyWith(status: CaptureStatus.raw);
        }
        nextEvents[i] = parsed;
        processed++;
      } on Object catch (error, stackTrace) {
        _logger?.error(
          '自动采集事件解析失败',
          source: 'auto_capture',
          error: '$error\n$stackTrace',
        );
        nextEvents[i] = original.copyWith(
          status: CaptureStatus.failed,
          failureReason: '解析失败，可稍后重试',
          processedAt: DateTime.now(),
        );
        processed++;
      }
    }
    if (processed == 0) return 0;
    try {
      await _repository.saveCaptureProcessing(
        entries: nextEntries,
        captureEvents: nextEvents,
      );
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return 0;
    }
    _entries
      ..clear()
      ..addAll(nextEntries);
    _captureEvents
      ..clear()
      ..addAll(nextEvents);
    notifyListeners();
    if (createdEntries > 0) onEntryAdded?.call();
    return processed;
  }

  /// 把待确认事件转换为标准记账页草稿。退款仍需关联原支出，因此返回 null，改走合并入口。
  AiEntryDraft? captureEntryDraft(String eventId) {
    final event = _captureEvents
        .where((item) => item.id == eventId && item.bookId == _activeBookId)
        .firstOrNull;
    final amount = event?.parsedAmount;
    final type = event?.kind.entryType;
    if (event == null ||
        amount == null ||
        type == null ||
        type == EntryType.refund ||
        type == EntryType.transfer &&
            (event.accountCandidateId == null ||
                event.toAccountCandidateId == null)) {
      return null;
    }
    return AiEntryDraft(
      type: type,
      amount: amount,
      currencyCode: event.currencyCode,
      categoryId: event.categoryCandidateId ?? '',
      accountId: event.accountCandidateId ?? '',
      toAccountId: event.toAccountCandidateId,
      note: event.merchant,
      occurredAt: event.receivedAt,
      warnings: <AiDraftWarning>[
        if (event.categoryCandidateId == null) AiDraftWarning.categoryUnmatched,
        if (event.accountCandidateId == null) AiDraftWarning.accountUnmatched,
      ],
    );
  }

  /// 返回待确认事件应附带到新交易的来源证据。
  EntrySourceRecord? captureSourceRecord(String eventId) {
    final event = _captureEvents
        .where((item) => item.id == eventId && item.bookId == _activeBookId)
        .firstOrNull;
    return event == null ? null : sourceRecordForCapture(event);
  }

  /// 用户明确确认一条已解析事件，并按当前候选直接生成正式交易。
  ///
  /// 主要用于标准记账页不能表达的关联退款；仍复用 [_buildAutomaticCaptureEntry] 的
  /// 唯一原支出、账户、汇率与类型校验。交易与事件状态在同一事务提交，失败返回 null。
  Future<LedgerEntry?> confirmParsedCaptureEvent(String eventId) async {
    final eventIndex = _captureEvents.indexWhere(
      (event) =>
          event.id == eventId &&
          event.bookId == _activeBookId &&
          event.status != CaptureStatus.autoPosted &&
          event.status != CaptureStatus.confirmed &&
          event.status != CaptureStatus.merged,
    );
    if (eventIndex == -1) return null;
    final event = _captureEvents[eventIndex];
    final book = _ledgerBooks
        .where((item) => item.id == event.bookId)
        .firstOrNull;
    if (book == null) return null;
    final entry = _buildAutomaticCaptureEntry(event, _entries, book);
    if (entry == null) return null;
    final nextEntries = _entriesWithSyncedRefundCache(<LedgerEntry>[
      ..._entries,
      entry,
    ])..sort(_compareEntriesLatestFirst);
    final nextEvents = List<CaptureEvent>.of(_captureEvents);
    nextEvents[eventIndex] = event.copyWith(
      status: CaptureStatus.confirmed,
      linkedEntryId: entry.id,
    );
    try {
      await _repository.saveCaptureProcessing(
        entries: nextEntries,
        captureEvents: nextEvents,
      );
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return null;
    }
    _entries
      ..clear()
      ..addAll(nextEntries);
    _captureEvents
      ..clear()
      ..addAll(nextEvents);
    notifyListeners();
    onEntryAdded?.call();
    return entry;
  }

  /// 用户完成标准记账页后，把事件标为已确认并记录新交易关联。
  Future<bool> markCaptureEventConfirmed({
    required String eventId,
    required String entryId,
  }) => _updateCaptureStatus(
    eventId: eventId,
    status: CaptureStatus.confirmed,
    linkedEntryId: entryId,
  );

  /// 用户忽略事件；原文保留用于审计与避免同一条再次进入队列。
  Future<bool> ignoreCaptureEvent(String eventId) =>
      _updateCaptureStatus(eventId: eventId, status: CaptureStatus.ignored);

  /// 用户标记误识别；状态与原文保留，后续可据此改规则。
  Future<bool> markCaptureEventMisidentified(String eventId) =>
      _updateCaptureStatus(
        eventId: eventId,
        status: CaptureStatus.misidentified,
      );

  /// 重新解析事件。规则调整后可调用；会清除旧候选和失败信息，但保留原文与幂等指纹。
  Future<bool> retryCaptureEvent(String eventId) async {
    final index = _captureEvents.indexWhere(
      (event) => event.id == eventId && event.bookId == _activeBookId,
    );
    if (index == -1) return false;
    final next = List<CaptureEvent>.of(_captureEvents);
    next[index] = next[index].copyWith(
      status: CaptureStatus.raw,
      clearParsedAmount: true,
      kind: CaptureTransactionKind.unknown,
      clearAccountCandidateId: true,
      clearToAccountCandidateId: true,
      clearCategoryCandidateId: true,
      tagCandidateIds: const <String>[],
      confidence: CaptureConfidence.low,
      confidenceScore: 0,
      clearLinkedEntryId: true,
      clearDuplicateEntryId: true,
      appliedRuleIds: const <String>[],
      failureReason: '',
      clearProcessedAt: true,
    );
    try {
      await _repository.saveCaptureEvents(next);
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return false;
    }
    _captureEvents
      ..clear()
      ..addAll(next);
    notifyListeners();
    return (await processPendingCaptureEvents()) > 0;
  }

  /// 批量重跑当前账本最近的未落账原始事件。
  ///
  /// [limit] 限制一次读取的事件数，避免规则调整后一次处理过多原文。已确认、已自动
  /// 入账、已合并、已忽略及误识别事件均跳过，避免撤销用户决定或制造重复交易。
  /// 本次回放只更新解析候选，不执行高置信度自动入账；用户可在待确认列表复核结果。
  Future<int> replayRecentCaptureEvents({int limit = 100}) async {
    if (limit <= 0) return 0;
    final candidates = captureEvents
        .where(
          (event) =>
              event.linkedEntryId == null &&
              (event.status == CaptureStatus.raw ||
                  event.status == CaptureStatus.failed ||
                  event.status == CaptureStatus.pendingReview ||
                  event.status == CaptureStatus.duplicateSuspected),
        )
        .take(limit)
        .map((event) => event.id)
        .toSet();
    if (candidates.isEmpty) return 0;
    final next = <CaptureEvent>[
      for (final event in _captureEvents)
        if (candidates.contains(event.id))
          event.copyWith(
            status: CaptureStatus.raw,
            clearParsedAmount: true,
            kind: CaptureTransactionKind.unknown,
            clearAccountCandidateId: true,
            clearToAccountCandidateId: true,
            clearCategoryCandidateId: true,
            tagCandidateIds: const <String>[],
            confidence: CaptureConfidence.low,
            confidenceScore: 0,
            clearDuplicateEntryId: true,
            appliedRuleIds: const <String>[],
            aiAssisted: false,
            failureReason: '',
            clearProcessedAt: true,
          )
        else
          event,
    ];
    try {
      await _repository.saveCaptureEvents(next);
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return 0;
    }
    _captureEvents
      ..clear()
      ..addAll(next);
    notifyListeners();
    return processPendingCaptureEvents(allowAutomaticActions: false);
  }

  /// 用户明确把事件合并到已有交易：追加来源证据并原子更新事件状态。
  Future<bool> mergeCaptureEventIntoEntry({
    required String eventId,
    required String entryId,
  }) async {
    final eventIndex = _captureEvents.indexWhere(
      (event) => event.id == eventId && event.bookId == _activeBookId,
    );
    final entryIndex = _entries.indexWhere(
      (entry) => entry.id == entryId && entry.bookId == _activeBookId,
    );
    if (eventIndex == -1 || entryIndex == -1) return false;
    final nextEntries = List<LedgerEntry>.of(_entries);
    final nextEvents = List<CaptureEvent>.of(_captureEvents);
    final record = sourceRecordForCapture(nextEvents[eventIndex]);
    final current = nextEntries[entryIndex];
    if (!current.sourceRecords.any(
      (source) => source.fingerprint == record.fingerprint,
    )) {
      nextEntries[entryIndex] = current.copyWith(
        sourceRecords: <EntrySourceRecord>[...current.sourceRecords, record],
      );
    }
    nextEvents[eventIndex] = nextEvents[eventIndex].copyWith(
      status: CaptureStatus.merged,
      linkedEntryId: entryId,
      duplicateEntryId: entryId,
    );
    try {
      await _repository.saveCaptureProcessing(
        entries: nextEntries,
        captureEvents: nextEvents,
      );
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return false;
    }
    _entries
      ..clear()
      ..addAll(nextEntries);
    _captureEvents
      ..clear()
      ..addAll(nextEvents);
    notifyListeners();
    return true;
  }

  /// 撤销一笔由自动采集直接生成的交易，并把事件退回待确认。
  Future<bool> undoAutoCapturedEntry(String eventId) async {
    final eventIndex = _captureEvents.indexWhere(
      (event) =>
          event.id == eventId &&
          event.bookId == _activeBookId &&
          event.status == CaptureStatus.autoPosted,
    );
    if (eventIndex == -1) return false;
    final entryId = _captureEvents[eventIndex].linkedEntryId;
    if (entryId == null) return false;
    var nextEntries = _entries
        .where((entry) => entry.id != entryId && entry.refundOf != entryId)
        .toList();
    nextEntries = _entriesWithSyncedRefundCache(nextEntries)
      ..sort(_compareEntriesLatestFirst);
    final nextEvents = List<CaptureEvent>.of(_captureEvents);
    nextEvents[eventIndex] = nextEvents[eventIndex].copyWith(
      status: CaptureStatus.pendingReview,
      clearLinkedEntryId: true,
    );
    try {
      await _repository.saveCaptureProcessing(
        entries: nextEntries,
        captureEvents: nextEvents,
      );
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return false;
    }
    _entries
      ..clear()
      ..addAll(nextEntries);
    _captureEvents
      ..clear()
      ..addAll(nextEvents);
    notifyListeners();
    return true;
  }

  /// 仅更新事件状态/关联，不改正式交易。
  Future<bool> _updateCaptureStatus({
    required String eventId,
    required CaptureStatus status,
    String? linkedEntryId,
  }) async {
    final index = _captureEvents.indexWhere(
      (event) => event.id == eventId && event.bookId == _activeBookId,
    );
    if (index == -1) return false;
    final next = List<CaptureEvent>.of(_captureEvents);
    next[index] = next[index].copyWith(
      status: status,
      linkedEntryId: linkedEntryId,
      clearLinkedEntryId:
          linkedEntryId == null &&
          (status == CaptureStatus.ignored ||
              status == CaptureStatus.misidentified),
    );
    try {
      await _repository.saveCaptureEvents(next);
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return false;
    }
    _captureEvents
      ..clear()
      ..addAll(next);
    notifyListeners();
    return true;
  }

  /// 构造允许自动落库的交易；任一关键金额/账户/汇率缺失即返回 null。
  LedgerEntry? _buildAutomaticCaptureEntry(
    CaptureEvent event,
    List<LedgerEntry> entries,
    LedgerBook book,
  ) {
    final amount = event.parsedAmount;
    final type = event.kind.entryType;
    final account = _accounts
        .where(
          (item) =>
              item.id == event.accountCandidateId && item.bookId == book.id,
        )
        .firstOrNull;
    if (amount == null || amount <= 0 || type == null || account == null) {
      return null;
    }
    double? convert(String targetCode) {
      final result = convertCurrencyAmount(
        amount: amount,
        sourceCurrencyCode: event.currencyCode,
        targetCurrencyCode: targetCode,
        baseCurrencyCode: book.baseCurrencyCode,
        bookId: book.id,
        date: event.receivedAt,
        rates: _exchangeRates,
      );
      return result is ConvertedCurrencyAmount ? result.amount : null;
    }

    final accountAmount = convert(account.currencyCode);
    if (accountAmount == null) return null;
    final source = sourceRecordForCapture(event);

    if (type == EntryType.refund) {
      final candidates = entries
          .where(
            (entry) =>
                entry.bookId == book.id &&
                entry.type == EntryType.expense &&
                entry.currencyCode == event.currencyCode &&
                entry.accountId == account.id &&
                (entry.amount - amount).abs() <
                    currencyAmountTolerance(event.currencyCode) &&
                !entry.occurredAt.isAfter(event.receivedAt) &&
                calendarDaysBetween(entry.occurredAt, event.receivedAt) <= 90,
          )
          .toList();
      if (candidates.length != 1) return null;
      final original = candidates.single;
      final baseAmount = original.amount == 0
          ? null
          : normalizeCurrencyAmount(
              original.baseAmount * amount / original.amount,
              book.baseCurrencyCode,
            );
      if (baseAmount == null || baseAmount <= 0) return null;
      return LedgerEntry(
        id: _generateId('entry'),
        bookId: book.id,
        type: EntryType.refund,
        amount: normalizeCurrencyAmount(amount, event.currencyCode),
        currencyCode: event.currencyCode,
        accountAmount: normalizeCurrencyAmount(
          accountAmount,
          account.currencyCode,
        ),
        baseAmount: baseAmount,
        conversionSource: event.currencyCode == book.baseCurrencyCode
            ? ConversionSource.identity
            : ConversionSource.rateTable,
        categoryId: original.categoryId,
        accountId: account.id,
        note: event.merchant,
        occurredAt: event.receivedAt,
        occurredAtPrecision: OccurredAtPrecision.minute,
        refundOf: original.id,
        settledAt: event.receivedAt,
        sourceRecords: <EntrySourceRecord>[source],
      );
    }

    if (type == EntryType.transfer) {
      final target = _accounts
          .where(
            (item) =>
                item.id == event.toAccountCandidateId &&
                item.bookId == book.id &&
                item.id != account.id,
          )
          .firstOrNull;
      if (target == null) return null;
      final targetAmount = convert(target.currencyCode);
      final transferCategory = _categories
          .where((category) => category.type == EntryType.transfer)
          .firstOrNull;
      if (targetAmount == null || transferCategory == null) return null;
      return LedgerEntry(
        id: _generateId('entry'),
        bookId: book.id,
        type: EntryType.transfer,
        amount: normalizeCurrencyAmount(amount, event.currencyCode),
        currencyCode: event.currencyCode,
        accountAmount: normalizeCurrencyAmount(
          accountAmount,
          account.currencyCode,
        ),
        toAccountAmount: normalizeCurrencyAmount(
          targetAmount,
          target.currencyCode,
        ),
        baseAmount: 0,
        conversionSource: event.currencyCode == book.baseCurrencyCode
            ? ConversionSource.identity
            : ConversionSource.rateTable,
        categoryId: transferCategory.id,
        accountId: account.id,
        toAccountId: target.id,
        note: event.merchant,
        occurredAt: event.receivedAt,
        occurredAtPrecision: OccurredAtPrecision.minute,
        sourceRecords: <EntrySourceRecord>[source],
      );
    }

    final categoryId = event.categoryCandidateId;
    final baseAmount = convert(book.baseCurrencyCode);
    if (categoryId == null || baseAmount == null) return null;
    return LedgerEntry(
      id: _generateId('entry'),
      bookId: book.id,
      type: type,
      amount: normalizeCurrencyAmount(amount, event.currencyCode),
      currencyCode: event.currencyCode,
      accountAmount: normalizeCurrencyAmount(
        accountAmount,
        account.currencyCode,
      ),
      baseAmount: normalizeCurrencyAmount(baseAmount, book.baseCurrencyCode),
      conversionSource: event.currencyCode == book.baseCurrencyCode
          ? ConversionSource.identity
          : ConversionSource.rateTable,
      categoryId: categoryId,
      accountId: account.id,
      note: event.merchant,
      occurredAt: event.receivedAt,
      occurredAtPrecision: OccurredAtPrecision.minute,
      tagIds: event.tagCandidateIds,
      sourceRecords: <EntrySourceRecord>[source],
    );
  }

  /// 读取桌面小组件实例配置（设备偏好，不属于账本备份）。
  List<WidgetInstanceConfig> get widgetInstanceConfigs =>
      WidgetConfigStore.load(_store);

  Future<void> saveWidgetInstanceConfigs(
    Iterable<WidgetInstanceConfig> configs,
  ) => WidgetConfigStore.save(_store, configs);

  List<UserWidgetDefinition> get userWidgetDefinitions =>
      WidgetConfigStore.loadDefinitions(_store);

  List<WidgetPlacement> get widgetPlacements =>
      WidgetConfigStore.loadPlacements(_store);

  Future<void> saveUserWidgetDefinitions(
    Iterable<UserWidgetDefinition> definitions,
  ) async {
    try {
      await WidgetConfigStore.saveDefinitions(_store, definitions);
    } on Object catch (error) {
      _logger?.error(
        'Widget definitions save failed',
        source: 'widgets',
        error: error,
      );
      rethrow;
    }
    onWidgetProjectionInvalidated?.call();
  }

  WidgetLedgerSnapshot? widgetLedgerSnapshot(
    String? selectedBookId,
    DateTime now,
  ) {
    final id = selectedBookId ?? _activeBookId;
    final book = ledgerBooks.where((item) => item.id == id).firstOrNull;
    if (book == null) return null;
    final startDay = _budgetCycleStartDays[id] ?? naturalMonthStartDay;
    final keyMonth = budgetCycleKeyMonthFor(now, startDay);
    return WidgetLedgerSnapshot(
      book: book,
      entries: entriesForBook(id),
      accounts: List.unmodifiable(_accounts.where((item) => item.bookId == id)),
      rates: List.unmodifiable(
        _exchangeRates.where((item) => item.bookId == id),
      ),
      budgetWindow: budgetCycleOfKeyMonth(keyMonth, startDay),
      budget:
          _monthlyBudgets['$id:${_monthKey(keyMonth)}'] ??
          _monthlyBudgets[_defaultMonthlyBudgetKey(id)] ??
          0,
    );
  }

  Future<void> saveWidgetPlacements(Iterable<WidgetPlacement> placements) =>
      WidgetConfigStore.savePlacements(_store, placements);

  List<LedgerEntry> get entries =>
      _entriesView ??= List<LedgerEntry>.unmodifiable(
        _entries.where((entry) => entry.bookId == _activeBookId),
      );

  /// Read-only entries for cross-book widget previews.
  List<LedgerEntry> entriesForBook(String bookId) =>
      List<LedgerEntry>.unmodifiable(
        _entries.where((entry) => entry.bookId == bookId),
      );

  List<LedgerBook> get ledgerBooks => List<LedgerBook>.unmodifiable(
    _ledgerBooks.isEmpty ? _seedLedgerBooks : _ledgerBooks,
  );

  LedgerBook get activeBook => ledgerBooks.firstWhere(
    (book) => book.id == _activeBookId,
    orElse: () => ledgerBooks.first,
  );

  CurrencyDefinition get activeBaseCurrency =>
      CurrencyCatalog.require(activeBook.baseCurrencyCode);

  List<ExchangeRate> get exchangeRates =>
      _exchangeRatesView ??= List<ExchangeRate>.unmodifiable(
        _exchangeRates.where((rate) => rate.bookId == _activeBookId).toList()
          ..sort((a, b) {
            final byCode = a.currencyCode.compareTo(b.currencyCode);
            if (byCode != 0) return byCode;
            final byDate = b.effectiveDate.compareTo(a.effectiveDate);
            return byDate != 0 ? byDate : b.id.compareTo(a.id);
          }),
      );

  ExchangeRate? exchangeRateFor(String currencyCode, DateTime date) {
    return exchangeRateAt(
      bookId: _activeBookId,
      baseCurrencyCode: activeBook.baseCurrencyCode,
      currencyCode: currencyCode,
      date: date,
      rates: _exchangeRates,
    );
  }

  double? rateToBaseFor(String currencyCode, DateTime date) {
    return rateToBaseAt(
      bookId: _activeBookId,
      baseCurrencyCode: activeBook.baseCurrencyCode,
      currencyCode: currencyCode,
      date: date,
      rates: _exchangeRates,
    );
  }

  CurrencyConversionResult convertAmount({
    required num amount,
    required String sourceCurrencyCode,
    required String targetCurrencyCode,
    required DateTime date,
  }) {
    return convertCurrencyAmount(
      amount: amount,
      sourceCurrencyCode: sourceCurrencyCode,
      targetCurrencyCode: targetCurrencyCode,
      baseCurrencyCode: activeBook.baseCurrencyCode,
      bookId: _activeBookId,
      date: date,
      rates: _exchangeRates,
    );
  }

  ConvertedAccountBalances accountBalancesInBase({
    Iterable<Account>? accounts,
    DateTime? date,
  }) {
    return convertAccountBalancesToBase(
      accounts: accounts ?? this.accounts,
      balanceOf: accountBalance,
      bookId: _activeBookId,
      baseCurrencyCode: activeBook.baseCurrencyCode,
      date: date ?? DateTime.now(),
      rates: _exchangeRates,
    );
  }

  bool ledgerBookHasFinancialData(String bookId) {
    bool hasBudget(Map<String, double> budgets) => budgets.entries.any(
      (entry) => entry.key.startsWith('$bookId:') && entry.value != 0,
    );

    return _entries.any((entry) => entry.bookId == bookId) ||
        _accounts.any(
          (account) =>
              account.bookId == bookId &&
              (account.initialBalance != 0 || account.creditLimit != null),
        ) ||
        _recurringRules.any((rule) => rule.bookId == bookId) ||
        _exchangeRates.any((rate) => rate.bookId == bookId) ||
        _balanceAnchors.any((anchor) => anchor.bookId == bookId) ||
        _billingStatements.any((statement) => statement.bookId == bookId) ||
        _creditAccounts.any(
          (creditAccount) =>
              creditAccount.bookId == bookId &&
              (creditAccount.creditLimit != null ||
                  creditAccount.cycleBudget != null),
        ) ||
        hasBudget(_monthlyBudgets) ||
        hasBudget(_categoryBudgets) ||
        (_dailyBudgets[bookId] ?? 0) != 0;
  }

  bool accountCurrencyLocked(Account account) {
    return account.initialBalance != 0 ||
        account.creditLimit != null ||
        _balanceAnchors.any((anchor) => anchor.accountId == account.id) ||
        _billingStatements.any(
          (statement) => statement.accountId == account.id,
        ) ||
        _entries.any(
          (entry) =>
              entry.bookId == account.bookId &&
              entryTouchesAccount(entry, account.id),
        );
  }

  ({int accounts, int entries, int recurringRules, int budgetSettings})
  currencyReinterpretImpact(String bookId) {
    bool belongsToBook(String key) => key.startsWith('$bookId:');
    return (
      accounts: _accounts.where((account) => account.bookId == bookId).length,
      entries: _entries.where((entry) => entry.bookId == bookId).length,
      recurringRules: _recurringRules
          .where((rule) => rule.bookId == bookId)
          .length,
      budgetSettings:
          _monthlyBudgets.keys.where(belongsToBook).length +
          _categoryBudgets.keys.where(belongsToBook).length +
          ((_dailyBudgets[bookId] ?? 0) != 0 ? 1 : 0),
    );
  }

  List<Account> get accounts => _accountsView ??= List<Account>.unmodifiable(
    _accounts.where((account) => account.bookId == _activeBookId),
  );

  /// 当前账本的信用主体。一个主体可关联多个不同币种的 [Account] 子账户。
  List<CreditAccount> get creditAccounts =>
      _creditAccountsView ??= List<CreditAccount>.unmodifiable(
        _creditAccounts.where((item) => item.bookId == _activeBookId),
      );

  /// 查找账户所属的信用主体；普通账户或未迁移的异常数据返回 null。
  CreditAccount? creditAccountForAccount(Account account) {
    // 页面可能仍持有创建前的 Account 快照（其中尚无 parent id）；优先从 Controller
    // 当前账户集合补取关联，避免刚创建后进入详情页看不到主体，或保存时重复建主体。
    final persistedId = _accounts
        .where((item) => item.id == account.id && item.bookId == account.bookId)
        .firstOrNull
        ?.creditAccountId;
    final creditAccountId = account.creditAccountId ?? persistedId;
    return _creditAccounts
        .where(
          (item) => item.id == creditAccountId && item.bookId == account.bookId,
        )
        .firstOrNull;
  }

  /// 返回信用主体下的币种子账户，保持账户列表中的用户排序。
  List<Account> accountsForCreditAccount(String creditAccountId) =>
      List<Account>.unmodifiable(
        _accounts.where(
          (account) =>
              account.bookId == _activeBookId &&
              account.creditAccountId == creditAccountId,
        ),
      );

  /// 计算首页信用主体账期快照；缺汇率时快照会标记 [CreditCycleOverview.missingConversion]。
  CreditCycleOverview creditCycleOverview(
    CreditAccount creditAccount, {
    DateTime? now,
  }) => buildCreditCycleOverview(
    creditAccount: creditAccount,
    accounts: _accounts.where((item) => item.bookId == creditAccount.bookId),
    entries: _entries.where((item) => item.bookId == creditAccount.bookId),
    statements: _projectBillingStatements(
      creditAccount.bookId,
      now ?? DateTime.now(),
    ),
    allocations: _statementRepaymentAllocations.where(
      (item) => item.bookId == creditAccount.bookId,
    ),
    baseCurrencyCode: activeBook.baseCurrencyCode,
    now: now ?? DateTime.now(),
    balanceOf: accountBalance,
    convertToCreditCurrency: (amount, sourceCurrencyCode, date) {
      final result = convertAmount(
        amount: amount,
        sourceCurrencyCode: sourceCurrencyCode,
        targetCurrencyCode: creditAccount.currencyCode,
        date: date,
      );
      return result is ConvertedCurrencyAmount ? result.amount : null;
    },
  );

  /// 生成当前账本全部信用主体的提醒投影，供提醒设置页和系统通知共用。
  ///
  /// 未完整配置账单日/还款规则的主体无法可靠推导日期，因此不进入结果；这比用默认
  /// 日期制造“看似精确”的提醒更安全。结果按最近到期日、再按账户名排序，优先展示
  /// 需要马上处理的信用账户。
  List<CreditReminderSnapshot> creditReminderSnapshots({DateTime? now}) {
    final reference = now ?? DateTime.now();
    final snapshots =
        creditAccounts
            .where((item) => item.hasCompleteCycleRule)
            .map((creditAccount) {
              final overview = creditCycleOverview(
                creditAccount,
                now: reference,
              );
              return buildCreditReminderSnapshot(
                creditAccount: creditAccount,
                overview: overview,
                childAccounts: _accounts.where(
                  (item) =>
                      item.bookId == creditAccount.bookId &&
                      item.creditAccountId == creditAccount.id,
                ),
                statements: _projectBillingStatements(
                  creditAccount.bookId,
                  reference,
                ),
                now: reference,
                convertToCreditCurrency: (amount, sourceCurrencyCode, date) {
                  final result = convertAmount(
                    amount: amount,
                    sourceCurrencyCode: sourceCurrencyCode,
                    targetCurrencyCode: creditAccount.currencyCode,
                    date: date,
                  );
                  return result is ConvertedCurrencyAmount
                      ? result.amount
                      : null;
                },
              );
            })
            .toList(growable: false)
          ..sort((a, b) {
            final byDue = a.daysUntilDue.compareTo(b.daysUntilDue);
            return byDue != 0
                ? byDue
                : a.creditAccount.name.compareTo(b.creditAccount.name);
          });
    return List<CreditReminderSnapshot>.unmodifiable(snapshots);
  }

  /// 返回本账期尚未成功通知过的预算档位。
  ///
  /// 同一账期只会从 80% → 达到 → 超出逐级通知；若用户退款后再次跨过已经通知的
  /// 档位，不会重复打扰。关闭预算提醒时直接返回空列表，但保留已送达记录，重新开启
  /// 后也不会补发旧档位。
  List<CreditReminderSnapshot> pendingBudgetReminderSnapshots({DateTime? now}) {
    if (!_reminderSettings.cycleBudgetEnabled) {
      return const <CreditReminderSnapshot>[];
    }
    return creditReminderSnapshots(now: now)
        .where((snapshot) {
          final level = snapshot.budgetAlertLevel;
          if (level == CycleBudgetAlertLevel.none) {
            return false;
          }
          final delivered =
              _deliveredBudgetAlertLevels[_budgetReminderDeliveryId(
                snapshot,
              )] ??
              CycleBudgetAlertLevel.none.index;
          return level.index > delivered;
        })
        .toList(growable: false);
  }

  /// 在系统确认通知已显示后持久化去重档位。
  ///
  /// [snapshot] 必须来自当前实时投影；方法只写设备本地元数据，不触发全局重建，避免
  /// “标记已通知 → notifyListeners → 再次调度”的循环。写入失败时记录日志并保留旧
  /// 状态，下次刷新可安全重试。
  Future<bool> markBudgetReminderDelivered(
    CreditReminderSnapshot snapshot,
  ) async {
    final level = snapshot.budgetAlertLevel;
    if (level == CycleBudgetAlertLevel.none) {
      return true;
    }
    final key = _budgetReminderDeliveryId(snapshot);
    final previous = _deliveredBudgetAlertLevels[key] ?? 0;
    if (previous >= level.index) {
      return true;
    }
    final next = Map<String, int>.of(_deliveredBudgetAlertLevels)
      ..[key] = level.index;
    // 去重元数据只需覆盖最近若干账期；限制规模可避免长期使用后 KV 无限增长。
    while (next.length > 128) {
      next.remove(next.keys.first);
    }
    try {
      await _store.writeAndFlush(_reminderDeliveryKey, jsonEncode(next));
    } catch (error) {
      _logger?.error('保存预算提醒去重状态失败', source: 'ReminderDelivery', error: error);
      return false;
    }
    _deliveredBudgetAlertLevels
      ..clear()
      ..addAll(next);
    return true;
  }

  /// 生成跨重启稳定的账期预算通知去重键。
  String _budgetReminderDeliveryId(CreditReminderSnapshot snapshot) {
    final cycleEnd = dateOnly(snapshot.overview.cycle.end);
    final month = cycleEnd.month.toString().padLeft(2, '0');
    final day = cycleEnd.day.toString().padLeft(2, '0');
    return '${snapshot.creditAccount.bookId}:'
        '${snapshot.creditAccount.id}:'
        '${cycleEnd.year}-$month-$day';
  }

  /// 保存信用主体草稿，并把额度/日期同步到子账户的兼容镜像字段。
  /// 主体和子账户在同一事务落库，保存失败时内存保持原状。
  Future<bool> saveCreditAccountDraft(CreditAccount creditAccount) async {
    final index = _creditAccounts.indexWhere(
      (item) => item.id == creditAccount.id,
    );
    final statementDay = creditAccount.statementDay;
    final dueDay = creditAccount.dueDay;
    final daysAfterStatement = creditAccount.daysAfterStatement;
    final creditLimit = creditAccount.creditLimit;
    final cycleBudget = creditAccount.cycleBudget;
    if (index == -1 ||
        creditAccount.bookId != _activeBookId ||
        creditAccount.name.trim().isEmpty ||
        !CurrencyCatalog.isSupported(creditAccount.currencyCode) ||
        (creditLimit != null && (!creditLimit.isFinite || creditLimit < 0)) ||
        (cycleBudget != null && (!cycleBudget.isFinite || cycleBudget < 0)) ||
        (statementDay != null && (statementDay < 1 || statementDay > 28)) ||
        (creditAccount.dueRuleType == CreditDueRuleType.fixedDay &&
            dueDay != null &&
            (dueDay < 1 || dueDay > 28)) ||
        (creditAccount.dueRuleType == CreditDueRuleType.daysAfterStatement &&
            (daysAfterStatement == null ||
                daysAfterStatement <= 0 ||
                daysAfterStatement > 3650))) {
      return false;
    }
    final normalized = creditAccount.copyWith(
      name: creditAccount.name.trim(),
      institution: creditAccount.institution.trim(),
      cardLast4: cardLast4Of(creditAccount.cardLast4),
      creditLimit: creditAccount.creditLimit == null
          ? null
          : normalizeCurrencyAmount(
              creditAccount.creditLimit!,
              creditAccount.currencyCode,
            ),
      clearCreditLimit: creditAccount.creditLimit == null,
      cycleBudget: creditAccount.cycleBudget == null
          ? null
          : normalizeCurrencyAmount(
              creditAccount.cycleBudget!,
              creditAccount.currencyCode,
            ),
      clearCycleBudget: creditAccount.cycleBudget == null,
      dueDay: creditAccount.dueRuleType == CreditDueRuleType.fixedDay
          ? creditAccount.dueDay
          : null,
      clearDueDay:
          creditAccount.dueRuleType != CreditDueRuleType.fixedDay ||
          creditAccount.dueDay == null,
      daysAfterStatement:
          creditAccount.dueRuleType == CreditDueRuleType.daysAfterStatement
          ? creditAccount.daysAfterStatement
          : null,
      clearDaysAfterStatement:
          creditAccount.dueRuleType != CreditDueRuleType.daysAfterStatement ||
          creditAccount.daysAfterStatement == null,
    );
    final nextCreditAccounts = List<CreditAccount>.of(_creditAccounts)
      ..[index] = normalized;
    final nextAccounts = _accountsWithCreditMirrors(_accounts, normalized);
    try {
      await _repository.saveCreditAccountAggregate(
        creditAccounts: nextCreditAccounts,
        accounts: nextAccounts,
      );
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return false;
    }
    _creditAccounts
      ..clear()
      ..addAll(nextCreditAccounts);
    _accounts
      ..clear()
      ..addAll(nextAccounts);
    notifyListeners();
    return true;
  }

  /// 当前账本的余额核准锚点，按核准时间倒序。
  List<BalanceAnchor> get balanceAnchors {
    final list =
        _balanceAnchors
            .where((anchor) => anchor.bookId == _activeBookId)
            .toList()
          ..sort((a, b) => b.effectiveAt.compareTo(a.effectiveAt));
    return List<BalanceAnchor>.unmodifiable(list);
  }

  /// 按 [bookId] 与 [now] 投影正式账单的退款冲抵，不修改已落库的实际还款值。
  List<BillingStatement> _projectBillingStatements(
    String bookId,
    DateTime now,
  ) {
    final refunds = allocateStatementRefunds(
      entries: _entries.where((entry) => entry.bookId == bookId),
      statements: _billingStatements.where((item) => item.bookId == bookId),
      now: now,
    );
    final refundedByStatement = <String, double>{};
    for (final refund in refunds) {
      refundedByStatement.update(
        refund.statementId,
        (amount) => amount + refund.amount,
        ifAbsent: () => refund.amount,
      );
    }
    final list =
        _billingStatements.where((statement) => statement.bookId == bookId).map(
          (statement) {
            final adjusted = statement.copyWith(
              refundAmount: refundedByStatement[statement.id] ?? 0,
            );
            return adjusted.copyWith(
              status: normalizedStatementStatus(adjusted),
            );
          },
        ).toList()..sort((a, b) => b.statementDate.compareTo(a.statementDate));
    return List<BillingStatement>.unmodifiable(list);
  }

  /// 当前账本的正式账单，包含从已到账退款实时推导的冲抵金额，按账单日倒序。
  List<BillingStatement> get billingStatements =>
      _projectBillingStatements(_activeBookId, DateTime.now());

  /// 当前账本的正式账单还款归属快照，供只读 AI 工具按信用主体计算提前还款。
  List<StatementRepaymentAllocation> get statementRepaymentAllocations =>
      List<StatementRepaymentAllocation>.unmodifiable(
        _statementRepaymentAllocations.where(
          (allocation) => allocation.bookId == _activeBookId,
        ),
      );

  List<BillingStatement> billingStatementsForAccount(String accountId) =>
      List<BillingStatement>.unmodifiable(
        billingStatements.where((item) => item.accountId == accountId),
      );

  List<StatementRepaymentAllocation> allocationsForStatement(
    String statementId,
  ) => List<StatementRepaymentAllocation>.unmodifiable(
    _statementRepaymentAllocations.where(
      (allocation) => allocation.statementId == statementId,
    ),
  );

  /// 当前账本某期账单的出账后退款冲抵。关系由已到账退款和原消费实时推导，
  /// 不把退款写进还款分配，也不需要在账单表维护第二份金额缓存。
  List<StatementRefundAllocation> refundAllocationsForStatement(
    String statementId, {
    DateTime? now,
  }) => List<StatementRefundAllocation>.unmodifiable(
    allocateStatementRefunds(
      entries: _entries.where((entry) => entry.bookId == _activeBookId),
      statements: _billingStatements.where(
        (statement) => statement.bookId == _activeBookId,
      ),
      now: now ?? DateTime.now(),
    ).where((allocation) => allocation.statementId == statementId),
  );

  /// 计算还款分配时某张账单在退款冲抵后的实际待还，避免把退款当成可重复分配的额度。
  double _statementOutstandingWithRefunds(BillingStatement statement) {
    final refunded = refundAllocationsForStatement(
      statement.id,
    ).fold<double>(0, (total, allocation) => total + allocation.amount);
    return statement.copyWith(refundAmount: refunded).outstandingAmount;
  }

  BalanceAnchor? latestBalanceAnchor(String accountId) => _balanceAnchors
      .where((anchor) => anchor.accountId == accountId)
      .fold<BalanceAnchor?>(
        null,
        (latest, anchor) =>
            latest == null || anchor.effectiveAt.isAfter(latest.effectiveAt)
            ? anchor
            : latest,
      );

  CreditStatementOverview creditOverview(Account account, {DateTime? now}) =>
      creditStatementOverview(
        account: account,
        entries: _entries.where((entry) => entry.bookId == account.bookId),
        statements: _billingStatements.where(
          (statement) => statement.accountId == account.id,
        ),
        now: now ?? DateTime.now(),
      );

  /// 保存一个“该时点余额已确认”的锚点。它不会创建校准交易，也不会改写历史流水。
  Future<bool> saveBalanceAnchor({
    required Account account,
    required DateTime effectiveAt,
    required double balance,
    String note = '',
  }) async {
    if (!balance.isFinite ||
        !_accounts.any(
          (item) => item.id == account.id && item.bookId == account.bookId,
        )) {
      return false;
    }
    final normalized = normalizeCurrencyAmount(balance, account.currencyCode);
    final next = List<BalanceAnchor>.of(_balanceAnchors);
    final sameMoment = next.indexWhere(
      (anchor) =>
          anchor.accountId == account.id &&
          anchor.effectiveAt.millisecondsSinceEpoch ==
              effectiveAt.millisecondsSinceEpoch,
    );
    final now = DateTime.now();
    final anchor = BalanceAnchor(
      id: sameMoment == -1 ? _generateId('anchor') : next[sameMoment].id,
      bookId: account.bookId,
      accountId: account.id,
      effectiveAt: effectiveAt,
      balance: normalized,
      createdAt: sameMoment == -1 ? now : next[sameMoment].createdAt,
      note: note.trim(),
    );
    if (sameMoment == -1) {
      next.add(anchor);
    } else {
      next[sameMoment] = anchor;
    }
    if (!await _runTrackedWrite(() => _repository.saveBalanceAnchors(next))) {
      return false;
    }
    _balanceAnchors
      ..clear()
      ..addAll(next);
    notifyListeners();
    return true;
  }

  /// 新建或更新一期正式账单。同一来源账单 id 会幂等更新，不会重复新增。
  Future<bool> saveBillingStatement(BillingStatement statement) async {
    final account = _accounts
        .where(
          (item) =>
              item.id == statement.accountId &&
              item.bookId == statement.bookId &&
              item.type.supportsCredit,
        )
        .firstOrNull;
    if (account == null ||
        statement.currencyCode != account.currencyCode ||
        !statement.statementAmount.isFinite ||
        statement.statementAmount < 0 ||
        !statement.minimumPayment.isFinite ||
        statement.minimumPayment < 0 ||
        statement.minimumPayment > statement.statementAmount ||
        !statement.paidAmount.isFinite ||
        statement.paidAmount < 0 ||
        statement.periodEnd.isBefore(statement.periodStart)) {
      return false;
    }
    // 先按来源或显式 id 找到旧记录，再计算最终已还金额。重复导入同一期账单时，
    // 银行文件可能不再携带“导入前已还”字段；因此不能直接用新文件的 0 覆盖本地
    // 已核准金额，否则账单会从“已结清”倒退成“待还”。
    final baseCandidate = statement.copyWith(
      paidAmount: normalizeCurrencyAmount(
        statement.paidAmount.clamp(0, statement.statementAmount),
        account.currencyCode,
      ),
    );
    final next = List<BillingStatement>.of(_billingStatements);
    var index = next.indexWhere((item) => item.id == baseCandidate.id);
    if (index == -1 &&
        baseCandidate.sourceId.isNotEmpty &&
        baseCandidate.sourceStatementId.isNotEmpty) {
      index = next.indexWhere(
        (item) =>
            item.bookId == baseCandidate.bookId &&
            item.accountId == baseCandidate.accountId &&
            item.sourceId == baseCandidate.sourceId &&
            item.sourceStatementId == baseCandidate.sourceStatementId,
      );
    }
    var paidAmount = baseCandidate.paidAmount;
    if (index != -1) {
      final previous = next[index];
      // 同一个账单来源只能更新原账单，不能借同一 source key 把账单挂到
      // 另一个账本或账户；否则现有还款分配会失去明确归属。
      if (previous.bookId != baseCandidate.bookId ||
          previous.accountId != baseCandidate.accountId) {
        return false;
      }
      // 旧 paidAmount 代表此前导入/人工核准的基线，分配表金额代表本地可追溯的
      // 还款证据；两者都必须保留，取最大值可避免重复导入造成余额失真。
      final allocated = _statementRepaymentAllocations
          .where((item) => item.statementId == previous.id)
          .fold<double>(0, (sum, item) => sum + item.amount);
      // 账单金额一旦已经被还款或分配证据覆盖，导入一份金额更小的修正版
      // 不能静默截断 paidAmount；拒绝本次更新可以保留账务可解释性，等待用户
      // 先修正对应还款/账单证据。
      final tolerance = currencyAmountTolerance(account.currencyCode);
      if (previous.paidAmount > baseCandidate.statementAmount + tolerance ||
          allocated > baseCandidate.statementAmount + tolerance) {
        return false;
      }
      if (previous.paidAmount > paidAmount) {
        paidAmount = previous.paidAmount;
      }
      if (allocated > paidAmount) {
        paidAmount = allocated;
      }
    }
    final normalized = baseCandidate.copyWith(
      paidAmount: normalizeCurrencyAmount(
        paidAmount.clamp(0, baseCandidate.statementAmount),
        account.currencyCode,
      ),
    );
    final candidate = normalized.copyWith(
      status: normalizedStatementStatus(normalized),
    );
    if (index == -1) {
      next.add(candidate);
    } else {
      next[index] = BillingStatement(
        id: next[index].id,
        bookId: candidate.bookId,
        accountId: candidate.accountId,
        statementDate: candidate.statementDate,
        periodStart: candidate.periodStart,
        periodEnd: candidate.periodEnd,
        statementAmount: candidate.statementAmount,
        minimumPayment: candidate.minimumPayment,
        dueDate: candidate.dueDate,
        paidAmount: candidate.paidAmount,
        status: candidate.status,
        currencyCode: candidate.currencyCode,
        sourceId: candidate.sourceId,
        sourceStatementId: candidate.sourceStatementId,
        note: candidate.note,
      );
    }
    if (!await _runTrackedWrite(
      () => _repository.saveBillingStatements(next),
    )) {
      return false;
    }
    _billingStatements
      ..clear()
      ..addAll(next);
    notifyListeners();
    return true;
  }

  /// 由页面创建手工正式账单；id 只由 Controller 生成，调用方无需拼接主键。
  Future<bool> createBillingStatement({
    required Account account,
    required DateTime statementDate,
    required DateTime periodStart,
    required DateTime periodEnd,
    required double statementAmount,
    required double minimumPayment,
    required DateTime dueDate,
    required double paidAmount,
    String note = '',
  }) {
    return saveBillingStatement(
      BillingStatement(
        id: _generateId('statement'),
        bookId: account.bookId,
        accountId: account.id,
        statementDate: statementDate,
        periodStart: periodStart,
        periodEnd: periodEnd,
        statementAmount: normalizeCurrencyAmount(
          statementAmount,
          account.currencyCode,
        ),
        minimumPayment: normalizeCurrencyAmount(
          minimumPayment,
          account.currencyCode,
        ),
        dueDate: dueDate,
        paidAmount: normalizeCurrencyAmount(paidAmount, account.currencyCode),
        status: BillingStatementStatus.open,
        currencyCode: account.currencyCode,
        note: note.trim(),
      ),
    );
  }

  /// 删除一期正式账单及其还款分配；原还款交易保留，不影响账户真实余额。
  Future<bool> deleteBillingStatement(String statementId) async {
    if (!_billingStatements.any((item) => item.id == statementId)) return false;
    final nextStatements = _billingStatements
        .where((item) => item.id != statementId)
        .toList();
    final nextAllocations = _statementRepaymentAllocations
        .where((item) => item.statementId != statementId)
        .toList();
    if (!await _runTrackedWrite(
      () => _repository.saveCreditAggregate(
        entries: _entries,
        statements: nextStatements,
        allocations: nextAllocations,
      ),
    )) {
      return false;
    }
    _billingStatements
      ..clear()
      ..addAll(nextStatements);
    _statementRepaymentAllocations
      ..clear()
      ..addAll(nextAllocations);
    notifyListeners();
    return true;
  }

  /// 清除某笔还款与正式账单之间的全部分配关系。
  ///
  /// 编辑交易时，用户可能把原来的信用卡还款改成普通转账，或者改到
  /// 另一张非信用账户。此时旧分配不能继续保留，否则账单的「已还金额」
  /// 会和交易实际含义不一致。本方法同时回退各账单的 paidAmount，并以
  /// 一次原子写入保持账单与分配表的一致性。
  ///
  /// [repaymentEntryId] 是要解除关联的还款交易 id。没有旧分配时视为
  /// 成功，便于调用方安全地重复执行。
  Future<bool> _clearRepaymentAllocations(String repaymentEntryId) async {
    final previousAllocations = _statementRepaymentAllocations
        .where((item) => item.repaymentEntryId == repaymentEntryId)
        .toList();
    if (previousAllocations.isEmpty) return true;

    final previousByStatement = <String, double>{};
    for (final allocation in previousAllocations) {
      previousByStatement[allocation.statementId] =
          (previousByStatement[allocation.statementId] ?? 0) +
          allocation.amount;
    }
    final nextStatements = <BillingStatement>[
      for (final statement in _billingStatements)
        if (!previousByStatement.containsKey(statement.id))
          statement
        else
          (() {
            final paid = normalizeCurrencyAmount(
              (statement.paidAmount - previousByStatement[statement.id]!).clamp(
                0,
                statement.statementAmount,
              ),
              statement.currencyCode,
            );
            final updated = statement.copyWith(paidAmount: paid);
            return updated.copyWith(status: normalizedStatementStatus(updated));
          })(),
    ];
    final nextAllocations = _statementRepaymentAllocations
        .where((item) => item.repaymentEntryId != repaymentEntryId)
        .toList();
    if (!await _runTrackedWrite(
      () => _repository.saveCreditAggregate(
        entries: _entries,
        statements: nextStatements,
        allocations: nextAllocations,
      ),
    )) {
      return false;
    }
    _billingStatements
      ..clear()
      ..addAll(nextStatements);
    _statementRepaymentAllocations
      ..clear()
      ..addAll(nextAllocations);
    notifyListeners();
    return true;
  }

  /// 把一笔已保存的还款按“最早到期优先”自动分配给尚未结清的账单。
  ///
  /// 分配可跨多期；超过已出账待还的剩余金额保持未分配，代表提前还款/未出账部分。
  Future<double> allocateRepaymentToStatements({
    required String repaymentEntryId,
    required String creditAccountId,
    required double repaymentAmount,
  }) async {
    final entry = _entries
        .where((item) => item.id == repaymentEntryId)
        .firstOrNull;
    final account = _accounts
        .where((item) => item.id == creditAccountId)
        .firstOrNull;
    if (entry == null ||
        account == null ||
        entry.type != EntryType.transfer ||
        entry.toAccountId != creditAccountId ||
        entry.bookId != account.bookId ||
        !repaymentAmount.isFinite ||
        repaymentAmount <= 0) {
      return 0;
    }
    final previousAllocations = _statementRepaymentAllocations
        .where((item) => item.repaymentEntryId == repaymentEntryId)
        .toList();
    final previousByStatement = <String, double>{};
    for (final allocation in previousAllocations) {
      previousByStatement[allocation.statementId] =
          (previousByStatement[allocation.statementId] ?? 0) +
          allocation.amount;
    }
    final nextAllocations = _statementRepaymentAllocations
        .where((item) => item.repaymentEntryId != repaymentEntryId)
        .toList();
    final nextStatements = <BillingStatement>[
      for (final statement in _billingStatements)
        if (!previousByStatement.containsKey(statement.id))
          statement
        else
          (() {
            final paid = normalizeCurrencyAmount(
              (statement.paidAmount - previousByStatement[statement.id]!).clamp(
                0,
                statement.statementAmount,
              ),
              account.currencyCode,
            );
            final updated = statement.copyWith(paidAmount: paid);
            return updated.copyWith(status: normalizedStatementStatus(updated));
          })(),
    ];
    final candidates =
        <int>[
          for (var i = 0; i < nextStatements.length; i++)
            if (nextStatements[i].accountId == creditAccountId &&
                _statementOutstandingWithRefunds(nextStatements[i]) > 0)
              i,
        ]..sort(
          (a, b) =>
              nextStatements[a].dueDate.compareTo(nextStatements[b].dueDate),
        );
    // 还款分配的上限必须是真实转账进入信用账户的金额，避免调用方传入
    // 错误金额时凭空增加账单 paidAmount；超出部分不参与本次账单分配。
    final transferAmount =
        entry.toAccountAmount ??
        (entry.currencyCode == account.currencyCode ? entry.amount : 0);
    if (!transferAmount.isFinite || transferAmount <= 0) {
      return 0;
    }
    var remaining = normalizeCurrencyAmount(
      repaymentAmount.clamp(0, transferAmount),
      account.currencyCode,
    );
    var allocated = 0.0;
    final now = DateTime.now();
    for (final index in candidates) {
      if (remaining <= 0) break;
      final statement = nextStatements[index];
      final amount = normalizeCurrencyAmount(
        remaining.clamp(0, _statementOutstandingWithRefunds(statement)),
        account.currencyCode,
      );
      if (amount <= 0) continue;
      nextAllocations.add(
        StatementRepaymentAllocation(
          id: _generateId('allocation'),
          bookId: account.bookId,
          statementId: statement.id,
          repaymentEntryId: repaymentEntryId,
          amount: amount,
          createdAt: now,
        ),
      );
      final updated = statement.copyWith(
        paidAmount: normalizeCurrencyAmount(
          statement.paidAmount + amount,
          account.currencyCode,
        ),
      );
      nextStatements[index] = updated.copyWith(
        status: normalizedStatementStatus(updated),
      );
      allocated += amount;
      remaining = normalizeCurrencyAmount(
        remaining - amount,
        account.currencyCode,
      );
    }
    if (!await _runTrackedWrite(
      () => _repository.saveCreditAggregate(
        entries: _entries,
        statements: nextStatements,
        allocations: nextAllocations,
      ),
    )) {
      return 0;
    }
    _billingStatements
      ..clear()
      ..addAll(nextStatements);
    _statementRepaymentAllocations
      ..clear()
      ..addAll(nextAllocations);
    notifyListeners();
    return allocated;
  }

  List<AccountGroup> get accountGroups {
    return _accountGroupsView ??= List<AccountGroup>.unmodifiable(
      _accountGroups.where((group) => group.bookId == _activeBookId).toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder)),
    );
  }

  List<Category> get categories =>
      _categoriesView ??= List<Category>.unmodifiable(
        _categories.isEmpty ? _seedCategories : _categories,
      );

  /// 全部标签（按创建/排序顺序）。标签与账本无关，全局共享。
  List<Tag> get tags => List<Tag>.unmodifiable(_tags);

  Tag? tagById(String id) => _tags.where((tag) => tag.id == id).firstOrNull;

  /// 某标签被多少笔交易使用（当前账本无关，统计全部交易）。
  int tagUsageCount(String tagId) {
    return _entries.where((entry) => entry.tagIds.contains(tagId)).length;
  }

  /// 某交易的图片附件（按加入顺序）。
  List<Attachment> attachmentsForEntry(String entryId) {
    return List<Attachment>.unmodifiable(
      _attachments.where((a) => a.entryId == entryId),
    );
  }

  int attachmentCountForEntry(String entryId) {
    return _attachments.where((a) => a.entryId == entryId).length;
  }

  // id 生成（_generateId / _idSeq）已下沉到 _ControllerState，便于载入期的
  // _syncRefundData() 等基础流程合成条目时复用。

  /// 为交易新增一张图片附件（[dataUrl] 为压缩后的 JPEG data URL）。
  void addAttachment(String entryId, String dataUrl) {
    if (dataUrl.isEmpty) {
      return;
    }
    _attachments.add(
      Attachment(id: _generateId('att'), entryId: entryId, dataUrl: dataUrl),
    );
    _persistAttachments();
    notifyListeners();
  }

  void removeAttachment(String attachmentId) {
    final before = _attachments.length;
    _attachments.removeWhere((a) => a.id == attachmentId);
    if (_attachments.length == before) {
      return;
    }
    _persistAttachments();
    notifyListeners();
  }

  /// 删除若干交易时一并清理它们的附件。返回是否有附件被移除。
  bool _removeAttachmentsForEntries(Set<String> entryIds) {
    if (entryIds.isEmpty) {
      return false;
    }
    final before = _attachments.length;
    _attachments.removeWhere((a) => entryIds.contains(a.entryId));
    return _attachments.length != before;
  }

  // ---- 周期记账 ----

  /// 当前账本下的周期记账规则（按加入顺序）。
  List<RecurringRule> get recurringRules => List<RecurringRule>.unmodifiable(
    _recurringRules.where((rule) => rule.bookId == _activeBookId),
  );

  void addRecurringRule(RecurringRule rule) {
    _recurringRules.add(rule);
    _persistRecurringRules();
    notifyListeners();
  }

  void updateRecurringRule(RecurringRule rule) {
    final index = _recurringRules.indexWhere((item) => item.id == rule.id);
    if (index == -1) {
      return;
    }
    _recurringRules[index] = rule;
    _persistRecurringRules();
    notifyListeners();
  }

  void setRecurringRuleActive(String ruleId, bool active) {
    final index = _recurringRules.indexWhere((item) => item.id == ruleId);
    if (index == -1) {
      return;
    }
    _recurringRules[index] = _recurringRules[index].copyWith(active: active);
    _persistRecurringRules();
    notifyListeners();
  }

  void deleteRecurringRule(String ruleId) {
    final before = _recurringRules.length;
    _recurringRules.removeWhere((item) => item.id == ruleId);
    if (_recurringRules.length == before) {
      return;
    }
    _persistRecurringRules();
    notifyListeners();
  }

  /// Persists one recurring-rule editor draft before publishing it in memory.
  Future<bool> saveRecurringRuleDraft(
    RecurringRule rule, {
    required bool isNew,
  }) async {
    final book = ledgerBooks
        .where((book) => book.id == rule.bookId)
        .firstOrNull;
    if (book == null || !_validRecurringRuleCurrencyAmounts(rule, book)) {
      return false;
    }
    final next = List<RecurringRule>.of(_recurringRules);
    if (isNew) {
      next.add(rule);
    } else {
      final index = next.indexWhere((item) => item.id == rule.id);
      if (index == -1) {
        return false;
      }
      next[index] = rule;
    }
    try {
      await _repository.saveRecurringRules(next);
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return false;
    }
    _recurringRules
      ..clear()
      ..addAll(next);
    notifyListeners();
    return true;
  }

  bool _validRecurringRuleCurrencyAmounts(RecurringRule rule, LedgerBook book) {
    bool positive(double? value) =>
        value != null && value.isFinite && value > 0;
    final account = _accounts
        .where(
          (account) =>
              account.id == rule.accountId && account.bookId == rule.bookId,
        )
        .firstOrNull;
    final toAccount = _accounts
        .where(
          (account) =>
              account.id == rule.toAccountId && account.bookId == rule.bookId,
        )
        .firstOrNull;
    if (!CurrencyCatalog.isSupported(rule.currencyCode) ||
        !positive(rule.amount) ||
        rule.accountId.isEmpty && rule.accountAmount != null ||
        rule.accountId.isNotEmpty && !positive(rule.accountAmount)) {
      return false;
    }
    if (rule.type == EntryType.transfer) {
      return isZeroCurrencyAmount(rule.baseAmount, book.baseCurrencyCode) &&
          rule.accountId.isNotEmpty &&
          rule.toAccountId != null &&
          rule.toAccountId!.isNotEmpty &&
          rule.toAccountId != rule.accountId &&
          positive(rule.toAccountAmount) &&
          (account == null || rule.currencyCode == account.currencyCode) &&
          (toAccount == null || rule.toAccountId == toAccount.id);
    }
    return positive(rule.baseAmount) &&
        rule.toAccountId == null &&
        rule.toAccountAmount == null;
  }

  /// Persists the active switches edited on the recurring-rule list as a batch.
  Future<bool> saveRecurringActiveDraft(Map<String, bool> activeById) async {
    final next = _recurringRules
        .map(
          (rule) => activeById.containsKey(rule.id)
              ? rule.copyWith(active: activeById[rule.id])
              : rule,
        )
        .toList();
    try {
      await _repository.saveRecurringRules(next);
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return false;
    }
    _recurringRules
      ..clear()
      ..addAll(next);
    notifyListeners();
    return true;
  }

  // ---- 本地汇率 ----

  Future<bool> saveExchangeRateDraft({
    String? id,
    required String currencyCode,
    required DateTime effectiveDate,
    required double rateToBase,
    ExchangeRateSource source = ExchangeRateSource.manual,
  }) async {
    final code = currencyCode.trim().toUpperCase();
    final baseCode = activeBook.baseCurrencyCode.toUpperCase();
    if (activeBook.currencySetupStatus != CurrencySetupStatus.confirmed ||
        !CurrencyCatalog.isSupported(code) ||
        code == baseCode ||
        !isValidExchangeRate(rateToBase)) {
      return false;
    }
    final date = DateTime(
      effectiveDate.year,
      effectiveDate.month,
      effectiveDate.day,
    );
    final idIndex = id == null
        ? -1
        : _exchangeRates.indexWhere(
            (rate) => rate.bookId == _activeBookId && rate.id == id,
          );
    final keyIndex = _exchangeRates.indexWhere(
      (rate) =>
          rate.bookId == _activeBookId &&
          rate.baseCurrencyCode == baseCode &&
          rate.currencyCode == code &&
          currencyDateKey(rate.effectiveDate) == currencyDateKey(date),
    );
    if (idIndex != -1 && keyIndex != -1 && idIndex != keyIndex) return false;
    final existingIndex = idIndex != -1 ? idIndex : keyIndex;
    final now = DateTime.now();
    final existing = existingIndex == -1 ? null : _exchangeRates[existingIndex];
    final candidate = ExchangeRate(
      id: existing?.id ?? id ?? _generateId('rate'),
      bookId: _activeBookId,
      baseCurrencyCode: baseCode,
      currencyCode: code,
      effectiveDate: date,
      rateToBase: rateToBase,
      source: source,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );
    final next = List<ExchangeRate>.of(_exchangeRates);
    if (existingIndex == -1) {
      next.add(candidate);
    } else {
      next[existingIndex] = candidate;
    }
    try {
      await _repository.saveExchangeRates(next);
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return false;
    }
    _exchangeRates
      ..clear()
      ..addAll(next);
    notifyListeners();
    return true;
  }

  Future<bool> deleteExchangeRate(String id) async {
    final next = <ExchangeRate>[
      for (final rate in _exchangeRates)
        if (rate.id != id || rate.bookId != _activeBookId) rate,
    ];
    if (next.length == _exchangeRates.length) return false;
    try {
      await _repository.saveExchangeRates(next);
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return false;
    }
    _exchangeRates
      ..clear()
      ..addAll(next);
    notifyListeners();
    return true;
  }

  /// Returns due rules in the active ledger that cannot currently be posted
  /// because one or more local rates are missing.
  Map<String, Set<String>> dueRecurringMissingRates(DateTime now) {
    final result = <String, Set<String>>{};
    for (final rule in recurringRules.where((rule) => rule.active)) {
      final dueDates = dueDatesFor(rule, now);
      if (dueDates.isEmpty) continue;
      for (final due in dueDates) {
        final materialized = _materializeRecurringEntry(rule, due);
        if (materialized.missingCodes.isNotEmpty) {
          result[rule.id] = materialized.missingCodes;
          break;
        }
      }
    }
    return result;
  }

  ({LedgerEntry? entry, Set<String> missingCodes}) _materializeRecurringEntry(
    RecurringRule rule,
    DateTime due,
  ) {
    final book = ledgerBooks
        .where((book) => book.id == rule.bookId)
        .firstOrNull;
    if (book == null) return (entry: null, missingCodes: const <String>{});
    final account = _accounts
        .where(
          (account) =>
              account.id == rule.accountId && account.bookId == rule.bookId,
        )
        .firstOrNull;
    final toAccount = _accounts
        .where(
          (account) =>
              account.id == rule.toAccountId && account.bookId == rule.bookId,
        )
        .firstOrNull;
    final sourceCode = rule.type == EntryType.transfer && account != null
        ? account.currencyCode
        : rule.currencyCode;
    final id = 'entry_recur_${rule.id}_${due.millisecondsSinceEpoch}';
    if (rule.ratePolicy == RecurringRatePolicy.fixedAmounts) {
      return (
        entry: LedgerEntry(
          id: id,
          bookId: rule.bookId,
          type: rule.type,
          amount: rule.amount,
          currencyCode: sourceCode,
          accountAmount: rule.accountId.isEmpty ? null : rule.accountAmount,
          toAccountAmount: rule.type == EntryType.transfer
              ? rule.toAccountAmount
              : null,
          baseAmount: rule.type == EntryType.transfer ? 0 : rule.baseAmount,
          conversionSource: ConversionSource.manual,
          categoryId: rule.categoryId,
          accountId: rule.accountId,
          toAccountId: rule.type == EntryType.transfer
              ? rule.toAccountId
              : null,
          note: rule.note,
          occurredAt: due,
        ),
        missingCodes: const <String>{},
      );
    }

    final missing = <String>{};
    double? converted(String targetCode) {
      final result = convertCurrencyAmount(
        amount: rule.amount,
        sourceCurrencyCode: sourceCode,
        targetCurrencyCode: targetCode,
        baseCurrencyCode: book.baseCurrencyCode,
        bookId: rule.bookId,
        date: due,
        rates: _exchangeRates,
      );
      if (result is ConvertedCurrencyAmount) return result.amount;
      if (result is MissingCurrencyRate) missing.addAll(result.currencyCodes);
      return null;
    }

    final accountAmount = rule.accountId.isEmpty
        ? null
        : converted(account?.currencyCode ?? sourceCode);
    final toAccountAmount = rule.type == EntryType.transfer
        ? converted(toAccount?.currencyCode ?? sourceCode)
        : null;
    final baseAmount = rule.type == EntryType.transfer
        ? 0.0
        : converted(book.baseCurrencyCode);
    if (missing.isNotEmpty ||
        rule.accountId.isNotEmpty && accountAmount == null ||
        rule.type == EntryType.transfer && toAccountAmount == null ||
        rule.type != EntryType.transfer && baseAmount == null) {
      return (entry: null, missingCodes: missing);
    }
    return (
      entry: LedgerEntry(
        id: id,
        bookId: rule.bookId,
        type: rule.type,
        amount: normalizeCurrencyAmount(rule.amount, sourceCode),
        currencyCode: sourceCode,
        accountAmount: accountAmount,
        toAccountAmount: toAccountAmount,
        baseAmount: baseAmount!,
        conversionSource: ConversionSource.rateTable,
        categoryId: rule.categoryId,
        accountId: rule.accountId,
        toAccountId: rule.type == EntryType.transfer ? rule.toAccountId : null,
        note: rule.note,
        occurredAt: due,
      ),
      missingCodes: const <String>{},
    );
  }

  /// Atomically posts all due recurring entries and advances only dates that
  /// were successfully materialized. A missing rate leaves that due date in
  /// place for retry. Returns -1 if persistence fails.
  Future<int> applyDueRecurring(DateTime now) async {
    var generated = 0;
    final nextEntries = List<LedgerEntry>.of(_entries);
    final nextRules = List<RecurringRule>.of(_recurringRules);
    final existingIds = nextEntries.map((e) => e.id).toSet();
    for (var i = 0; i < nextRules.length; i++) {
      final rule = nextRules[i];
      final dueDates = dueDatesFor(rule, now);
      if (dueDates.isEmpty) {
        continue;
      }
      DateTime? lastProcessed;
      for (final due in dueDates) {
        final id = 'entry_recur_${rule.id}_${due.millisecondsSinceEpoch}';
        if (!existingIds.add(id)) {
          lastProcessed = due;
          continue;
        }
        final materialized = _materializeRecurringEntry(rule, due);
        if (materialized.entry == null) {
          existingIds.remove(id);
          break;
        }
        nextEntries.add(materialized.entry!);
        generated += 1;
        lastProcessed = due;
      }
      if (lastProcessed != null) {
        nextRules[i] = rule.copyWith(
          nextRunDate: advanceRecurring(
            lastProcessed,
            rule.frequency,
            anchorDay: rule.startDate.day,
          ),
        );
      }
    }
    final rulesChanged = !listEquals(nextRules, _recurringRules);
    if (generated == 0 && !rulesChanged) return 0;
    nextEntries.sort(_compareEntriesLatestFirst);
    try {
      await _repository.saveRecurringGeneration(
        entries: nextEntries,
        recurringRules: nextRules,
      );
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return -1;
    }
    _entries
      ..clear()
      ..addAll(nextEntries);
    _recurringRules
      ..clear()
      ..addAll(nextRules);
    notifyListeners();
    return generated;
  }

  ThemePreference get themePreference => _themePreference;

  UserProfile get profile => _profile;

  String get assetCoverUrl => _assetCoverUrl;

  bool get hapticsEnabled => _hapticsEnabled;

  AssetAccountViewMode get assetAccountViewMode => _assetAccountViewMode;

  BackupSettings get backupSettings => _backupSettings;

  void _persistBackupSettings() {
    _store.write(_backupSettingsKey, _backupSettings.encode());
  }

  /// 保存用户选择的备份目录（Android SAF 树 URI 或桌面路径）。
  void setBackupDirectory(String uri, String label) {
    _backupSettings = _backupSettings.copyWith(
      directoryUri: uri,
      directoryLabel: label,
    );
    _persistBackupSettings();
    notifyListeners();
  }

  /// 清除备份目录，同时关闭自动备份。
  void clearBackupDirectory() {
    _backupSettings = _backupSettings.copyWith(
      clearDirectory: true,
      frequency: BackupFrequency.manual,
    );
    _persistBackupSettings();
    notifyListeners();
  }

  void setBackupFrequency(BackupFrequency frequency) {
    _backupSettings = _backupSettings.copyWith(frequency: frequency);
    _persistBackupSettings();
    notifyListeners();
  }

  void setBackupIntervalHours(int hours) {
    _backupSettings = _backupSettings.copyWith(
      intervalHours: hours < 1 ? 1 : hours,
    );
    _persistBackupSettings();
    notifyListeners();
  }

  void setBackupRetention(int retention) {
    _backupSettings = _backupSettings.copyWith(
      retention: retention < 1 ? 1 : retention,
    );
    _persistBackupSettings();
    notifyListeners();
  }

  /// 备份成功后记录时间，供自动备份频率判断与「上次备份时间」展示。
  void recordBackupTime(DateTime time) {
    _backupSettings = _backupSettings.copyWith(lastBackupAt: time);
    _persistBackupSettings();
    notifyListeners();
  }

  /// 备份加密口令（明文存本机 KV，供自动备份无人值守加密；空表示不加密）。
  /// 保护的是离开设备的备份文件，本机数据本身已在应用私有存储内。
  String get backupPassphrase => _backupPassphrase;

  bool get backupEncryptionEnabled => _backupPassphrase.isNotEmpty;

  void setBackupPassphrase(String passphrase) {
    _backupPassphrase = passphrase;
    if (passphrase.isEmpty) {
      _store.delete(_backupPassphraseKey);
    } else {
      _store.write(_backupPassphraseKey, passphrase);
    }
    notifyListeners();
  }

  /// 清除加密口令：后续备份不再加密（已加密的旧文件仍需原口令导入）。
  void clearBackupPassphrase() => setBackupPassphrase('');

  /// WebDAV 备份配置（地址/账号/密码/是否自动上传）；密码明文存本机 KV。
  WebdavConfig get webdavConfig => _webdavConfig;

  void setWebdavConfig(WebdavConfig config) {
    _webdavConfig = config;
    if (config.isConfigured) {
      _store.write(_webdavKey, config.encode());
    } else {
      _store.delete(_webdavKey);
    }
    notifyListeners();
  }

  void setWebdavAutoUpload(bool enabled) {
    setWebdavConfig(_webdavConfig.copyWith(autoUpload: enabled));
  }

  Future<bool> saveDataManagementPreferencesDraft({
    required BackupFrequency frequency,
    required int intervalHours,
    required int retention,
    required bool webdavAutoUpload,
  }) async {
    final nextBackup = _backupSettings.copyWith(
      frequency: frequency,
      intervalHours: intervalHours < 1 ? 1 : intervalHours,
      retention: retention < 1 ? 1 : retention,
    );
    final nextWebdav = _webdavConfig.copyWith(autoUpload: webdavAutoUpload);
    try {
      await _store.writeAndFlush(_backupSettingsKey, nextBackup.encode());
      if (nextWebdav.isConfigured) {
        await _store.writeAndFlush(_webdavKey, nextWebdav.encode());
      }
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return false;
    }
    _backupSettings = nextBackup;
    _webdavConfig = nextWebdav;
    notifyListeners();
    return true;
  }

  void clearWebdavConfig() {
    _webdavConfig = const WebdavConfig();
    _store.delete(_webdavKey);
    notifyListeners();
  }

  List<Category> categoriesForType(EntryType type) {
    return categoriesFor(type, categories);
  }

  Category categoryById(String id) {
    return categoryByIdFrom(categories, id);
  }

  /// 指定类型的顶级分类（多级分类树的根）。
  List<Category> rootCategoriesForType(EntryType type) {
    return rootCategories(categories, type);
  }

  /// 某分类的直接子分类。
  List<Category> childCategories(String parentId) {
    return childrenOf(categories, parentId);
  }

  /// 某分类的完整路径标签，如「餐饮 / 咖啡」。
  String categoryPathLabel(String id) {
    return pathLabel(categories, id);
  }

  /// 前序展开某类型的整棵分类树（携带层级深度），供缩进列表渲染。
  List<CategoryNode> categoryTreeForType(EntryType type) {
    return flattenTree(categories, type);
  }

  /// 当前账本的预算周期起始日（1–28，默认 1 = 自然月）。预算体系（预算页 / 预算
  /// 面板 / 预算小组件）按此周期取数；统计报表仍按自然月。
  int get budgetCycleStartDay => clampBudgetCycleStartDay(
    _budgetCycleStartDays[_activeBookId] ?? naturalMonthStartDay,
  );

  /// 当前账本是否启用了自定义预算周期（起始日 ≠ 1）。文案据此在「本月/本期」间切换。
  bool get budgetCycleIsCustom => budgetCycleStartDay != naturalMonthStartDay;

  void setBudgetCycleStartDay(int day) {
    final clamped = clampBudgetCycleStartDay(day);
    if (clamped == budgetCycleStartDay) {
      return;
    }
    // 默认值不落键：与「未设置」等价，备份/存储里不留冗余项。
    if (clamped == naturalMonthStartDay) {
      _budgetCycleStartDays.remove(_activeBookId);
    } else {
      _budgetCycleStartDays[_activeBookId] = clamped;
    }
    _persistBudgetCycleStartDays();
    notifyListeners();
  }

  /// 键月为 [keyMonth] 的预算周期窗口（当前账本起始日）。预算的存取键仍是键月
  /// `yyyy-MM`（见 [monthlyBudget]），此窗口决定「这一期」聚合哪些交易。
  DateWindow budgetWindow(DateTime keyMonth) =>
      budgetCycleOfKeyMonth(keyMonth, budgetCycleStartDay);

  /// 包含 [date] 的预算周期的键月（当前账本起始日）——面板/小组件用「现在」换算
  /// 出应读取哪一期的预算。
  DateTime budgetKeyMonthFor(DateTime date) =>
      budgetCycleKeyMonthFor(date, budgetCycleStartDay);

  /// 当前账本的「默认月预算」：设一次每月自动沿用（0 = 未设默认）。存于预算表的
  /// 哨兵键 `bookId:default`，与逐月键 `bookId:yyyy-MM` 天然不冲突。
  double get defaultMonthlyBudget =>
      _monthlyBudgets[_defaultMonthlyBudgetKey(_activeBookId)] ?? 0;

  double _normalizeActiveBaseAmount(double amount) =>
      normalizeCurrencyAmount(amount, activeBook.baseCurrencyCode);

  void setDefaultMonthlyBudget(double amount) {
    final normalized = _normalizeActiveBaseAmount(amount);
    final key = _defaultMonthlyBudgetKey(_activeBookId);
    if (normalized <= 0) {
      _monthlyBudgets.remove(key);
    } else {
      _monthlyBudgets[key] = normalized;
    }
    _persistBudgets();
    notifyListeners();
  }

  /// 某键月的实际月预算：单月覆盖优先，否则沿用默认月预算，都没有则 0。
  double monthlyBudget(DateTime month) =>
      _monthlyBudgets['$_activeBookId:${_monthKey(month)}'] ??
      defaultMonthlyBudget;

  /// 该键月是否设了单独的覆盖值（用于区分「沿用默认」与「本月单独」）。
  bool monthlyBudgetIsOverride(DateTime month) =>
      _monthlyBudgets.containsKey('$_activeBookId:${_monthKey(month)}');

  /// 设某键月的单月覆盖（amount 可为 0，表示「本月不设预算」；恢复默认沿用请用
  /// [clearMonthlyBudgetOverride]）。
  void setMonthlyBudget(DateTime month, double amount) {
    final normalized = _normalizeActiveBaseAmount(amount);
    _monthlyBudgets['$_activeBookId:${_monthKey(month)}'] = normalized <= 0
        ? 0
        : normalized;
    _persistBudgets();
    notifyListeners();
  }

  /// 清除某键月的单月覆盖，回到沿用默认月预算。
  void clearMonthlyBudgetOverride(DateTime month) {
    if (_monthlyBudgets.remove('$_activeBookId:${_monthKey(month)}') != null) {
      _persistBudgets();
      notifyListeners();
    }
  }

  /// 当前账本某分类的「默认预算」：设一次每月自动沿用（0 = 未设）。
  double defaultCategoryBudget(String categoryId) =>
      _categoryBudgets[_defaultCategoryBudgetKey(_activeBookId, categoryId)] ??
      0;

  void setDefaultCategoryBudget(String categoryId, double amount) {
    final normalized = _normalizeActiveBaseAmount(amount);
    final key = _defaultCategoryBudgetKey(_activeBookId, categoryId);
    if (normalized <= 0) {
      _categoryBudgets.remove(key);
    } else {
      _categoryBudgets[key] = normalized;
    }
    _persistCategoryBudgets();
    notifyListeners();
  }

  /// 某键月某分类的实际预算：单月覆盖优先，否则沿用分类默认，都没有则 0。
  double categoryBudget(DateTime month, String categoryId) =>
      _categoryBudgets[_categoryBudgetKey(_activeBookId, month, categoryId)] ??
      defaultCategoryBudget(categoryId);

  /// 该键月的分类是否设置了单独覆盖值。只检查当前账本的单期键，不把默认预算
  /// 视为覆盖，供总览页区分「本期单独」与「沿用默认」。
  bool categoryBudgetIsOverride(DateTime month, String categoryId) =>
      _categoryBudgets.containsKey(
        _categoryBudgetKey(_activeBookId, month, categoryId),
      );

  /// 设某键月某分类的单月覆盖（0 = 移除覆盖，回到沿用分类默认）。
  void setCategoryBudget(DateTime month, String categoryId, double amount) {
    final normalized = _normalizeActiveBaseAmount(amount);
    final key = _categoryBudgetKey(_activeBookId, month, categoryId);
    if (normalized <= 0) {
      _categoryBudgets.remove(key);
    } else {
      _categoryBudgets[key] = normalized;
    }
    _persistCategoryBudgets();
    notifyListeners();
  }

  /// 清除某键月的分类单期覆盖，恢复沿用分类默认预算；没有默认值时回落 0。
  void clearCategoryBudgetOverride(DateTime month, String categoryId) {
    final key = _categoryBudgetKey(_activeBookId, month, categoryId);
    if (_categoryBudgets.remove(key) != null) {
      _persistCategoryBudgets();
      notifyListeners();
    }
  }

  /// 当前账本的每日花销上限（0 表示未设置）。
  double dailyBudget() {
    return _dailyBudgets[_activeBookId] ?? 0;
  }

  void setDailyBudget(double amount) {
    final normalized = _normalizeActiveBaseAmount(amount);
    if (normalized <= 0) {
      _dailyBudgets.remove(_activeBookId);
    } else {
      _dailyBudgets[_activeBookId] = normalized;
    }
    _persistDailyBudgets();
    notifyListeners();
  }

  void setThemePreference(ThemePreference preference) {
    if (_themePreference == preference) {
      return;
    }
    _themePreference = preference;
    themePreferenceListenable.value = preference;
    _store.write(_themeKey, preference.name);
    notifyListeners();
  }

  LocalePreference get localePreference => _localePreference;

  /// 语言是设备本地偏好：不进 JSON 备份，初始化数据时保留。
  void setLocalePreference(LocalePreference preference) {
    if (_localePreference == preference) {
      return;
    }
    _localePreference = preference;
    localePreferenceListenable.value = preference;
    _store.write(_localeKey, preference.name);
    notifyListeners();
  }

  ReminderSettings get reminderSettings => _reminderSettings;

  /// 记账提醒配置变化时的回调（由 `main.dart` 注入，用于重排本地通知）。
  ValueChanged<ReminderSettings>? onReminderChanged;

  void setReminderSettings(ReminderSettings settings) {
    if (_reminderSettings == settings) {
      return;
    }
    _reminderSettings = settings;
    _store.write(_reminderKey, settings.encode());
    notifyListeners();
    onReminderChanged?.call(settings);
  }

  Future<bool> saveReminderSettingsDraft(ReminderSettings settings) async {
    try {
      await _store.writeAndFlush(_reminderKey, settings.encode());
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return false;
    }
    _reminderSettings = settings;
    notifyListeners();
    onReminderChanged?.call(settings);
    return true;
  }

  void setHapticsEnabled(bool enabled) {
    if (_hapticsEnabled == enabled) {
      return;
    }
    _hapticsEnabled = enabled;
    _store.write(_hapticsKey, enabled.toString());
    notifyListeners();
  }

  /// 首页 FAB（记一笔）的行为：手动记账（默认）或 AI 对话记账。设备本地偏好，
  /// 不进 JSON 备份、初始化保留。
  FabActionMode get fabActionMode => _fabActionMode;

  void setFabActionMode(FabActionMode mode) {
    _fabActionMode = mode;
    _store.write(_fabActionKey, mode.name);
    notifyListeners();
  }

  /// 金额数字键盘的数字排列。设备本地偏好，不影响账目数据。
  NumberPadLayout get numberPadLayout => _numberPadLayout;

  /// 首页走势卡片的自定义配置（各槽展示的指标、曲线序列、标题）。设备本地显示偏好，
  /// 不进 JSON 备份、初始化时保留。
  HomeTrendConfig get homeTrendConfig => _homeTrendConfig;

  void setHomeTrendConfig(HomeTrendConfig config) {
    _homeTrendConfig = config;
    _store.write(_homeTrendKey, config.encode());
    notifyListeners();
  }

  void resetHomeTrendConfig() {
    _homeTrendConfig = HomeTrendConfig.defaults;
    _store.delete(_homeTrendKey);
    notifyListeners();
  }

  Future<bool> saveBudgetSettingsDraft({
    required double defaultMonthlyBudget,
    required double dailyBudget,
    required int cycleStartDay,
    required Map<String, double> defaultCategoryBudgets,
  }) async {
    final normalizedMonthly = _normalizeActiveBaseAmount(defaultMonthlyBudget);
    final normalizedDaily = _normalizeActiveBaseAmount(dailyBudget);
    final nextMonthly = Map<String, double>.of(_monthlyBudgets);
    final monthlyKey = _defaultMonthlyBudgetKey(_activeBookId);
    if (normalizedMonthly <= 0) {
      nextMonthly.remove(monthlyKey);
    } else {
      nextMonthly[monthlyKey] = normalizedMonthly;
    }

    final nextCategories = Map<String, double>.of(_categoryBudgets)
      ..removeWhere(
        (key, _) =>
            key.startsWith('$_activeBookId:$_budgetDefaultMonthSegment:'),
      );
    for (final entry in defaultCategoryBudgets.entries) {
      final normalized = _normalizeActiveBaseAmount(entry.value);
      if (normalized > 0) {
        nextCategories[_defaultCategoryBudgetKey(_activeBookId, entry.key)] =
            normalized;
      }
    }

    final nextDaily = Map<String, double>.of(_dailyBudgets);
    if (normalizedDaily <= 0) {
      nextDaily.remove(_activeBookId);
    } else {
      nextDaily[_activeBookId] = normalizedDaily;
    }

    final clampedStartDay = clampBudgetCycleStartDay(cycleStartDay);
    final nextCycleDays = Map<String, int>.of(_budgetCycleStartDays);
    if (clampedStartDay == naturalMonthStartDay) {
      nextCycleDays.remove(_activeBookId);
    } else {
      nextCycleDays[_activeBookId] = clampedStartDay;
    }
    final previousCycleJson = jsonEncode(_budgetCycleStartDays);
    try {
      await _store.writeAndFlush(_budgetCycleKey, jsonEncode(nextCycleDays));
      await _repository.saveBudgetSettings(
        monthlyBudgets: nextMonthly,
        categoryBudgets: nextCategories,
        dailyBudgets: nextDaily,
      );
    } catch (error, stackTrace) {
      try {
        await _store.writeAndFlush(_budgetCycleKey, previousCycleJson);
      } catch (_) {
        // 原错误已上报；回滚偏好也失败时保留同一条用户提示，避免重复噪音。
      }
      _handlePersistError(error, stackTrace);
      return false;
    }

    _monthlyBudgets
      ..clear()
      ..addAll(nextMonthly);
    _categoryBudgets
      ..clear()
      ..addAll(nextCategories);
    _dailyBudgets
      ..clear()
      ..addAll(nextDaily);
    _budgetCycleStartDays
      ..clear()
      ..addAll(nextCycleDays);
    notifyListeners();
    return true;
  }

  Future<bool> saveHomeTrendConfigDraft(HomeTrendConfig config) async {
    try {
      await _store.writeAndFlush(_homeTrendKey, config.encode());
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return false;
    }
    _homeTrendConfig = config;
    notifyListeners();
    return true;
  }

  /// 当前账本的默认付款账户 id；未设置、或该账户已删除/隐藏时返回 null。设备本地
  /// 偏好，不进 JSON 备份、初始化时随账户一起清空。记账（手动/AI 未识别账户时）
  /// 用它作默认账户。
  String? get defaultAccountId {
    final id = _defaultAccountIds[_activeBookId];
    if (id == null || id.isEmpty) {
      return null;
    }
    final valid = _accounts.any(
      (account) =>
          account.id == id &&
          account.bookId == _activeBookId &&
          !account.hidden,
    );
    return valid ? id : null;
  }

  void setDefaultAccountId(String? accountId) {
    if (accountId == null || accountId.isEmpty) {
      _defaultAccountIds.remove(_activeBookId);
    } else {
      _defaultAccountIds[_activeBookId] = accountId;
    }
    _persistDefaultAccounts();
    notifyListeners();
  }

  /// 账户编辑页显式提交默认账户偏好，KV 写入成功后才更新内存。
  Future<bool> saveDefaultAccountDraft(String? accountId) async {
    final next = Map<String, String>.of(_defaultAccountIds);
    if (accountId == null || accountId.isEmpty) {
      next.remove(_activeBookId);
    } else {
      next[_activeBookId] = accountId;
    }
    try {
      await _store.writeAndFlush(_defaultAccountKey, jsonEncode(next));
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return false;
    }
    _defaultAccountIds
      ..clear()
      ..addAll(next);
    notifyListeners();
    return true;
  }

  /// 是否强制所有金额展示两位小数（`12` → `12.00`）。全局显示偏好（不分账本），
  /// 进 JSON 备份、初始化保留。经顶层量 [amountForceTwoDecimals] 让无 context 的金额
  /// 格式化纯函数（小组件、通知、`series_math` 等）同步生效。
  bool get amountForceTwoDecimals => _amountForceTwoDecimals;

  void setAmountForceTwoDecimals(bool value) {
    _amountForceTwoDecimals = value;
    amount_format.amountForceTwoDecimals = value;
    _store.write(_amountFormatKey, value.toString());
    notifyListeners();
  }

  MoneyUnitStyle get moneyUnitStyle => _moneyUnitStyle;

  bool get hideUnitInSingleCurrency => _hideUnitInSingleCurrency;

  void setMoneyDisplayPreferences({
    required MoneyUnitStyle unitStyle,
    required bool hideInSingleCurrency,
  }) {
    if (_moneyUnitStyle == unitStyle &&
        _hideUnitInSingleCurrency == hideInSingleCurrency) {
      return;
    }
    _moneyUnitStyle = unitStyle;
    _hideUnitInSingleCurrency = hideInSingleCurrency;
    _store.write(_moneyUnitStyleKey, unitStyle.name);
    _store.write(_hideSingleCurrencyUnitKey, hideInSingleCurrency.toString());
    notifyListeners();
  }

  /// 记账自动识别（`category_suggest.dart` 的 `suggestEntry`）总开关：关闭后手动记账
  /// 页不再按历史自动填充类型/分类/标签/备注。全局偏好（不分账本），**默认开**，
  /// 进 JSON 备份、初始化保留。AI 草稿与导入草稿本就不走自动识别，不受此开关影响。
  bool get autoSuggestEnabled => _autoSuggestEnabled;

  /// 交易列表是否在每行显示该账户当时的结余。全局偏好（不分账本），**默认关**，
  /// 进 JSON 备份、初始化保留。
  bool get showRunningBalance => _showRunningBalance;

  /// 交易 id → 该账户在这笔交易之后的余额（当前账本口径）。
  /// 惰性计算并随派生视图一起失效；只有开启「显示逐笔结余」时才会被读取。
  Map<String, double> get balanceAfterEntry => _balanceAfterEntryCache ??=
      accountBalanceAfterEntry(accounts: accounts, entries: entries);

  void setAutoSuggestEnabled(bool value) {
    if (_autoSuggestEnabled == value) {
      return;
    }
    _autoSuggestEnabled = value;
    _store.write(_autoSuggestKey, value.toString());
    notifyListeners();
  }

  /// 主设置页一次性提交显示与记账偏好；所有 KV 写入完成后才更新 Controller。
  Future<bool> saveAppPreferencesDraft({
    required ThemePreference themePreference,
    required LocalePreference localePreference,
    required bool hapticsEnabled,
    required bool amountForceTwoDecimals,
    required MoneyUnitStyle moneyUnitStyle,
    required bool hideUnitInSingleCurrency,
    required FabActionMode fabActionMode,
    required String? defaultAccountId,
    required bool autoSuggestEnabled,
    required bool showRunningBalance,
    required NumberPadLayout numberPadLayout,
  }) async {
    final nextDefaultAccounts = Map<String, String>.of(_defaultAccountIds);
    if (defaultAccountId == null || defaultAccountId.isEmpty) {
      nextDefaultAccounts.remove(_activeBookId);
    } else {
      nextDefaultAccounts[_activeBookId] = defaultAccountId;
    }
    try {
      await _store.writeAndFlush(_themeKey, themePreference.name);
      await _store.writeAndFlush(_localeKey, localePreference.name);
      await _store.writeAndFlush(_hapticsKey, hapticsEnabled.toString());
      await _store.writeAndFlush(
        _amountFormatKey,
        amountForceTwoDecimals.toString(),
      );
      await _store.writeAndFlush(_moneyUnitStyleKey, moneyUnitStyle.name);
      await _store.writeAndFlush(
        _hideSingleCurrencyUnitKey,
        hideUnitInSingleCurrency.toString(),
      );
      await _store.writeAndFlush(_fabActionKey, fabActionMode.name);
      await _store.writeAndFlush(
        _defaultAccountKey,
        jsonEncode(nextDefaultAccounts),
      );
      await _store.writeAndFlush(
        _autoSuggestKey,
        autoSuggestEnabled.toString(),
      );
      await _store.writeAndFlush(
        _runningBalanceKey,
        showRunningBalance.toString(),
      );
      await _store.writeAndFlush(_numberPadLayoutKey, numberPadLayout.name);
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return false;
    }

    _themePreference = themePreference;
    _localePreference = localePreference;
    _hapticsEnabled = hapticsEnabled;
    _amountForceTwoDecimals = amountForceTwoDecimals;
    amount_format.amountForceTwoDecimals = amountForceTwoDecimals;
    _moneyUnitStyle = moneyUnitStyle;
    _hideUnitInSingleCurrency = hideUnitInSingleCurrency;
    _fabActionMode = fabActionMode;
    _defaultAccountIds
      ..clear()
      ..addAll(nextDefaultAccounts);
    _autoSuggestEnabled = autoSuggestEnabled;
    _showRunningBalance = showRunningBalance;
    _numberPadLayout = numberPadLayout;
    themePreferenceListenable.value = themePreference;
    localePreferenceListenable.value = localePreference;
    notifyListeners();
    return true;
  }

  /// AI 对话记账的连接配置（请求地址/API Key/模型）。设备本地偏好，不进 JSON
  /// 备份、初始化保留（API Key 明文存本机）。
  AiSettings get aiSettings => _aiSettings;

  void setAiSettings(AiSettings settings) {
    if (_aiSettings == settings) {
      return;
    }
    _aiSettings = settings;
    if (_aiCapabilityProfile?.matches(settings) == false ||
        !settings.isConfigured) {
      setAiCapabilityProfile(null);
    }
    if (settings.isConfigured ||
        settings.baseUrl.isNotEmpty ||
        settings.apiKey.isNotEmpty ||
        settings.model.isNotEmpty) {
      _store.write(_aiSettingsKey, settings.encode());
    } else {
      _store.delete(_aiSettingsKey);
    }
    notifyListeners();
  }

  /// Persists the AI connection editor draft before publishing it in memory.
  Future<bool> saveAiSettingsDraft(
    AiSettings settings, {
    AiCapabilityProfile? detectedProfile,
  }) async {
    try {
      if (settings.isConfigured ||
          settings.baseUrl.isNotEmpty ||
          settings.apiKey.isNotEmpty ||
          settings.model.isNotEmpty) {
        await _store.writeAndFlush(_aiSettingsKey, settings.encode());
      } else {
        await _store.deleteAndFlush(_aiSettingsKey);
      }
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return false;
    }

    _aiSettings = settings;
    final nextProfile = detectedProfile?.matches(settings) == true
        ? detectedProfile
        : _aiCapabilityProfile?.matches(settings) == true
        ? _aiCapabilityProfile
        : null;
    setAiCapabilityProfile(nextProfile);
    notifyListeners();
    return true;
  }

  AiCapabilityProfile? get aiCapabilityProfile => _aiCapabilityProfile;

  /// 保存不含密钥的 AI 能力缓存；仅更新窄粒度 notifier。
  void setAiCapabilityProfile(AiCapabilityProfile? profile) {
    if (_aiCapabilityProfile == profile) return;
    _aiCapabilityProfile = profile;
    if (profile == null) {
      _store.delete(_aiCapabilitiesKey);
    } else {
      _store.write(_aiCapabilitiesKey, profile.encode());
    }
    aiCapabilityListenable.value = profile;
  }

  /// AI 对话查询的聊天记录（每条 `{role, content, displays?}`，助手消息可带序列化的
  /// 结果卡片）。设备本地、不进 JSON 备份、初始化保留。
  List<Map<String, Object?>> get aiChatHistory =>
      List<Map<String, Object?>>.unmodifiable(_aiChatHistory);

  /// 覆盖保存聊天记录。不 notifyListeners——历史无响应式依赖，只由聊天页读写，
  /// 避免每条消息触发全应用重建。
  void setAiChatHistory(List<Map<String, Object?>> history) {
    _aiChatHistory = List<Map<String, Object?>>.from(history);
    if (_aiChatHistory.isEmpty) {
      _store.delete(_aiChatHistoryKey);
    } else {
      _store.write(_aiChatHistoryKey, jsonEncode(_aiChatHistory));
    }
  }

  /// 清空聊天记录。
  void clearAiChatHistory() => setAiChatHistory(<Map<String, Object?>>[]);

  /// 用户是否已同意隐私政策与用户协议（首启动前为 false）。
  bool get onboardingCompleted => _onboardingCompleted;

  /// 标记新用户引导已完成（只走一次，初始化数据不清除）。
  void completeOnboarding() {
    if (_onboardingCompleted) {
      return;
    }
    _onboardingCompleted = true;
    _store.write(_onboardingKey, 'true');
    notifyListeners();
  }

  bool get privacyConsentAccepted => _privacyConsentAccepted;

  /// 记录用户已同意隐私政策与用户协议。一经同意即持久化，重启后不再询问。
  Future<bool> acceptPrivacyConsent() async {
    if (_privacyConsentAccepted) {
      return true;
    }
    try {
      await _store.writeAndFlush(_privacyConsentKey, 'true');
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return false;
    }
    _privacyConsentAccepted = true;
    notifyListeners();
    return true;
  }

  /// 当前应用锁配置（含锁类型、加盐哈希、生物识别开关）。
  AppLockConfig get appLockConfig => _appLockConfig;

  /// 是否已启用应用锁（PIN 或图案）。
  bool get appLockEnabled => _appLockConfig.enabled;

  /// 当前锁类型。
  AppLockKind get appLockKind => _appLockConfig.kind;

  /// 是否开启了生物识别快捷解锁（仅在已启用应用锁时有意义）。
  bool get biometricUnlockEnabled =>
      _appLockConfig.enabled && _appLockConfig.biometricEnabled;

  /// 设置或修改应用锁密钥（PIN 数字串或图案点序列）。生成新盐并落库，不存明文。
  Future<bool> setAppLock({
    required AppLockKind kind,
    required String secret,
  }) async {
    assert(kind != AppLockKind.none, 'setAppLock 不能用于关闭应用锁');
    final next = AppLockConfig.fromSecret(
      kind: kind,
      secret: secret,
      biometricEnabled: _appLockConfig.biometricEnabled,
    );
    try {
      await _store.writeAndFlush(_appLockKey, jsonEncode(next.toJson()));
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return false;
    }
    _appLockConfig = next;
    notifyListeners();
    onAppLockChanged?.call(_appLockConfig.enabled);
    return true;
  }

  /// 校验输入的密钥是否匹配当前应用锁。
  bool verifyAppLock(String input) => _appLockConfig.verify(input);

  /// 关闭应用锁（同时关闭生物识别）。
  Future<bool> disableAppLock() async {
    if (!_appLockConfig.enabled) {
      return true;
    }
    try {
      await _store.deleteAndFlush(_appLockKey);
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return false;
    }
    _appLockConfig = const AppLockConfig.none();
    notifyListeners();
    onAppLockChanged?.call(false);
    return true;
  }

  /// 开关生物识别快捷解锁。仅在已启用应用锁时生效。
  Future<bool> setBiometricUnlockEnabled(bool enabled) async {
    if (!_appLockConfig.enabled || _appLockConfig.biometricEnabled == enabled) {
      return _appLockConfig.enabled;
    }
    final next = _appLockConfig.copyWith(biometricEnabled: enabled);
    try {
      await _store.writeAndFlush(_appLockKey, jsonEncode(next.toJson()));
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return false;
    }
    _appLockConfig = next;
    notifyListeners();
    return true;
  }

  void toggleAssetAccountViewMode() {
    _assetAccountViewMode = _assetAccountViewMode == AssetAccountViewMode.group
        ? AssetAccountViewMode.type
        : AssetAccountViewMode.group;
    _store.write(_assetViewModeKey, _assetAccountViewMode.name);
    notifyListeners();
  }

  /// Saves the asset page's appearance and ordering as one explicit editor
  /// submission. Orders are scoped to the active book and both view modes;
  /// unrelated books retain their existing preferences.
  Future<bool> saveAssetDisplayDraft({
    required AssetAccountViewMode viewMode,
    required String coverUrl,
    required Map<AssetAccountViewMode, List<String>> sectionOrders,
    required Map<AssetAccountViewMode, Map<String, List<String>>> accountOrders,
    required Set<String> collapsedSections,
  }) async {
    final activeAccountIds = accounts.map((account) => account.id).toSet();
    for (final mode in AssetAccountViewMode.values) {
      final sectionIds = sectionOrders[mode];
      final bySection = accountOrders[mode];
      if (sectionIds == null ||
          bySection == null ||
          sectionIds.toSet().length != sectionIds.length) {
        return false;
      }
      for (final order in bySection.values) {
        if (order.toSet().length != order.length ||
            order.any((id) => !activeAccountIds.contains(id))) {
          return false;
        }
      }
    }

    final nextCollapsedSections = <String>{..._collapsedAssetSections}
      ..removeWhere((key) => key.startsWith('$_activeBookId:'));
    for (final key in collapsedSections) {
      final separator = key.indexOf(':');
      if (separator <= 0 || separator == key.length - 1) {
        return false;
      }
      final mode = key.substring(0, separator);
      if (!AssetAccountViewMode.values.any((item) => item.name == mode)) {
        return false;
      }
      nextCollapsedSections.add('$_activeBookId:$key');
    }

    final nextSectionOrders = Map<String, List<String>>.fromEntries(
      _assetSectionOrders.entries.map(
        (entry) => MapEntry(entry.key, List<String>.of(entry.value)),
      ),
    );
    final nextAccountOrders = Map<String, List<String>>.fromEntries(
      _assetAccountOrders.entries.map(
        (entry) => MapEntry(entry.key, List<String>.of(entry.value)),
      ),
    );
    for (final mode in AssetAccountViewMode.values) {
      nextSectionOrders[_assetSectionOrderKeyForMode(_activeBookId, mode)] =
          List<String>.of(sectionOrders[mode]!);
      final prefix = '$_activeBookId:${mode.name}:';
      nextAccountOrders.removeWhere((key, _) => key.startsWith(prefix));
      for (final entry in accountOrders[mode]!.entries) {
        nextAccountOrders[_assetSectionKey(_activeBookId, mode, entry.key)] =
            List<String>.of(entry.value);
      }
    }

    final normalizedCover = coverUrl.trim();
    final previous = <String, String?>{
      _assetCoverKey: _store.read(_assetCoverKey),
      _assetViewModeKey: _store.read(_assetViewModeKey),
      _assetAccountOrderKey: _store.read(_assetAccountOrderKey),
      _assetSectionOrderKey: _store.read(_assetSectionOrderKey),
      _assetSectionCollapsedKey: _store.read(_assetSectionCollapsedKey),
    };
    try {
      if (normalizedCover.isEmpty) {
        await _store.deleteAndFlush(_assetCoverKey);
      } else {
        await _store.writeAndFlush(_assetCoverKey, normalizedCover);
      }
      await _store.writeAndFlush(_assetViewModeKey, viewMode.name);
      await _store.writeAndFlush(
        _assetAccountOrderKey,
        jsonEncode(nextAccountOrders),
      );
      await _store.writeAndFlush(
        _assetSectionOrderKey,
        jsonEncode(nextSectionOrders),
      );
      await _store.writeAndFlush(
        _assetSectionCollapsedKey,
        jsonEncode(nextCollapsedSections.toList()),
      );
    } catch (error, stackTrace) {
      for (final entry in previous.entries) {
        try {
          if (entry.value == null) {
            await _store.deleteAndFlush(entry.key);
          } else {
            await _store.writeAndFlush(entry.key, entry.value!);
          }
        } catch (_) {
          // The original error is reported below; rollback is best-effort.
        }
      }
      _handlePersistError(error, stackTrace);
      return false;
    }

    _assetAccountViewMode = viewMode;
    _assetCoverUrl = normalizedCover;
    _assetAccountOrders
      ..clear()
      ..addAll(nextAccountOrders);
    _assetSectionOrders
      ..clear()
      ..addAll(nextSectionOrders);
    _collapsedAssetSections
      ..clear()
      ..addAll(nextCollapsedSections);
    notifyListeners();
    return true;
  }

  bool isAssetSectionCollapsed({
    required AssetAccountViewMode mode,
    required String sectionId,
  }) {
    return _collapsedAssetSections.contains(
      _assetSectionKey(_activeBookId, mode, sectionId),
    );
  }

  void toggleAssetSectionCollapsed({
    required AssetAccountViewMode mode,
    required String sectionId,
  }) {
    final key = _assetSectionKey(_activeBookId, mode, sectionId);
    if (!_collapsedAssetSections.add(key)) {
      _collapsedAssetSections.remove(key);
    }
    _persistAssetSectionCollapsed();
    notifyListeners();
  }

  List<Account> sortedAccountsForAssetSection({
    required AssetAccountViewMode mode,
    required String sectionId,
    required Iterable<Account> accounts,
  }) {
    final sorted = accounts.toList();
    final order =
        _assetAccountOrders[_assetSectionKey(_activeBookId, mode, sectionId)];
    if (order == null || order.isEmpty) {
      sorted.sort(_defaultAccountCompare);
      return sorted;
    }
    final orderIndex = <String, int>{
      for (final item in order.indexed) item.$2: item.$1,
    };
    sorted.sort((a, b) {
      final aIndex = orderIndex[a.id];
      final bIndex = orderIndex[b.id];
      if (aIndex != null && bIndex != null) {
        return aIndex.compareTo(bIndex);
      }
      if (aIndex != null) {
        return -1;
      }
      if (bIndex != null) {
        return 1;
      }
      return _defaultAccountCompare(a, b);
    });
    return sorted;
  }

  void reorderAssetAccounts({
    required AssetAccountViewMode mode,
    required String sectionId,
    required List<Account> accounts,
    required int oldIndex,
    required int newIndex,
  }) {
    if (oldIndex < 0 ||
        oldIndex >= accounts.length ||
        newIndex < 0 ||
        newIndex >= accounts.length) {
      return;
    }
    final next = accounts.toList();
    final moved = next.removeAt(oldIndex);
    next.insert(newIndex, moved);
    _assetAccountOrders[_assetSectionKey(_activeBookId, mode, sectionId)] = next
        .map((account) => account.id)
        .toList();
    _persistAssetAccountOrders();
    notifyListeners();
  }

  List<T> sortedAssetSections<T>({
    required AssetAccountViewMode mode,
    required List<T> sections,
    required String Function(T section) idOf,
  }) {
    final sorted = sections.toList();
    final order =
        _assetSectionOrders[_assetSectionOrderKeyForMode(_activeBookId, mode)];
    if (order == null || order.isEmpty) {
      return sorted;
    }
    final orderIndex = <String, int>{
      for (final item in order.indexed) item.$2: item.$1,
    };
    sorted.sort((a, b) {
      final aIndex = orderIndex[idOf(a)];
      final bIndex = orderIndex[idOf(b)];
      if (aIndex != null && bIndex != null) {
        return aIndex.compareTo(bIndex);
      }
      if (aIndex != null) {
        return -1;
      }
      if (bIndex != null) {
        return 1;
      }
      return 0;
    });
    return sorted;
  }

  void reorderAssetSections<T>({
    required AssetAccountViewMode mode,
    required List<T> sections,
    required String Function(T section) idOf,
    required int oldIndex,
    required int newIndex,
  }) {
    if (oldIndex < 0 ||
        oldIndex >= sections.length ||
        newIndex < 0 ||
        newIndex > sections.length) {
      return;
    }
    final next = sections.toList();
    final moved = next.removeAt(oldIndex);
    next.insert(newIndex.clamp(0, next.length).toInt(), moved);
    _assetSectionOrders[_assetSectionOrderKeyForMode(_activeBookId, mode)] =
        next.map(idOf).toList();
    _persistAssetSectionOrders();
    notifyListeners();
  }

  /// 页面的面板配置(含关闭项),顺序即渲染顺序。
  List<PagePanelSetting> panelSettings(PanelPageKind page) {
    return List<PagePanelSetting>.unmodifiable(_pagePanels[page]!);
  }

  /// 页面当前开启的面板 id,按渲染顺序返回。
  List<String> enabledPanelIds(PanelPageKind page) {
    return _pagePanels[page]!
        .where((item) => item.enabled)
        .map((item) => item.id)
        .toList(growable: false);
  }

  /// 开关面板;为避免页面变空,最后一个开启的面板不允许关闭,返回 false。
  bool setPanelEnabled(PanelPageKind page, String panelId, bool enabled) {
    final panels = _pagePanels[page]!;
    final index = panels.indexWhere((item) => item.id == panelId);
    if (index == -1 || panels[index].enabled == enabled) {
      return true;
    }
    if (!enabled && panels.where((item) => item.enabled).length <= 1) {
      return false;
    }
    panels[index] = panels[index].copyWith(enabled: enabled);
    _persistPagePanels(page);
    notifyListeners();
    return true;
  }

  /// 恢复页面面板为默认顺序并全部开启。
  void resetPanels(PanelPageKind page) {
    _pagePanels[page] = _defaultPanelSettings(page.specs);
    _persistPagePanels(page);
    notifyListeners();
  }

  void reorderPanels(PanelPageKind page, int oldIndex, int newIndex) {
    final panels = _pagePanels[page]!;
    if (oldIndex < 0 ||
        oldIndex >= panels.length ||
        newIndex < 0 ||
        newIndex > panels.length) {
      return;
    }
    final moved = panels.removeAt(oldIndex);
    panels.insert(newIndex.clamp(0, panels.length).toInt(), moved);
    _persistPagePanels(page);
    notifyListeners();
  }

  Future<bool> savePanelSettingsDraft(
    PanelPageKind page,
    List<PagePanelSetting> panels,
  ) async {
    final normalized = _normalizePanelSettings(panels, page.specs);
    try {
      await _store.writeAndFlush(
        _panelsKeyFor(page),
        jsonEncode(normalized.map((item) => item.toJson()).toList()),
      );
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return false;
    }
    _pagePanels[page] = normalized;
    notifyListeners();
    return true;
  }

  // 交易列表始终维护 occurredAt 倒序;同一时刻用 id 决出稳定顺序。
  VoidCallback? onEntryAdded;

  void addEntry(LedgerEntry entry) {
    _entries.insert(0, entry);
    _entries.sort(_compareEntriesLatestFirst);
    _persistEntries();
    notifyListeners();
    onEntryAdded?.call();
  }

  /// Atomically persists an entry together with its refunds and attachments.
  ///
  /// [entry.refundedBaseAmount] is ignored and derived again from the settled
  /// refunds, preventing an editor's stale entry snapshot from overwriting the
  /// controller-managed cache.
  Future<EntrySaveResult> saveEntryAggregateDraftResult({
    required LedgerEntry entry,
    required bool isNew,
    List<LedgerEntry> refunds = const <LedgerEntry>[],
    List<Attachment> attachments = const <Attachment>[],
    String? rememberRateCurrencyCode,
    double? rememberRateToBase,
    DateTime? rememberRateEffectiveDate,
  }) async {
    final currentIndex = _entries.indexWhere((item) => item.id == entry.id);
    if ((isNew && currentIndex != -1) || (!isNew && currentIndex == -1)) {
      return const EntrySaveValidationFailure(EntryValidationCode.staleDraft);
    }
    if (!isNew && _entries[currentIndex].bookId != entry.bookId) {
      return const EntrySaveValidationFailure(EntryValidationCode.staleDraft);
    }
    final book = ledgerBooks
        .where((item) => item.id == entry.bookId)
        .firstOrNull;
    if (book == null || !_validEntryCurrencyAmounts(entry, book)) {
      return const EntrySaveValidationFailure(
        EntryValidationCode.invalidAmounts,
      );
    }
    if (refunds.any(
      (refund) =>
          refund.type != EntryType.refund ||
          refund.refundOf != entry.id ||
          refund.bookId != entry.bookId ||
          refund.currencyCode != entry.currencyCode ||
          refund.amount <= 0 ||
          !_validEntryCurrencyAmounts(refund, book),
    )) {
      return const EntrySaveValidationFailure(
        EntryValidationCode.invalidRefund,
      );
    }
    if (attachments.any((attachment) => attachment.entryId != entry.id)) {
      return const EntrySaveValidationFailure(
        EntryValidationCode.invalidAttachments,
      );
    }
    final refundTotal = refunds.fold<double>(
      0,
      (total, refund) => total + refund.amount,
    );
    final refundTolerance = currencyAmountTolerance(entry.currencyCode);
    if (entry.type != EntryType.expense && refunds.isNotEmpty ||
        refundTotal > entry.amount + refundTolerance) {
      return const EntrySaveValidationFailure(
        EntryValidationCode.refundExceedsExpense,
      );
    }

    final existingEntryIds = _entries.map((item) => item.id).toSet();
    final hasNewEntry =
        isNew || refunds.any((refund) => !existingEntryIds.contains(refund.id));
    final nextEntries = <LedgerEntry>[];
    for (final current in _entries) {
      if (current.id == entry.id) {
        nextEntries.add(entry.copyWith(refundedBaseAmount: 0));
      } else if (current.type == EntryType.refund &&
          current.refundOf == entry.id) {
        continue;
      } else {
        nextEntries.add(current);
      }
    }
    if (isNew) {
      nextEntries.add(entry.copyWith(refundedBaseAmount: 0));
    }
    nextEntries.addAll(refunds);

    final settledByExpense = <String, double>{};
    for (final current in nextEntries) {
      if (current.isSettledRefund && current.refundOf != null) {
        settledByExpense[current.refundOf!] =
            (settledByExpense[current.refundOf!] ?? 0) + current.baseAmount;
      }
    }
    for (var i = 0; i < nextEntries.length; i++) {
      final current = nextEntries[i];
      if (current.type != EntryType.expense) {
        continue;
      }
      final refundedBaseAmount = (settledByExpense[current.id] ?? 0)
          .clamp(0.0, current.baseAmount)
          .toDouble();
      nextEntries[i] = current.copyWith(refundedBaseAmount: refundedBaseAmount);
    }
    final aggregateEntries = nextEntries
        .where(
          (current) => current.id == entry.id || current.refundOf == entry.id,
        )
        .toList(growable: false);
    final aggregateIssue = validateLedgerEntries(
      books: <LedgerBook>[book],
      accounts: _accounts.where((account) => account.bookId == book.id),
      entries: aggregateEntries,
      allowMissingAccounts: !isNew,
      requireMinorUnitNormalization: true,
    );
    if (aggregateIssue != null) {
      return EntrySaveValidationFailure(
        aggregateIssue.code == LedgerDataValidationCode.invalidRefund ||
                aggregateIssue.code ==
                    LedgerDataValidationCode.refundExceedsExpense ||
                aggregateIssue.code == LedgerDataValidationCode.staleRefundCache
            ? EntryValidationCode.invalidRefund
            : EntryValidationCode.invalidAmounts,
      );
    }
    nextEntries.sort(_compareEntriesLatestFirst);

    final nextAttachments = <Attachment>[
      for (final attachment in _attachments)
        if (attachment.entryId != entry.id) attachment,
      ...attachments,
    ];
    List<ExchangeRate>? nextRates;
    if (rememberRateCurrencyCode != null ||
        rememberRateToBase != null ||
        rememberRateEffectiveDate != null) {
      if (rememberRateCurrencyCode == null ||
          rememberRateToBase == null ||
          rememberRateEffectiveDate == null) {
        return const EntrySaveValidationFailure(
          EntryValidationCode.invalidRememberedRate,
        );
      }
      final code = rememberRateCurrencyCode.trim().toUpperCase();
      final baseCode = book.baseCurrencyCode.toUpperCase();
      if (book.currencySetupStatus != CurrencySetupStatus.confirmed ||
          !CurrencyCatalog.isSupported(code) ||
          code == baseCode ||
          !isValidExchangeRate(rememberRateToBase)) {
        return const EntrySaveValidationFailure(
          EntryValidationCode.invalidRememberedRate,
        );
      }
      final effectiveDate = dateOnly(rememberRateEffectiveDate);
      final existingIndex = _exchangeRates.indexWhere(
        (rate) =>
            rate.bookId == entry.bookId &&
            rate.baseCurrencyCode == baseCode &&
            rate.currencyCode == code &&
            currencyDateKey(rate.effectiveDate) ==
                currencyDateKey(effectiveDate),
      );
      final now = DateTime.now();
      final existing = existingIndex == -1
          ? null
          : _exchangeRates[existingIndex];
      final candidate = ExchangeRate(
        id: existing?.id ?? _generateId('rate'),
        bookId: entry.bookId,
        baseCurrencyCode: baseCode,
        currencyCode: code,
        effectiveDate: effectiveDate,
        rateToBase: rememberRateToBase,
        source: ExchangeRateSource.manual,
        createdAt: existing?.createdAt ?? now,
        updatedAt: now,
      );
      nextRates = List<ExchangeRate>.of(_exchangeRates);
      if (existingIndex == -1) {
        nextRates.add(candidate);
      } else {
        nextRates[existingIndex] = candidate;
      }
    }
    try {
      await _repository.saveEntryAggregate(
        entries: nextEntries,
        attachments: nextAttachments,
        exchangeRates: nextRates,
      );
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return const EntrySavePersistenceFailure();
    }

    _entries
      ..clear()
      ..addAll(nextEntries);
    _attachments
      ..clear()
      ..addAll(nextAttachments);
    if (nextRates != null) {
      _exchangeRates
        ..clear()
        ..addAll(nextRates);
    }
    final hadStatementAllocations = _statementRepaymentAllocations.any(
      (allocation) => allocation.repaymentEntryId == entry.id,
    );
    if (hadStatementAllocations) {
      final targetAccount = entry.toAccountId == null
          ? null
          : _accounts
                .where((account) => account.id == entry.toAccountId)
                .firstOrNull;
      if (entry.type == EntryType.transfer &&
          targetAccount != null &&
          targetAccount.type.supportsCredit &&
          entry.toAccountAmount != null) {
        // 目标仍是信用账户时，先回退旧分配，再按新金额重新计算。
        final allocated = await allocateRepaymentToStatements(
          repaymentEntryId: entry.id,
          creditAccountId: targetAccount.id,
          repaymentAmount: entry.toAccountAmount!,
        );
        // 金额全部覆盖已结清账单时 allocated 可能为 0；只有旧分配仍
        // 留在内存中，才说明二次原子写入失败，需要向调用方报告失败。
        if (allocated == 0 &&
            _statementRepaymentAllocations.any(
              (allocation) => allocation.repaymentEntryId == entry.id,
            )) {
          return const EntrySavePersistenceFailure();
        }
      } else if (!await _clearRepaymentAllocations(entry.id)) {
        return const EntrySavePersistenceFailure();
      }
    }
    notifyListeners();
    if (hasNewEntry) {
      onEntryAdded?.call();
    }
    return const EntrySaveSuccess();
  }

  /// 兼容既有调用点的 bool 入口；新页面优先使用 [saveEntryAggregateDraftResult]
  /// 获取稳定的校验失败原因。
  Future<bool> saveEntryAggregateDraft({
    required LedgerEntry entry,
    required bool isNew,
    List<LedgerEntry> refunds = const <LedgerEntry>[],
    List<Attachment> attachments = const <Attachment>[],
    String? rememberRateCurrencyCode,
    double? rememberRateToBase,
    DateTime? rememberRateEffectiveDate,
  }) async {
    final result = await saveEntryAggregateDraftResult(
      entry: entry,
      isNew: isNew,
      refunds: refunds,
      attachments: attachments,
      rememberRateCurrencyCode: rememberRateCurrencyCode,
      rememberRateToBase: rememberRateToBase,
      rememberRateEffectiveDate: rememberRateEffectiveDate,
    );
    return result.isSuccess;
  }

  bool _validEntryCurrencyAmounts(LedgerEntry entry, LedgerBook book) {
    bool positive(double? value) =>
        value != null && value.isFinite && value > 0;
    bool nonNegative(double value) => value.isFinite && value >= 0;
    Account? accountFor(String? id) {
      if (id == null || id.isEmpty) return null;
      return _accounts
          .where(
            (account) => account.id == id && account.bookId == entry.bookId,
          )
          .firstOrNull;
    }

    final code = entry.currencyCode.toUpperCase();
    if (!CurrencyCatalog.isSupported(code) ||
        !positive(entry.amount) ||
        !nonNegative(entry.fee)) {
      return false;
    }
    final account = accountFor(entry.accountId);
    final toAccount = accountFor(entry.toAccountId);
    if (entry.accountId.isEmpty) {
      if (entry.accountAmount != null) return false;
    } else if (!positive(entry.accountAmount)) {
      return false;
    }
    if (entry.toAccountId == null || entry.toAccountId!.isEmpty) {
      if (entry.toAccountAmount != null) return false;
    } else if (!positive(entry.toAccountAmount)) {
      return false;
    }
    if (entry.type == EntryType.transfer) {
      if (!isZeroCurrencyAmount(entry.baseAmount, book.baseCurrencyCode) ||
          entry.accountId.isEmpty &&
              (entry.toAccountId == null || entry.toAccountId!.isEmpty) ||
          account != null && code != account.currencyCode ||
          entry.accountId.isEmpty &&
              toAccount != null &&
              code != toAccount.currencyCode) {
        return false;
      }
    } else if (!positive(entry.baseAmount) || entry.toAccountId != null) {
      return false;
    }
    if (entry.type != EntryType.transfer && entry.fee != 0) {
      return false;
    }
    return true;
  }

  /// 解析 CSV 文本并把交易导入当前账本；匹配不到的账户/分类按名称新建。
  /// 返回导入计划（含成功笔数与逐行错误）供 UI 反馈。解析失败抛 [FormatException]。
  ImportPlan importTransactionsFromCsv(String content) {
    final rows = parseCsv(content);
    final plan = buildImportPlan(
      rows: rows,
      bookId: _activeBookId,
      existingAccounts: accounts,
      existingCategories: categories,
      now: DateTime.now(),
      baseCurrencyCode: activeBook.baseCurrencyCode,
      exchangeRates: exchangeRates,
      existingTags: tags,
      seedEnglish: _seedEnglish,
      existingEntries: entries,
    );
    _applyImportPlan(plan);
    return plan;
  }

  void _applyImportPlan(ImportPlan plan) {
    if (plan.entries.isEmpty) {
      return;
    }
    _accounts.addAll(plan.newAccounts);
    if (plan.newCategories.isNotEmpty) {
      // 首次导入前若仍是默认分类占位，先落地为真实列表再追加。
      if (_categories.isEmpty) {
        _categories.addAll(_seedCategories);
      }
      _categories.addAll(plan.newCategories);
    }
    if (plan.newTags.isNotEmpty) {
      _tags.addAll(plan.newTags);
    }
    final importedById = <String, LedgerEntry>{
      for (final entry in plan.entries) entry.id: entry,
      for (final entry in plan.reconciliationUpdates) entry.id: entry,
    };
    _entries.removeWhere((entry) => importedById.containsKey(entry.id));
    _entries.addAll(importedById.values);
    _entries.sort(_compareEntriesLatestFirst);
    // 导入会同时写账户/分类/交易与核准证据，必须单事务保存，不能留下半套数据。
    _persistAllLedgerData();
    notifyListeners();
    // 导入也新增了交易：触发自动备份与小组件刷新，与手动记账一致。
    onEntryAdded?.call();
  }

  /// 仅解析所选平台账单为导入计划，**不落库**——供导入预览页展示、让用户
  /// 排除/编辑后再确认。解析失败抛 [FormatException]。
  ImportPlan parsePlatformImport(
    ImportPlatform platform,
    Uint8List bytes, {
    Map<String, double> rateOverrides = const <String, double>{},
  }) {
    return buildPlatformImportPlan(
      platform: platform,
      bytes: bytes,
      bookId: _activeBookId,
      existingAccounts: accounts,
      existingCategories: categories,
      now: DateTime.now(),
      baseCurrencyCode: activeBook.baseCurrencyCode,
      exchangeRates: exchangeRates,
      rateOverrides: rateOverrides,
      seedEnglish: _seedEnglish,
      existingEntries: entries,
    );
  }

  /// 落库用户在导入预览页确认（可能已筛选/编辑）的交易子集。
  /// [candidateAccounts]/[candidateCategories] 为解析计划里待新建的账户/分类，
  /// 这里只创建被保留交易**实际引用到**、且当前尚不存在的那些，避免建出用不上的
  /// 空账户/空分类。空交易列表直接返回、不写库。
  bool applyImportEntries({
    required List<LedgerEntry> entries,
    required List<Account> candidateAccounts,
    required List<Category> candidateCategories,
    List<Tag> candidateTags = const <Tag>[],
    Set<String> alwaysCreateAccountIds = const <String>{},
    List<ExchangeRate> candidateExchangeRates = const <ExchangeRate>[],
    List<LedgerEntry> reconciliationUpdates = const <LedgerEntry>[],
  }) {
    if (entries.isEmpty &&
        alwaysCreateAccountIds.isEmpty &&
        reconciliationUpdates.isEmpty) {
      return false;
    }
    final importIssue = validateLedgerEntries(
      books: ledgerBooks,
      accounts: <Account>[..._accounts, ...candidateAccounts],
      entries: entries,
      requireMinorUnitNormalization: true,
    );
    if (importIssue != null) {
      _logger?.warning(
        'Import validation failed: ${importIssue.code.name}',
        source: 'import',
      );
      return false;
    }
    final referencedAccountIds = <String>{};
    final referencedCategoryIds = <String>{};
    final referencedTagIds = <String>{};
    for (final entry in entries) {
      if (entry.accountId.isNotEmpty) {
        referencedAccountIds.add(entry.accountId);
      }
      final toAccountId = entry.toAccountId;
      if (toAccountId != null && toAccountId.isNotEmpty) {
        referencedAccountIds.add(toAccountId);
      }
      if (entry.categoryId.isNotEmpty) {
        referencedCategoryIds.add(entry.categoryId);
      }
      referencedTagIds.addAll(entry.tagIds);
    }
    final existingAccountIds = _accounts.map((account) => account.id).toSet();
    final newAccounts = candidateAccounts
        .where(
          (account) =>
              (referencedAccountIds.contains(account.id) ||
                  alwaysCreateAccountIds.contains(account.id)) &&
              !existingAccountIds.contains(account.id),
        )
        .toList();
    final existingCategoryIds = _categories
        .map((category) => category.id)
        .toSet();
    final newCategories = candidateCategories
        .where(
          (category) =>
              referencedCategoryIds.contains(category.id) &&
              !existingCategoryIds.contains(category.id),
        )
        .toList();
    // 分类映射后，子分类的 parentId 可能指向一个「被映射到现有分类、自身不再新建」的
    // 父候选。这里把这类悬空 parentId 一并保留创建，避免子分类挂到不存在的父上（由
    // _healCategoryData 兜底重挂顶级，但优先按候选补建父级更贴近用户来源层级）。
    final createdCategoryIds = newCategories.map((c) => c.id).toSet();
    for (var i = 0; i < newCategories.length; i++) {
      final parentId = newCategories[i].parentId;
      if (parentId != null &&
          !createdCategoryIds.contains(parentId) &&
          !existingCategoryIds.contains(parentId)) {
        final parent = candidateCategories
            .where((c) => c.id == parentId)
            .firstOrNull;
        if (parent != null) {
          newCategories.add(parent);
          createdCategoryIds.add(parent.id);
        }
      }
    }
    final existingTagIds = _tags.map((tag) => tag.id).toSet();
    final newTags = candidateTags
        .where(
          (tag) =>
              referencedTagIds.contains(tag.id) &&
              !existingTagIds.contains(tag.id),
        )
        .toList();
    final existingRateKeys = _exchangeRates
        .map(
          (rate) =>
              '${rate.bookId}:${rate.currencyCode}:${currencyDateKey(rate.effectiveDate)}',
        )
        .toSet();
    final newRates = <ExchangeRate>[];
    for (final rate in candidateExchangeRates) {
      final key =
          '${rate.bookId}:${rate.currencyCode}:${currencyDateKey(rate.effectiveDate)}';
      if (rate.bookId == _activeBookId &&
          rate.baseCurrencyCode == activeBook.baseCurrencyCode &&
          rate.currencyCode != rate.baseCurrencyCode &&
          CurrencyCatalog.isSupported(rate.currencyCode) &&
          isValidExchangeRate(rate.rateToBase) &&
          existingRateKeys.add(key)) {
        newRates.add(rate);
      }
    }

    // 名称去首尾空格：候选账户经预览页改名后可能带空格，与 addAccount 同规则。
    _accounts.addAll(
      newAccounts.map(
        (account) => _normalizeAccountCurrencyAmounts(
          account.copyWith(name: account.name.trim()),
        ),
      ),
    );
    if (newCategories.isNotEmpty) {
      // 首次导入前若仍是默认分类占位，先落地为真实列表再追加。
      if (_categories.isEmpty) {
        _categories.addAll(_seedCategories);
      }
      _categories.addAll(newCategories);
    }
    if (newTags.isNotEmpty) {
      _tags.addAll(newTags);
    }
    if (newRates.isNotEmpty) {
      _exchangeRates.addAll(newRates);
    }
    final importedById = <String, LedgerEntry>{
      for (final entry in entries) entry.id: entry,
      for (final entry in reconciliationUpdates) entry.id: entry,
    };
    _entries.removeWhere((entry) => importedById.containsKey(entry.id));
    _entries.addAll(importedById.values);
    _entries.sort(_compareEntriesLatestFirst);
    // 导入数据里的旧式单标量退款（如一木账单的「退款」列）迁成关联退款条目、
    // 并重算净额缓存，使余额/统计当场即正确（不必等下次载入自愈）。
    _syncRefundData();
    // 交易与其来源证据、候选账户/分类/标签/汇率是一份导入提交，原子整替保存。
    _persistAllLedgerData();
    notifyListeners();
    // 导入也新增了交易：触发自动备份与小组件刷新，与手动记账一致。
    onEntryAdded?.call();
    return true;
  }

  void updateEntry(LedgerEntry entry) {
    final index = _entries.indexWhere((item) => item.id == entry.id);
    if (index == -1) {
      return;
    }
    _entries[index] = entry;
    _entries.sort(_compareEntriesLatestFirst);
    _persistEntries();
    notifyListeners();
  }

  /// 用户确认来源证据与本地交易属于同一笔后，标记为人工核准；金额不自动改变。
  Future<bool> confirmEntryReconciliation(String entryId) async {
    final index = _entries.indexWhere((entry) => entry.id == entryId);
    if (index == -1 || _entries[index].sourceRecords.isEmpty) return false;
    final next = List<LedgerEntry>.of(_entries);
    next[index] = next[index].copyWith(
      reconciliationStatus: ReconciliationStatus.manuallyConfirmed,
    );
    if (!await _runTrackedWrite(() => _repository.saveEntries(next))) {
      return false;
    }
    _entries
      ..clear()
      ..addAll(next);
    notifyListeners();
    return true;
  }

  /// 标记 / 取消标记支出为「待报销」。仅支出有效。
  void setEntryReimbursable(String entryId, bool reimbursable) {
    final index = _entries.indexWhere((item) => item.id == entryId);
    if (index == -1 || _entries[index].type != EntryType.expense) {
      return;
    }
    _entries[index] = _entries[index].copyWith(reimbursable: reimbursable);
    _persistEntries();
    notifyListeners();
  }

  LedgerEntry? _entryOrNull(String id) {
    for (final entry in _entries) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  /// 某笔支出下的退款条目（到账优先、发起其次的时间倒序）。含待到账。
  List<LedgerEntry> refundsForEntry(String expenseId) {
    final list = _entries
        .where((e) => e.type == EntryType.refund && e.refundOf == expenseId)
        .toList();
    list.sort((a, b) {
      final ad = a.settledAt ?? a.occurredAt;
      final bd = b.settledAt ?? b.occurredAt;
      return bd.compareTo(ad);
    });
    return List<LedgerEntry>.unmodifiable(list);
  }

  /// 当前账本所有「待到账」退款（发起日倒序），用于「待退款」清单页。
  List<LedgerEntry> get pendingRefunds {
    final list = _entries
        .where((e) => e.bookId == _activeBookId && e.isPendingRefund)
        .toList();
    list.sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
    return List<LedgerEntry>.unmodifiable(list);
  }

  /// 某笔支出已挂的退款总额（含待到账），用于「剩余可退」与超额拦截。
  double refundedTotalFor(String expenseId) {
    var sum = 0.0;
    for (final e in _entries) {
      if (e.type == EntryType.refund && e.refundOf == expenseId) {
        sum += e.amount;
      }
    }
    return sum;
  }

  /// 某笔支出「剩余可退」额 = 原金额 − 已挂退款（含待到账），钳到 `[0, amount]`。
  /// 决策 D：禁止超额，退款上限为原金额。
  double remainingRefundable(String expenseId) {
    final expense = _entryOrNull(expenseId);
    if (expense == null || expense.type != EntryType.expense) return 0;
    return (expense.amount - refundedTotalFor(expenseId))
        .clamp(0.0, expense.amount)
        .toDouble();
  }

  /// 给某笔支出添加一笔退款。金额自动截到「剩余可退」（决策 D：禁止超额）。
  /// [settledAt] 为 null 表示「待到账」（不进余额 / 净额，只进待退款清单）。
  /// 返回实际记入的退款条目；金额 ≤ 0 或支出不存在时返回 null。
  LedgerEntry? addRefund({
    required String expenseId,
    required double amount,
    required String accountId,
    required DateTime initiatedAt,
    DateTime? settledAt,
    String note = '',
    double? accountAmount,
    double? baseAmount,
    ConversionSource? conversionSource,
  }) {
    final expense = _entryOrNull(expenseId);
    if (expense == null || expense.type != EntryType.expense) return null;
    final capped = amount.clamp(0.0, remainingRefundable(expenseId)).toDouble();
    if (capped <= 0) return null;
    final book = _ledgerBooks
        .where((book) => book.id == expense.bookId)
        .firstOrNull;
    if (book == null) return null;
    final normalizedAmount = normalizeCurrencyAmount(
      capped,
      expense.currencyCode,
    );
    final resolvedBaseAmount = normalizeCurrencyAmount(
      baseAmount ?? expense.baseAmount * normalizedAmount / expense.amount,
      book.baseCurrencyCode,
    );
    final account = accountId.isEmpty
        ? null
        : _accounts
              .where(
                (account) =>
                    account.id == accountId && account.bookId == expense.bookId,
              )
              .firstOrNull;
    double? resolvedAccountAmount;
    if (account != null) {
      if (accountAmount != null) {
        resolvedAccountAmount = normalizeCurrencyAmount(
          accountAmount,
          account.currencyCode,
        );
      } else if (account.id == expense.accountId &&
          expense.accountAmount != null) {
        resolvedAccountAmount = normalizeCurrencyAmount(
          expense.accountAmount! * normalizedAmount / expense.amount,
          account.currencyCode,
        );
      } else if (account.currencyCode == book.baseCurrencyCode) {
        resolvedAccountAmount = resolvedBaseAmount;
      } else {
        final converted = convertCurrencyAmount(
          amount: normalizedAmount,
          sourceCurrencyCode: expense.currencyCode,
          targetCurrencyCode: account.currencyCode,
          baseCurrencyCode: book.baseCurrencyCode,
          bookId: expense.bookId,
          date: initiatedAt,
          rates: _exchangeRates,
        );
        if (converted is! ConvertedCurrencyAmount) return null;
        resolvedAccountAmount = converted.amount;
      }
    } else if (accountId.isNotEmpty) {
      // Keep compatibility with an already-deleted account reference while
      // still requiring an explicit actual amount for new cross-currency data.
      resolvedAccountAmount = accountAmount ?? normalizedAmount;
    }
    final refund = LedgerEntry(
      id: _generateId('entry'),
      bookId: expense.bookId,
      type: EntryType.refund,
      amount: normalizedAmount,
      currencyCode: expense.currencyCode,
      accountAmount: resolvedAccountAmount,
      baseAmount: resolvedBaseAmount,
      conversionSource:
          conversionSource ??
          (expense.currencyCode == book.baseCurrencyCode &&
                  (account == null ||
                      account.currencyCode == book.baseCurrencyCode)
              ? ConversionSource.identity
              : ConversionSource.rateTable),
      categoryId: expense.categoryId,
      accountId: accountId,
      note: note,
      occurredAt: initiatedAt,
      refundOf: expenseId,
      settledAt: settledAt,
    );
    _entries.add(refund);
    _entries.sort(_compareEntriesLatestFirst);
    _syncRefundCache(); // 重算原支出净额缓存
    _persistEntries();
    notifyListeners();
    onEntryAdded?.call();
    return refund;
  }

  /// 更新一笔退款（金额/到账账户/发起日期/备注/到账状态）。
  /// 金额自动截到「剩余可退（不含本笔旧值）」，防止超额。
  void updateRefund(LedgerEntry refund) {
    final index = _entries.indexWhere(
      (e) => e.id == refund.id && e.type == EntryType.refund,
    );
    if (index == -1) return;
    final expenseId = refund.refundOf ?? _entries[index].refundOf;
    final expense = expenseId == null ? null : _entryOrNull(expenseId);
    var otherSum = 0.0;
    for (final e in _entries) {
      if (e.id != refund.id &&
          e.type == EntryType.refund &&
          e.refundOf == expenseId) {
        otherSum += e.amount;
      }
    }
    final cap = expense == null
        ? refund.amount
        : (expense.amount - otherSum).clamp(0.0, expense.amount).toDouble();
    _entries[index] = refund.copyWith(
      amount: refund.amount.clamp(0.0, cap).toDouble(),
    );
    _entries.sort(_compareEntriesLatestFirst);
    _syncRefundCache();
    _persistEntries();
    notifyListeners();
  }

  /// 标记退款「已到账」（传到账日期）或改回「待到账」（传 null）。
  void setRefundSettled(String refundId, DateTime? settledAt) {
    final index = _entries.indexWhere(
      (e) => e.id == refundId && e.type == EntryType.refund,
    );
    if (index == -1) return;
    _entries[index] = _entries[index].copyWith(
      settledAt: settledAt,
      clearSettledAt: settledAt == null,
    );
    _syncRefundCache();
    _persistEntries();
    notifyListeners();
  }

  /// 删除一笔退款条目（原支出净额缓存随之恢复）。
  Future<bool> deleteRefund(String refundId) async {
    final index = _entries.indexWhere(
      (e) => e.id == refundId && e.type == EntryType.refund,
    );
    if (index == -1) return false;
    final nextEntries = _entriesWithSyncedRefundCache(
      _entries.where((entry) => entry.id != refundId),
    )..sort(_compareEntriesLatestFirst);
    final nextAttachments = _attachments
        .where((attachment) => attachment.entryId != refundId)
        .toList();
    final saved = await _runTrackedWrite(
      () => _repository.saveEntryAggregate(
        entries: nextEntries,
        attachments: nextAttachments,
      ),
    );
    if (!saved) {
      return false;
    }
    _entries
      ..clear()
      ..addAll(nextEntries);
    _attachments
      ..clear()
      ..addAll(nextAttachments);
    notifyListeners();
    return true;
  }

  void addLedgerBook(String name, {String? baseCurrencyCode}) {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      return;
    }
    final code = (baseCurrencyCode ?? activeBook.baseCurrencyCode)
        .toUpperCase();
    if (!CurrencyCatalog.isSupported(code)) return;
    final now = DateTime.now();
    final book = LedgerBook(
      id: _generateId('book'),
      name: trimmedName,
      createdAt: now,
      isDefault: false,
      baseCurrencyCode: code,
      currencySetupStatus: CurrencySetupStatus.confirmed,
    );
    _ledgerBooks.add(book);
    _activeBookId = book.id;
    _persistLedgerBooks();
    _store.write(_activeBookKey, _activeBookId);
    notifyListeners();
  }

  void renameLedgerBook(String bookId, String name) {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      return;
    }
    final index = _ledgerBooks.indexWhere((book) => book.id == bookId);
    if (index == -1) {
      return;
    }
    _ledgerBooks[index] = _ledgerBooks[index].copyWith(name: trimmedName);
    _persistLedgerBooks();
    notifyListeners();
  }

  /// 空账本可直接改变本位币；已有财务数据时必须新建账本，不能换算历史数字。
  Future<bool> changeEmptyLedgerBookBaseCurrency(
    String bookId,
    String currencyCode,
  ) async {
    final code = currencyCode.trim().toUpperCase();
    final bookIndex = _ledgerBooks.indexWhere((book) => book.id == bookId);
    if (bookIndex == -1 ||
        !CurrencyCatalog.isSupported(code) ||
        ledgerBookHasFinancialData(bookId)) {
      return false;
    }
    final current = _ledgerBooks[bookIndex];
    final nextBooks = List<LedgerBook>.of(_ledgerBooks)
      ..[bookIndex] = current.copyWith(
        baseCurrencyCode: code,
        currencySetupStatus: CurrencySetupStatus.confirmed,
      );
    final nextAccounts = <Account>[
      for (final account in _accounts)
        account.bookId == bookId
            ? account.copyWith(currencyCode: code)
            : account,
    ];
    final nextRates = <ExchangeRate>[
      for (final rate in _exchangeRates)
        if (rate.bookId != bookId) rate,
    ];
    try {
      await _repository.replaceAllLedgerData(
        _ledgerDataSnapshot(
          books: nextBooks,
          accounts: nextAccounts,
          exchangeRates: nextRates,
        ),
      );
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return false;
    }
    _ledgerBooks
      ..clear()
      ..addAll(nextBooks);
    _accounts
      ..clear()
      ..addAll(nextAccounts);
    _exchangeRates
      ..clear()
      ..addAll(nextRates);
    notifyListeners();
    return true;
  }

  /// 首版旧账本的一次性“重解释”：所有数字保持不变，只把它们的币种标签从
  /// 迁移占位 CNY 改为用户确认的币种。全部核心表在同一 SQLite 事务内替换。
  Future<bool> reinterpretLegacyLedgerBookCurrency(
    String bookId,
    String currencyCode,
  ) async {
    final code = currencyCode.trim().toUpperCase();
    final bookIndex = _ledgerBooks.indexWhere((book) => book.id == bookId);
    if (bookIndex == -1 ||
        _ledgerBooks[bookIndex].currencySetupStatus !=
            CurrencySetupStatus.legacyUnconfirmed ||
        !CurrencyCatalog.isSupported(code)) {
      return false;
    }
    final nextBooks = List<LedgerBook>.of(_ledgerBooks)
      ..[bookIndex] = _ledgerBooks[bookIndex].copyWith(
        baseCurrencyCode: code,
        currencySetupStatus: CurrencySetupStatus.confirmed,
      );
    final nextAccounts = <Account>[
      for (final account in _accounts)
        account.bookId == bookId
            ? account.copyWith(currencyCode: code)
            : account,
    ];
    final nextEntries = <LedgerEntry>[
      for (final entry in _entries)
        if (entry.bookId != bookId)
          entry
        else
          entry.copyWith(
            currencyCode: code,
            accountAmount: entry.accountId.isEmpty ? null : entry.amount,
            clearAccountAmount: entry.accountId.isEmpty,
            toAccountAmount: entry.toAccountId?.isNotEmpty == true
                ? entry.amount
                : null,
            clearToAccountAmount: entry.toAccountId?.isNotEmpty != true,
            baseAmount: entry.type == EntryType.transfer ? 0 : entry.amount,
            conversionSource: ConversionSource.legacy,
          ),
    ];
    final nextRecurringRules = <RecurringRule>[
      for (final rule in _recurringRules)
        if (rule.bookId != bookId)
          rule
        else
          rule.copyWith(
            currencyCode: code,
            accountAmount: rule.accountId.isEmpty ? null : rule.amount,
            clearAccountAmount: rule.accountId.isEmpty,
            toAccountAmount: rule.toAccountId?.isNotEmpty == true
                ? rule.amount
                : null,
            clearToAccountAmount: rule.toAccountId?.isNotEmpty != true,
            baseAmount: rule.type == EntryType.transfer ? 0 : rule.amount,
            ratePolicy: RecurringRatePolicy.fixedAmounts,
          ),
    ];
    final nextRates = <ExchangeRate>[
      for (final rate in _exchangeRates)
        if (rate.bookId != bookId) rate,
    ];
    final nextStatements = <BillingStatement>[
      for (final statement in _billingStatements)
        if (statement.bookId != bookId)
          statement
        else
          BillingStatement(
            id: statement.id,
            bookId: statement.bookId,
            accountId: statement.accountId,
            statementDate: statement.statementDate,
            periodStart: statement.periodStart,
            periodEnd: statement.periodEnd,
            statementAmount: statement.statementAmount,
            minimumPayment: statement.minimumPayment,
            dueDate: statement.dueDate,
            paidAmount: statement.paidAmount,
            status: statement.status,
            currencyCode: code,
            sourceId: statement.sourceId,
            sourceStatementId: statement.sourceStatementId,
            note: statement.note,
          ),
    ];
    try {
      await _repository.replaceAllLedgerData(
        _ledgerDataSnapshot(
          books: nextBooks,
          accounts: nextAccounts,
          entries: nextEntries,
          recurringRules: nextRecurringRules,
          exchangeRates: nextRates,
          billingStatements: nextStatements,
        ),
      );
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return false;
    }
    _ledgerBooks
      ..clear()
      ..addAll(nextBooks);
    _accounts
      ..clear()
      ..addAll(nextAccounts);
    _entries
      ..clear()
      ..addAll(nextEntries);
    _recurringRules
      ..clear()
      ..addAll(nextRecurringRules);
    _exchangeRates
      ..clear()
      ..addAll(nextRates);
    _billingStatements
      ..clear()
      ..addAll(nextStatements);
    notifyListeners();
    return true;
  }

  void switchLedgerBook(String bookId) {
    if (!_ledgerBooks.any((book) => book.id == bookId)) {
      return;
    }
    _activeBookId = bookId;
    _store.write(_activeBookKey, _activeBookId);
    notifyListeners();
  }

  bool deleteLedgerBook(String bookId) {
    final book = _ledgerBooks.where((item) => item.id == bookId).firstOrNull;
    if (book == null || book.isDefault) {
      return false;
    }
    _ledgerBooks.removeWhere((item) => item.id == bookId);
    final removedEntryIds = _entries
        .where((entry) => entry.bookId == bookId)
        .map((entry) => entry.id)
        .toSet();
    _entries.removeWhere((entry) => entry.bookId == bookId);
    _accounts.removeWhere((account) => account.bookId == bookId);
    _accountGroups.removeWhere((group) => group.bookId == bookId);
    _creditAccounts.removeWhere(
      (creditAccount) => creditAccount.bookId == bookId,
    );
    _recurringRules.removeWhere((rule) => rule.bookId == bookId);
    _exchangeRates.removeWhere((rate) => rate.bookId == bookId);
    _balanceAnchors.removeWhere((anchor) => anchor.bookId == bookId);
    final removedStatementIds = _billingStatements
        .where((statement) => statement.bookId == bookId)
        .map((statement) => statement.id)
        .toSet();
    _billingStatements.removeWhere((statement) => statement.bookId == bookId);
    _statementRepaymentAllocations.removeWhere(
      (allocation) =>
          allocation.bookId == bookId ||
          removedStatementIds.contains(allocation.statementId),
    );
    _captureEvents.removeWhere((event) => event.bookId == bookId);
    _autoCaptureRules.removeWhere((rule) => rule.bookId == bookId);
    _collapsedAssetSections.removeWhere((key) => key.startsWith('$bookId:'));
    _assetAccountOrders.removeWhere((key, _) => key.startsWith('$bookId:'));
    _assetSectionOrders.removeWhere((key, _) => key.startsWith('$bookId:'));
    _monthlyBudgets.removeWhere((key, _) => key.startsWith('$bookId:'));
    _categoryBudgets.removeWhere((key, _) => key.startsWith('$bookId:'));
    _dailyBudgets.remove(bookId);
    _defaultAccountIds.remove(bookId);
    _persistDefaultAccounts();
    _budgetCycleStartDays.remove(bookId);
    _persistBudgetCycleStartDays();
    if (_activeBookId == bookId) {
      _activeBookId = defaultLedgerBookId;
      _store.write(_activeBookKey, _activeBookId);
    }
    // 内存里剥离该账本的附件，落库交给下方整体写入（附件已含在快照里）。
    _removeAttachmentsForEntries(removedEntryIds);
    _persistAllLedgerData();
    // 原始事件和规则不在账本整体写入事务内，删账本时单独原子保存两张表。
    _trackWrite(
      _repository.saveAutoCaptureMetadata(
        captureEvents: List<CaptureEvent>.of(_captureEvents),
        rules: List<AutoCaptureRule>.of(_autoCaptureRules),
      ),
    );
    // 以下为 KV 偏好类，不在账目事务内。
    _persistAssetSectionCollapsed();
    _persistAssetAccountOrders();
    _persistAssetSectionOrders();
    notifyListeners();
    return true;
  }

  int entryCountForBook(String bookId) {
    return _entries.where((entry) => entry.bookId == bookId).length;
  }

  Future<bool> deleteEntry(String entryId) {
    // 删支出时级联删除挂它的退款条目；删退款时由 _syncRefundData 恢复原支出净额缓存。
    return _deleteEntryIds(<String>{entryId});
  }

  /// 批量删除交易（连同关联退款条目与附件级联清理）。
  Future<bool> deleteEntries(Set<String> entryIds) {
    if (entryIds.isEmpty) {
      return Future<bool>.value(false);
    }
    return _deleteEntryIds(entryIds);
  }

  Set<String> _withDependentRefundIds(Set<String> entryIds) {
    final refundIds = _entries
        .where(
          (e) =>
              e.type == EntryType.refund &&
              e.refundOf != null &&
              entryIds.contains(e.refundOf),
        )
        .map((e) => e.id)
        .toSet();
    return <String>{...entryIds, ...refundIds};
  }

  Future<bool> _deleteEntryIds(Set<String> entryIds) async {
    final removeIds = _withDependentRefundIds(entryIds);
    if (!_entries.any((entry) => removeIds.contains(entry.id))) {
      return false;
    }
    final nextEntries = _entriesWithSyncedRefundCache(
      _entries.where((entry) => !removeIds.contains(entry.id)),
    )..sort(_compareEntriesLatestFirst);
    final nextAttachments = _attachments
        .where((attachment) => !removeIds.contains(attachment.entryId))
        .toList();
    final removedAllocations = _statementRepaymentAllocations
        .where((allocation) => removeIds.contains(allocation.repaymentEntryId))
        .toList();
    final removedByStatement = <String, double>{};
    for (final allocation in removedAllocations) {
      removedByStatement[allocation.statementId] =
          (removedByStatement[allocation.statementId] ?? 0) + allocation.amount;
    }
    final nextAllocations = _statementRepaymentAllocations
        .where((allocation) => !removeIds.contains(allocation.repaymentEntryId))
        .toList();
    final nextStatements = <BillingStatement>[
      for (final statement in _billingStatements)
        if (!removedByStatement.containsKey(statement.id))
          statement
        else
          (() {
            final account = _accounts
                .where((item) => item.id == statement.accountId)
                .firstOrNull;
            final paid = normalizeCurrencyAmount(
              (statement.paidAmount - removedByStatement[statement.id]!).clamp(
                0,
                statement.statementAmount,
              ),
              account?.currencyCode ?? statement.currencyCode,
            );
            final updated = statement.copyWith(paidAmount: paid);
            return updated.copyWith(status: normalizedStatementStatus(updated));
          })(),
    ];
    final saved = await _runTrackedWrite(
      () => _repository.replaceAllLedgerData(
        _ledgerDataSnapshot(
          entries: nextEntries,
          attachments: nextAttachments,
          billingStatements: nextStatements,
          statementRepaymentAllocations: nextAllocations,
        ),
      ),
    );
    if (!saved) {
      return false;
    }
    _entries
      ..clear()
      ..addAll(nextEntries);
    _attachments
      ..clear()
      ..addAll(nextAttachments);
    _billingStatements
      ..clear()
      ..addAll(nextStatements);
    _statementRepaymentAllocations
      ..clear()
      ..addAll(nextAllocations);
    // 正式交易被删除后保留原始事件审计证据，但清掉悬空关联并退回待确认。
    await _sanitizeAutoCaptureReferences(removedEntryIds: removeIds);
    notifyListeners();
    return true;
  }

  /// 批量改分类：只改与目标分类同类型的交易（类型不符的跳过）。返回改动数量。
  int setEntriesCategory(Set<String> entryIds, String categoryId) {
    final category = _categories.where((c) => c.id == categoryId).firstOrNull;
    if (category == null || entryIds.isEmpty) {
      return 0;
    }
    var changed = 0;
    for (var i = 0; i < _entries.length; i++) {
      final entry = _entries[i];
      if (entryIds.contains(entry.id) && entry.type == category.type) {
        _entries[i] = entry.copyWith(categoryId: categoryId);
        changed += 1;
      }
    }
    if (changed > 0) {
      _persistEntries();
      notifyListeners();
    }
    return changed;
  }

  List<LedgerEntry>? _safeBatchAccountEntries(Set<String> entryIds) {
    if (entryIds.isEmpty) {
      return null;
    }
    final selected = _entries
        .where(
          (entry) =>
              entry.bookId == _activeBookId && entryIds.contains(entry.id),
        )
        .toList();
    if (selected.length != entryIds.length) {
      return null;
    }
    for (final entry in selected) {
      final source = _accounts
          .where(
            (account) =>
                account.id == entry.accountId && account.bookId == entry.bookId,
          )
          .firstOrNull;
      if (source == null || entry.accountAmount == null) {
        // “无账户”或悬空账户没有可直接搬到新账户的实际账户金额。
        return null;
      }
    }
    return selected;
  }

  /// 批量改账户只能在账户币种不变时复用冻结的 accountAmount/baseAmount。
  /// 跨币种、无账户或转入账户冲突都必须逐笔编辑，不能静默猜汇率/结算金额。
  List<Account> batchAccountChangeCandidates(Set<String> entryIds) {
    final selected = _safeBatchAccountEntries(entryIds);
    if (selected == null) {
      return const <Account>[];
    }
    final sourceCurrencies = <String>{
      for (final entry in selected)
        _accounts
            .firstWhere(
              (account) =>
                  account.id == entry.accountId &&
                  account.bookId == entry.bookId,
            )
            .currencyCode,
    };
    if (sourceCurrencies.length != 1) {
      return const <Account>[];
    }
    final currencyCode = sourceCurrencies.single;
    final forbiddenTransferTargets = <String>{
      for (final entry in selected)
        if (entry.type == EntryType.transfer && entry.toAccountId != null)
          entry.toAccountId!,
    };
    return List<Account>.unmodifiable(
      accounts.where(
        (account) =>
            !account.hidden &&
            account.currencyCode == currencyCode &&
            !forbiddenTransferTargets.contains(account.id),
      ),
    );
  }

  Future<BatchAccountChangeResult> setEntriesAccount(
    Set<String> entryIds,
    String accountId,
  ) async {
    final target = _accounts
        .where(
          (account) =>
              account.id == accountId &&
              account.bookId == _activeBookId &&
              !account.hidden,
        )
        .firstOrNull;
    if (target == null) {
      return const BatchAccountChangeResult(
        status: BatchAccountChangeStatus.invalidTarget,
      );
    }
    final selected = _safeBatchAccountEntries(entryIds);
    if (selected == null ||
        selected.any((entry) {
          final source = _accounts.firstWhere(
            (account) =>
                account.id == entry.accountId && account.bookId == entry.bookId,
          );
          return source.currencyCode != target.currencyCode ||
              entry.type == EntryType.transfer &&
                  entry.toAccountId == target.id;
        })) {
      return const BatchAccountChangeResult(
        status: BatchAccountChangeStatus.unsafeSelection,
      );
    }

    final changedIds = <String>{
      for (final entry in selected)
        if (entry.accountId != target.id) entry.id,
    };
    if (changedIds.isEmpty) {
      return const BatchAccountChangeResult(
        status: BatchAccountChangeStatus.success,
      );
    }
    final nextEntries = <LedgerEntry>[
      for (final entry in _entries)
        changedIds.contains(entry.id)
            ? entry.copyWith(accountId: target.id)
            : entry,
    ];
    final saved = await _runTrackedWrite(
      () => _repository.saveEntries(nextEntries),
    );
    if (!saved) {
      return const BatchAccountChangeResult(
        status: BatchAccountChangeStatus.persistenceFailure,
      );
    }
    _entries
      ..clear()
      ..addAll(nextEntries);
    notifyListeners();
    return BatchAccountChangeResult(
      status: BatchAccountChangeStatus.success,
      changed: changedIds.length,
    );
  }

  bool _isAccountCurrencyAllowed(Account account) {
    final book = _ledgerBooks
        .where((item) => item.id == account.bookId)
        .firstOrNull;
    return book != null &&
        CurrencyCatalog.isSupported(account.currencyCode) &&
        (book.currencySetupStatus == CurrencySetupStatus.confirmed ||
            account.currencyCode == book.baseCurrencyCode);
  }

  Account _normalizeAccountCurrencyAmounts(Account account) {
    final creditLimit = account.creditLimit;
    return account.copyWith(
      initialBalance: normalizeCurrencyAmount(
        account.initialBalance,
        account.currencyCode,
      ),
      creditLimit: creditLimit == null
          ? null
          : normalizeCurrencyAmount(creditLimit, account.currencyCode),
      clearCreditLimit: creditLimit == null,
      // 普通账户不能保留信用主体引用；账户类型切换后在此统一清理，避免悬空父子关系。
      clearCreditAccountId: !account.type.supportsCredit,
    );
  }

  /// 校验已有信用主体引用必须存在于同一账本；null 表示稍后自动新建主体。
  bool _hasValidCreditAccountLink(Account account) {
    final creditAccountId = account.creditAccountId;
    if (!account.type.supportsCredit ||
        creditAccountId == null ||
        creditAccountId.isEmpty) {
      return true;
    }
    return _creditAccounts.any(
      (item) => item.id == creditAccountId && item.bookId == account.bookId,
    );
  }

  /// 把主体的共享额度与日期规则复制到全部币种子账户的兼容字段。
  ///
  /// 旧页面和旧备份仍会读取这些字段；新计算只认 [CreditAccount]。集中同步可避免
  /// 编辑人民币子账户后美元子账户仍保留另一份额度。相对日规则没有固定 dueDay，
  /// 因此兼容字段统一清空。
  List<Account> _accountsWithCreditMirrors(
    Iterable<Account> accounts,
    CreditAccount creditAccount,
  ) => accounts
      .map(
        (account) => account.creditAccountId != creditAccount.id
            ? account
            : account.copyWith(
                cardLast4: creditAccount.cardLast4,
                // 旧账户字段没有“额度币种”。只有与主体同币种的子账户保留镜像值；
                // 外币子账户必须清空，避免把 ¥70,000 错显示成 $70,000。
                creditLimit: account.currencyCode == creditAccount.currencyCode
                    ? creditAccount.creditLimit
                    : null,
                clearCreditLimit:
                    account.currencyCode != creditAccount.currencyCode ||
                    creditAccount.creditLimit == null,
                statementDay: creditAccount.statementDay,
                clearStatementDay: creditAccount.statementDay == null,
                dueDay: creditAccount.dueRuleType == CreditDueRuleType.fixedDay
                    ? creditAccount.dueDay
                    : null,
                clearDueDay:
                    creditAccount.dueRuleType != CreditDueRuleType.fixedDay ||
                    creditAccount.dueDay == null,
              ),
      )
      .toList();

  /// 判断币种子账户编辑页是否真的改动了共享额度/日期；普通名称、备注和卡号编辑
  /// 不得反向覆盖信用主体，主体卡尾号只允许在专用编辑页修改。
  bool _creditMirrorsChanged(Account before, Account after) =>
      before.creditAccountId == after.creditAccountId &&
      (before.creditLimit != after.creditLimit ||
          before.statementDay != after.statementDay ||
          before.dueDay != after.dueDay);

  void addAccount(Account account) {
    if (!_isAccountCurrencyAllowed(account)) return;
    // 名称统一去首尾空格（与 addAccountGroup、导入侧 plan_builder 同规则）。
    var normalized = _normalizeAccountCurrencyAmounts(
      account.copyWith(name: account.name.trim()),
    );
    if (!_hasValidCreditAccountLink(normalized)) return;
    CreditAccount? createdCreditAccount;
    if (normalized.type.supportsCredit &&
        (normalized.creditAccountId == null ||
            normalized.creditAccountId!.isEmpty)) {
      final creditAccount = _creditAccountFromLegacyAccount(normalized);
      createdCreditAccount = creditAccount;
      _creditAccounts.add(creditAccount);
      normalized = normalized.copyWith(creditAccountId: creditAccount.id);
    } else if (normalized.creditAccountId != null) {
      final parent = _creditAccounts.firstWhere(
        (item) => item.id == normalized.creditAccountId,
      );
      normalized = _accountsWithCreditMirrors(<Account>[
        normalized,
      ], parent).single;
    }
    _accounts.add(normalized);
    if (createdCreditAccount == null) {
      _persistAccounts();
    } else {
      _trackWrite(
        _repository.saveCreditAccountAggregate(
          creditAccounts: List<CreditAccount>.of(_creditAccounts),
          accounts: List<Account>.of(_accounts),
        ),
      );
    }
    notifyListeners();
  }

  /// 编辑页提交新账户：只有 SQLite 写入成功后才更新内存并通知 UI。
  Future<bool> addAccountDraft(Account account) async {
    if (!_isAccountCurrencyAllowed(account)) return false;
    var normalized = _normalizeAccountCurrencyAmounts(
      account.copyWith(name: account.name.trim()),
    );
    if (!_hasValidCreditAccountLink(normalized)) return false;
    CreditAccount? createdCreditAccount;
    if (normalized.type.supportsCredit &&
        (normalized.creditAccountId == null ||
            normalized.creditAccountId!.isEmpty)) {
      createdCreditAccount = _creditAccountFromLegacyAccount(normalized);
      normalized = normalized.copyWith(
        creditAccountId: createdCreditAccount.id,
      );
    } else if (normalized.creditAccountId != null) {
      final parent = _creditAccounts.firstWhere(
        (item) => item.id == normalized.creditAccountId,
      );
      normalized = _accountsWithCreditMirrors(<Account>[
        normalized,
      ], parent).single;
    }
    final next = <Account>[..._accounts, normalized];
    try {
      if (createdCreditAccount == null) {
        await _repository.saveAccounts(next);
      } else {
        await _repository.saveCreditAccountAggregate(
          creditAccounts: <CreditAccount>[
            ..._creditAccounts,
            createdCreditAccount,
          ],
          accounts: next,
        );
      }
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return false;
    }
    _accounts.add(normalized);
    if (createdCreditAccount != null) {
      _creditAccounts.add(createdCreditAccount);
    }
    notifyListeners();
    return true;
  }

  /// 用旧账户字段创建一对一信用主体。id 由账户 id 稳定派生，重复调用不会产生漂移。
  CreditAccount _creditAccountFromLegacyAccount(Account account) =>
      CreditAccount(
        id: 'credit-account-${account.id}',
        bookId: account.bookId,
        name: account.name,
        institution: '',
        cardLast4: account.cardLast4,
        currencyCode: account.currencyCode,
        creditLimit: account.creditLimit,
        statementDay: account.statementDay,
        dueRuleType: CreditDueRuleType.fixedDay,
        dueDay: account.dueDay,
        daysAfterStatement: null,
        cycleBudget: null,
      );

  void updateAccount(Account account) {
    final index = _accounts.indexWhere((item) => item.id == account.id);
    if (index == -1) {
      return;
    }
    final current = _accounts[index];
    if (!_isAccountCurrencyAllowed(account) ||
        (current.currencyCode != account.currencyCode &&
            accountCurrencyLocked(current))) {
      return;
    }
    final accountWithPersistedLink =
        account.type.supportsCredit && account.creditAccountId == null
        ? account.copyWith(creditAccountId: current.creditAccountId)
        : account;
    var normalized = _normalizeAccountCurrencyAmounts(
      accountWithPersistedLink.copyWith(name: account.name.trim()),
    );
    if (!_hasValidCreditAccountLink(normalized)) return;
    final nextCreditAccounts = List<CreditAccount>.of(_creditAccounts);
    CreditAccount? createdCreditAccount;
    if (normalized.type.supportsCredit &&
        (normalized.creditAccountId == null ||
            normalized.creditAccountId!.isEmpty)) {
      createdCreditAccount = _creditAccountFromLegacyAccount(normalized);
      normalized = normalized.copyWith(
        creditAccountId: createdCreditAccount.id,
      );
      nextCreditAccounts.add(createdCreditAccount);
    }
    var nextAccounts = List<Account>.of(_accounts)..[index] = normalized;
    final creditIndex = nextCreditAccounts.indexWhere(
      (item) => item.id == normalized.creditAccountId,
    );
    final associationChanged =
        current.creditAccountId != normalized.creditAccountId;
    var creditProfileChanged = false;
    if (creditIndex != -1 && _creditMirrorsChanged(current, normalized)) {
      final currentCredit = nextCreditAccounts[creditIndex];
      final nextCredit = currentCredit.copyWith(
        creditLimit: normalized.currencyCode == currentCredit.currencyCode
            ? normalized.creditLimit
            : currentCredit.creditLimit,
        clearCreditLimit:
            normalized.currencyCode == currentCredit.currencyCode &&
            normalized.creditLimit == null,
        statementDay: normalized.statementDay,
        clearStatementDay: normalized.statementDay == null,
        dueDay: currentCredit.dueRuleType == CreditDueRuleType.fixedDay
            ? normalized.dueDay
            : null,
        clearDueDay:
            currentCredit.dueRuleType != CreditDueRuleType.fixedDay ||
            normalized.dueDay == null,
      );
      nextCreditAccounts[creditIndex] = nextCredit;
      nextAccounts = _accountsWithCreditMirrors(nextAccounts, nextCredit);
      creditProfileChanged = true;
    } else if (creditIndex != -1 && associationChanged) {
      nextAccounts = _accountsWithCreditMirrors(
        nextAccounts,
        nextCreditAccounts[creditIndex],
      );
    }
    if (current.creditAccountId != null &&
        current.creditAccountId != normalized.creditAccountId &&
        !nextAccounts.any(
          (item) => item.creditAccountId == current.creditAccountId,
        )) {
      nextCreditAccounts.removeWhere(
        (item) => item.id == current.creditAccountId,
      );
    }
    _accounts
      ..clear()
      ..addAll(nextAccounts);
    final requiresAggregate =
        createdCreditAccount != null ||
        creditProfileChanged ||
        nextCreditAccounts.length != _creditAccounts.length;
    if (requiresAggregate) {
      _creditAccounts
        ..clear()
        ..addAll(nextCreditAccounts);
      _trackWrite(
        _repository.saveCreditAccountAggregate(
          creditAccounts: List<CreditAccount>.of(_creditAccounts),
          accounts: List<Account>.of(_accounts),
        ),
      );
    } else {
      _persistAccounts();
    }
    notifyListeners();
  }

  /// 编辑页提交已有账户：只有 SQLite 写入成功后才替换内存快照。
  Future<bool> saveAccountDraft(Account account) async {
    final index = _accounts.indexWhere((item) => item.id == account.id);
    if (index == -1) {
      return false;
    }
    final current = _accounts[index];
    if (!_isAccountCurrencyAllowed(account) ||
        (current.currencyCode != account.currencyCode &&
            accountCurrencyLocked(current))) {
      return false;
    }
    final accountWithPersistedLink =
        account.type.supportsCredit && account.creditAccountId == null
        ? account.copyWith(creditAccountId: current.creditAccountId)
        : account;
    var normalized = _normalizeAccountCurrencyAmounts(
      accountWithPersistedLink.copyWith(name: account.name.trim()),
    );
    if (!_hasValidCreditAccountLink(normalized)) return false;
    final nextCreditAccounts = List<CreditAccount>.of(_creditAccounts);
    CreditAccount? createdCreditAccount;
    if (normalized.type.supportsCredit &&
        (normalized.creditAccountId == null ||
            normalized.creditAccountId!.isEmpty)) {
      createdCreditAccount = _creditAccountFromLegacyAccount(normalized);
      normalized = normalized.copyWith(
        creditAccountId: createdCreditAccount.id,
      );
      nextCreditAccounts.add(createdCreditAccount);
    }
    var next = List<Account>.of(_accounts)..[index] = normalized;
    final creditIndex = nextCreditAccounts.indexWhere(
      (item) => item.id == normalized.creditAccountId,
    );
    final associationChanged =
        current.creditAccountId != normalized.creditAccountId;
    var creditProfileChanged = false;
    if (creditIndex != -1 && _creditMirrorsChanged(current, normalized)) {
      final currentCredit = nextCreditAccounts[creditIndex];
      final nextCredit = currentCredit.copyWith(
        creditLimit: normalized.currencyCode == currentCredit.currencyCode
            ? normalized.creditLimit
            : currentCredit.creditLimit,
        clearCreditLimit:
            normalized.currencyCode == currentCredit.currencyCode &&
            normalized.creditLimit == null,
        statementDay: normalized.statementDay,
        clearStatementDay: normalized.statementDay == null,
        dueDay: currentCredit.dueRuleType == CreditDueRuleType.fixedDay
            ? normalized.dueDay
            : null,
        clearDueDay:
            currentCredit.dueRuleType != CreditDueRuleType.fixedDay ||
            normalized.dueDay == null,
      );
      nextCreditAccounts[creditIndex] = nextCredit;
      next = _accountsWithCreditMirrors(next, nextCredit);
      creditProfileChanged = true;
    } else if (creditIndex != -1 && associationChanged) {
      next = _accountsWithCreditMirrors(next, nextCreditAccounts[creditIndex]);
    }
    if (current.creditAccountId != null &&
        current.creditAccountId != normalized.creditAccountId &&
        !next.any((item) => item.creditAccountId == current.creditAccountId)) {
      nextCreditAccounts.removeWhere(
        (item) => item.id == current.creditAccountId,
      );
    }
    final requiresAggregate =
        createdCreditAccount != null ||
        creditProfileChanged ||
        nextCreditAccounts.length != _creditAccounts.length;
    try {
      if (!requiresAggregate) {
        await _repository.saveAccounts(next);
      } else {
        await _repository.saveCreditAccountAggregate(
          creditAccounts: nextCreditAccounts,
          accounts: next,
        );
      }
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return false;
    }
    _accounts
      ..clear()
      ..addAll(next);
    if (requiresAggregate) {
      _creditAccounts
        ..clear()
        ..addAll(nextCreditAccounts);
    }
    notifyListeners();
    return true;
  }

  /// 删除账户。成功返回被停用的周期规则数，落库失败/账户仍有流水时返回 null。
  Future<int?> deleteAccount(String accountId) {
    return _deleteAccount(accountId, deleteRelatedEntries: false);
  }

  /// 删除账户及其相关交易。成功返回被停用的周期规则数，失败返回 null。
  Future<int?> deleteAccountAndRelatedEntries(String accountId) {
    return _deleteAccount(accountId, deleteRelatedEntries: true);
  }

  Future<int?> _deleteAccount(
    String accountId, {
    required bool deleteRelatedEntries,
  }) async {
    final removedAccount = _accounts
        .where((account) => account.id == accountId)
        .firstOrNull;
    if (removedAccount == null) {
      return null;
    }
    final directlyRelatedIds = _entries
        .where((entry) => entryTouchesAccount(entry, accountId))
        .map((entry) => entry.id)
        .toSet();
    if (!deleteRelatedEntries && directlyRelatedIds.isNotEmpty) {
      return null;
    }
    final removeIds = deleteRelatedEntries
        ? _withDependentRefundIds(directlyRelatedIds)
        : const <String>{};

    var affected = 0;
    final nextRules = <RecurringRule>[];
    for (final rule in _recurringRules) {
      final hitsFrom = rule.accountId == accountId;
      final hitsTo = rule.toAccountId == accountId;
      if (!hitsFrom && !hitsTo) {
        nextRules.add(rule);
        continue;
      }
      nextRules.add(
        rule.copyWith(
          active: false,
          accountId: hitsFrom ? '' : null,
          clearToAccountId: hitsTo,
        ),
      );
      affected++;
    }
    final nextAccounts = _accounts
        .where((account) => account.id != accountId)
        .toList();
    final nextCreditAccounts = _creditAccounts
        .where(
          (creditAccount) =>
              creditAccount.id != removedAccount.creditAccountId ||
              nextAccounts.any(
                (account) => account.creditAccountId == creditAccount.id,
              ),
        )
        .toList();
    final nextEntries = _entriesWithSyncedRefundCache(
      _entries.where((entry) => !removeIds.contains(entry.id)),
    )..sort(_compareEntriesLatestFirst);
    final nextAttachments = _attachments
        .where((attachment) => !removeIds.contains(attachment.entryId))
        .toList();
    final nextOrders = <String, List<String>>{
      for (final entry in _assetAccountOrders.entries)
        entry.key: entry.value.where((id) => id != accountId).toList(),
    };
    final nextDefaults = Map<String, String>.of(_defaultAccountIds)
      ..removeWhere((_, id) => id == accountId);
    final removedStatementIds = _billingStatements
        .where((statement) => statement.accountId == accountId)
        .map((statement) => statement.id)
        .toSet();
    final nextAnchors = _balanceAnchors
        .where((anchor) => anchor.accountId != accountId)
        .toList();
    final nextStatements = _billingStatements
        .where((statement) => statement.accountId != accountId)
        .toList();
    final nextAllocations = _statementRepaymentAllocations
        .where(
          (allocation) =>
              !removedStatementIds.contains(allocation.statementId) &&
              !removeIds.contains(allocation.repaymentEntryId),
        )
        .toList();

    final saved = await _runTrackedWrite(
      () => _repository.replaceAllLedgerData(
        _ledgerDataSnapshot(
          accounts: nextAccounts,
          creditAccounts: nextCreditAccounts,
          attachments: nextAttachments,
          entries: nextEntries,
          recurringRules: nextRules,
          balanceAnchors: nextAnchors,
          billingStatements: nextStatements,
          statementRepaymentAllocations: nextAllocations,
        ),
      ),
    );
    if (!saved) {
      return null;
    }

    _accounts
      ..clear()
      ..addAll(nextAccounts);
    _creditAccounts
      ..clear()
      ..addAll(nextCreditAccounts);
    _entries
      ..clear()
      ..addAll(nextEntries);
    _attachments
      ..clear()
      ..addAll(nextAttachments);
    _recurringRules
      ..clear()
      ..addAll(nextRules);
    _balanceAnchors
      ..clear()
      ..addAll(nextAnchors);
    _billingStatements
      ..clear()
      ..addAll(nextStatements);
    _statementRepaymentAllocations
      ..clear()
      ..addAll(nextAllocations);
    _assetAccountOrders
      ..clear()
      ..addAll(nextOrders);
    _defaultAccountIds
      ..clear()
      ..addAll(nextDefaults);
    await _persistAccountDeletionPreferences();
    await _sanitizeAutoCaptureReferences(
      removedEntryIds: removeIds,
      removedAccountIds: <String>{accountId},
    );
    notifyListeners();
    return affected;
  }

  Future<void> _persistAccountDeletionPreferences() async {
    try {
      await _store.writeAndFlush(
        _assetAccountOrderKey,
        jsonEncode(_assetAccountOrders),
      );
      if (_defaultAccountIds.isEmpty) {
        await _store.deleteAndFlush(_defaultAccountKey);
      } else {
        await _store.writeAndFlush(
          _defaultAccountKey,
          jsonEncode(_defaultAccountIds),
        );
      }
    } catch (error, stackTrace) {
      // SQLite 权威删除已成功；KV 只保存排序/默认账户，失败时记录并提示，下一次
      // 载入会按现存账户自愈，不回滚已经完成的核心数据删除。
      _handlePersistError(error, stackTrace);
    }
  }

  bool adjustAccountBalance(
    Account account,
    double targetBalance, {
    String note = '余额调整',
  }) {
    final currentBalance = accountBalance(account);
    final difference = targetBalance - currentBalance;
    if (isZeroCurrencyAmount(difference, account.currencyCode)) {
      return false;
    }
    final now = DateTime.now();
    final book = _ledgerBooks
        .where((item) => item.id == account.bookId)
        .firstOrNull;
    if (book == null) return false;
    final rate = rateToBaseAt(
      bookId: account.bookId,
      baseCurrencyCode: book.baseCurrencyCode,
      currencyCode: account.currencyCode,
      date: now,
      rates: _exchangeRates,
    );
    if (rate == null) return false;
    final baseAmount = normalizeCurrencyAmount(
      difference.abs() * rate,
      book.baseCurrencyCode,
    );
    _entries.insert(
      0,
      LedgerEntry(
        id: _generateId('entry'),
        bookId: account.bookId,
        type: difference > 0 ? EntryType.income : EntryType.expense,
        amount: difference.abs(),
        currencyCode: account.currencyCode,
        accountAmount: difference.abs(),
        baseAmount: baseAmount,
        conversionSource: account.currencyCode == book.baseCurrencyCode
            ? ConversionSource.identity
            : ConversionSource.rateTable,
        categoryId: difference > 0
            ? 'balance_adjust_income'
            : 'balance_adjust_expense',
        accountId: account.id,
        note: note,
        occurredAt: now,
      ),
    );
    _entries.sort(_compareEntriesLatestFirst);
    _persistEntries();
    notifyListeners();
    // 余额调整也生成了一笔交易：触发自动备份与小组件刷新。
    onEntryAdded?.call();
    return true;
  }

  /// 不生成交易,直接调整初始余额,使当前余额等于目标值。
  void rebaseAccountBalance(Account account, double targetBalance) {
    final currentBalance = accountBalance(account);
    final difference = targetBalance - currentBalance;
    if (isZeroCurrencyAmount(difference, account.currencyCode)) {
      return;
    }
    final index = _accounts.indexWhere((item) => item.id == account.id);
    if (index == -1) {
      return;
    }
    _accounts[index] = _accounts[index].copyWith(
      initialBalance: normalizeCurrencyAmount(
        _accounts[index].initialBalance + difference,
        account.currencyCode,
      ),
    );
    _persistAccounts();
    notifyListeners();
  }

  /// 新增分类。传入 [parentId] 则创建为该分类的子分类（多级分类）；
  /// 子分类的类型强制继承父分类，[type] 仅在创建顶级分类时生效。
  void addCategory({
    required EntryType type,
    required String label,
    required String iconCode,
    String? parentId,
  }) {
    final trimmedLabel = label.trim();
    if (trimmedLabel.isEmpty) {
      return;
    }
    var resolvedType = type;
    if (parentId != null) {
      final parent = _categories
          .where((category) => category.id == parentId)
          .firstOrNull;
      if (parent == null) {
        return;
      }
      // 子分类类型必须与父分类一致。
      resolvedType = parent.type;
    }
    // 同一父级下已存在同名同类型分类则不重复创建（避免增殖出重复同名分类，
    // 也避免触犯分类唯一约束；名称按归一化比较，容忍大小写/空白/全半角差异）。
    final normalized = normalizedCategoryLabel(trimmedLabel);
    final duplicate = _categories.any(
      (category) =>
          category.type == resolvedType &&
          category.parentId == parentId &&
          normalizedCategoryLabel(category.label) == normalized,
    );
    if (duplicate) {
      return;
    }
    _categories.add(
      Category(
        id: _generateId('category'),
        label: trimmedLabel,
        type: resolvedType,
        iconCode: iconCode,
        parentId: parentId,
      ),
    );
    _persistCategories();
    notifyListeners();
  }

  /// 移动分类到新的父分类下（[newParentId] 为 null 表示移到顶级）。
  /// 拦截：系统分类、指向自身、成环（移到自己的后代下）、跨类型。
  bool moveCategory(String categoryId, String? newParentId) {
    if (_isProtectedCategory(categoryId) || categoryId == newParentId) {
      return false;
    }
    final index = _categories.indexWhere((c) => c.id == categoryId);
    if (index == -1) {
      return false;
    }
    final category = _categories[index];
    if (category.parentId == newParentId) {
      return false;
    }
    if (newParentId != null) {
      final parent = _categories.where((c) => c.id == newParentId).firstOrNull;
      if (parent == null || parent.type != category.type) {
        return false;
      }
      // 不能移动到自己的后代之下，否则会成环。
      if (isDescendantOf(_categories, newParentId, categoryId)) {
        return false;
      }
    }
    // 从原位置摘出并追加到末尾，成为新父级下的最后一个同级。
    _categories.removeAt(index);
    _categories.add(category.copyWith(parentId: newParentId));
    _persistCategories();
    notifyListeners();
    return true;
  }

  void renameCategory(String categoryId, String label) {
    final trimmedLabel = label.trim();
    if (trimmedLabel.isEmpty) {
      return;
    }
    final index = _categories.indexWhere(
      (category) => category.id == categoryId,
    );
    if (index == -1) {
      return;
    }
    _categories[index] = _categories[index].copyWith(label: trimmedLabel);
    _persistCategories();
    notifyListeners();
  }

  void updateCategoryIcon(String categoryId, String iconCode) {
    final index = _categories.indexWhere(
      (category) => category.id == categoryId,
    );
    if (index == -1) {
      return;
    }
    _categories[index] = _categories[index].copyWith(iconCode: iconCode);
    _persistCategories();
    notifyListeners();
  }

  /// 在同一父级（[parentId] 为 null 即顶级）的兄弟分类间重排。
  /// 仅在这些兄弟节点占据的全局位置上做置换，不影响其余分类与各自子树。
  void reorderCategories(
    EntryType type,
    String? parentId,
    int oldIndex,
    int newIndex,
  ) {
    final positions = <int>[];
    for (var i = 0; i < _categories.length; i++) {
      final category = _categories[i];
      if (category.type == type && category.parentId == parentId) {
        positions.add(i);
      }
    }
    if (oldIndex < 0 ||
        oldIndex >= positions.length ||
        newIndex < 0 ||
        newIndex > positions.length) {
      return;
    }
    final siblings = <Category>[for (final p in positions) _categories[p]];
    final moved = siblings.removeAt(oldIndex);
    siblings.insert(newIndex.clamp(0, siblings.length), moved);
    for (var k = 0; k < positions.length; k++) {
      _categories[positions[k]] = siblings[k];
    }
    _persistCategories();
    notifyListeners();
  }

  /// Persists a complete category ordering draft after the user explicitly
  /// saves sorting mode. Category fields are read from the current controller
  /// snapshot so a stale editor cannot overwrite a rename or icon change.
  Future<bool> saveCategoryOrderDraft(List<String> orderedIds) async {
    final currentIds = _categories.map((category) => category.id).toSet();
    if (orderedIds.length != _categories.length ||
        orderedIds.toSet().length != orderedIds.length ||
        !orderedIds.toSet().containsAll(currentIds)) {
      return false;
    }
    final byId = <String, Category>{
      for (final category in _categories) category.id: category,
    };
    final next = <Category>[for (final id in orderedIds) byId[id]!];
    try {
      await _repository.saveCategories(next);
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return false;
    }
    _categories
      ..clear()
      ..addAll(next);
    notifyListeners();
    return true;
  }

  Future<bool> deleteCategory(String categoryId) async {
    if (_isProtectedCategory(categoryId)) {
      return false;
    }
    final category = _categories
        .where((item) => item.id == categoryId)
        .firstOrNull;
    if (category == null || categoryUsageCount(categoryId) > 0) {
      return false;
    }
    // 仍被周期规则引用时不能删除，否则规则到期会生成悬空分类的交易。
    if (categoryUsedByRecurringRule(categoryId)) {
      return false;
    }
    // 有子分类时不能直接删除，需先移动或删除子分类。
    if (hasChildren(_categories, categoryId)) {
      return false;
    }
    if (categoriesForType(category.type).length <= 1) {
      return false;
    }
    final nextCategories = _categories
        .where((item) => item.id != categoryId)
        .toList();
    // 清理该分类在各账本/月份下的分类预算，避免残留孤儿键。
    final nextCategoryBudgets = Map<String, double>.of(_categoryBudgets)
      ..removeWhere((key, _) => key.endsWith(':$categoryId'));
    final saved = await _runTrackedWrite(
      () => _repository.replaceAllLedgerData(
        _ledgerDataSnapshot(
          categories: nextCategories,
          categoryBudgets: nextCategoryBudgets,
        ),
      ),
    );
    if (!saved) {
      return false;
    }
    _categories
      ..clear()
      ..addAll(nextCategories);
    _categoryBudgets
      ..clear()
      ..addAll(nextCategoryBudgets);
    await _sanitizeAutoCaptureReferences(
      removedCategoryIds: <String>{categoryId},
    );
    notifyListeners();
    return true;
  }

  int categoryUsageCount(String categoryId) {
    return _entries.where((entry) => entry.categoryId == categoryId).length;
  }

  /// 该分类及其全部子分类合计引用的交易笔数。用于分类管理列表展示笔数，
  /// 使「大类」也能反映记在子类下的消费（避免只记子类时大类恒显示 0 笔的困惑）。
  int categoryUsageCountInTree(String categoryId) {
    final ids = <String>{categoryId, ...descendantIds(categories, categoryId)};
    return _entries.where((entry) => ids.contains(entry.categoryId)).length;
  }

  /// 是否有周期规则正引用该分类（含尚未生成过任何交易的规则）。
  bool categoryUsedByRecurringRule(String categoryId) {
    return _recurringRules.any((rule) => rule.categoryId == categoryId);
  }

  /// 引用该分类的周期规则数（用于 UI 提示）。
  int categoryRecurringRuleCount(String categoryId) {
    return _recurringRules
        .where((rule) => rule.categoryId == categoryId)
        .length;
  }

  /// 把 [sourceId] 分类合并到 [targetId]：其全部交易与周期规则改指向 [targetId]，
  /// 随后删除 [sourceId]（连同其分类预算）。用于统一同义分类（如「交通出行」并入「交通」）。
  ///
  /// 返回被改动的交易笔数；无法合并时返回 -1（源受保护 / 源或目标不存在 / 类型不一致 /
  /// 源与目标相同 / 源仍有子分类 / 目标是源的后代）。源有子分类时应先移动或删除子分类。
  Future<int> mergeCategoryInto(String sourceId, String targetId) async {
    if (sourceId == targetId || _isProtectedCategory(sourceId)) {
      return -1;
    }
    final source = _categories.where((c) => c.id == sourceId).firstOrNull;
    final target = _categories.where((c) => c.id == targetId).firstOrNull;
    if (source == null || target == null || source.type != target.type) {
      return -1;
    }
    // 源有子分类无法整体合并（会孤立子树）；目标是源的后代同理不允许。
    if (hasChildren(_categories, sourceId) ||
        isDescendantOf(_categories, targetId, sourceId)) {
      return -1;
    }
    final changed = _entries
        .where((entry) => entry.categoryId == sourceId)
        .length;
    final nextEntries = <LedgerEntry>[
      for (final entry in _entries)
        entry.categoryId == sourceId
            ? entry.copyWith(categoryId: targetId)
            : entry,
    ];
    final nextRules = <RecurringRule>[
      for (final rule in _recurringRules)
        rule.categoryId == sourceId
            ? rule.copyWith(categoryId: targetId)
            : rule,
    ];
    final nextCategories = _categories
        .where((category) => category.id != sourceId)
        .toList();
    // 清理源分类的分类预算，避免残留孤儿键。
    final nextCategoryBudgets = Map<String, double>.of(_categoryBudgets)
      ..removeWhere((key, _) => key.endsWith(':$sourceId'));
    final saved = await _runTrackedWrite(
      () => _repository.replaceAllLedgerData(
        _ledgerDataSnapshot(
          categories: nextCategories,
          entries: nextEntries,
          recurringRules: nextRules,
          categoryBudgets: nextCategoryBudgets,
        ),
      ),
    );
    if (!saved) {
      return -1;
    }
    _entries
      ..clear()
      ..addAll(nextEntries);
    _recurringRules
      ..clear()
      ..addAll(nextRules);
    _categories
      ..clear()
      ..addAll(nextCategories);
    _categoryBudgets
      ..clear()
      ..addAll(nextCategoryBudgets);
    await _sanitizeAutoCaptureReferences(
      removedCategoryIds: <String>{sourceId},
      categoryRemap: <String, String>{sourceId: targetId},
    );
    notifyListeners();
    return changed;
  }

  // ---- 标签 ----

  /// 新增标签。名称去重（忽略首尾空白，区分大小写），已存在则返回其 id。
  String? addTag(String label) {
    final trimmed = label.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final existing = _tags.where((tag) => tag.label == trimmed).firstOrNull;
    if (existing != null) {
      return existing.id;
    }
    final tag = Tag(id: _generateId('tag'), label: trimmed);
    _tags.add(tag);
    _persistTags();
    notifyListeners();
    return tag.id;
  }

  void renameTag(String tagId, String label) {
    final trimmed = label.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final index = _tags.indexWhere((tag) => tag.id == tagId);
    if (index == -1) {
      return;
    }
    _tags[index] = _tags[index].copyWith(label: trimmed);
    _persistTags();
    notifyListeners();
  }

  void reorderTags(int oldIndex, int newIndex) {
    if (oldIndex < 0 ||
        oldIndex >= _tags.length ||
        newIndex < 0 ||
        newIndex > _tags.length) {
      return;
    }
    final moved = _tags.removeAt(oldIndex);
    _tags.insert(newIndex.clamp(0, _tags.length), moved);
    _persistTags();
    notifyListeners();
  }

  /// Persists the tag order only after sorting mode is explicitly saved.
  Future<bool> saveTagOrderDraft(List<String> orderedIds) async {
    final currentIds = _tags.map((tag) => tag.id).toSet();
    if (orderedIds.length != _tags.length ||
        orderedIds.toSet().length != orderedIds.length ||
        !orderedIds.toSet().containsAll(currentIds)) {
      return false;
    }
    final byId = <String, Tag>{for (final tag in _tags) tag.id: tag};
    final next = <Tag>[for (final id in orderedIds) byId[id]!];
    try {
      await _repository.saveTags(next);
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return false;
    }
    _tags
      ..clear()
      ..addAll(next);
    notifyListeners();
    return true;
  }

  /// 删除标签，并从所有交易的 tagIds 中移除该标签的引用。
  Future<bool> deleteTag(String tagId) async {
    final index = _tags.indexWhere((tag) => tag.id == tagId);
    if (index == -1) {
      return false;
    }
    final nextTags = List<Tag>.of(_tags)..removeAt(index);
    final nextEntries = <LedgerEntry>[
      for (final entry in _entries)
        if (entry.tagIds.contains(tagId))
          entry.copyWith(
            tagIds: entry.tagIds.where((id) => id != tagId).toList(),
          )
        else
          entry,
    ];
    final saved = await _runTrackedWrite(
      () => _repository.replaceAllLedgerData(
        _ledgerDataSnapshot(tags: nextTags, entries: nextEntries),
      ),
    );
    if (!saved) {
      return false;
    }
    _tags
      ..clear()
      ..addAll(nextTags);
    _entries
      ..clear()
      ..addAll(nextEntries);
    await _sanitizeAutoCaptureReferences(removedTagIds: <String>{tagId});
    notifyListeners();
    return true;
  }

  Future<bool> addAccountGroup(String name) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      return false;
    }
    final next = <AccountGroup>[
      ..._accountGroups,
      AccountGroup(
        id: _generateId('group'),
        bookId: _activeBookId,
        name: trimmedName,
        sortOrder: accountGroups.length,
      ),
    ];
    final saved = await _runTrackedWrite(
      () => _repository.saveAccountGroups(next),
    );
    if (!saved) {
      return false;
    }
    _accountGroups
      ..clear()
      ..addAll(next);
    notifyListeners();
    return true;
  }

  Future<bool> renameAccountGroup(String groupId, String name) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      return false;
    }
    final index = _accountGroups.indexWhere((group) => group.id == groupId);
    if (index == -1) {
      return false;
    }
    final next = List<AccountGroup>.of(_accountGroups);
    next[index] = next[index].copyWith(name: trimmedName);
    final saved = await _runTrackedWrite(
      () => _repository.saveAccountGroups(next),
    );
    if (!saved) {
      return false;
    }
    _accountGroups
      ..clear()
      ..addAll(next);
    notifyListeners();
    return true;
  }

  Future<bool> deleteAccountGroup(String groupId) async {
    if (!_accountGroups.any((group) => group.id == groupId)) {
      return false;
    }
    final grouped = <String, List<AccountGroup>>{};
    for (final group in _accountGroups.where((group) => group.id != groupId)) {
      grouped.putIfAbsent(group.bookId, () => <AccountGroup>[]).add(group);
    }
    final nextGroups = <AccountGroup>[];
    for (final groups in grouped.values) {
      groups.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
      nextGroups.addAll(
        groups.indexed.map((item) => item.$2.copyWith(sortOrder: item.$1)),
      );
    }
    final nextAccounts = <Account>[
      for (final account in _accounts)
        account.groupId == groupId
            ? account.copyWith(groupId: 'ungrouped')
            : account,
    ];
    final saved = await _runTrackedWrite(
      () => _repository.replaceAllLedgerData(
        _ledgerDataSnapshot(accounts: nextAccounts, accountGroups: nextGroups),
      ),
    );
    if (!saved) {
      return false;
    }
    _accountGroups
      ..clear()
      ..addAll(nextGroups);
    _accounts
      ..clear()
      ..addAll(nextAccounts);
    notifyListeners();
    return true;
  }

  void reorderAccountGroup(int oldIndex, int newIndex) {
    final groups = accountGroups.toList();
    final otherGroups = _accountGroups
        .where((group) => group.bookId != _activeBookId)
        .toList();
    if (newIndex > oldIndex) {
      newIndex -= 1;
    }
    final moved = groups.removeAt(oldIndex);
    groups.insert(newIndex, moved);
    _accountGroups
      ..clear()
      ..addAll(otherGroups)
      ..addAll(
        groups.indexed.map((item) => item.$2.copyWith(sortOrder: item.$1)),
      );
    _persistAccountGroups();
    notifyListeners();
  }

  /// Persists the active book's account-group order after explicit save.
  Future<bool> saveAccountGroupOrderDraft(List<String> orderedIds) async {
    final current = accountGroups;
    final currentIds = current.map((group) => group.id).toSet();
    if (orderedIds.length != current.length ||
        orderedIds.toSet().length != orderedIds.length ||
        !orderedIds.toSet().containsAll(currentIds)) {
      return false;
    }
    final byId = <String, AccountGroup>{
      for (final group in current) group.id: group,
    };
    final nextActive = <AccountGroup>[
      for (final item in orderedIds.indexed)
        byId[item.$2]!.copyWith(sortOrder: item.$1),
    ];
    final next = <AccountGroup>[
      for (final group in _accountGroups)
        if (group.bookId != _activeBookId) group,
      ...nextActive,
    ];
    try {
      await _repository.saveAccountGroups(next);
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return false;
    }
    _accountGroups
      ..clear()
      ..addAll(next);
    notifyListeners();
    return true;
  }

  void updateProfile(UserProfile profile) {
    _profile = profile;
    _store.write(_profileKey, jsonEncode(profile.toJson()));
    notifyListeners();
  }

  /// 个人资料编辑页的显式提交；KV 写入成功后才替换 Controller 快照。
  Future<bool> saveProfileDraft(UserProfile profile) async {
    try {
      await _store.writeAndFlush(_profileKey, jsonEncode(profile.toJson()));
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return false;
    }
    _profile = profile;
    notifyListeners();
    return true;
  }

  void setAssetCoverUrl(String value) {
    _assetCoverUrl = value.trim();
    if (_assetCoverUrl.isEmpty) {
      _store.delete(_assetCoverKey);
    } else {
      _store.write(_assetCoverKey, _assetCoverUrl);
    }
    notifyListeners();
  }

  void resetAllData() {
    // 偏好类 KV 键清空；账目类数据在下方以默认状态写回 SQLite。
    for (final key in <String>[
      _themeKey,
      _profileKey,
      _activeBookKey,
      _assetCoverKey,
      _hapticsKey,
      _assetViewModeKey,
      _assetSectionCollapsedKey,
      _assetAccountOrderKey,
      _assetSectionOrderKey,
      _homePanelsKey,
      _reportPanelsKey,
      _autoCaptureSettingsKey,
      WidgetConfigStore.definitionsKey,
      WidgetConfigStore.placementsKey,
      WidgetConfigStore.storageKey,
    ]) {
      _store.delete(key);
    }
    _entries.clear();
    _captureEvents.clear();
    _autoCaptureRules.clear();
    _accounts
      ..clear()
      ..addAll(defaultAccounts);
    _accountGroups
      ..clear()
      ..addAll(defaultAccountGroups);
    _creditAccounts.clear();
    _ledgerBooks
      ..clear()
      ..addAll(_seedLedgerBooks);
    _categories
      ..clear()
      ..addAll(_seedCategories);
    _tags.clear();
    _attachments.clear();
    _recurringRules.clear();
    _exchangeRates.clear();
    _balanceAnchors.clear();
    _billingStatements.clear();
    _statementRepaymentAllocations.clear();
    _monthlyBudgets.clear();
    _categoryBudgets.clear();
    _dailyBudgets.clear();
    _profile = _seedProfile;
    _themePreference = ThemePreference.system;
    _activeBookId = defaultLedgerBookId;
    _assetCoverUrl = '';
    _hapticsEnabled = true;
    _autoCaptureSettings = AutoCaptureSettings.disabled;
    onAutoCaptureSettingsChanged?.call(_autoCaptureSettings);
    _assetAccountViewMode = AssetAccountViewMode.type;
    _collapsedAssetSections.clear();
    _assetAccountOrders.clear();
    _assetSectionOrders.clear();
    // 账户被清空，默认付款账户随之失效。
    _defaultAccountIds.clear();
    _persistDefaultAccounts();
    // 预算周期起始日随预算一起回到默认（自然月）。
    _budgetCycleStartDays.clear();
    _persistBudgetCycleStartDays();
    for (final page in PanelPageKind.values) {
      _pagePanels[page] = _defaultPanelSettings(page.specs);
    }
    // 把重置后的默认状态写回 SQLite（单事务原子替换全部表）。
    _persistAllLedgerData();
    _persistCaptureEvents();
    _persistAutoCaptureRules();
    themePreferenceListenable.value = _themePreference;
    notifyListeners();
  }

  String exportDataJson() {
    final payload = <String, Object?>{
      'app': 'verifin',
      'version': 7,
      'exportedAt': DateTime.now().toIso8601String(),
      'data': <String, Object?>{
        'ledgerBooks': _ledgerBooks.map((book) => book.toJson()).toList(),
        'activeBookId': _activeBookId,
        'entries': _entries.map((entry) => entry.toJson()).toList(),
        'accounts': _accounts.map((account) => account.toJson()).toList(),
        'accountGroups': _accountGroups.map((group) => group.toJson()).toList(),
        'creditAccounts': _creditAccounts
            .map((creditAccount) => creditAccount.toJson())
            .toList(),
        'categories': _categories.map((category) => category.toJson()).toList(),
        'tags': _tags.map((tag) => tag.toJson()).toList(),
        'attachments': _attachments.map((a) => a.toJson()).toList(),
        'recurringRules': _recurringRules.map((r) => r.toJson()).toList(),
        'exchangeRates': _exchangeRates.map((rate) => rate.toJson()).toList(),
        'balanceAnchors': _balanceAnchors.map((item) => item.toJson()).toList(),
        'billingStatements': _billingStatements
            .map((item) => item.toJson())
            .toList(),
        'statementRepaymentAllocations': _statementRepaymentAllocations
            .map((item) => item.toJson())
            .toList(),
        'monthlyBudgets': Map<String, double>.from(_monthlyBudgets),
        'categoryBudgets': Map<String, double>.from(_categoryBudgets),
        'dailyBudgets': Map<String, double>.from(_dailyBudgets),
        'budgetCycleStartDays': Map<String, int>.from(_budgetCycleStartDays),
        'profile': _profile.toJson(),
        'themePreference': _themePreference.name,
        'assetCoverUrl': _assetCoverUrl,
        'hapticsEnabled': _hapticsEnabled,
        'assetAccountViewMode': _assetAccountViewMode.name,
        'collapsedAssetSections': _collapsedAssetSections.toList(),
        'assetAccountOrders': _assetAccountOrders,
        'assetSectionOrders': _assetSectionOrders,
        'homePanels': _pagePanels[PanelPageKind.home]!
            .map((item) => item.toJson())
            .toList(),
        'reportPanels': _pagePanels[PanelPageKind.reports]!
            .map((item) => item.toJson())
            .toList(),
        'defaultAccountIds': Map<String, String>.from(_defaultAccountIds),
        'fabActionMode': _fabActionMode.name,
        'amountForceTwoDecimals': _amountForceTwoDecimals,
        'currencyFractionStyle': amount_format.currencyFractionStyle.name,
        'moneyUnitStyle': _moneyUnitStyle.name,
        'hideUnitInSingleCurrency': _hideUnitInSingleCurrency,
        'autoSuggestEnabled': _autoSuggestEnabled,
        'showRunningBalance': _showRunningBalance,
        'homeTrendConfig': _homeTrendConfig.toJson(),
      },
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  /// 从明文导出 JSON 导入。**字节层的格式判定（zip/加密信封/明文）不在 controller**
  /// ——调用方先经 `BackupService.decodeBackupBytes`（必要时 `decryptEnvelope`）
  /// 还原成明文 JSON 再传入，controller 只认 JSON。
  void importDataJson(String rawJson) {
    final Object? decoded;
    try {
      decoded = jsonDecode(rawJson);
    } on FormatException {
      // jsonDecode 的原始报错是英文（Unexpected character…），不能直接展示给用户。
      throw const FormatException('备份文件格式不正确');
    }
    if (decoded is! Map) {
      throw const FormatException('备份文件格式不正确');
    }
    final root = Map<String, Object?>.from(decoded);

    final rawVersion = root['version'];
    if (rawVersion != null && rawVersion is! num) {
      throw const FormatException('备份版本格式不正确');
    }
    final version = (rawVersion as num?)?.toInt() ?? 1;
    if (version < 1 || version > 7) {
      throw FormatException('不支持的备份版本：$version');
    }

    // 防御性拦截加密信封：它带 `app:'verifin'` 但只有密文、无任何数据键，若直接
    // 往下走会被当成「空备份」用默认数据覆盖并清库。加密备份必须先解密再导入。
    if (root['enc'] != null || root.containsKey('cipher')) {
      throw const FormatException('这是加密备份，请先输入口令解密后再导入');
    }

    final dataValue = root['data'] ?? root;
    if (dataValue is! Map) {
      throw const FormatException('备份文件缺少数据内容');
    }
    final data = Map<String, Object?>.from(dataValue);

    // 只接受本应用的备份：必须至少含一个已知数据键。仅有 `app` 标记而无任何数据键
    // 的 JSON（如残缺/异常文件）一律拒绝，绝不在导入前清空/覆盖现有数据。
    final looksLikeVeriFinBackup = data.keys.any(_knownBackupDataKeys.contains);
    if (!looksLikeVeriFinBackup) {
      throw const FormatException('不是本应用的备份文件');
    }

    final importedBooks = _decodeModelList<LedgerBook>(
      data['ledgerBooks'],
      LedgerBook.fromJson,
    );
    final nextLedgerBooks = <LedgerBook>[
      ...(importedBooks.isEmpty ? _seedLedgerBooks : importedBooks),
    ];
    if (!nextLedgerBooks.any((book) => book.id == defaultLedgerBookId)) {
      nextLedgerBooks.insert(0, _seedLedgerBooks.first);
    }

    final importedActiveBookId = data['activeBookId'] as String?;
    final nextActiveBookId =
        importedActiveBookId != null &&
            nextLedgerBooks.any((book) => book.id == importedActiveBookId)
        ? importedActiveBookId
        : defaultLedgerBookId;

    final nextEntries = _decodeModelList<LedgerEntry>(
      data['entries'],
      LedgerEntry.fromJson,
    )..sort(_compareEntriesLatestFirst);
    var nextAccounts = _decodeModelList<Account>(
      data['accounts'],
      Account.fromJson,
    );
    final nextAccountGroups = _decodeModelList<AccountGroup>(
      data['accountGroups'],
      AccountGroup.fromJson,
    );
    var nextCreditAccounts = _decodeModelList<CreditAccount>(
      data['creditAccounts'],
      CreditAccount.fromJson,
    );
    // v4 及更早备份只有账户内的额度/日期。为每个信用账户补一个稳定的一对一主体，
    // 保持旧行为；新备份则直接恢复显式父子关系。
    if (nextCreditAccounts.isEmpty) {
      final migratedAccounts = <Account>[];
      final migratedCreditAccounts = <CreditAccount>[];
      for (final account in nextAccounts) {
        if (!account.type.supportsCredit) {
          migratedAccounts.add(account);
          continue;
        }
        final creditAccountId =
            account.creditAccountId ?? 'credit-account-${account.id}';
        migratedCreditAccounts.add(
          CreditAccount(
            id: creditAccountId,
            bookId: account.bookId,
            name: account.name,
            institution: '',
            cardLast4: account.cardLast4,
            currencyCode: account.currencyCode,
            creditLimit: account.creditLimit,
            statementDay: account.statementDay,
            dueRuleType: CreditDueRuleType.fixedDay,
            dueDay: account.dueDay,
            daysAfterStatement: null,
            cycleBudget: null,
          ),
        );
        migratedAccounts.add(
          account.copyWith(creditAccountId: creditAccountId),
        );
      }
      nextAccounts = migratedAccounts;
      nextCreditAccounts = migratedCreditAccounts;
    }
    final importedCategories = _decodeModelList<Category>(
      data['categories'],
      Category.fromJson,
    );
    final nextCategories = <Category>[
      ...(importedCategories.isEmpty ? _seedCategories : importedCategories),
    ];
    final nextTags = _decodeModelList<Tag>(data['tags'], Tag.fromJson);
    final nextAttachments = _decodeModelList<Attachment>(
      data['attachments'],
      Attachment.fromJson,
    );
    final nextRecurringRules = _decodeModelList<RecurringRule>(
      data['recurringRules'],
      RecurringRule.fromJson,
    );
    final nextExchangeRates = _decodeModelList<ExchangeRate>(
      data['exchangeRates'],
      ExchangeRate.fromJson,
    );
    final nextBalanceAnchors = _decodeModelList<BalanceAnchor>(
      data['balanceAnchors'],
      BalanceAnchor.fromJson,
    );
    final nextBillingStatements = _decodeModelList<BillingStatement>(
      data['billingStatements'],
      BillingStatement.fromJson,
    );
    final nextStatementRepaymentAllocations =
        _decodeModelList<StatementRepaymentAllocation>(
          data['statementRepaymentAllocations'],
          StatementRepaymentAllocation.fromJson,
        );
    final nextMonthlyBudgets = _bookScopedBudgets(
      _decodeBudgets(data['monthlyBudgets']),
    );
    final nextCategoryBudgets = _bookScopedBudgets(
      _decodeBudgets(data['categoryBudgets']),
    );
    // 按日预算键是纯 bookId（无日期前缀），无需 _bookScopedBudgets 迁移。
    final nextDailyBudgets = _decodeBudgets(data['dailyBudgets']);
    // 预算周期起始日（键为 bookId）：旧备份缺键回落空表（= 全部自然月）。
    final rawBudgetCycles = data['budgetCycleStartDays'];
    final nextBudgetCycleStartDays = <String, int>{
      if (rawBudgetCycles is Map)
        for (final entry in rawBudgetCycles.entries)
          if (entry.value is num)
            entry.key.toString(): clampBudgetCycleStartDay(
              (entry.value as num).toInt(),
            ),
    };

    final profileValue = data['profile'];
    final nextProfile = profileValue is Map
        ? UserProfile.fromJson(Map<String, Object?>.from(profileValue))
        : _seedProfile;
    final nextThemePreference = ThemePreference.fromStorage(
      data['themePreference'] as String?,
    );
    final nextAssetCoverUrl = data['assetCoverUrl'] as String? ?? '';
    final nextHapticsEnabled = data['hapticsEnabled'] as bool? ?? true;
    final nextAssetAccountViewMode = AssetAccountViewMode.fromStorage(
      data['assetAccountViewMode'] as String?,
    );
    final nextCollapsedAssetSections = _decodeStringSet(
      data['collapsedAssetSections'],
    );
    final nextAssetAccountOrders = _decodeStringListMap(
      data['assetAccountOrders'],
    );
    final nextAssetSectionOrders = _decodeStringListMap(
      data['assetSectionOrders'],
    );
    // 旧备份没有面板字段,归一化会补全默认开启的面板。
    final nextHomePanels = _normalizePanelSettings(
      _decodeModelList<PagePanelSetting>(
        data['homePanels'],
        PagePanelSetting.fromJson,
      ),
      homePanelSpecs,
    );
    final nextReportPanels = _normalizePanelSettings(
      _decodeModelList<PagePanelSetting>(
        data['reportPanels'],
        PagePanelSetting.fromJson,
      ),
      reportPanelSpecs,
    );
    // 以下 4 项是设备偏好，缺键（旧备份）回落默认，与 theme/haptics 等同一套「整替」语义。
    final rawDefaultAccounts = data['defaultAccountIds'];
    final nextDefaultAccountIds = <String, String>{
      if (rawDefaultAccounts is Map)
        for (final entry in rawDefaultAccounts.entries)
          entry.key.toString(): entry.value.toString(),
    };
    final nextFabActionMode = FabActionMode.fromStorage(
      data['fabActionMode'] as String?,
    );
    final nextCurrencyFractionStyle = data.containsKey('currencyFractionStyle')
        ? CurrencyFractionStyle.fromStorage(
            data['currencyFractionStyle'] as String?,
          )
        : (data['amountForceTwoDecimals'] as bool? ?? false)
        ? CurrencyFractionStyle.standard
        : CurrencyFractionStyle.compact;
    final nextAmountForceTwoDecimals =
        nextCurrencyFractionStyle == CurrencyFractionStyle.standard;
    final nextMoneyUnitStyle = MoneyUnitStyle.fromStorage(
      data['moneyUnitStyle'] as String?,
    );
    final nextHideUnitInSingleCurrency =
        data['hideUnitInSingleCurrency'] as bool? ?? true;
    // 旧备份没有这个键：按「功能一直是开着的」还原，不因恢复备份而静默关掉。
    final nextAutoSuggestEnabled = data['autoSuggestEnabled'] as bool? ?? true;
    // 旧备份没有这个键：默认关闭，保持旧行为。
    final nextShowRunningBalance = data['showRunningBalance'] as bool? ?? false;
    final homeTrendValue = data['homeTrendConfig'];
    final nextHomeTrendConfig = homeTrendValue is Map
        ? HomeTrendConfig.fromJson(Map<String, dynamic>.from(homeTrendValue))
        : HomeTrendConfig.defaults;

    _validateImportedCurrencyData(
      books: nextLedgerBooks,
      accounts: nextAccounts,
      creditAccounts: nextCreditAccounts,
      entries: nextEntries,
      recurringRules: nextRecurringRules,
      exchangeRates: nextExchangeRates,
      monthlyBudgets: nextMonthlyBudgets,
      categoryBudgets: nextCategoryBudgets,
      dailyBudgets: nextDailyBudgets,
      balanceAnchors: nextBalanceAnchors,
      billingStatements: nextBillingStatements,
      statementRepaymentAllocations: nextStatementRepaymentAllocations,
    );
    final ledgerIssue = validateLedgerEntries(
      books: nextLedgerBooks,
      accounts: nextAccounts,
      entries: nextEntries,
      allowMissingAccounts: true,
    );
    if (ledgerIssue != null &&
        ledgerIssue.code != LedgerDataValidationCode.staleRefundCache) {
      throw FormatException('账目关联或金额不合法：${ledgerIssue.code.name}');
    }

    _ledgerBooks
      ..clear()
      ..addAll(nextLedgerBooks);
    _activeBookId = nextActiveBookId;
    _entries
      ..clear()
      ..addAll(nextEntries);
    _accounts
      ..clear()
      ..addAll(nextAccounts);
    _accountGroups
      ..clear()
      ..addAll(nextAccountGroups);
    _creditAccounts
      ..clear()
      ..addAll(nextCreditAccounts);
    _normalizeGroupOrder();
    _categories
      ..clear()
      ..addAll(nextCategories);
    _tags
      ..clear()
      ..addAll(nextTags);
    _attachments
      ..clear()
      ..addAll(nextAttachments);
    _recurringRules
      ..clear()
      ..addAll(nextRecurringRules);
    _exchangeRates
      ..clear()
      ..addAll(nextExchangeRates);
    _balanceAnchors
      ..clear()
      ..addAll(nextBalanceAnchors);
    _billingStatements
      ..clear()
      ..addAll(nextBillingStatements);
    _statementRepaymentAllocations
      ..clear()
      ..addAll(nextStatementRepaymentAllocations);
    _monthlyBudgets
      ..clear()
      ..addAll(nextMonthlyBudgets);
    _categoryBudgets
      ..clear()
      ..addAll(nextCategoryBudgets);
    _dailyBudgets
      ..clear()
      ..addAll(nextDailyBudgets);
    _budgetCycleStartDays
      ..clear()
      ..addAll(nextBudgetCycleStartDays);
    _profile = nextProfile;
    _themePreference = nextThemePreference;
    _assetCoverUrl = nextAssetCoverUrl;
    _hapticsEnabled = nextHapticsEnabled;
    _assetAccountViewMode = nextAssetAccountViewMode;
    _collapsedAssetSections
      ..clear()
      ..addAll(nextCollapsedAssetSections);
    _assetAccountOrders
      ..clear()
      ..addAll(nextAssetAccountOrders);
    _assetSectionOrders
      ..clear()
      ..addAll(nextAssetSectionOrders);
    _pagePanels[PanelPageKind.home] = nextHomePanels;
    _pagePanels[PanelPageKind.reports] = nextReportPanels;
    _defaultAccountIds
      ..clear()
      ..addAll(nextDefaultAccountIds);
    _fabActionMode = nextFabActionMode;
    _amountForceTwoDecimals = nextAmountForceTwoDecimals;
    amount_format.amountForceTwoDecimals = nextAmountForceTwoDecimals;
    _moneyUnitStyle = nextMoneyUnitStyle;
    _hideUnitInSingleCurrency = nextHideUnitInSingleCurrency;
    _autoSuggestEnabled = nextAutoSuggestEnabled;
    _showRunningBalance = nextShowRunningBalance;
    _homeTrendConfig = nextHomeTrendConfig;
    // 桌面 appWidgetId 与配置只属于当前设备，不随备份导入。
    WidgetConfigStore.savePlacementsSync(_store, const <WidgetPlacement>[]);

    // 备份恢复零参照完整性校验，是「幽灵同名分类」的唯一现实入口（内部不一致的外部/
    // 异构/手改备份）；覆盖后跑一遍自愈，堵住这个入口。落库统一由下方 _persistAllLedgerData。
    _healCategoryData();
    // 退款自愈：把导入数据里的旧标量退款迁成关联退款条目并重算净额缓存。
    _syncRefundData();
    _persistAllLedgerData();
    _store.write(_activeBookKey, _activeBookId);
    _store.write(_profileKey, jsonEncode(_profile.toJson()));
    _store.write(_themeKey, _themePreference.name);
    _store.write(_hapticsKey, _hapticsEnabled.toString());
    _store.write(_assetViewModeKey, _assetAccountViewMode.name);
    _persistAssetSectionCollapsed();
    _persistAssetAccountOrders();
    _persistAssetSectionOrders();
    for (final page in PanelPageKind.values) {
      _persistPagePanels(page);
    }
    _persistDefaultAccounts();
    _persistBudgetCycleStartDays();
    _store.write(_fabActionKey, _fabActionMode.name);
    _store.write(_amountFormatKey, _amountForceTwoDecimals.toString());
    _store.write(_moneyUnitStyleKey, _moneyUnitStyle.name);
    _store.write(
      _hideSingleCurrencyUnitKey,
      _hideUnitInSingleCurrency.toString(),
    );
    _store.write(_autoSuggestKey, _autoSuggestEnabled.toString());
    _store.write(_runningBalanceKey, _showRunningBalance.toString());
    _store.write(_homeTrendKey, _homeTrendConfig.encode());
    if (_assetCoverUrl.isEmpty) {
      _store.delete(_assetCoverKey);
    } else {
      _store.write(_assetCoverKey, _assetCoverUrl);
    }
    themePreferenceListenable.value = _themePreference;
    // 原始事件与规则按隐私约定不进备份，恢复新账本后要清理它们对旧账本实体的悬空引用。
    unawaited(
      _healAutoCaptureReferences().then((_) {
        if (!_controllerDisposed) notifyListeners();
      }),
    );
    notifyListeners();
  }

  void _validateImportedCurrencyData({
    required List<LedgerBook> books,
    required List<Account> accounts,
    required List<CreditAccount> creditAccounts,
    required List<LedgerEntry> entries,
    required List<RecurringRule> recurringRules,
    required List<ExchangeRate> exchangeRates,
    required Map<String, double> monthlyBudgets,
    required Map<String, double> categoryBudgets,
    required Map<String, double> dailyBudgets,
    required List<BalanceAnchor> balanceAnchors,
    required List<BillingStatement> billingStatements,
    required List<StatementRepaymentAllocation> statementRepaymentAllocations,
  }) {
    void requireCurrency(String code, String field) {
      if (!CurrencyCatalog.isSupported(code)) {
        throw FormatException('$field 使用了不支持的币种：$code');
      }
    }

    void requireFinite(
      num? value,
      String field, {
      bool positive = false,
      bool nonNegative = false,
    }) {
      if (value == null) return;
      if (!value.isFinite ||
          (positive && value <= 0) ||
          (nonNegative && value < 0)) {
        throw FormatException('$field 金额不合法');
      }
    }

    final booksById = <String, LedgerBook>{};
    for (final book in books) {
      if (book.id.isEmpty || booksById.containsKey(book.id)) {
        throw const FormatException('账本 id 为空或重复');
      }
      requireCurrency(book.baseCurrencyCode, '账本 ${book.id}');
      booksById[book.id] = book;
    }

    final creditAccountsById = <String, CreditAccount>{};
    for (final creditAccount in creditAccounts) {
      if (creditAccount.id.isEmpty ||
          creditAccountsById.containsKey(creditAccount.id)) {
        throw FormatException('信用账户主体 id 为空或重复：${creditAccount.id}');
      }
      if (!booksById.containsKey(creditAccount.bookId)) {
        throw FormatException('信用账户主体 ${creditAccount.id} 引用了不存在的账本');
      }
      if (creditAccount.name.trim().isEmpty) {
        throw FormatException('信用账户主体 ${creditAccount.id} 名称为空');
      }
      requireCurrency(creditAccount.currencyCode, '信用账户主体 ${creditAccount.id}');
      requireFinite(
        creditAccount.creditLimit,
        '信用账户主体 ${creditAccount.id} 共享额度',
        nonNegative: true,
      );
      requireFinite(
        creditAccount.cycleBudget,
        '信用账户主体 ${creditAccount.id} 账期预算',
        nonNegative: true,
      );
      final statementDay = creditAccount.statementDay;
      if (statementDay != null && (statementDay < 1 || statementDay > 28)) {
        throw FormatException('信用账户主体 ${creditAccount.id} 账单日不合法');
      }
      switch (creditAccount.dueRuleType) {
        case CreditDueRuleType.fixedDay:
          final dueDay = creditAccount.dueDay;
          if (dueDay != null && (dueDay < 1 || dueDay > 28)) {
            throw FormatException('信用账户主体 ${creditAccount.id} 固定还款日不合法');
          }
        case CreditDueRuleType.daysAfterStatement:
          final days = creditAccount.daysAfterStatement;
          if (days == null || days <= 0) {
            throw FormatException('信用账户主体 ${creditAccount.id} 账单后天数不合法');
          }
      }
      creditAccountsById[creditAccount.id] = creditAccount;
    }

    for (final account in accounts) {
      if (!booksById.containsKey(account.bookId)) {
        throw FormatException('账户 ${account.id} 引用了不存在的账本');
      }
      requireCurrency(account.currencyCode, '账户 ${account.id}');
      requireFinite(account.initialBalance, '账户 ${account.id} 初始余额');
      requireFinite(
        account.creditLimit,
        '账户 ${account.id} 信用额度',
        nonNegative: true,
      );
      final creditAccountId = account.creditAccountId;
      if (account.type.supportsCredit &&
          (creditAccountId == null || creditAccountId.isEmpty)) {
        throw FormatException('信用账户 ${account.id} 缺少信用账户主体');
      }
      if (creditAccountId != null && creditAccountId.isNotEmpty) {
        final creditAccount = creditAccountsById[creditAccountId];
        if (creditAccount == null || creditAccount.bookId != account.bookId) {
          throw FormatException('账户 ${account.id} 引用了不存在或跨账本的信用账户主体');
        }
        if (!account.type.supportsCredit) {
          throw FormatException('非信用账户 ${account.id} 不能关联信用账户主体');
        }
      }
    }
    for (final creditAccount in creditAccounts) {
      if (!accounts.any(
        (account) => account.creditAccountId == creditAccount.id,
      )) {
        throw FormatException('信用账户主体 ${creditAccount.id} 没有币种子账户');
      }
    }

    for (final entry in entries) {
      if (!booksById.containsKey(entry.bookId)) {
        throw FormatException('交易 ${entry.id} 引用了不存在的账本');
      }
      requireCurrency(entry.currencyCode, '交易 ${entry.id}');
      requireFinite(entry.amount, '交易 ${entry.id} 原币金额', positive: true);
      requireFinite(
        entry.accountAmount,
        '交易 ${entry.id} 账户金额',
        nonNegative: true,
      );
      requireFinite(
        entry.toAccountAmount,
        '交易 ${entry.id} 转入金额',
        nonNegative: true,
      );
      requireFinite(
        entry.baseAmount,
        '交易 ${entry.id} 本位币金额',
        nonNegative: true,
      );
      requireFinite(
        entry.refundedBaseAmount,
        '交易 ${entry.id} 已退款金额',
        nonNegative: true,
      );
      requireFinite(entry.fee, '交易 ${entry.id} 手续费', nonNegative: true);
      final billingCycleId = entry.billingCycleId;
      if (billingCycleId != null) {
        final cycleDate = DateTime.tryParse(billingCycleId);
        if (cycleDate == null ||
            billingCycleIdFor(cycleDate) != billingCycleId) {
          throw FormatException('交易 ${entry.id} 的账期标识不合法，应为 yyyy-MM-dd');
        }
      }
    }

    for (final rule in recurringRules) {
      if (!booksById.containsKey(rule.bookId)) {
        throw FormatException('周期规则 ${rule.id} 引用了不存在的账本');
      }
      requireCurrency(rule.currencyCode, '周期规则 ${rule.id}');
      requireFinite(rule.amount, '周期规则 ${rule.id} 原币金额', positive: true);
      requireFinite(
        rule.accountAmount,
        '周期规则 ${rule.id} 账户金额',
        nonNegative: true,
      );
      requireFinite(
        rule.toAccountAmount,
        '周期规则 ${rule.id} 转入金额',
        nonNegative: true,
      );
      requireFinite(
        rule.baseAmount,
        '周期规则 ${rule.id} 本位币金额',
        nonNegative: true,
      );
    }

    final rateKeys = <String>{};
    for (final rate in exchangeRates) {
      final book = booksById[rate.bookId];
      if (book == null) {
        throw FormatException('汇率 ${rate.id} 引用了不存在的账本');
      }
      requireCurrency(rate.baseCurrencyCode, '汇率 ${rate.id} 本位币');
      requireCurrency(rate.currencyCode, '汇率 ${rate.id} 外币');
      if (rate.baseCurrencyCode != book.baseCurrencyCode ||
          rate.currencyCode == rate.baseCurrencyCode) {
        throw FormatException('汇率 ${rate.id} 的币种方向不合法');
      }
      requireFinite(rate.rateToBase, '汇率 ${rate.id}', positive: true);
      final key =
          '${rate.bookId}:${rate.currencyCode}:${currencyDateKey(rate.effectiveDate)}';
      if (rate.id.isEmpty || !rateKeys.add(key)) {
        throw const FormatException('汇率 id 为空或同日记录重复');
      }
    }

    for (final item in <Map<String, double>>[
      monthlyBudgets,
      categoryBudgets,
      dailyBudgets,
    ]) {
      for (final entry in item.entries) {
        requireFinite(entry.value, '预算 ${entry.key}', nonNegative: true);
      }
    }

    final accountsById = <String, Account>{
      for (final account in accounts) account.id: account,
    };
    final anchorIds = <String>{};
    for (final anchor in balanceAnchors) {
      if (anchor.id.isEmpty || !anchorIds.add(anchor.id)) {
        throw FormatException('余额锚点 id 为空或重复：${anchor.id}');
      }
      final account = accountsById[anchor.accountId];
      if (account == null || account.bookId != anchor.bookId) {
        throw FormatException('余额锚点 ${anchor.id} 引用了不存在的账户');
      }
      requireFinite(anchor.balance, '余额锚点 ${anchor.id}');
    }
    final statementsById = <String, BillingStatement>{};
    final statementSourceKeys = <String>{};
    for (final statement in billingStatements) {
      if (statement.id.isEmpty || statementsById.containsKey(statement.id)) {
        throw FormatException('正式账单 id 为空或重复：${statement.id}');
      }
      if (statement.sourceId.isNotEmpty &&
          statement.sourceStatementId.isNotEmpty &&
          !statementSourceKeys.add(
            '${statement.bookId}:${statement.accountId}:${statement.sourceId}:${statement.sourceStatementId}',
          )) {
        throw FormatException('正式账单来源 id 重复：${statement.sourceStatementId}');
      }
      final account = accountsById[statement.accountId];
      if (account == null ||
          account.bookId != statement.bookId ||
          !account.type.supportsCredit) {
        throw FormatException('正式账单 ${statement.id} 引用了无效信用账户');
      }
      requireCurrency(statement.currencyCode, '正式账单 ${statement.id}');
      if (statement.currencyCode != account.currencyCode ||
          statement.periodEnd.isBefore(statement.periodStart)) {
        throw FormatException('正式账单 ${statement.id} 的币种或账期不合法');
      }
      requireFinite(
        statement.statementAmount,
        '正式账单 ${statement.id} 应还金额',
        nonNegative: true,
      );
      requireFinite(
        statement.minimumPayment,
        '正式账单 ${statement.id} 最低还款',
        nonNegative: true,
      );
      requireFinite(
        statement.paidAmount,
        '正式账单 ${statement.id} 已还金额',
        nonNegative: true,
      );
      if (statement.minimumPayment > statement.statementAmount ||
          statement.paidAmount > statement.statementAmount) {
        throw FormatException('正式账单 ${statement.id} 金额超过应还金额');
      }
      statementsById[statement.id] = statement;
    }
    final entriesById = <String, LedgerEntry>{};
    for (final entry in entries) {
      entriesById.putIfAbsent(entry.id, () => entry);
    }
    final allocationIds = <String>{};
    final amountByStatement = <String, double>{};
    final amountByRepayment = <String, double>{};
    for (final allocation in statementRepaymentAllocations) {
      if (allocation.id.isEmpty || !allocationIds.add(allocation.id)) {
        throw FormatException('还款分配 id 为空或重复：${allocation.id}');
      }
      final statement = statementsById[allocation.statementId];
      final repayment = entriesById[allocation.repaymentEntryId];
      if (statement == null ||
          repayment == null ||
          allocation.bookId != statement.bookId ||
          repayment.bookId != statement.bookId ||
          repayment.type != EntryType.transfer ||
          repayment.toAccountId != statement.accountId) {
        throw FormatException('还款分配 ${allocation.id} 存在悬空引用');
      }
      requireFinite(allocation.amount, '还款分配 ${allocation.id}', positive: true);
      amountByStatement[statement.id] =
          (amountByStatement[statement.id] ?? 0) + allocation.amount;
      amountByRepayment[repayment.id] =
          (amountByRepayment[repayment.id] ?? 0) + allocation.amount;
    }
    for (final item in amountByStatement.entries) {
      final statement = statementsById[item.key]!;
      if (item.value >
          statement.statementAmount +
              currencyAmountTolerance(statement.currencyCode)) {
        throw FormatException('还款分配 ${statement.id} 超过账单应还金额');
      }
    }
    for (final item in amountByRepayment.entries) {
      final repayment = entriesById[item.key]!;
      final target = accountsById[repayment.toAccountId];
      final capacity =
          repayment.toAccountAmount ??
          (target != null && target.currencyCode == repayment.currencyCode
              ? repayment.amount
              : 0);
      if (item.value >
          capacity +
              currencyAmountTolerance(
                target?.currencyCode ?? repayment.currencyCode,
              )) {
        throw FormatException('还款交易 ${repayment.id} 的分配超过转入金额');
      }
    }
  }

  double accountBalance(Account account) {
    final cached = _accountBalanceCache ??= _computeAccountBalances();
    final value = cached[account.id];
    if (value != null) {
      return value;
    }
    // 不在当前账户集合里（如草稿账户）：退回逐条计算。
    final anchor = latestBalanceAnchor(account.id);
    var balance = anchor?.balance ?? account.initialBalance;
    for (final entry in _entries) {
      if (entry.bookId == account.bookId &&
          entryTouchesAccount(entry, account.id) &&
          (anchor == null ||
              accountEffectDate(entry).isAfter(anchor.effectiveAt))) {
        balance += accountDeltaForEntry(entry, account.id);
      }
    }
    // 按账户币种的 minor unit 消除连续加减产生的浮点残差。
    return normalizeCurrencyAmount(balance, account.currencyCode);
  }

  /// 一次遍历算出全部账户余额，供 [accountBalance] 复用。
  ///
  /// 逐账户调用是 O(账户数 × 交易数)，而首页、资产页、个人页和桌面小组件每次
  /// 重建都要取一遍全部余额。结果按账户币种归一，缓存由 [_invalidateDerivedViews] 失效。
  Map<String, double> _computeAccountBalances() {
    final accountsById = <String, Account>{
      for (final account in _accounts) account.id: account,
    };
    final latestAnchors = <String, BalanceAnchor>{};
    for (final anchor in _balanceAnchors) {
      final current = latestAnchors[anchor.accountId];
      if (current == null || anchor.effectiveAt.isAfter(current.effectiveAt)) {
        latestAnchors[anchor.accountId] = anchor;
      }
    }

    final balances = <String, double>{
      for (final account in _accounts)
        account.id:
            latestAnchors[account.id]?.balance ?? account.initialBalance,
    };
    for (final entry in _entries) {
      final fromId = entry.accountId;
      if (fromId.isNotEmpty) {
        final account = accountsById[fromId];
        final anchor = latestAnchors[fromId];
        if (account != null &&
            account.bookId == entry.bookId &&
            (anchor == null ||
                accountEffectDate(entry).isAfter(anchor.effectiveAt))) {
          balances[fromId] =
              balances[fromId]! + accountDeltaForEntry(entry, fromId);
        }
      }
      final toId = entry.toAccountId;
      // 转出=转入时不重复计入：accountDeltaForEntry 已把两端的净额合并算好。
      if (toId != null && toId.isNotEmpty && toId != fromId) {
        final account = accountsById[toId];
        final anchor = latestAnchors[toId];
        if (account != null &&
            account.bookId == entry.bookId &&
            (anchor == null ||
                accountEffectDate(entry).isAfter(anchor.effectiveAt))) {
          balances[toId] = balances[toId]! + accountDeltaForEntry(entry, toId);
        }
      }
    }
    return <String, double>{
      for (final account in _accounts)
        account.id: normalizeCurrencyAmount(
          balances[account.id]!,
          account.currencyCode,
        ),
    };
  }

  /// 载入偏好类小数据（KV）。账目类数据由 [_loadFromRepository] 从 SQLite 载入。
}
