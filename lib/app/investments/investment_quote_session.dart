/// 应用前台参考行情协调器；不依赖具体页面，不创建后台服务。
library;

import 'dart:async';

import '../models/investment.dart';
import 'investment_quote_sync.dart';

/// 在已授权、已解锁的前台会话内，串行检查当前账本各账户的自动刷新时间。
class InvestmentQuoteSession {
  /// [sync] 负责来源校验、账户计时和缓存；[isCurrent] 由应用层实时核对
  /// 前台/解锁、账本与同一不可变聚合，等待网络时也不能接受已失效的上下文。
  /// 构造仅声明应用级生命周期所有权，不联网；首次激活由 [update] 显式触发。
  InvestmentQuoteSession({required this.sync, required this.isCurrent}) {
    sync.setForegroundPortfolios(null);
    _enabled = sync.state.value.enabled;
    _automatic = sync.state.value.automatic;
    sync.state.addListener(_handleSyncChanged);
  }

  final InvestmentQuoteSync sync;
  final bool Function(InvestmentPortfolio) isCurrent;
  List<InvestmentPortfolio> _portfolios = const [];
  bool _active = false,
      _enabled = false,
      _automatic = false,
      _disposed = false,
      _rerun = false;
  int _revision = 0;
  Timer? _timer;
  Future<void>? _running;
  final _retryAfter = <InvestmentPortfolio, DateTime>{};

  /// 接收当前应用上下文；[active] 仅在前台且已解锁时为 true，
  /// [portfolios] 只包含当前账本真实账户的聚合。相同对象快照不重启请求，
  /// 避免报价通知本身造成重建、撤销与重复联网。
  void update({
    required bool active,
    required Iterable<InvestmentPortfolio> portfolios,
  }) {
    if (_disposed) return;
    final next = List<InvestmentPortfolio>.unmodifiable(portfolios);
    final unchanged =
        _active == active &&
        next.length == _portfolios.length &&
        List.generate(
          next.length,
          (index) => identical(next[index], _portfolios[index]),
        ).every((same) => same);
    if (unchanged) return;
    _active = active;
    _portfolios = next;
    _retryAfter.clear();
    sync.setForegroundPortfolios(active ? next : null);
    _restart();
  }

  /// 当前是否允许自动联网；手动刷新仍由同步器及页面独立验证，不借此绕过授权。
  bool get _canAutomaticallyRefresh =>
      !_disposed && _active && _enabled && _automatic;

  /// [portfolio] 必须仍属于本次前台快照，且应用层实时核对仍通过。
  bool _current(InvestmentPortfolio portfolio) =>
      _canAutomaticallyRefresh &&
      _portfolios.any((value) => identical(value, portfolio)) &&
      isCurrent(portfolio);

  /// 开关变化重启调度；手动请求完成只重排剩余时间，不重置任何账户的截止时间。
  void _handleSyncChanged() {
    if (_disposed) return;
    final value = sync.state.value;
    if (_enabled != value.enabled || _automatic != value.automatic) {
      _enabled = value.enabled;
      _automatic = value.automatic;
      _restart();
    } else if (_running == null) {
      _scheduleNext();
    }
  }

  /// 撤销旧批次后检查新会话；旧网络尚在收尾时只登记一次补跑，不并发批量请求。
  void _restart() {
    _revision++;
    _timer?.cancel();
    _timer = null;
    _retryAfter.clear();
    if (!_canAutomaticallyRefresh) {
      _rerun = false;
      return;
    }
    if (_running != null) {
      _rerun = true;
    } else {
      unawaited(refreshIfDue());
    }
  }

  /// 检查所有到期账户并串行获取；仍在各自冷却内或已有请求的账户直接跳过。
  /// 已有批次时返回同一 Future，供显式调用者等待；不会因为等待再发一轮请求。
  Future<void> refreshIfDue() {
    if (_running case final running?) return running;
    if (!_canAutomaticallyRefresh) return Future<void>.value();
    _timer?.cancel();
    _timer = null;
    final completed = Completer<void>();
    _running = completed.future;
    unawaited(_runDue(completed, _revision, List.of(_portfolios)));
    return completed.future;
  }

  /// 执行 [revision] 对应的 [portfolios] 快照；完成时释放 [completed] 并安排后续周期。
  /// 每个账户等待前后都复核实时上下文，换账本、锁屏或退后台后不再启动下一笔请求。
  Future<void> _runDue(
    Completer<void> completed,
    int revision,
    List<InvestmentPortfolio> portfolios,
  ) async {
    try {
      for (final portfolio in portfolios) {
        if (revision != _revision || !_canAutomaticallyRefresh) break;
        if (!_current(portfolio) || !sync.hasSupportedHoldings(portfolio)) {
          continue;
        }
        final state = sync.stateFor(portfolio);
        if (state.status == QuoteSyncStatus.loading ||
            state.cooldownUntil != null &&
                sync.clock().isBefore(state.cooldownUntil!)) {
          continue;
        }
        await sync.refresh(
          portfolio,
          automatic: true,
          isCurrent: () => revision == _revision && _current(portfolio),
        );
        final after = sync.stateFor(portfolio);
        if (after.attemptedAt == state.attemptedAt &&
            after.status != QuoteSyncStatus.loading) {
          // 配置正在异步保存等场景可能在真正请求前拒绝；仅给该账户退让，避免空转。
          _retryAfter[portfolio] = sync.clock().add(
            InvestmentQuoteSync.interval,
          );
        } else {
          _retryAfter.remove(portfolio);
        }
      }
    } catch (error) {
      // 行情是派生参考信息，调度异常时保留旧报价与手填价；下次前台检查可重试。
      // 逐来源的网络/缓存错误已由同步器发布账户状态，这里不广播与账目无关的弹窗。
      sync.logger?.warning(
        '应用前台行情调度异常：${error.runtimeType}',
        source: 'investment_quote',
      );
    } finally {
      _running = null;
      completed.complete();
      if (_rerun && _canAutomaticallyRefresh) {
        _rerun = false;
        unawaited(refreshIfDue());
      } else {
        _rerun = false;
        _scheduleNext();
      }
    }
  }

  /// 按所有受支持账户中最早的独立截止时间排程；离页不改变应用会话。
  /// 正在手动请求的账户暂时跳过，由其完成状态唤醒，避免零延时反复空转。
  void _scheduleNext() {
    _timer?.cancel();
    _timer = null;
    if (!_canAutomaticallyRefresh || _running != null) return;
    final now = sync.clock();
    DateTime? earliest;
    for (final portfolio in _portfolios) {
      if (!_current(portfolio) || !sync.hasSupportedHoldings(portfolio)) {
        continue;
      }
      final state = sync.stateFor(portfolio);
      if (state.status == QuoteSyncStatus.loading) continue;
      var due = state.cooldownUntil ?? now;
      final retry = _retryAfter[portfolio];
      if (retry != null && due.isBefore(retry)) due = retry;
      if (earliest == null || due.isBefore(earliest)) earliest = due;
    }
    if (earliest == null) return;
    final delay = earliest.isAfter(now)
        ? earliest.difference(now)
        : Duration.zero;
    final revision = _revision;
    _timer = Timer(delay, () {
      _timer = null;
      if (revision == _revision && _canAutomaticallyRefresh) {
        unawaited(refreshIfDue());
      }
    });
  }

  /// 应用退出或协调器移除时停止排程、撤销在途结果并释放监听，不关闭用户的偏好开关。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _revision++;
    _timer?.cancel();
    sync.state.removeListener(_handleSyncChanged);
    sync.setForegroundPortfolios(null);
  }
}
