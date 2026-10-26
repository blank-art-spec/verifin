import 'dart:async';

import 'package:flutter/material.dart';

import '../app/common_widgets.dart';
import '../app/feedback.dart';
import '../app/platform_bridge.dart';
import '../app/veri_fin_controller.dart';
import '../app/veri_fin_scope.dart';
import '../l10n/app_localizations.dart';

/// 设备本机三天通知捕获记录；读取及清空均不改变账本事件或正式交易。
class NotificationCaptureLogPage extends StatefulWidget {
  const NotificationCaptureLogPage({super.key});

  @override
  State<NotificationCaptureLogPage> createState() =>
      _NotificationCaptureLogPageState();
}

class _NotificationCaptureLogPageState
    extends State<NotificationCaptureLogPage> {
  final List<NotificationCaptureLogEntry> _entries = [];
  final Set<String> _expanded = {};
  VeriFinController? _controller;
  int? _observedResetGeneration;
  bool _awaitingResetWrites = false;
  bool _loading = false;
  bool _loadingMore = false;
  bool _clearing = false;
  bool _failed = false;
  bool _moreFailed = false;
  bool _hasMore = false;
  String? _cursor;
  int _generation = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = VeriFinScope.of(context);
    final resetGeneration = controller.notificationCaptureLogResetGeneration;
    if (identical(_controller, controller) &&
        _observedResetGeneration == resetGeneration) {
      return;
    }
    _awaitingResetWrites = resetGeneration > 0;
    _controller = controller;
    _observedResetGeneration = resetGeneration;
    // 初始化可保留当前 Navigator 和 State；立即抹去缓存正文，不等待读取或原生清理返回。
    _generation++;
    _entries.clear();
    _expanded.clear();
    _cursor = null;
    _hasMore = false;
    _loading = false;
    _loadingMore = false;
    _clearing = false;
    _failed = false;
    _moreFailed = false;
    unawaited(_read());
  }

  bool _requestIsCurrent(
    VeriFinController controller,
    int resetGeneration,
    int token,
  ) =>
      mounted &&
      identical(_controller, controller) &&
      controller.notificationCaptureLogResetGeneration == resetGeneration &&
      token == _generation;

  /// 刷新或清空使旧请求失效，避免迟到分页把已经删除的日志重新放回页面。
  Future<void> _read({bool more = false}) async {
    if (_clearing || (more && (_loading || _loadingMore || !_hasMore))) return;
    final before = more ? _cursor : null;
    if (more && before == null) return;
    final token = more ? _generation : ++_generation;
    final controller = VeriFinScope.of(context);
    final resetGeneration = controller.notificationCaptureLogResetGeneration;
    setState(() {
      if (more) {
        _loadingMore = true;
        _moreFailed = false;
      } else {
        _loading = true;
        _loadingMore = false;
        _failed = false;
        _moreFailed = false;
      }
    });
    if (_awaitingResetWrites) {
      final saved = await controller.waitForPendingWritesSucceeded();
      if (!_requestIsCurrent(controller, resetGeneration, token)) return;
      if (!saved) {
        setState(() {
          _loading = false;
          _loadingMore = false;
          _failed = true;
        });
        return;
      }
      _awaitingResetWrites = false;
    }
    final batch = await controller.readNotificationCaptureLogs(
      beforeId: before,
    );
    if (!_requestIsCurrent(controller, resetGeneration, token)) return;
    setState(() {
      _loading = false;
      _loadingMore = false;
      if (batch == null) {
        if (more) {
          _moreFailed = true;
        } else {
          _failed = true;
        }
        return;
      }
      if (!more) {
        _entries.clear();
        _expanded.clear();
      }
      final ids = _entries.map((entry) => entry.id).toSet();
      _entries.addAll(batch.entries.where((entry) => ids.add(entry.id)));
      final next = batch.nextBeforeId;
      final nextNumber = next == null ? null : int.tryParse(next);
      final beforeNumber = before == null ? null : int.tryParse(before);
      // 游标必须严格向更早的记录前进；错误桥接结果不能制造无限加载循环。
      _hasMore =
          batch.hasMore &&
          batch.entries.isNotEmpty &&
          nextNumber != null &&
          nextNumber > 0 &&
          (!more || (beforeNumber != null && nextNumber < beforeNumber));
      _cursor = _hasMore ? next : null;
    });
  }

  Future<void> _clear() async {
    if (_clearing || _entries.isEmpty) return;
    final l10n = AppLocalizations.of(context);
    final controller = VeriFinScope.of(context);
    final resetGeneration = controller.notificationCaptureLogResetGeneration;
    final confirmed = await showConfirmDialog(
      context,
      title: l10n.notificationCaptureLogClearTitle,
      message: l10n.notificationCaptureLogClearMessage,
      confirmLabel: l10n.commonClear,
      destructive: true,
    );
    if (!mounted ||
        !confirmed ||
        !identical(_controller, controller) ||
        controller.notificationCaptureLogResetGeneration != resetGeneration) {
      return;
    }
    final token = ++_generation;
    setState(() {
      _clearing = true;
      _loading = false;
      _loadingMore = false;
    });
    final saved = await controller.clearNotificationCaptureLogs();
    if (!mounted || !_requestIsCurrent(controller, resetGeneration, token)) {
      return;
    }
    setState(() {
      _clearing = false;
      if (saved) {
        _entries.clear();
        _expanded.clear();
        _cursor = null;
        _hasMore = false;
        _failed = false;
        _moreFailed = false;
      }
    });
    unawaited(
      VeriFeedbackHost.of(context).showMessage(
        message: saved
            ? l10n.notificationCaptureLogCleared
            : l10n.notificationCaptureLogClearFailed,
        tone: saved ? VeriFeedbackTone.success : VeriFeedbackTone.error,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      body: SafeArea(
        child: VeriPage(
          child: RefreshIndicator(
            onRefresh: _read,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 36),
              children: [
                VeriHeader(
                  title: l10n.notificationCaptureLogTitle,
                  showBack: true,
                  actions: [
                    IconButton(
                      key: const Key('notification_log_refresh'),
                      tooltip: l10n.commonRefresh,
                      onPressed: _clearing ? null : () => unawaited(_read()),
                      icon: const Icon(Icons.refresh),
                    ),
                    IconButton(
                      key: const Key('notification_log_clear'),
                      tooltip: l10n.notificationCaptureLogClearTitle,
                      onPressed: _clearing || _entries.isEmpty
                          ? null
                          : () => unawaited(_clear()),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                VeriCard(child: Text(l10n.notificationCaptureLogPrivacy)),
                const SizedBox(height: 12),
                if (_loading || _clearing)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                if (_failed)
                  VeriCard(
                    child: Column(
                      children: [
                        Text(l10n.notificationCaptureLogReadFailed),
                        TextButton(
                          key: const Key('notification_log_retry'),
                          onPressed: _clearing
                              ? null
                              : () => unawaited(_read()),
                          child: Text(l10n.notificationCaptureLogRetry),
                        ),
                      ],
                    ),
                  ),
                if (!_loading && !_failed && _entries.isEmpty)
                  EmptyState(
                    icon: Icons.notifications_none,
                    title: l10n.notificationCaptureLogEmpty,
                    description: l10n.notificationCaptureLogEmptyHint,
                  ),
                ..._entries.map(
                  (entry) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _NotificationLogCard(
                      key: ValueKey('notification_log_${entry.id}'),
                      entry: entry,
                      expanded: _expanded.contains(entry.id),
                      onToggle: () => setState(() {
                        if (!_expanded.add(entry.id)) {
                          _expanded.remove(entry.id);
                        }
                      }),
                    ),
                  ),
                ),
                if (_moreFailed)
                  Text(
                    l10n.notificationCaptureLogReadFailed,
                    textAlign: TextAlign.center,
                  ),
                if (_hasMore)
                  TextButton(
                    key: const Key('notification_log_more'),
                    onPressed: _loadingMore || _loading || _clearing
                        ? null
                        : () => unawaited(_read(more: true)),
                    child: _loadingMore
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(
                            _moreFailed
                                ? l10n.notificationCaptureLogRetry
                                : l10n.notificationCaptureLogLoadMore,
                          ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NotificationLogCard extends StatelessWidget {
  const _NotificationLogCard({
    super.key,
    required this.entry,
    required this.expanded,
    required this.onToggle,
  });

  final NotificationCaptureLogEntry entry;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final source = entry.sourceLabel.isNotEmpty
        ? entry.sourceLabel
        : entry.sourceId.isNotEmpty
        ? entry.sourceId
        : l10n.autoCaptureDiagnosticUnknownSource;
    String time(DateTime value) {
      final formattedTime = MaterialLocalizations.of(
        context,
      ).formatTimeOfDay(TimeOfDay.fromDateTime(value));
      return '${l10n.dateMonthDay(value)} $formattedTime';
    }

    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text('$label：$value'),
    );
    return VeriCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            source,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 5),
          Text(
            '${l10n.notificationCaptureLogRecordedAt}：${time(entry.recordedAt)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 5),
          Text(notificationCaptureOutcomeLabel(l10n, entry.outcome)),
          TextButton.icon(
            key: ValueKey('notification_log_detail_${entry.id}'),
            onPressed: onToggle,
            icon: Icon(expanded ? Icons.expand_less : Icons.expand_more),
            label: Text(
              expanded
                  ? l10n.notificationCaptureLogCollapse
                  : l10n.notificationCaptureLogDetails,
            ),
          ),
          if (expanded) ...[
            if (entry.sourceId.isNotEmpty)
              row(l10n.notificationCaptureLogSourceId, entry.sourceId),
            row(l10n.notificationCaptureLogOccurredAt, time(entry.occurredAt)),
            row(
              l10n.autoCaptureDiagnosticTextExtraction,
              notificationCaptureStageLabel(l10n, entry.textExtraction),
            ),
            row(
              l10n.autoCaptureDiagnosticFinancialFilter,
              notificationCaptureStageLabel(l10n, entry.financialFilter),
            ),
            row(
              l10n.autoCaptureDiagnosticQueueResult,
              notificationCaptureStageLabel(l10n, entry.queueResult),
            ),
            const Divider(),
            Text(
              l10n.notificationCaptureLogRawText,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            if (entry.rawText.isEmpty)
              Text(l10n.notificationCaptureLogNoBody)
            else
              SelectableText(
                entry.rawText,
                key: ValueKey('notification_log_body_${entry.id}'),
              ),
          ],
        ],
      ),
    );
  }
}

/// 实时诊断与历史日志共用原生阶段文案，未知代码不误报为成功。
String notificationCaptureStageLabel(AppLocalizations l10n, String value) =>
    switch (value) {
      'success' => l10n.autoCaptureDiagnosticSucceeded,
      'failed' ||
      'invalidText' ||
      'writeFailed' => l10n.autoCaptureDiagnosticFailed,
      'passed' => l10n.autoCaptureDiagnosticPassed,
      'rejected' => l10n.autoCaptureDiagnosticRejected,
      'enqueued' => l10n.autoCaptureDiagnosticEnqueued,
      'duplicate' => l10n.autoCaptureDiagnosticDuplicate,
      _ => l10n.autoCaptureDiagnosticNotRun,
    };

/// 实时诊断与历史日志共用最终结果解释。
String notificationCaptureOutcomeLabel(AppLocalizations l10n, String value) =>
    switch (value) {
      'nativeDisabled' => l10n.autoCaptureDiagnosticOutcomeNativeDisabled,
      'sourceBlocked' => l10n.autoCaptureDiagnosticOutcomeSourceBlocked,
      'textUnavailable' => l10n.autoCaptureDiagnosticOutcomeTextUnavailable,
      'financialRejected' => l10n.autoCaptureDiagnosticOutcomeFinancialRejected,
      'queued' => l10n.autoCaptureDiagnosticOutcomeQueued,
      'duplicate' => l10n.autoCaptureDiagnosticOutcomeDuplicate,
      'queueWriteFailed' => l10n.autoCaptureDiagnosticOutcomeQueueWriteFailed,
      _ => l10n.autoCaptureDiagnosticUnavailable,
    };
