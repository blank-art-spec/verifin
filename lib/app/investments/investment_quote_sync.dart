/// 仅在获准的前台会话中刷新参考行情；偏好/短缓存留设备，不进入账目备份。
library;

import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import '../../local_storage/local_storage.dart';
import '../../l10n/app_localizations.dart';
import '../logging/app_logger.dart';
import '../models/investment.dart';
import 'market_quote.dart';
import 'stock_projection.dart';

enum QuoteSyncStatus {
  idle,
  loading,
  ready,
  unavailable,
  failed,
  cooldown,
  notCached;

  /// 同步状态的本地化显示名；来源成功和缓存成功不等同于实时授权。
  String label(AppLocalizations l) => switch (this) {
    loading => l.commonProcessing,
    ready => l.marketReady,
    unavailable => l.marketUnavailable,
    failed => l.marketFailed,
    cooldown => l.marketCooldown,
    notCached => l.marketNotCached,
    idle => l.marketIdle,
  };
}

/// 给页面独立通知同步状态，不把开关/请求进度广播成所有账目变化。
class QuoteSyncState {
  /// [changed] 是当前账户本次接受的新报价数；失败保留旧缓存及原报价时间。
  /// [attemptedAt] 为该账户最近一次真实请求；[cooldownUntil] 仅表示自动刷新
  /// 最早可再次请求的时间，手动刷新不受它限制，也不会推迟这个时间。
  const QuoteSyncState({
    this.enabled = false,
    this.automatic = false,
    this.status = QuoteSyncStatus.idle,
    this.changed = 0,
    this.attemptedAt,
    this.cooldownUntil,
  });
  final bool enabled, automatic;
  final QuoteSyncStatus status;
  final int changed;
  final DateTime? attemptedAt, cooldownUntil;
}

/// 每个账本及原币账户各自保存的刷新状态；不会发送给行情来源。
class _AccountRefreshState {
  /// [attemptedAt] 记录最近一次真实请求；[automaticAt] 只约束自动请求。
  /// 状态和计数只在当前进程使用，冷启动仅恢复时间，不恢复过期的“处理中”。
  _AccountRefreshState({this.attemptedAt, this.automaticAt});

  DateTime? attemptedAt, automaticAt;
  QuoteSyncStatus status = QuoteSyncStatus.idle;
  int changed = 0;
}

