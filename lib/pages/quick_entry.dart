import 'package:flutter/material.dart';

import '../app/feedback.dart';
import '../app/models.dart';
import '../app/veri_fin_scope.dart';
import '../l10n/app_localizations.dart';
import 'ai_entry_sheet.dart';
import 'entry_detail_page.dart';
import 'securities_account_creation.dart';
import 'sheets.dart';
import 'transaction_entry_page.dart';

/// 首页、交易列表及 Android 通用快捷入口共享的新增流程。
/// [longPress] 保留用户选择的“点击手动、长按 AI”语义，手动动作再按账本类型分流。
Future<void> startQuickEntry({
  required BuildContext context,
  bool longPress = false,
}) async {
  final controller = VeriFinScope.of(context);
  final useAi = switch (controller.fabActionMode) {
    FabActionMode.manual => false,
    FabActionMode.ai => true,
    FabActionMode.manualTapAiLongPress => longPress,
  };
  if (useAi) {
    await startAiEntry(context);
    return;
  }
  final book = controller.activeBook;
  if (book.bookType == LedgerBookType.investment) {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => TransactionEntryPage(
          bookId: book.id,
          onCreateSecuritiesAccount: (entryContext) =>
              createSecuritiesAccount(context: entryContext, bookId: book.id),
        ),
      ),
    );
    return;
  }
  final defaultAccount = controller.accounts
      .where((value) => value.id == controller.defaultAccountId)
      .firstOrNull;
  final amount = await showNumberPadSheet(
    context,
    title: AppLocalizations.of(context).quickEntry,
    showTitle: false,
    currencyCode: defaultAccount?.currencyCode ?? book.baseCurrencyCode,
  );
  if (!context.mounted || amount == null || amount <= 0) return;
  if (controller.activeBook.id != book.id) {
    await VeriFeedbackHost.of(context).showMessage(
      message: AppLocalizations.of(context).entryBookUnavailable,
      tone: VeriFeedbackTone.warning,
    );
    return;
  }
  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => EntryDetailPage(
        initialAmount: amount,
        initialAccountId: controller.defaultAccountId,
      ),
    ),
  );
}
