part of 'veri_fin_controller.dart';

/// 期权草稿行情的只读查询入口，不写入账目或设备缓存。
mixin _OptionQuoteOps on _ControllerState {
  /// 只读查询未保存合约；切换账本或销毁后，旧结果只能作为 cancelled 返回。
  Future<DraftOptionQuoteResult> fetchDraftOptionQuote(
    MarketQuoteRequest request,
  ) async {
    if (_controllerDisposed) {
      return const DraftOptionQuoteResult(DraftOptionQuoteStatus.cancelled);
    }
    final bookId = _activeBookId;
    final result = await investmentQuoteSync.fetchDraftOptionQuote(
      request,
      isCurrent: () => !_controllerDisposed && _activeBookId == bookId,
    );
    if (_controllerDisposed || _activeBookId != bookId) {
      return const DraftOptionQuoteResult(DraftOptionQuoteStatus.cancelled);
    }
    return result;
  }
}
