/// 投资草稿的稳定失败原因；界面将原因映射为本地化提示，不直接展示底层异常。
library;

enum InvestmentValidationIssue {
  accountUnavailable,
  beforeOpening,
  insufficientCash,
  positionExceeded,
  expiredContract,
  beforeExpiry,
  specificationRequired,
  settlementConfirmationRequired,
  unknownCost,
  underlyingSharesInsufficient,
  uncoveredAssignmentNotConfirmed,
  contractIdentityLocked,
  adjustedContract,
  feesExceedPremium,
  subsequentEventConflict,
  invalidInput,
}

/// 保持既有 FormatException 捕获边界，同时给预览提供不依赖中文文案的原因码。
class InvestmentValidationException extends FormatException {
  /// [issue] 为稳定业务原因，[message] 仅供开发排查；[eventId] 标识重放失败的事件。
  /// 事件标识只留在本次计算中，用于区分当前草稿和受它影响的后续记录，不写日志。
  const InvestmentValidationException(
    this.issue,
    String message, {
    this.eventId,
  }) : super(message);

  final InvestmentValidationIssue issue;
  final String? eventId;
}
