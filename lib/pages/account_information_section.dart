/// 证券详情复用的账户资料与普通资金流水；不复制投资现金腿或资料保存逻辑。
library;

import 'package:flutter/material.dart';

import '../app/common_widgets.dart';
import '../app/ledger_math.dart';
import '../app/models.dart';
import '../app/reminder/account_entry_reminder.dart';
import '../app/veri_fin_scope.dart';
import '../l10n/app_localizations.dart';
import 'account_detail_page.dart';
import 'account_entry_reminder_page.dart';
import 'entry_detail_page.dart';
import 'sheets.dart';
import 'transactions_pages.dart';

/// 账户基本信息只读卡，编辑时复用通用账户页面中的同一份资料表单。
class AccountInformationSection extends StatelessWidget {
  /// [account] 是真实币种账户；分组、主账户和偏好从当前 Controller 只读获取。
  const AccountInformationSection({super.key, required this.account});

  final Account account;

  /// 展示持久化资料，不让查看资料改变账户默认值、持仓或行情授权。
  @override
  Widget build(BuildContext context) {
    final controller = VeriFinScope.of(context);
    final l = AppLocalizations.of(context);
    final parent = controller.parentForAccount(account);
    final group = controller.accountGroups
        .where((candidate) => candidate.id == account.groupId)
        .firstOrNull;
    // 将已保存的布尔状态转为当前语言文字；这里只展示，不改变账户偏好。
    String state(bool value) =>
        value ? l.accountPropertyYes : l.accountPropertyNo;
    return VeriCard(
      key: const Key('investment-account-information'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: SectionTitle(title: l.accountSectionBasic)),
              TextButton.icon(
                key: const Key('investment-edit-account-information'),
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        AccountDetailPage(account: account, editingOnly: true),
                  ),
                ),
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: Text(l.accountEditInformation),
              ),
            ],
          ),
          DetailInfoRow(inline: true, label: l.commonName, value: account.name),
          DetailInfoRow(
            inline: true,
            label: l.commonType,
            value: account.type.label(l),
          ),
          DetailInfoRow(
            inline: true,
            label: l.commonCurrency,
            value: account.currencyCode,
          ),
          if (parent != null)
            DetailInfoRow(
              inline: true,
              label: l.accountParentLabel,
              value: parent.name,
            ),
          DetailInfoRow(
            inline: true,
            label: l.commonGroup,
            value: group?.name ?? l.assetsUngrouped,
          ),
          DetailInfoRow(
            inline: true,
            label: l.commonNote,
            value: account.note.isEmpty ? l.commonNoneShort : account.note,
          ),
          const Divider(),
          DetailInfoRow(
            inline: true,
            label: l.includeInAssets,
            value: state(account.includeInAssets),
          ),
          DetailInfoRow(
            inline: true,
            label: l.accountHide,
            value: state(account.hidden),
          ),
          DetailInfoRow(
            inline: true,
            label: l.setAsDefaultAccount,
            value: state(controller.defaultAccountId == account.id),
          ),
          ValueListenableBuilder<List<AccountEntryReminder>>(
            valueListenable: controller.accountEntryRemindersListenable,
            builder: (context, reminders, _) => SettingsRow(
              icon: Icons.notifications_active_outlined,
              title: l.accountEntryReminderTitle,
              trailing:
                  reminders.any(
                    (rule) => rule.accountId == account.id && rule.enabled,
                  )
                  ? l.accountEntryReminderOn
                  : l.accountEntryReminderOff,
              trailingIcon: Icons.chevron_right,
              onTap: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => AccountEntryReminderPage(account: account),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 显示真实普通资金流水，证券买卖、期权和基金资金腿仍留在独立投资聚合。
class AccountFundingSection extends StatelessWidget {
  /// [account] 决定唯一账户范围，不能传入父账户代替实际币种账户。
  const AccountFundingSection({super.key, required this.account});

  final Account account;

  /// 从账户资金区新增普通记账，明确账户上下文优先于账本的通用新增模式。
  /// 金额键盘只收集草稿，取消和关闭不会生成任何普通或投资记录。
  Future<void> _addFundingEntry(BuildContext context) async {
    final amount = await showNumberPadSheet(
      context,
      title: AppLocalizations.of(context).quickEntry,
      currencyCode: account.currencyCode,
    );
    if (!context.mounted || amount == null || amount <= 0) return;
    final controller = VeriFinScope.of(context);
    if (!controller.accounts.any((candidate) => candidate.id == account.id)) {
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => EntryDetailPage(
          initialAmount: amount,
          initialAccountId: account.id,
        ),
      ),
    );
  }

  /// 读取同账户去重时间线，最多预览三条，完整列表沿用现有普通交易页面。
  @override
  Widget build(BuildContext context) {
    final controller = VeriFinScope.of(context);
    final l = AppLocalizations.of(context);
    final entries = accountTimelineEntries(controller.entries, account.id);
    return VeriCard(
      key: const Key('investment-account-funding'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: SectionTitle(title: l.accountFundingEntries)),
              VeriSectionAction(
                icon: Icons.add,
                tooltip: l.addEntryTooltip,
                onPressed: () => _addFundingEntry(context),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (entries.isEmpty)
            EmptyState(
              icon: Icons.receipt_long_outlined,
              title: l.noEntriesTitle,
              description: l.accountNoEntriesDesc,
            )
          else
            for (final entry in entries.take(3))
              TransactionTile(
                entry,
                accounts: controller.accounts,
                categories: controller.categories,
                tags: controller.tags,
                showDate: true,
                baseCurrencyCode: controller.activeBook.baseCurrencyCode,
                onTap: () => openEntryDetail(context, entry),
              ),
          TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => TransactionsPage(
                  accountId: account.id,
                  title: l.accountEntriesTitle(account.name),
                ),
              ),
            ),
            child: Text(l.allEntries),
          ),
        ],
      ),
    );
  }
}