/// 设备端轻量同步器；构造只读本地，不获取网络、不保存持仓。
class InvestmentQuoteSync {
  /// [client] 是当前构建允许的来源集合；[clock] 可用于稳定的冷却/旧报价测试。
  InvestmentQuoteSync({
    required this.store,
    required this.client,
    this.logger,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now {
    _restore();
  }
  final LocalKeyValueStore store;
  final MarketQuoteClient client;
  final AppLogger? logger;
  final DateTime Function() clock;
  final ValueNotifier<QuoteSyncState> state = ValueNotifier(
    const QuoteSyncState(),
  );

  /// 开关写入独立串行化；较早的开启确认不能覆盖较晚的关闭意图。
  Future<void> _settingsWrites = Future.value();
  int _configurationRevision = 0;
  final _cache = <String, ({String digest, MarketQuote quote})>{};
  final _contexts = <String, String>{};
  final _accounts = <String, _AccountRefreshState>{};
  final _runningOwners = <String>{};
  Timer? _timer;
  Future<void> Function()? _scheduledRefresh;
  int _generation = 0;
  bool _disposed = false, _enabled = false, _automatic = false;
  String? _visible;
  bool _applicationManaged = false, _applicationActive = false;
  final _foregroundOwners = <String>{};
  Future<void> _writeTail = Future.value();

  /// 只有实际估值依据改变时通知资产消费者，进度及偏好使用 state 单独通知。
  VoidCallback? onPricesChanged;
  static const _settingsKey = 'investment_quote_settings_v1',
      _cacheKey = 'investment_quote_cache_v1';
  static const interval = Duration(minutes: 5);

  /// 是否已由应用级协调器接管生命周期；页面据此避免另建一套自动请求。
  bool get applicationManaged => _applicationManaged;

  /// 使用明确数组编码账户键，避免任意账户 ID 内分隔符造成跨账本碰撞。
  String _owner(InvestmentPortfolio p) => jsonEncode([p.bookId, p.accountId]);

  /// 只保存账务上下文摘要；缓存不复制数量、成本、余额或交易备注。
  /// 手填价、覆盖选择及历史快照不改变证券身份，独立在在途检查中保护。
  String _digest(InvestmentPortfolio p) {
    final data = p.toJson()
      ..remove('manualPrices')
      ..remove('marketPriceIds')
      ..remove('valuationSnapshots');
    return sha256.convert(utf8.encode(jsonEncode(data))).toString();
  }

  /// 恢复偏好和小缓存；损坏缓存允许丢弃并明确记日志，不回退或重置权威账目。
  void _restore() {
    try {
      final raw = store.read(_settingsKey);
      if (raw != null) {
        final json = jsonDecode(raw) as Map;
        _enabled = json['enabled'] == true && client.hasAvailableSources;
        _automatic = json['automatic'] == true;
      }
      final cached = store.read(_cacheKey);
      if (cached != null) {
        if (cached.length > 512 * 1024) {
          throw const FormatException('行情缓存超过设备上限');
        }
        final payload = jsonDecode(cached) as Map;
        if (payload['version'] != 1 && payload['version'] != 2) {
          throw const FormatException('行情缓存版本无效');
        }
        final rows = payload['rows'] as List;
        final longest = client.adapters
            .where(client.allowsAdapter)
            .fold<Duration>(
              interval,
              (value, a) => a.capability.minimumInterval > value
                  ? a.capability.minimumInterval
                  : value,
            );
        // v1 的全局请求时间无法归属具体账户，只保留其报价，不复制全局冷却。
        if (payload['version'] == 2) {
          final accounts = payload['accounts'] as List;
          if (accounts.length > 100) {
            throw const FormatException('行情账户状态超过设备上限');
          }
          for (final raw in accounts) {
            final row = raw as Map;
            final owner = row['owner'] as String;
            final identity = jsonDecode(owner);
            if (identity is! List ||
                identity.length != 2 ||
                identity.any((value) => value is! String)) {
              throw const FormatException('行情账户状态身份无效');
            }
            final cooldown = DateTime.tryParse(
              row['cooldownUntil'] as String? ?? '',
            );
            _accounts[owner] = _AccountRefreshState(
              attemptedAt: DateTime.tryParse(
                row['attemptedAt'] as String? ?? '',
              ),
              automaticAt:
                  cooldown != null && !cooldown.isAfter(clock().add(longest))
                  ? cooldown
                  : null,
            );
          }
        }
        if (rows.length > 100) throw const FormatException('行情缓存条目超过上限');
        for (final raw in rows) {
          final row = raw as Map;
          final key = row['key'] as String;
          if (key.lastIndexOf('|') < 1) {
            throw const FormatException('行情缓存账户键无效');
          }
          _cache[key] = (
            digest: row['digest'] as String,
            quote: MarketQuote.fromJson(
              Map<String, Object?>.from(row['quote'] as Map),
            ),
          );
        }
      }
    } catch (_) {
      // 仅设备偏好/派生缓存损坏，默认关闭并丢弃；不会改动 SQLite 中的账户和持仓。
      _enabled = false;
      _cache.clear();
      _accounts.clear();
      logger?.warning('参考行情设备缓存无效，已停用联网并保留账目', source: 'investment_quote');
    }
    _publish(QuoteSyncStatus.idle);
  }

  /// 更新 [owner] 对应账户的结果；省略时更新当前可见账户。
  /// 页面始终只显示所选账户；应用级调度仍能收到其他账户的完成信号，
  /// 但不能把另一账户的完成/失败覆盖到当前显示。
  void _publish(QuoteSyncStatus status, {int changed = 0, String? owner}) {
    if (_disposed) return;
    final key = owner ?? _visible;
    if (key != null) {
      final account = _accounts.putIfAbsent(key, _AccountRefreshState.new);
      account.status = status;
      account.changed = changed;
    }
    if (owner != null && owner != _visible) {
      // 应用协调器也需要收到非可见账户完成信号；页面仍只展示自己的快照。
      if (_applicationManaged) _publishVisible();
      return;
    }
    _publishVisible(fallback: status);
  }

  /// 只读取当前账户状态并通知页面，不把上一账户的时间、计数或错误复制过来。
  /// [fallback] 仅在没有可见账户时提供授权操作的结果。
  void _publishVisible({QuoteSyncStatus fallback = QuoteSyncStatus.idle}) {
    if (_disposed) return;
    state.value = _stateForOwner(_visible, fallback: fallback);
  }

  /// 返回 [owner] 的独立快照，不改变当前页面选择，也不通知其他账户。
  /// [fallback] 只用于尚未产生账户结果的授权操作。
  QuoteSyncState _stateForOwner(
    String? owner, {
    QuoteSyncStatus fallback = QuoteSyncStatus.idle,
  }) {
    final account = _accounts[owner];
    return QuoteSyncState(
      enabled: _enabled,
      automatic: _automatic,
      status: _enabled && _runningOwners.contains(owner)
          ? QuoteSyncStatus.loading
          : account?.status ?? fallback,
      changed: account?.changed ?? 0,
      attemptedAt: account?.attemptedAt,
      cooldownUntil: account?.automaticAt,
    );
  }

  /// 读取 [portfolio] 的请求、运行及自动计时状态，供应用级协调器逐账户排程。
  QuoteSyncState stateFor(InvestmentPortfolio portfolio) =>
      _stateForOwner(_owner(portfolio));

  /// 声明当前前台、已解锁且属于当前账本的 [portfolios]；null 表示暂停联网。
  /// 此方法只更新授权范围，不自行发请求。相同账户范围保持修订不变，避免报价
  /// 通知重建界面时误撤销自己；后台/锁屏/换账本则撤销旧响应和页面遗留定时器。
  void setForegroundPortfolios(Iterable<InvestmentPortfolio>? portfolios) {
    if (_disposed) return;
    final next = portfolios == null
        ? <String>{}
        : portfolios.map(_owner).toSet();
    final active = portfolios != null;
    if (_applicationManaged &&
        _applicationActive == active &&
        setEquals(_foregroundOwners, next)) {
      return;
    }
    _applicationManaged = true;
    _applicationActive = active;
    _foregroundOwners
      ..clear()
      ..addAll(next);
    _generation++;
    _timer?.cancel();
    _timer = null;
    _scheduledRefresh = null;
  }

  /// 核对 [owner] 是否仍获当前前台会话允许；独立页面保持原有可见上下文入口。
  bool _allowsRequest(String owner) => _applicationManaged
      ? _applicationActive && _foregroundOwners.contains(owner)
      : _visible == owner;

  /// 用户主动启停联网；授权先持久成功才生效，关闭立即废弃所有在途结果和定时器。
  Future<bool> configure({
    required bool enabled,
    required bool automatic,
  }) async {
    if (_disposed || enabled && !client.hasAvailableSources) {
      _publish(QuoteSyncStatus.unavailable);
      return false;
    }
    // 用户关闭的意图立即撤销在途请求；即使设备偏好写入失败，也不继续被关闭的行为。
    final configuration = ++_configurationRevision;
    _generation++;
    _timer?.cancel();
    _timer = null;
    _scheduledRefresh = null;
    if (!enabled) _enabled = false;
    if (!automatic) _automatic = false;
    if (!enabled || !automatic) {
      // 应用批次可能正等待上一账户响应，必须在异步保存前通知其停止，不能
      // 等写入成功才让后续账户知道自动刷新已关闭。保存失败时仍保留本会话
      // 的停止意图；返回 false 及既有失败提示说明该偏好尚未持久保存。
      _publish(QuoteSyncStatus.idle);
    }
    try {
      final writing = _settingsWrites.then(
        (_) => store.writeAndFlush(
          _settingsKey,
          jsonEncode({'enabled': enabled, 'automatic': automatic}),
        ),
      );
      // 失败由本次 configure 的 catch 记录和反馈，队列只恢复后续写入能力。
      _settingsWrites = writing.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      );
      await writing;
    } catch (_) {
      logger?.warning('参考行情偏好保存失败', source: 'investment_quote');
      if (configuration == _configurationRevision) {
        _publish(QuoteSyncStatus.failed);
      }
      return false;
    }
    if (_disposed || configuration != _configurationRevision) return false;
    _enabled = enabled;
    _automatic = automatic;
    _generation++;
    _timer?.cancel();
    _timer = null;
    _scheduledRefresh = null;
    _publish(QuoteSyncStatus.idle);
    return true;
  }

  /// 账户、事件、恢复或初始化后核对上下文；不匹配缓存不能复活到新账目。
  /// 此调用发生在账目通知内，不回调 onPricesChanged，避免通知递归。
  void reconcile(Iterable<InvestmentPortfolio> values) {
    final portfolios = {for (final p in values) _owner(p): p};
    final next = portfolios.map((owner, p) => MapEntry(owner, _digest(p)));
    final altered = !mapEquals(next, _contexts);
    // 空账本冷启动时上下文仍为空，但设备缓存可能留有已删除账户的旧行。
    final hasOrphans = _cache.entries.any(
      (e) => next[e.key.substring(0, e.key.lastIndexOf('|'))] != e.value.digest,
    );
    final hasAccountOrphans = _accounts.keys.any(
      (owner) => !next.containsKey(owner),
    );
    if (!altered && !hasOrphans && !hasAccountOrphans) return;
    _contexts
      ..clear()
      ..addAll(next);
    for (final entry in _cache.entries.toList()) {
      final owner = entry.key.substring(0, entry.key.lastIndexOf('|'));
      if (next[owner] == entry.value.digest) continue;
      final portfolio = portfolios[owner];
      // 基金公开净值历史不包含账务，买卖或清仓后仍可按新真实份额重算。
      // 只重绑同一账户、仍存在且来源/品种/币种均合格的身份；股票保留原失效规则。
      if (portfolio != null &&
          _canReuseFundHistory(portfolio, entry.value.quote)) {
        _cache[entry.key] = (digest: next[owner]!, quote: entry.value.quote);
      } else {
        _cache.remove(entry.key);
      }
    }
    _accounts.removeWhere((owner, _) => !next.containsKey(owner));
    _generation++;
    _timer?.cancel();
    _timer = null;
    _scheduledRefresh = null;
    if (_visible != null && !next.containsKey(_visible)) _visible = null;
    // 清理的是派生缓存；失败由持久化方法记录，不覆盖此时其他账户的页面状态。
    unawaited(_persistCache());
    _publish(QuoteSyncStatus.idle);
  }

  /// 选择页面展示的账户；应用级模式下离页不撤销其他前台页面的自动请求。
  /// 未装配应用协调器的独立页面仍以可见上下文管理自己的请求与测试生命周期。
  void setVisible(InvestmentPortfolio? p) {
    final key = p == null ? null : _owner(p);
    if (key == _visible) return;
    _visible = key;
    if (_applicationManaged) {
      _publishVisible();
      return;
    }
    _generation++;
    _timer?.cancel();
    _timer = null;
    _scheduledRefresh = null;
    _publishVisible();
  }

  /// 为当前页面绑定自动回调，并按该账户原有截止时间排程。
  /// [refresh] 是页面提供的自动入口；重新进入页面不重新累计五分钟，
  /// 手动刷新也不会改变截止时间。离页和销毁会清除这个短命页面引用。
  void scheduleVisibleRefresh(Future<void> Function() refresh) {
    if (_applicationManaged) return;
    _scheduledRefresh = refresh;
    _armAutomaticRefresh();
  }

  /// 根据当前账户的最早自动时间设置一次定时器；实际请求完成后再排下一次。
  /// [notBefore] 仅供未能发起请求的自动回调退让，避免无支持证券时零延时空转。
  /// 当前已有请求时暂不设置定时器，等其 finally 解除防重复保护后重新排程。
  void _armAutomaticRefresh({DateTime? notBefore}) {
    _timer?.cancel();
    _timer = null;
    final owner = _visible, refresh = _scheduledRefresh;
    if (_disposed ||
        _applicationManaged ||
        !_enabled ||
        !_automatic ||
        owner == null ||
        refresh == null ||
        _runningOwners.contains(owner)) {
      return;
    }
    final now = clock();
    var due = _accounts[owner]?.automaticAt ?? now.add(interval);
    if (notBefore != null && due.isBefore(notBefore)) due = notBefore;
    final delay = due.isAfter(now) ? due.difference(now) : Duration.zero;
    final generation = _generation;
    _timer = Timer(delay, () {
      _timer = null;
      if (_disposed ||
          generation != _generation ||
          _visible != owner ||
          _runningOwners.contains(owner)) {
        return;
      }
      unawaited(_runAutomaticRefresh(refresh, owner, generation));
    });
  }

  /// 执行 [refresh] 后继续排程；[owner] 与 [generation] 阻止旧页面重新挂回定时器。
  /// 没有可请求证券时不反复立即重试；回调异常仅记安全类别并反馈当前账户失败。
  Future<void> _runAutomaticRefresh(
    Future<void> Function() refresh,
    String owner,
    int generation,
  ) async {
    final previous = _accounts[owner]?.automaticAt;
    try {
      await refresh();
    } catch (_) {
      logger?.warning('参考行情自动刷新回调失败', source: 'investment_quote');
      if (!_disposed && generation == _generation && _visible == owner) {
        _publish(QuoteSyncStatus.failed, owner: owner);
      }
    } finally {
      if (!_disposed &&
          generation == _generation &&
          _visible == owner &&
          identical(_scheduledRefresh, refresh)) {
        final unchanged = _accounts[owner]?.automaticAt == previous;
        _armAutomaticRefresh(
          notBefore: unchanged ? clock().add(interval) : null,
        );
      }
    }
  }

  /// 返回该账户已验证的缓存；关闭联网不会抹除已有参考价，也不会接受撤销准入来源。
  /// [includeFundHistory] 供行情和参考历史页读取已清仓基金的公开观察，不让零持仓进入资产。
  Map<String, MarketQuote> quotesFor(
    InvestmentPortfolio p, {
    bool includeFundHistory = false,
  }) {
    final result = <String, MarketQuote>{},
        owner = _owner(p),
        digest = _digest(p);
    final held = projectStocks(p).positions.map((p) => p.securityId).toSet();
    for (final s in p.securities.where(
      (s) => held.contains(s.id) || (includeFundHistory && s.isFund),
    )) {
      final request = MarketQuoteRequest(s),
          adapter = client.adapterFor(MarketQuoteRequest(s));
      final row = _cache['$owner|${s.id}'];
      if (row == null ||
          row.digest != digest ||
          adapter == null ||
          row.quote.source != adapter.capability.id) {
        continue;
      }
      if (row.quote.reference(request, clock()) != null) {
        result[s.id] = row.quote;
      }
    }
    return Map.unmodifiable(result);
  }

  /// 读取同一账户、同一基金身份的合格公开净值历史，清仓后也可生成既往参考收益。
  /// [p] 必须是当前账务上下文，[securityId] 是基金稳定身份；撤销来源、删账户或清缓存失效。
  FundNavHistory? fundNavHistoryFor(InvestmentPortfolio p, String securityId) =>
      quotesFor(p, includeFundHistory: true)[securityId]?.navHistory;

  /// 判断 [quote] 的纯公开历史能否在 [portfolio] 的新账务修订继续使用。
  /// 不继承旧持仓或收益，只保留仍被当前构建来源接受的同一基金日期/价格资料。
  bool _canReuseFundHistory(InvestmentPortfolio portfolio, MarketQuote quote) {
    if (quote.navHistory == null || quote.currency != portfolio.currencyCode) {
      return false;
    }
    final security = portfolio.securities
        .where(
          (s) =>
              s.id == quote.securityId &&
              s.isFund &&
              s.option == null &&
              s.currencyCode == portfolio.currencyCode,
        )
        .firstOrNull;
    if (security == null) return false;
    final request = MarketQuoteRequest(security);
    final adapter = client.adapterFor(request);
    return adapter != null &&
        quote.source == adapter.capability.id &&
        quote.reference(request, clock()) != null;
  }

  /// 判断已采用的清仓基金是否还缺覆盖最后业务日的公开历史。
  /// [portfolio]/[security] 仅用于本地需求判定；覆盖后不继续为空持仓自动联网。
  /// 关闭采用、完全没有份额事实或只存在未来交易时不额外查询。
  bool _needsFundHistory(
    InvestmentPortfolio portfolio,
    StockSecurity security,
  ) {
    if (!security.isFund || !portfolio.marketPriceIds.contains(security.id)) {
      return false;
    }
    final now = clock();
    final relevantTimes = [
      if (!portfolio.openedAt.isAfter(now) &&
          portfolio.openingHoldings.any((h) => h.securityId == security.id))
        portfolio.openedAt,
      for (final event in portfolio.events)
        if (event.securityId == security.id && !event.occurredAt.isAfter(now))
          event.occurredAt,
    ];
    if (relevantTimes.isEmpty) return false;
    final latest = relevantTimes.reduce((a, b) => a.isAfter(b) ? a : b);
    final hk = latest.toUtc().add(const Duration(hours: 8));
    final requiredDate = DateTime.utc(hk.year, hk.month, hk.day);
    final history = fundNavHistoryFor(portfolio, security.id);
    return history == null || history.points.last.date.isBefore(requiredDate);
  }

  /// 返回当前持有或尚需补齐清仓历史、且来源明确支持的公开请求，每来源最多20项。
  /// 所有账户信息只用于本地选择，实际传给适配器的对象仍仅含公开证券身份。
  Map<MarketQuoteAdapter, List<MarketQuoteRequest>> _requestGroups(
    InvestmentPortfolio portfolio,
  ) {
    final groups = <MarketQuoteAdapter, List<MarketQuoteRequest>>{};
    final held = projectStocks(
      portfolio,
    ).positions.map((position) => position.securityId).toSet();
    for (final security in portfolio.securities.where(
      (security) =>
          held.contains(security.id) || _needsFundHistory(portfolio, security),
    )) {
      final request = MarketQuoteRequest(security);
      final adapter = client.adapterFor(request);
      if (adapter == null) continue;
      final group = groups.putIfAbsent(adapter, () => []);
      if (group.length < 20) group.add(request);
    }
    return groups;
  }

  /// [portfolio] 有可请求的真实持仓时才参与应用级排程，避免空账户或不支持品种空转。
  bool hasSupportedHoldings(InvestmentPortfolio portfolio) =>
      _requestGroups(portfolio).isNotEmpty;

  /// 合并同来源的最多20个身份，串行来源请求、每批15秒上限；不抓全市场再筛持仓。
  /// [isCurrent] 在请求前及提交前重读账本、持仓和手填修订，旧响应不会跨上下文生效。
  /// [automatic] 默认为 false，表示用户手动刷新，不等待本地五分钟间隔。
  /// 页面进入及定时调用传 true，只受该账户自己的自动间隔约束；手动请求
  /// 不推迟自动计时。同一账户已有请求时直接返回 false，避免连续点击产生并发。
  Future<bool> refresh(
    InvestmentPortfolio p, {
    required bool Function() isCurrent,
    bool automatic = false,
  }) async {
    if (_disposed || !_enabled || !_allowsRequest(_owner(p)) || !isCurrent()) {
      return false;
    }
    final owner = _owner(p);
    if (_runningOwners.contains(owner)) return false;
    final now = clock();
    final account = _accounts.putIfAbsent(owner, _AccountRefreshState.new);
    if (automatic &&
        account.automaticAt != null &&
        now.isBefore(account.automaticAt!)) {
      _publish(QuoteSyncStatus.cooldown, owner: owner);
      return false;
    }
    final groups = _requestGroups(p);
    if (groups.isEmpty) {
      _publish(QuoteSyncStatus.unavailable, owner: owner);
      return false;
    }
    account.attemptedAt = now;
    final minimum = groups.keys.fold<Duration>(
      interval,
      (value, a) => a.capability.minimumInterval > value
          ? a.capability.minimumInterval
          : value,
    );
    if (automatic) account.automaticAt = now.add(minimum);
    _runningOwners.add(owner);
    final revision = _generation, digest = _digest(p);
    _publish(QuoteSyncStatus.loading, owner: owner);
    var changed = 0, failed = false;
    try {
      for (final group in groups.entries) {
        // 上一来源失败同样可能伴随关闭或离页；开始下一批之前必须重新核对授权。
        if (_disposed ||
            revision != _generation ||
            !_enabled ||
            !_allowsRequest(owner) ||
            !isCurrent()) {
          return false;
        }
        try {
          final quotes = await group.key
              .fetch(List.unmodifiable(group.value))
              .timeout(const Duration(seconds: 15));
          if (_disposed ||
              revision != _generation ||
              !_enabled ||
              !_allowsRequest(owner) ||
              !isCurrent()) {
            return false;
          }
          if (!client.allowsAdapter(group.key)) {
            failed = true;
            continue;
          }
          for (final quote in quotes.take(20)) {
            final request = group.value
                .where((q) => q.securityId == quote.securityId)
                .firstOrNull;
            if (request == null || quote.source != group.key.capability.id) {
              continue;
            }
            final reference = quote.reference(request, clock());
            if (reference == null) {
              failed = true;
              continue;
            }
            final key = '$owner|${quote.securityId}',
                old = _cache[key]?.quote.reference(request, clock());
            if (old != null && reference.time.isBefore(old.time)) continue;
            _cache[key] = (digest: digest, quote: quote);
            changed++;
          }
        } catch (_) {
          // 有界来源失败属于正常降级；只记来源/数量，不记录异常原文或响应正文。
          failed = true;
          logger?.warning(
            '参考行情来源 ${group.key.capability.id} 失败，数量 ${group.value.length}',
            source: 'investment_quote',
          );
        }
      }
      if (_disposed || revision != _generation || !isCurrent()) return false;
      final persisted = await _persistCache();
      if (_disposed || revision != _generation || !isCurrent()) return false;
      _publish(
        !persisted
            ? QuoteSyncStatus.notCached
            : failed
            ? QuoteSyncStatus.failed
            : changed > 0
            ? QuoteSyncStatus.ready
            : QuoteSyncStatus.unavailable,
        changed: changed,
        owner: owner,
      );
      if (changed > 0) onPricesChanged?.call();
      return changed > 0;
    } finally {
      // 即使离页已撤销结果，也要等真实请求退出后才解除该账户的防重复保护。
      _runningOwners.remove(owner);
      if (!_disposed &&
          identical(_accounts[owner], account) &&
          account.status == QuoteSyncStatus.loading) {
        _publish(QuoteSyncStatus.idle, owner: owner);
      } else if (!_disposed && (_visible == owner || _applicationManaged)) {
        // 配置改变可能已把内部结果改成空闲，仍须移除页面上的请求中状态。
        _publishVisible();
      }
      if (!_disposed && _visible == owner) _armAutomaticRefresh();
    }
  }

  /// 小缓存串行持久化、最多100项；失败显示“未缓存”，本次内存报价及旧磁盘可解释。
  Future<bool> _persistCache() async {
    if (_cache.length > 100) {
      final keys = _cache.keys.toList()
        ..sort(
          (a, b) =>
              _cache[a]!.quote.fetchedAt.compareTo(_cache[b]!.quote.fetchedAt),
        );
      for (final key in keys.take(_cache.length - 100)) {
        _cache.remove(key);
      }
    }
    if (_accounts.length > 100) {
      final owners = _accounts.keys.toList()
        ..sort(
          (a, b) => (_accounts[a]!.attemptedAt ?? DateTime(1970)).compareTo(
            _accounts[b]!.attemptedAt ?? DateTime(1970),
          ),
        );
      final removable = owners.where(
        (owner) => owner != _visible && !_runningOwners.contains(owner),
      );
      for (final owner in removable.take(_accounts.length - 100)) {
        _accounts.remove(owner);
      }
    }
    if (_accounts.length > 100) {
      // 极端并发时不淘汰正在使用的状态，也不写入下次无法恢复的超限缓存。
      return false;
    }
    final raw = jsonEncode({
      'version': 2,
      'accounts': [
        for (final entry in _accounts.entries)
          {
            'owner': entry.key,
            'attemptedAt': entry.value.attemptedAt?.toIso8601String(),
            'cooldownUntil': entry.value.automaticAt?.toIso8601String(),
          },
      ],
      'rows': [
        for (final e in _cache.entries)
          {
            'key': e.key,
            'digest': e.value.digest,
            'quote': e.value.quote.toJson(),
          },
      ],
    });
    if (raw.length > 512 * 1024) {
      return false;
    }
    final operation = _writeTail.then(
      (_) => store.writeAndFlush(_cacheKey, raw),
    );
    _writeTail = operation.catchError((Object error, StackTrace stack) {
      /* 失败不阻塞后续缓存写入。 */
    });
    try {
      await operation;
      return true;
    } catch (_) {
      logger?.warning('参考行情缓存保存失败，当前报价仅在内存可用', source: 'investment_quote');
      return false;
    }
  }

  /// 显式恢复/初始化时清缓存并撤销在途修订，设备授权偏好保留。
  Future<void> clearCache() async {
    _generation++;
    _cache.clear();
    _accounts.clear();
    _timer?.cancel();
    _timer = null;
    _scheduledRefresh = null;
    final persisted = await _persistCache();
    _publish(persisted ? QuoteSyncStatus.idle : QuoteSyncStatus.notCached);
  }

  /// 离开 Controller 生命周期后停止全部回调；不要求常驻服务或后台权限。
  void dispose() {
    _disposed = true;
    _generation++;
    _timer?.cancel();
    _scheduledRefresh = null;
    onPricesChanged = null;
    state.dispose();
  }
}
