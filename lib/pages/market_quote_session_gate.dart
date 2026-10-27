import 'package:flutter/material.dart';

import '../app/investments/investment_quote_session.dart';
import '../app/investments/investment_quote_sync.dart';
import '../app/models.dart';
import '../app/veri_fin_controller.dart';
import '../app/veri_fin_scope.dart';
import 'app_lock_gate.dart';

/// 将应用前台与解锁状态交给行情协调器；本组件不绘制额外界面。
/// 必须放在隐私同意、应用锁及引导门卫内部，避免启动时提前访问行情来源。
class MarketQuoteSessionGate extends StatefulWidget {
  /// [child] 是正常应用路由树；组件只管理参考行情，不接触通知或后台服务。
  const MarketQuoteSessionGate({super.key, required this.child});

  final Widget child;

  /// 为本次应用会话保存唯一协调器，路由切换不会重新创建它。
  @override
  State<MarketQuoteSessionGate> createState() => _MarketQuoteSessionGateState();
}

class _MarketQuoteSessionGateState extends State<MarketQuoteSessionGate>
    with WidgetsBindingObserver {
  VeriFinController? _controller;
  InvestmentQuoteSync? _sync;
  InvestmentQuoteSession? _session;
  bool _foreground = false, _unlocked = false, _queued = false;

  /// 读取真实生命周期；后台创建组件时不假定应用已在前台。
  @override
  void initState() {
    super.initState();
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  /// 订阅 Controller 与应用锁；账本、持仓或解锁改变后只合并一次帧末检查。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = VeriFinScope.of(context);
    if (!identical(_controller, controller)) {
      _session?.dispose();
      _controller = controller;
      _sync = controller.investmentQuoteSync;
      _session = InvestmentQuoteSession(
        sync: _sync!,
        isCurrent: (portfolio) =>
            mounted &&
            _foreground &&
            _unlocked &&
            _controller!.privacyConsentAccepted &&
            _controller!.onboardingCompleted &&
            _controller!.activeBook.id == portfolio.bookId &&
            identical(
              _controller!.investmentFor(portfolio.accountId),
              portfolio,
            ),
      );
    }
    _unlocked = AppUnlockScope.of(context);
    if (!_foreground || !_unlocked) {
      _updateSession();
    } else {
      _queueUpdate();
    }
  }

  /// 等应用门卫和当前路由完成本帧更新，再检查可联网的账户；不在 build 中发请求。
  void _queueUpdate() {
    if (_queued) return;
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      if (mounted) _updateSession();
    });
  }

  /// 只用 Controller 公共读取取得当前账本聚合；不访问 repository 或其他账本数据。
  void _updateSession() {
    final controller = _controller;
    if (controller == null) return;
    final portfolios = <InvestmentPortfolio>[
      for (final account in controller.accounts)
        // 空值感知元素只加入已启用投资的账户，不为普通现金账户创建聚合。
        ?controller.investmentFor(account.id),
    ];
    _session?.update(
      active:
          _foreground &&
          _unlocked &&
          controller.privacyConsentAccepted &&
          controller.onboardingCompleted,
      portfolios: portfolios,
    );
  }

  /// 任何非 resumed 状态立即暂停；恢复后仍等待解锁门卫确认，才重新检查独立冷却。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _queueUpdate();
    } else {
      _updateSession();
    }
  }

  /// 退出应用时释放前台调度和观察者；不会修改已保存的联网授权偏好。
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session?.dispose();
    super.dispose();
  }

  /// 保留正常界面和导航结构，不创建独立演示页面。
  @override
  Widget build(BuildContext context) => widget.child;
}
