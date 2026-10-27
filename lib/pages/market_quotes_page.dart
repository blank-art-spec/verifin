/// 参考行情设置与状态；按构建区分发布准入与实验验证，没有可用来源时保留手填。
library;

import 'dart:async';
import 'package:flutter/material.dart';
import '../app/common_widgets.dart';
import '../app/investments/investment_widgets.dart';
import '../app/currency_math.dart';
import '../app/feedback.dart';
import '../app/investments/investment_quote_sync.dart';
import '../app/investments/market_quote.dart';
import '../app/investments/stock_projection.dart';
import '../app/investments/quote_format.dart';
import '../app/veri_fin_controller.dart';
import '../app/veri_fin_scope.dart';
import '../app/models.dart';
import '../l10n/app_localizations.dart';
import 'app_lock_gate.dart';

class MarketQuotesPage extends StatefulWidget {
  /// [accountId] 为当前可见的原币账户，页面只展示该账户的持仓及已装配来源。
  const MarketQuotesPage({super.key, required this.accountId});
  final String accountId;

  /// 页面私有生命周期负责暂停刷新，不要求 Android 后台权限或常驻服务。
  @override
  State<MarketQuotesPage> createState() => _MarketQuotesPageState();
}

class _MarketQuotesPageState extends State<MarketQuotesPage>
    with WidgetsBindingObserver {
  VeriFinController? _controller;
  InvestmentQuoteSync? _sync;
  InvestmentPortfolio? _boundPortfolio;
  bool _foreground = true, _unlocked = true, _saving = false;

  /// 监听前后台；创建状态不联网，等真实页面可见与授权核对后再刷新。
  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  /// 跟随账本及应用锁状态，下一帧只激活当前可交互路由。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller = VeriFinScope.of(context);
    _sync = _controller!.investmentQuoteSync;
    _unlocked = AppUnlockScope.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _activate();
    });
  }

  /// 失去前台或锁屏立即暂停，回前台后等门卫更新完成再重新检查可见性。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _boundPortfolio = null;
      _sync?.setVisible(null);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _activate();
      });
    }
  }

  /// 只有顶层、前台且解锁的页面可以触发请求，其他页面保留旧参考缓存。
  bool get _interactive =>
      mounted &&
      _foreground &&
      _unlocked &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  /// 页面进入时检查缓存/冷却，自动模式仅对这个仍可见的页面排程。
  void _activate({bool force = false}) {
    final p = _controller!.investmentFor(widget.accountId);
    if (!_interactive || p == null) {
      _boundPortfolio = null;
      _sync!.setVisible(null);
      return;
    }
    // 行情自身通知不会重新触发请求或重置定时器；授权变化才显式强制重绑。
    if (!force && identical(p, _boundPortfolio)) return;
    _boundPortfolio = p;
    _sync!.setVisible(p);
    if (_sync!.state.value.enabled) {
      // 请求内有修订与异常保护，页面只声明一次可见生命周期。
      unawaited(_refresh());
      _sync!.scheduleVisibleRefresh(_refresh);
    }
  }

  /// 刷新前后都核对同一聚合实例及账本；字段/持仓/恢复改变会使旧结果失效。
  Future<void> _refresh() async {
    final c = _controller!, p = c.investmentFor(widget.accountId);
    if (!_interactive || p == null) {
      _sync!.setVisible(null);
      return;
    }
    await _sync!.refresh(
      p,
      isCurrent: () =>
          _interactive &&
          c.activeBook.id == p.bookId &&
          identical(c.investmentFor(widget.accountId), p),
    );
  }

  /// 用户主动设置联网；失败使用统一轻提示，偏好不进账目备份。
  Future<void> _configure(bool enabled, bool automatic) async {
    if (_saving) return;
    setState(() => _saving = true);
    final ok = await _sync!.configure(enabled: enabled, automatic: automatic);
    if (!mounted) return;
    setState(() => _saving = false);
    if (!ok) {
      await VeriFeedbackHost.of(context).showMessage(
        message: AppLocalizations.of(context).marketSaveFailed,
        tone: VeriFeedbackTone.error,
      );
      if (!mounted) return;
    }
    _activate(force: true);
  }

  /// 离开路由立即取消页面定时并撤销在途结果；Controller 的缓存仍可供离线估值。
  @override
  void dispose() {
    _sync?.setVisible(null);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 明确区分来源准入、设备联网授权及每证券持续手填覆盖三个用户选择。
  @override
  Widget build(BuildContext context) {
    final c = VeriFinScope.of(context),
        p = c.investmentFor(widget.accountId),
        l = AppLocalizations.of(context);
    if (p == null) {
      return Scaffold(
        body: SafeArea(child: Center(child: Text(l.investSaveError))),
      );
    }
    final sync = c.investmentQuoteSync;
    final held = projectStocks(p).positions.map((h) => h.securityId).toSet();
    // 只展示当前构建实际装配的来源；已移除的研究候选不再形成空配置项。
    final sources = sync.client.adapters.map((adapter) => adapter.capability);
    return Scaffold(
      body: SafeArea(
        child: VeriPage(
          child: Material(
            type: MaterialType.transparency,
            child: ValueListenableBuilder<QuoteSyncState>(
              valueListenable: sync.state,
              builder: (context, state, child) {
                final quotes = sync.quotesFor(p);
                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                  children: [
                    VeriHeader(title: l.marketTitle, showBack: true),
                    const SizedBox(height: 12),
                    InvestmentHint(
                      sync.client.hasResearchSources
                          ? l.marketResearchConsent
                          : l.marketConsent,
                    ),
                    const SizedBox(height: 8),
                    InvestmentSection(
                      title: l.marketTitle,
                      children: [
                        if (!sync.client.hasAvailableSources)
                          InvestmentHint(l.marketGatePending),
                        if (sync.client.hasResearchSources)
                          InvestmentHint(l.marketResearchNote),
                        CompactSwitchRow(
                          icon: Icons.cloud_outlined,
                          value: state.enabled,
                          title: Text(l.marketEnable),
                          onChanged: _saving || !sync.client.hasAvailableSources
                              ? null
                              : (v) => _configure(v, state.automatic),
                        ),
                        CompactSwitchRow(
                          icon: Icons.autorenew,
                          value: state.automatic,
                          title: Text(l.marketAutomatic),
                          onChanged: _saving || !state.enabled
                              ? null
                              : (v) => _configure(state.enabled, v),
                        ),
                        FilledButton(
                          onPressed:
                              !state.enabled ||
                                  state.status == QuoteSyncStatus.loading
                              ? null
                              : _refresh,
                          child: Text(l.marketRefresh),
                        ),
                        const SizedBox(height: 8),
                        InvestmentHint(state.status.label(l)),
                        if (state.attemptedAt != null)
                          Text(
                            '${l.marketAttempt}: ${formatQuoteTime(context, state.attemptedAt!)}',
                          ),
                        if (state.cooldownUntil != null)
                          Text(
                            '${l.marketNextRefresh}: ${formatQuoteTime(context, state.cooldownUntil!)}',
                          ),
                      ],
                    ),
                    if (sources.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      InvestmentSection(
                        title: l.marketSourceReview,
                        children: [
                          for (final source in sources)
                            DetailInfoRow(
                              inline: true,
                              label: source.id,
                              value: source.approved
                                  ? l.marketSourceConnected
                                  : source.researchOnly &&
                                        sync.client.allowResearchSources
                                  ? l.marketSourceResearch
                                  : l.marketAwaitingReview,
                            ),
                        ],
                      ),
                    ],
                    for (final s in p.securities.where(
                      (s) => held.contains(s.id),
                    )) ...[
                      const SizedBox(height: 12),
                      VeriCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              s.name,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              s.symbol,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 8),
                            // 卡片已有实色表面，直接绘制文字和开关，避免 ListTile 墨水被卡片遮住。
                            Row(
                              children: [
                                Expanded(child: Text(l.marketUseForValuation)),
                                Switch(
                                  value: p.marketPriceIds.contains(s.id),
                                  onChanged:
                                      sync.client.adapterFor(
                                            MarketQuoteRequest(s),
                                          ) ==
                                          null
                                      ? null
                                      : (v) async {
                                          final ok = await c
                                              .setInvestmentMarketPrice(
                                                widget.accountId,
                                                s.id,
                                                v,
                                              );
                                          if (!context.mounted) return;
                                          if (!ok) {
                                            await VeriFeedbackHost.of(
                                              context,
                                            ).showMessage(
                                              message: l.marketSaveFailed,
                                              tone: VeriFeedbackTone.error,
                                            );
                                          }
                                        },
                                ),
                              ],
                            ),
                            if (quotes[s.id] case final q?) ...[
                              Text(
                                '${q.source} · ${formatUserSecurityPrice(q.reference(MarketQuoteRequest(s), sync.clock())!.price, p.currencyCode)}',
                              ),
                              Text(
                                '${l.marketQuoteTime}: ${formatQuoteTime(context, q.reference(MarketQuoteRequest(s), sync.clock())!.time)}',
                              ),
                              Text(
                                '${l.investFetchedAt}: ${formatQuoteTime(context, q.fetchedAt)}',
                              ),
                              Text(q.tradeState.label(l)),
                              if (q.delayMinutes != null)
                                Text(l.marketDelayKnown(q.delayMinutes!)),
                              if (q.tradeState != QuoteTradeState.unknown &&
                                  q.delayMinutes == null)
                                Text(l.marketStateUnknown),
                            ] else
                              InvestmentHint(
                                sync.client.adapterFor(MarketQuoteRequest(s)) !=
                                        null
                                    ? l.marketNoQuote
                                    : s.option != null
                                    ? l.marketOptionUnsupported
                                    : l.marketSecurityUnsupported,
                              ),
                            DetailInfoRow(
                              inline: true,
                              label: l.marketManualFallback,
                              value: p.manualPrices[s.id] == null
                                  ? l.investUnknown
                                  : formatUserSecurityPrice(
                                      p.manualPrices[s.id]!,
                                      p.currencyCode,
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
