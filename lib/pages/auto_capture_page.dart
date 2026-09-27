import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_theme.dart';
import '../app/common_widgets.dart';
import '../app/currency_math.dart';
import '../app/feedback.dart';
import '../app/models.dart';
import '../app/platform_bridge.dart';
import '../app/veri_fin_controller.dart';
import '../app/veri_fin_scope.dart';
import '../l10n/app_localizations.dart';
import 'entry_detail_page.dart';
import 'sheets.dart';
import 'transaction_detail_page.dart';

/// 首次启用通知监听时使用的常见支付来源白名单。银行 App 包名数量多且变化频繁，
/// 由“监听所有来源”覆盖；原生仍会做金融关键词前置过滤。
const List<String> _defaultCapturePackages = <String>[
  'com.eg.android.AlipayGphone',
  'com.tencent.mm',
  'com.unionpay',
  'com.sankuai.meituan',
  'com.jingdong.app.mall',
];

class AutoCapturePage extends StatefulWidget {
  const AutoCapturePage({super.key});

  @override
  State<AutoCapturePage> createState() => _AutoCapturePageState();
}

class _AutoCapturePageState extends State<AutoCapturePage>
    with WidgetsBindingObserver {
  AutoCaptureSettings? _settings;
  bool _notificationAccess = false;
  bool _smsSupported = false;
  bool _smsPermission = false;
  bool _pendingNotificationEnable = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshPermissions());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _settings ??= VeriFinScope.of(context).autoCaptureSettings;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshPermissions(enablePendingNotification: true));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 刷新两项系统权限；从通知设置页回来且授权成功时，完成之前挂起的开启动作。
  Future<void> _refreshPermissions({
    bool enablePendingNotification = false,
  }) async {
    final notification = await AppAutoCaptureBridge.notificationAccessGranted();
    final smsSupported = await AppAutoCaptureBridge.smsCaptureSupported();
    final sms = await AppAutoCaptureBridge.smsPermissionGranted();
    if (!mounted) return;
    setState(() {
      _notificationAccess = notification;
      _smsSupported = smsSupported;
      _smsPermission = sms;
    });
    if (enablePendingNotification &&
        _pendingNotificationEnable &&
        notification) {
      _pendingNotificationEnable = false;
      await _saveSettings(
        _settings!.copyWith(
          notificationEnabled: true,
          sourcePackages: _settings!.sourcePackages.isEmpty
              ? _defaultCapturePackages
              : _settings!.sourcePackages,
        ),
      );
    }
  }

  /// 先刷盘 Dart 配置；成功后 Controller 的根级钩子会同步原生服务。
  /// 失败时保留页面原值并显示全局保存失败提示。
  Future<bool> _saveSettings(AutoCaptureSettings next) async {
    final saved = await VeriFinScope.of(
      context,
    ).saveAutoCaptureSettingsDraft(next);
    if (!mounted || !saved) return false;
    setState(() => _settings = next);
    return true;
  }

  /// 切换通知监听。开启必须先由用户在系统通知使用权页授权，关闭不撤销系统授权。
  Future<void> _toggleNotifications(bool enabled) async {
    if (!enabled) {
      await _saveSettings(_settings!.copyWith(notificationEnabled: false));
      return;
    }
    final granted = await AppAutoCaptureBridge.notificationAccessGranted();
    if (!mounted) return;
    if (!granted) {
      _pendingNotificationEnable = true;
      await AppAutoCaptureBridge.openNotificationAccessSettings();
      return;
    }
    await _saveSettings(
      _settings!.copyWith(
        notificationEnabled: true,
        sourcePackages: _settings!.sourcePackages.isEmpty
            ? _defaultCapturePackages
            : _settings!.sourcePackages,
      ),
    );
  }

  /// 切换短信补充通道。开启时仅请求 RECEIVE_SMS；拒绝后保持关闭，不反复弹权限框。
  Future<void> _toggleSms(bool enabled) async {
    if (!_smsSupported) return;
    if (!enabled) {
      await _saveSettings(_settings!.copyWith(smsEnabled: false));
      return;
    }
    final granted =
        _smsPermission || await AppAutoCaptureBridge.requestSmsPermission();
    if (!mounted) return;
    setState(() => _smsPermission = granted);
    if (!granted) {
      unawaited(
        VeriFeedbackHost.of(context).showMessage(
          message: AppLocalizations.of(context).autoCaptureSmsPermissionDenied,
          tone: VeriFeedbackTone.warning,
          duration: VeriFeedbackDuration.long,
        ),
      );
      return;
    }
    await _saveSettings(_settings!.copyWith(smsEnabled: true));
  }

  /// 切换 AI 补充识别。开启前必须已有完整 AI 配置；该开关只允许发送本地规则无法
  /// 完整判断的新事件原文，AI 参与的结果始终进入待确认，不会自动落账。
  Future<void> _toggleAiAssist(bool enabled) async {
    final controller = VeriFinScope.of(context);
    if (enabled && !controller.aiSettings.isConfigured) {
      await VeriFeedbackHost.of(context).showMessage(
        message: AppLocalizations.of(context).autoCaptureAiAssistNotConfigured,
        tone: VeriFeedbackTone.warning,
        duration: VeriFeedbackDuration.long,
      );
      return;
    }
    await _saveSettings(_settings!.copyWith(aiAssistEnabled: enabled));
  }

  @override
  Widget build(BuildContext context) {
    final controller = VeriFinScope.of(context);
    final l10n = AppLocalizations.of(context);
    final settings = _settings ?? controller.autoCaptureSettings;
    final stats = controller.autoCaptureStats();
    final attention = controller.captureEvents
        .where(
          (event) =>
              event.status.needsAttention ||
              event.status == CaptureStatus.raw ||
              event.status == CaptureStatus.autoPosted,
        )
        .take(30)
        .toList();
    return Scaffold(
      body: SafeArea(
        child: VeriPage(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 36),
            children: <Widget>[
              VeriHeader(
                title: l10n.autoCaptureTitle,
                subtitle: l10n.autoCaptureSubtitle,
                showBack: true,
              ),
              const SizedBox(height: 10),
              _AutoCaptureStatsCard(stats: stats),
              const SizedBox(height: 12),
              Text(
                l10n.autoCaptureSourcesTitle,
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 6),
              VeriCard(
                child: Column(
                  children: <Widget>[
                    CompactSwitchRow(
                      icon: Icons.notifications_active_outlined,
                      title: Text(l10n.autoCaptureNotificationTitle),
                      subtitle: Text(
                        _notificationAccess
                            ? l10n.autoCaptureNotificationDesc
                            : l10n.autoCaptureNotificationPermissionNeeded,
                      ),
                      value:
                          settings.notificationEnabled && _notificationAccess,
                      onChanged: _toggleNotifications,
                    ),
                    const Divider(height: 1),
                    CompactSwitchRow(
                      icon: Icons.sms_outlined,
                      title: Text(l10n.autoCaptureSmsTitle),
                      subtitle: Text(
                        _smsSupported
                            ? l10n.autoCaptureSmsDesc
                            : l10n.autoCaptureSmsUnavailable,
                      ),
                      value:
                          _smsSupported &&
                          settings.smsEnabled &&
                          _smsPermission,
                      onChanged: _smsSupported ? _toggleSms : null,
                    ),
                    const Divider(height: 1),
                    CompactSwitchRow(
                      icon: Icons.apps_outlined,
                      title: Text(l10n.autoCaptureListenAllTitle),
                      subtitle: Text(l10n.autoCaptureListenAllDesc),
                      value: settings.listenAllNotificationSources,
                      onChanged: settings.notificationEnabled
                          ? (value) => _saveSettings(
                              settings.copyWith(
                                listenAllNotificationSources: value,
                              ),
                            )
                          : null,
                    ),
                    const Divider(height: 1),
                    CompactSwitchRow(
                      icon: Icons.auto_awesome_outlined,
                      title: Text(l10n.autoCaptureAiAssistTitle),
                      subtitle: Text(
                        controller.aiSettings.isConfigured
                            ? l10n.autoCaptureAiAssistDesc
                            : l10n.autoCaptureAiAssistNotConfigured,
                      ),
                      value: settings.aiAssistEnabled,
                      onChanged: _toggleAiAssist,
                    ),
                    const Divider(height: 1),
                    CompactSwitchRow(
                      icon: Icons.verified_outlined,
                      title: Text(l10n.autoCaptureAutoPostTitle),
                      subtitle: Text(l10n.autoCaptureAutoPostDesc),
                      value: settings.autoPostHighConfidence,
                      onChanged: (value) => _saveSettings(
                        settings.copyWith(autoPostHighConfidence: value),
                      ),
                    ),
                    const Divider(height: 1),
                    SettingsRow(
                      icon: Icons.rule_outlined,
                      title: l10n.autoCaptureRulesTitle,
                      trailing: l10n.countRules(
                        controller.autoCaptureRules.length,
                      ),
                      trailingIcon: Icons.chevron_right,
                      onTap: () => Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => const AutoCaptureRulesPage(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      l10n.autoCaptureQueueTitle,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      await AppAutoCaptureBridge.drainQueue(
                        ingest: (inputs) async {
                          await controller.ingestCaptureInputs(inputs);
                        },
                        isStored: controller.captureInputIsStored,
                      );
                    },
                    icon: const Icon(Icons.refresh, size: 18),
                    label: Text(l10n.commonRefresh),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              if (attention.isEmpty)
                VeriCard(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    child: Center(child: Text(l10n.autoCaptureQueueEmpty)),
                  ),
                )
              else
                ...attention.map(
                  (event) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _CaptureEventCard(
                      event: event,
                      onReview: event.status == CaptureStatus.autoPosted
                          ? () => _openLinkedEntry(event)
                          : () => _reviewEvent(event),
                      onMerge: event.duplicateEntryId == null
                          ? null
                          : () => _mergeEvent(event),
                      onIgnore: () => _ignoreEvent(event),
                      onUndo: event.status == CaptureStatus.autoPosted
                          ? () => _undoEvent(event)
                          : null,
                      onMisidentified: () => _markMisidentified(event),
                      onRetry: () => controller.retryCaptureEvent(event.id),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 用标准记账页复核事件；保存时来源证据与交易一起落库，返回后再更新事件状态。
  Future<void> _reviewEvent(CaptureEvent event) async {
    final controller = VeriFinScope.of(context);
    if (event.kind == CaptureTransactionKind.refund) {
      final l10n = AppLocalizations.of(context);
      final confirmed = await showConfirmDialog(
        context,
        title: l10n.autoCaptureConfirmRefundTitle,
        message: l10n.autoCaptureConfirmRefundMessage,
        confirmLabel: l10n.commonConfirm,
      );
      if (!confirmed || !mounted) return;
      final entry = await controller.confirmParsedCaptureEvent(event.id);
      if (!mounted || entry != null) return;
      unawaited(
        VeriFeedbackHost.of(context).showMessage(
          message: l10n.autoCaptureNeedsMoreInfo,
          tone: VeriFeedbackTone.warning,
        ),
      );
      return;
    }
    final draft = controller.captureEntryDraft(event.id);
    final source = controller.captureSourceRecord(event.id);
    if (draft == null || source == null) {
      unawaited(
        VeriFeedbackHost.of(context).showMessage(
          message: AppLocalizations.of(context).autoCaptureNeedsMoreInfo,
          tone: VeriFeedbackTone.warning,
        ),
      );
      return;
    }
    final entry = await Navigator.of(context).push<LedgerEntry>(
      MaterialPageRoute<LedgerEntry>(
        builder: (_) => EntryDetailPage(
          initialAmount: draft.amount,
          initialDraft: draft,
          initialSourceRecords: <EntrySourceRecord>[source],
        ),
      ),
    );
    if (!mounted || entry == null) return;
    await controller.markCaptureEventConfirmed(
      eventId: event.id,
      entryId: entry.id,
    );
  }

  /// 打开自动入账对应的正式交易，避免“核对”按钮再次创建一笔重复交易。
  Future<void> _openLinkedEntry(CaptureEvent event) async {
    final entryId = event.linkedEntryId;
    if (entryId == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => TransactionDetailPage(entryId: entryId),
      ),
    );
  }

  /// 将疑似重复事件合并到解析器给出的候选交易。
  Future<void> _mergeEvent(CaptureEvent event) async {
    final entryId = event.duplicateEntryId;
    if (entryId == null) return;
    await VeriFinScope.of(
      context,
    ).mergeCaptureEventIntoEntry(eventId: event.id, entryId: entryId);
  }

  Future<void> _ignoreEvent(CaptureEvent event) async {
    await VeriFinScope.of(context).ignoreCaptureEvent(event.id);
  }

  Future<void> _undoEvent(CaptureEvent event) async {
    await VeriFinScope.of(context).undoAutoCapturedEntry(event.id);
  }

  Future<void> _markMisidentified(CaptureEvent event) async {
    await VeriFinScope.of(context).markCaptureEventMisidentified(event.id);
  }
}

class _AutoCaptureStatsCard extends StatelessWidget {
  const _AutoCaptureStatsCard({required this.stats});

  final AutoCaptureStats stats;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return VeriCard(
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              SummaryMetric(
                label: l10n.autoCaptureTodayRecognized,
                value: '${stats.todayRecognized}',
                color: veriRoyal,
              ),
              SummaryMetric(
                label: l10n.autoCapturePostedCount,
                value: '${stats.autoPosted}',
                color: veriSemantic(context, veriIncome),
              ),
              SummaryMetric(
                label: l10n.autoCapturePendingCount,
                value: '${stats.pendingReview}',
                color: veriSemantic(context, veriWarning),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              SummaryMetric(
                label: l10n.autoCaptureDuplicateCount,
                value: '${stats.duplicateSuspected}',
                color: veriSemantic(context, veriBlue),
              ),
              SummaryMetric(
                label: l10n.autoCaptureUnrecognizedCount,
                value: '${stats.unrecognized}',
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CaptureEventCard extends StatelessWidget {
  const _CaptureEventCard({
    required this.event,
    required this.onReview,
    required this.onIgnore,
    required this.onMisidentified,
    required this.onRetry,
    this.onMerge,
    this.onUndo,
  });

  final CaptureEvent event;
  final VoidCallback onReview;
  final VoidCallback? onMerge;
  final VoidCallback onIgnore;
  final VoidCallback? onUndo;
  final VoidCallback onMisidentified;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final time = MaterialLocalizations.of(
      context,
    ).formatTimeOfDay(TimeOfDay.fromDateTime(event.receivedAt));
    final amount = event.parsedAmount == null
        ? '—'
        : formatUserMoney(event.parsedAmount!, event.currencyCode);
    return VeriCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              VeriIconBox(
                icon: event.sourceKind == CaptureSourceKind.sms
                    ? Icons.sms_outlined
                    : Icons.notifications_none,
                color: _confidenceColor(context, event.confidence),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      event.merchant.isEmpty
                          ? event.sourceLabel
                          : event.merchant,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${event.sourceLabel} · ${l10n.dateMonthDay(event.receivedAt)} $time'
                      '${event.aiAssisted ? ' · ${l10n.autoCaptureAiAssistedLabel}' : ''}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              Text(
                amount,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            event.rawText,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: <Widget>[
              TextButton(
                onPressed: onReview,
                child: Text(l10n.autoCaptureReview),
              ),
              if (onMerge != null)
                TextButton(
                  onPressed: onMerge,
                  child: Text(l10n.autoCaptureMerge),
                ),
              if (onUndo != null)
                TextButton(
                  onPressed: onUndo,
                  child: Text(l10n.autoCaptureUndo),
                ),
              TextButton(
                onPressed: onRetry,
                child: Text(l10n.autoCaptureRetry),
              ),
              TextButton(
                onPressed: onIgnore,
                child: Text(l10n.autoCaptureIgnore),
              ),
              TextButton(
                onPressed: onMisidentified,
                child: Text(l10n.autoCaptureMisidentified),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Color _confidenceColor(BuildContext context, CaptureConfidence confidence) =>
      switch (confidence) {
        CaptureConfidence.high => veriSemantic(context, veriIncome),
        CaptureConfidence.medium => veriSemantic(context, veriWarning),
        CaptureConfidence.low => Theme.of(context).colorScheme.onSurfaceVariant,
      };
}

class AutoCaptureRulesPage extends StatelessWidget {
  const AutoCaptureRulesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = VeriFinScope.of(context);
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      body: SafeArea(
        child: VeriPage(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 36),
            children: <Widget>[
              VeriHeader(
                title: l10n.autoCaptureRulesTitle,
                subtitle: l10n.autoCaptureRulesSubtitle,
                showBack: true,
                actions: <Widget>[
                  IconButton(
                    tooltip: l10n.commonAdd,
                    onPressed: () => Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => const AutoCaptureRuleEditorPage(),
                      ),
                    ),
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (controller.autoCaptureRules.isEmpty)
                VeriCard(child: Center(child: Text(l10n.autoCaptureRulesEmpty)))
              else
                VeriCard(
                  child: Column(
                    children: <Widget>[
                      for (final pair
                          in controller.autoCaptureRules.indexed) ...<Widget>[
                        if (pair.$1 > 0) const Divider(height: 1),
                        SettingsRow(
                          icon: pair.$2.enabled
                              ? Icons.rule_outlined
                              : Icons.rule_folder_outlined,
                          title: pair.$2.name,
                          trailing: '${pair.$2.priority}',
                          trailingIcon: Icons.chevron_right,
                          onTap: () => Navigator.of(context).push<void>(
                            MaterialPageRoute<void>(
                              builder: (_) => AutoCaptureRuleEditorPage(
                                initialRule: pair.$2,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class AutoCaptureRuleEditorPage extends StatefulWidget {
  const AutoCaptureRuleEditorPage({super.key, this.initialRule});

  final AutoCaptureRule? initialRule;

  @override
  State<AutoCaptureRuleEditorPage> createState() =>
      _AutoCaptureRuleEditorPageState();
}

class _AutoCaptureRuleEditorPageState extends State<AutoCaptureRuleEditorPage> {
  late final TextEditingController _name;
  late final TextEditingController _keyword;
  late final TextEditingController _sourceId;
  late final TextEditingController _cardLast4;
  late final TextEditingController _amount;
  late final TextEditingController _merchant;
  CaptureSourceKind? _sourceKind;
  CaptureTransactionKind? _matchKind;
  CaptureTransactionKind? _setKind;
  String? _accountId;
  String? _toAccountId;
  String? _categoryId;
  List<String> _tagIds = <String>[];
  bool _enabled = true;

  @override
  void initState() {
    super.initState();
    final rule = widget.initialRule;
    _name = TextEditingController(text: rule?.name ?? '');
    _keyword = TextEditingController(text: rule?.textContains ?? '');
    _sourceId = TextEditingController(text: rule?.sourceId ?? '');
    _cardLast4 = TextEditingController(text: rule?.cardLast4 ?? '');
    _amount = TextEditingController(text: rule?.exactAmount?.toString() ?? '');
    _merchant = TextEditingController(text: rule?.setMerchant ?? '');
    _sourceKind = rule?.sourceKind;
    _matchKind = rule?.matchKind;
    _setKind = rule?.setKind;
    _accountId = rule?.setAccountId;
    _toAccountId = rule?.setToAccountId;
    _categoryId = rule?.setCategoryId;
    _tagIds = List<String>.of(rule?.setTagIds ?? const <String>[]);
    _enabled = rule?.enabled ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _keyword.dispose();
    _sourceId.dispose();
    _cardLast4.dispose();
    _amount.dispose();
    _merchant.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final controller = VeriFinScope.of(context);
    return Scaffold(
      body: SafeArea(
        child: VeriPage(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 36),
            children: <Widget>[
              VeriHeader(
                title: widget.initialRule == null
                    ? l10n.autoCaptureRuleCreateTitle
                    : l10n.autoCaptureRuleEditTitle,
                showBack: true,
                actions: <Widget>[SaveHeaderAction(onPressed: _save)],
              ),
              const SizedBox(height: 10),
              VeriCard(
                child: Column(
                  children: <Widget>[
                    TextField(
                      controller: _name,
                      decoration: InputDecoration(
                        labelText: l10n.autoCaptureRuleName,
                      ),
                    ),
                    CompactSwitchRow(
                      icon: Icons.toggle_on_outlined,
                      title: Text(l10n.enabledLabel),
                      value: _enabled,
                      onChanged: (value) => setState(() => _enabled = value),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.autoCaptureRuleConditions,
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 6),
              VeriCard(
                child: Column(
                  children: <Widget>[
                    DropdownButtonFormField<CaptureSourceKind?>(
                      initialValue: _sourceKind,
                      decoration: InputDecoration(
                        labelText: l10n.autoCaptureRuleSourceKind,
                      ),
                      items: <DropdownMenuItem<CaptureSourceKind?>>[
                        DropdownMenuItem(
                          value: null,
                          child: Text(l10n.autoCaptureRuleAny),
                        ),
                        ...CaptureSourceKind.values.map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text(_sourceKindLabel(l10n, value)),
                          ),
                        ),
                      ],
                      onChanged: (value) => setState(() => _sourceKind = value),
                    ),
                    TextField(
                      controller: _sourceId,
                      decoration: InputDecoration(
                        labelText: l10n.autoCaptureRuleSourceId,
                      ),
                    ),
                    TextField(
                      controller: _keyword,
                      decoration: InputDecoration(
                        labelText: l10n.autoCaptureRuleKeyword,
                      ),
                    ),
                    TextField(
                      controller: _cardLast4,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: l10n.autoCaptureRuleCardLast4,
                      ),
                    ),
                    TextField(
                      controller: _amount,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: l10n.autoCaptureRuleAmount,
                      ),
                    ),
                    DropdownButtonFormField<CaptureTransactionKind?>(
                      initialValue: _matchKind,
                      decoration: InputDecoration(
                        labelText: l10n.autoCaptureRuleMatchKind,
                      ),
                      items: <DropdownMenuItem<CaptureTransactionKind?>>[
                        DropdownMenuItem(
                          value: null,
                          child: Text(l10n.autoCaptureRuleAny),
                        ),
                        ...CaptureTransactionKind.values
                            .where(
                              (value) =>
                                  value != CaptureTransactionKind.unknown,
                            )
                            .map(
                              (value) => DropdownMenuItem(
                                value: value,
                                child: Text(_kindLabel(l10n, value)),
                              ),
                            ),
                      ],
                      onChanged: (value) => setState(() => _matchKind = value),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.autoCaptureRuleActions,
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 6),
              VeriCard(
                child: Column(
                  children: <Widget>[
                    DropdownButtonFormField<CaptureTransactionKind?>(
                      initialValue: _setKind,
                      decoration: InputDecoration(
                        labelText: l10n.autoCaptureRuleSetKind,
                      ),
                      items: <DropdownMenuItem<CaptureTransactionKind?>>[
                        DropdownMenuItem(
                          value: null,
                          child: Text(l10n.autoCaptureRuleNoChange),
                        ),
                        ...CaptureTransactionKind.values
                            .where(
                              (value) =>
                                  value != CaptureTransactionKind.unknown,
                            )
                            .map(
                              (value) => DropdownMenuItem(
                                value: value,
                                child: Text(_kindLabel(l10n, value)),
                              ),
                            ),
                      ],
                      onChanged: (value) => setState(() {
                        _setKind = value;
                        _categoryId = null;
                      }),
                    ),
                    SettingsRow(
                      icon: Icons.account_balance_wallet_outlined,
                      title: l10n.autoCaptureRuleAccount,
                      trailing: _accountName(controller, _accountId, l10n),
                      trailingIcon: Icons.chevron_right,
                      onTap: () => _pickAccount(target: false),
                    ),
                    const Divider(height: 1),
                    SettingsRow(
                      icon: Icons.output_outlined,
                      title: l10n.autoCaptureRuleToAccount,
                      trailing: _accountName(controller, _toAccountId, l10n),
                      trailingIcon: Icons.chevron_right,
                      onTap: () => _pickAccount(target: true),
                    ),
                    const Divider(height: 1),
                    SettingsRow(
                      icon: Icons.category_outlined,
                      title: l10n.autoCaptureRuleCategory,
                      trailing: _categoryId == null
                          ? l10n.autoCaptureRuleNoChange
                          : controller.categoryPathLabel(_categoryId!),
                      trailingIcon: Icons.chevron_right,
                      onTap: _pickCategory,
                    ),
                    const Divider(height: 1),
                    SettingsRow(
                      icon: Icons.label_outline,
                      title: l10n.autoCaptureRuleTags,
                      trailing: _tagIds.isEmpty
                          ? l10n.autoCaptureRuleNoChange
                          : l10n.countItems(_tagIds.length),
                      trailingIcon: Icons.chevron_right,
                      onTap: _pickTags,
                    ),
                    TextField(
                      controller: _merchant,
                      decoration: InputDecoration(
                        labelText: l10n.autoCaptureRuleMerchant,
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.initialRule != null) ...<Widget>[
                const SizedBox(height: 18),
                OutlinedButton.icon(
                  onPressed: _delete,
                  icon: const Icon(Icons.delete_outline),
                  label: Text(l10n.commonDelete),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickAccount({required bool target}) async {
    final controller = VeriFinScope.of(context);
    final selected = await showAccountPickerSheet(
      context: context,
      title: target
          ? AppLocalizations.of(context).autoCaptureRuleToAccount
          : AppLocalizations.of(context).autoCaptureRuleAccount,
      accounts: controller.accounts
          .where((account) => !account.hidden)
          .toList(),
      selectedId: target ? _toAccountId : _accountId,
      balanceOf: controller.accountBalance,
      noneLabel: AppLocalizations.of(context).autoCaptureRuleNoChange,
    );
    if (!mounted || selected == null) return;
    setState(() {
      if (target) {
        _toAccountId = selected.id.isEmpty ? null : selected.id;
      } else {
        _accountId = selected.id.isEmpty ? null : selected.id;
      }
    });
  }

  Future<void> _pickCategory() async {
    final controller = VeriFinScope.of(context);
    final type = _setKind?.entryType;
    if (type == null || type == EntryType.refund) return;
    final id = await showCategoryPickerSheet(
      context,
      categories: controller.categoriesForType(type),
      selectedId: _categoryId ?? '',
      title: AppLocalizations.of(context).autoCaptureRuleCategory,
    );
    if (!mounted || id == null) return;
    setState(() => _categoryId = id);
  }

  Future<void> _pickTags() async {
    final selected = await pickEntryTags(
      context: context,
      selectedIds: _tagIds,
    );
    if (!mounted || selected == null) return;
    setState(() => _tagIds = selected);
  }

  Future<void> _save() async {
    final controller = VeriFinScope.of(context);
    final initial = widget.initialRule;
    final rule = AutoCaptureRule(
      id:
          initial?.id ??
          'capture_rule_${DateTime.now().microsecondsSinceEpoch}',
      bookId: controller.activeBook.id,
      name: _name.text,
      priority: initial?.priority ?? controller.autoCaptureRules.length + 1,
      enabled: _enabled,
      sourceKind: _sourceKind,
      sourceId: _sourceId.text,
      textContains: _keyword.text,
      cardLast4: _cardLast4.text,
      exactAmount: double.tryParse(_amount.text.trim()),
      matchKind: _matchKind,
      setKind: _setKind,
      setAccountId: _accountId,
      setToAccountId: _toAccountId,
      setCategoryId: _categoryId,
      setTagIds: _tagIds,
      setMerchant: _merchant.text,
    );
    final saved = await controller.saveAutoCaptureRule(rule);
    if (!mounted) return;
    if (saved) {
      Navigator.of(context).pop();
    } else {
      unawaited(
        VeriFeedbackHost.of(context).showMessage(
          message: AppLocalizations.of(context).autoCaptureRuleInvalid,
          tone: VeriFeedbackTone.warning,
        ),
      );
    }
  }

  Future<void> _delete() async {
    final id = widget.initialRule?.id;
    if (id == null) return;
    final l10n = AppLocalizations.of(context);
    final confirmed = await showConfirmDialog(
      context,
      title: l10n.autoCaptureRuleDeleteTitle,
      message: l10n.autoCaptureRuleDeleteMessage,
      confirmLabel: l10n.commonDelete,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    final deleted = await VeriFinScope.of(context).deleteAutoCaptureRule(id);
    if (mounted && deleted) Navigator.of(context).pop();
  }

  String _accountName(
    VeriFinController controller,
    String? id,
    AppLocalizations l10n,
  ) => id == null
      ? l10n.autoCaptureRuleNoChange
      : controller.accounts
                .where((account) => account.id == id)
                .firstOrNull
                ?.name ??
            l10n.autoCaptureRuleNoChange;
}

String _sourceKindLabel(AppLocalizations l10n, CaptureSourceKind kind) =>
    switch (kind) {
      CaptureSourceKind.notification => l10n.autoCaptureSourceNotification,
      CaptureSourceKind.sms => l10n.autoCaptureSourceSms,
      CaptureSourceKind.sharedText => l10n.autoCaptureSourceShared,
      CaptureSourceKind.manual => l10n.autoCaptureSourceManual,
    };

String _kindLabel(AppLocalizations l10n, CaptureTransactionKind kind) =>
    switch (kind) {
      CaptureTransactionKind.expense => l10n.entryTypeExpense,
      CaptureTransactionKind.income => l10n.entryTypeIncome,
      CaptureTransactionKind.refund => l10n.entryTypeRefund,
      CaptureTransactionKind.transfer => l10n.entryTypeTransfer,
      CaptureTransactionKind.creditRepayment =>
        l10n.autoCaptureKindCreditRepayment,
      CaptureTransactionKind.creditLineRepayment =>
        l10n.autoCaptureKindCreditLineRepayment,
      CaptureTransactionKind.cashback => l10n.autoCaptureKindCashback,
      CaptureTransactionKind.unknown => l10n.autoCaptureKindUnknown,
    };
