/// 仅在获准且可见的页面刷新参考行情；偏好/短缓存留设备，不进入账目备份。
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
  /// [changed] 是本次接受的新报价数；失败会继续保留旧缓存及原报价时间。
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
  Timer? _timer;
  int _generation = 0;
  bool _disposed = false,
      _enabled = false,
      _automatic = false,
      _running = false;
  String? _visible;
  DateTime? _attempt, _cooldown;
  Future<void> _writeTail = Future.value();

  /// 只有实际估值依据改变时通知资产消费者，进度及偏好使用 state 单独通知。
  VoidCallback? onPricesChanged;
  static const _settingsKey = 'investment_quote_settings_v1',
      _cacheKey = 'investment_quote_cache_v1';
  static const interval = Duration(minutes: 5);

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
        if (payload['version'] != 1) throw const FormatException('行情缓存版本无效');
        final rows = payload['rows'] as List;
        _attempt = DateTime.tryParse(payload['attemptedAt'] as String? ?? '');
        final cooldown = DateTime.tryParse(
          payload['cooldownUntil'] as String? ?? '',
        );
        final longest = client.adapters
            .where(client.allowsAdapter)
            .fold<Duration>(
              interval,
              (value, a) => a.capability.minimumInterval > value
                  ? a.capability.minimumInterval
                  : value,
            );
        if (cooldown != null && !cooldown.isAfter(clock().add(longest))) {
          _cooldown = cooldown;
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
      logger?.warning('参考行情设备缓存无效，已停用联网并保留账目', source: 'investment_quote');
    }
    _publish(QuoteSyncStatus.idle);
  }

  /// 发布不可变状态；异步退出后不再调用已销毁的通知器。
  void _publish(QuoteSyncStatus status, {int changed = 0}) {
    if (_disposed) return;
    state.value = QuoteSyncState(
      enabled: _enabled,
      automatic: _automatic,
      status: status,
      changed: changed,
      attemptedAt: _attempt,
      cooldownUntil: _cooldown,
    );
  }

  /// 用户主动启停联网；授权先持久成功才生效，关闭立即废弃所有在途结果和定时器。
  Future<bool> configure({
    required bool enabled,
    required bool automatic,
  }) async {
    if (_disposed || enabled && !client.hasAvailableSources) {
      _publish(QuoteSyncStatus.unavailable);
      return false;
    }
    // 用户关闭的意图立即撤销在途请求；即使设备偏好写入失败，也不继续本次会话联网。
    final configuration = ++_configurationRevision;
    _generation++;
    _running = false;
    _timer?.cancel();
    _timer = null;
    if (!enabled) _enabled = false;
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
    _running = false;
    _timer?.cancel();
    _timer = null;
    _publish(QuoteSyncStatus.idle);
    return true;
  }

  /// 账户、事件、恢复或初始化后核对上下文；不匹配缓存不能复活到新账目。
  /// 此调用发生在账目通知内，不回调 onPricesChanged，避免通知递归。
  void reconcile(Iterable<InvestmentPortfolio> values) {
    final next = {for (final p in values) _owner(p): _digest(p)};
    final altered = !mapEquals(next, _contexts);
    // 空账本冷启动时上下文仍为空，但设备缓存可能留有已删除账户的旧行。
    final hasOrphans = _cache.entries.any(
      (e) => next[e.key.substring(0, e.key.lastIndexOf('|'))] != e.value.digest,
    );
    if (!altered && !hasOrphans) return;
    _contexts
      ..clear()
      ..addAll(next);
    _cache.removeWhere((key, row) {
      final owner = key.substring(0, key.lastIndexOf('|'));
      return next[owner] != row.digest;
    });
    _generation++;
    _running = false;
    _timer?.cancel();
    _timer = null;
    if (_visible != null && !next.containsKey(_visible)) _visible = null;
    unawaited(_persistCache());
    _publish(QuoteSyncStatus.idle);
  }

  /// 选择可见页面；null 表示离页、退后台或锁屏，立即停止定时与废弃在途结果。
  void setVisible(InvestmentPortfolio? p) {
    final key = p == null ? null : _owner(p);
    if (key == _visible) return;
    _visible = key;
    _generation++;
    _running = false;
    _timer?.cancel();
    _timer = null;
    _publish(QuoteSyncStatus.idle);
  }

  /// 为当前页面设置五分钟定时器；每次执行仍检查授权、可见性及调用方账本修订。
  /// [refresh] 是页面提供的短命回调，dispose/setVisible(null) 会清理引用。
  void scheduleVisibleRefresh(Future<void> Function() refresh) {
    _timer?.cancel();
    _timer = null;
    if (_disposed || !_enabled || !_automatic || _visible == null) return;
    _timer = Timer.periodic(interval, (_) {
      if (!_running) unawaited(refresh());
    });
  }

  /// 返回该账户已验证的缓存；关闭联网不会抹除已有参考价，也不会接受撤销准入来源。
  Map<String, MarketQuote> quotesFor(InvestmentPortfolio p) {
    final result = <String, MarketQuote>{},
        owner = _owner(p),
        digest = _digest(p);
    final held = projectStocks(p).positions.map((p) => p.securityId).toSet();
    for (final s in p.securities.where((s) => held.contains(s.id))) {
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

  /// 合并同来源的最多20个身份，串行来源请求、每批15秒上限；不抓全市场再筛持仓。
  /// [isCurrent] 在请求前及提交前重读账本、持仓和手填修订，旧响应不会跨上下文生效。
  Future<bool> refresh(
    InvestmentPortfolio p, {
    required bool Function() isCurrent,
  }) async {
    if (_disposed || !_enabled || _visible != _owner(p) || !isCurrent()) {
      return false;
    }
    if (_running) return false;
    final now = clock();
    if (_cooldown != null && now.isBefore(_cooldown!)) {
      _publish(QuoteSyncStatus.cooldown);
      return false;
    }
    final groups = <MarketQuoteAdapter, List<MarketQuoteRequest>>{};
    final held = projectStocks(p).positions.map((p) => p.securityId).toSet();
    for (final s in p.securities.where((s) => held.contains(s.id))) {
      final request = MarketQuoteRequest(s),
          adapter = client.adapterFor(MarketQuoteRequest(s));
      if (adapter != null) {
        final group = groups.putIfAbsent(adapter, () => []);
        if (group.length < 20) group.add(request);
      }
    }
    if (groups.isEmpty) {
      _publish(QuoteSyncStatus.unavailable);
      return false;
    }
    _attempt = now;
    final minimum = groups.keys.fold<Duration>(
      interval,
      (value, a) => a.capability.minimumInterval > value
          ? a.capability.minimumInterval
          : value,
    );
    _cooldown = now.add(minimum);
    _running = true;
    final revision = _generation, owner = _owner(p), digest = _digest(p);
    _publish(QuoteSyncStatus.loading);
    var changed = 0, failed = false;
    try {
      for (final group in groups.entries) {
        // 上一来源失败同样可能伴随关闭或离页；开始下一批之前必须重新核对授权。
        if (_disposed ||
            revision != _generation ||
            !_enabled ||
            _visible != owner ||
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
              _visible != owner ||
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
      _running = false;
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
      );
      if (changed > 0) onPricesChanged?.call();
      return changed > 0;
    } finally {
      if (!_disposed && revision == _generation) {
        _running = false;
        if (state.value.status == QuoteSyncStatus.loading) {
          _publish(QuoteSyncStatus.idle);
        }
      }
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
    final raw = jsonEncode({
      'version': 1,
      'attemptedAt': _attempt?.toIso8601String(),
      'cooldownUntil': _cooldown?.toIso8601String(),
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
      _publish(QuoteSyncStatus.notCached);
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
      _publish(QuoteSyncStatus.notCached);
      return false;
    }
  }

  /// 显式恢复/初始化时清缓存并撤销在途修订，设备授权偏好保留。
  Future<void> clearCache() async {
    _generation++;
    _running = false;
    _cache.clear();
    _timer?.cancel();
    _timer = null;
    final persisted = await _persistCache();
    _publish(persisted ? QuoteSyncStatus.idle : QuoteSyncStatus.notCached);
  }

  /// 离开 Controller 生命周期后停止全部回调；不要求常驻服务或后台权限。
  void dispose() {
    _disposed = true;
    _generation++;
    _timer?.cancel();
    onPricesChanged = null;
    state.dispose();
  }
}
