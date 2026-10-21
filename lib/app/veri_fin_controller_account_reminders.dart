part of 'veri_fin_controller.dart';

/// 账户确认提醒领域操作：保存配置、跨账本投影、用户确认后的幂等落账。
/// 复用交易草稿的串行队列，不依赖当前浏览的账本，也不直接访问平台桥。
mixin _AccountEntryReminderOps on _ControllerState, _ControllerOps {
  /// 获取 [accountId] 的本机提醒；没有配置时为 null，页面据此显示默认关闭的草稿。
  AccountEntryReminder? accountEntryReminder(String accountId) =>
      accountEntryRemindersListenable.value
          .where((rule) => rule.accountId == accountId)
          .firstOrNull;

  /// 验证预设交易与时间范围；[rule] 不允许绑定无账户、转账、退款或已删除的实体。
  /// 仅自定义星期要求至少选一天，工作日模式允许空星期以包含全部调休补班。
  bool _validAccountEntryReminder(AccountEntryReminder rule) {
    if (!_accounts.any(
          (account) =>
              account.id == rule.accountId &&
              account.bookId == rule.bookId &&
              account.currencyCode == rule.currencyCode,
        ) ||
        !_ledgerBooks.any((book) => book.id == rule.bookId) ||
        rule.hour < 0 ||
        rule.hour > 23 ||
        rule.minute < 0 ||
        rule.minute > 59 ||
        (rule.repeatMode == AccountReminderRepeatMode.weekdays &&
            rule.weekdays.isEmpty) ||
        rule.weekdays.any((day) => day < 1 || day > 7) ||
        rule.confirmLabel.length > 12 ||
        rule.cancelLabel.length > 12 ||
        rule.type != EntryType.income && rule.type != EntryType.expense) {
      return false;
    }
    return !rule.enabled ||
        (rule.amount.isFinite &&
            rule.amount > 0 &&
            rule.amount ==
                normalizeCurrencyAmount(rule.amount, rule.currencyCode) &&
            _categories.any(
              (category) =>
                  category.id == rule.categoryId && category.type == rule.type,
            ));
  }

  /// 保存账户提醒草稿；仅在 KV 明确落盘成功后更新独立通知源。
  /// 每次保存更换修订 id，旧系统通知不能按新金额或新分类意外落账。
  Future<bool> saveAccountEntryReminder(AccountEntryReminder draft) =>
      _enqueueCaptureMutation(() async {
        if (!_validAccountEntryReminder(draft)) return false;
        final current = accountEntryReminder(draft.accountId);
        final rule = draft.copyWith(
          id: _generateId('account_reminder'),
          name: draft.name.trim(),
          confirmLabel: draft.confirmLabel.trim(),
          cancelLabel: draft.cancelLabel.trim(),
          weekdays: (draft.weekdays.toSet().toList()..sort()),
          handledDate: current?.handledDate ?? '',
        );
        return _writeAccountEntryReminders(<AccountEntryReminder>[
          for (final item in accountEntryRemindersListenable.value)
            if (item.accountId != rule.accountId) item,
          rule,
        ]);
      });

  /// 写入完整配置快照 [rules]；异常统一记日志并反馈，失败保留原内存配置。
  Future<bool> _writeAccountEntryReminders(
    List<AccountEntryReminder> rules,
  ) async {
    try {
      await _store.writeAndFlush(
        _accountEntryReminderKey,
        jsonEncode(rules.map((rule) => rule.toJson()).toList()),
      );
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return false;
    }
    accountEntryRemindersListenable.value =
        List<AccountEntryReminder>.unmodifiable(rules);
    return true;
  }

  /// 投影全部账本有效且已启用的提醒；[l10n] 决定默认按钮及通知文案。
  /// 金额在原生侧仅作为展示文本，实际落账永远读取 Controller 的最新配置。
  /// 工作日模式额外携带同源离线日历，原生重启和进程回收后仍可独立判断。
  List<Map<String, Object?>> accountEntryReminderNotifications(
    AppLocalizations l10n,
  ) => [
    for (final rule in accountEntryRemindersListenable.value)
      if (rule.enabled && _validAccountEntryReminder(rule))
        <String, Object?>{
          ...rule.toJson(),
          // 仅工作日模式携带公共日历，Android 落盘后可在无 Flutter 进程时独立判断。
          if (rule.repeatMode == AccountReminderRepeatMode.chinaWorkdays)
            'workdayCalendar': mainlandChinaWorkdayCalendar.toJson(),
          'title': rule.name.isEmpty
              ? l10n.accountEntryReminderTitle
              : rule.name,
          'channelName': l10n.accountEntryReminderTitle,
          'body': l10n.accountEntryReminderNotification(
            _ledgerBooks.firstWhere((book) => book.id == rule.bookId).name,
            _accounts
                .firstWhere((account) => account.id == rule.accountId)
                .name,
            rule.type.label(l10n),
            // 通知同时覆盖不同账本，显式保留币种，避免沿用当前账本隐藏单位的偏好。
            formatUserMoney(rule.amount, rule.currencyCode, forceUnit: true),
          ),
          'confirmLabel': rule.confirmLabel.isEmpty
              ? l10n.accountEntryReminderConfirmDefault
              : rule.confirmLabel,
          'cancelLabel': rule.cancelLabel.isEmpty
              ? l10n.commonCancel
              : rule.cancelLabel,
        },
  ];

  /// 处理原生通知的显式选择。[id] 必须匹配当前修订；[date] 是通知实际触发日期，
  /// 只接受当天，避免点击昨天的通知误记到今天。[confirm] 为 false 只保存跳过标记。
  /// 确认交易 id 固定为账户＋日期；KV 标记写入失败或进程重建后仍由 SQLite 阻止重复。
  /// 按 matchesDate 重查日期规则，拒绝假期或未知年度暂停期间的过时通知操作。
  Future<AccountReminderResult> handleAccountEntryReminder({
    required String id,
    required String date,
    required bool confirm,
  }) => _enqueueCaptureMutation(() async {
    final rule = accountEntryRemindersListenable.value
        .where((item) => item.id == id)
        .firstOrNull;
    final today = dateOnly(DateTime.now());
    if (rule == null ||
        !rule.enabled ||
        !_validAccountEntryReminder(rule) ||
        date != currencyDateKey(today) ||
        !rule.matchesDate(today)) {
      return AccountReminderResult.expired;
    }
    final entryId = 'entry_account_reminder_${rule.accountId}_$date';
    if (rule.handledDate == date ||
        _entries.any((entry) => entry.id == entryId)) {
      return AccountReminderResult.alreadyHandled;
    }
    if (confirm) {
      final book = _ledgerBooks.firstWhere((book) => book.id == rule.bookId);
      final converted = convertCurrencyAmount(
        amount: rule.amount,
        sourceCurrencyCode: rule.currencyCode,
        targetCurrencyCode: book.baseCurrencyCode,
        baseCurrencyCode: book.baseCurrencyCode,
        bookId: rule.bookId,
        date: today,
        rates: _exchangeRates,
      );
      if (converted is! ConvertedCurrencyAmount) {
        return AccountReminderResult.missingRate;
      }
      // 已处于串行队列，调用内部草稿入口，避免嵌套等待同一队列造成死锁。
      final result = await _saveEntryAggregateDraftResult(
        isNew: true,
        entry: LedgerEntry(
          id: entryId,
          bookId: rule.bookId,
          type: rule.type,
          amount: rule.amount,
          currencyCode: rule.currencyCode,
          accountAmount: rule.amount,
          baseAmount: converted.amount,
          conversionSource: rule.currencyCode == book.baseCurrencyCode
              ? ConversionSource.identity
              : ConversionSource.rateTable,
          categoryId: rule.categoryId,
          accountId: rule.accountId,
          note: rule.name,
          occurredAt: DateTime(
            today.year,
            today.month,
            today.day,
            rule.hour,
            rule.minute,
          ),
          occurredAtPrecision: OccurredAtPrecision.minute,
        ),
      );
      if (!result.isSuccess) return AccountReminderResult.failed;
    }
    final written = await _writeAccountEntryReminders([
      for (final item in accountEntryRemindersListenable.value)
        item.id == id ? item.copyWith(handledDate: date) : item,
    ]);
    // 确认时 SQLite 已是权威结果，不能因辅助 KV 写入失败谎报交易未保存；稳定 id
    // 仍防重复。取消没有 SQLite 交易，必须等待标记成功才能确认消费原生操作。
    return confirm
        ? AccountReminderResult.recorded
        : written
        ? AccountReminderResult.cancelled
        : AccountReminderResult.failed;
  });
}
