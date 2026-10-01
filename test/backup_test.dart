import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/backup/backup_service.dart';
import 'package:verifin/app/home_metrics.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/test_harness.dart';

void main() {
  useTestDatabases();

  test('恢复预览计算账户余额且不修改当前内存或冷启动数据', () async {
    final source = await makeController();
    final bookId = source.activeBook.id;
    source
      ..addAccount(
        Account(
          id: 'preview-account',
          bookId: bookId,
          name: '待恢复账户',
          type: AccountType.cash,
          groupId: null,
          initialBalance: 100,
          iconCode: 'wallet',
          note: '',
          includeInAssets: true,
          hidden: false,
        ),
      )
      ..addEntry(
        LedgerEntry(
          id: 'preview-entry',
          bookId: bookId,
          type: EntryType.expense,
          amount: 30,
          categoryId: source.categories
              .firstWhere((category) => category.type == EntryType.expense)
              .id,
          accountId: 'preview-account',
          note: '测试支出',
          occurredAt: DateTime(2026, 9, 28),
        ),
      );
    await source.waitForPendingWrites();
    final backup = source.exportDataJson();

    final targetStore = LocalKeyValueStore();
    final target = await makeController(targetStore);
    final beforeAccountIds = target.accounts
        .map((account) => account.id)
        .toList();
    final beforeEntryIds = target.entries.map((entry) => entry.id).toList();
    final preview = target.importDataJson(backup, dryRun: true);
    expect(preview.entryCount, 1);
    expect(preview.accountBalances, hasLength(1));
    expect(preview.accountBalances.single.balance, 70);
    expect(preview.missingAccountCount, 0);
    expect(preview.orphanRefundCount, 0);
    expect(target.accounts.map((account) => account.id), beforeAccountIds);
    expect(target.entries.map((entry) => entry.id), beforeEntryIds);
    await target.waitForPendingWrites();
    final reopened = await makeController(targetStore);
    expect(reopened.accounts, isEmpty);
    expect(reopened.entries, isEmpty);

    final legacyRoot = Map<String, dynamic>.from(jsonDecode(backup) as Map);
    final legacyData = Map<String, dynamic>.from(legacyRoot['data'] as Map);
    final legacyEntries = (legacyData['entries'] as List)
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
    legacyEntries.single['refundedBaseAmount'] = 20;
    legacyData['entries'] = legacyEntries;
    legacyRoot['data'] = legacyData;
    final legacyJson = jsonEncode(legacyRoot);
    final legacyPreview = reopened.importDataJson(legacyJson, dryRun: true);
    expect(legacyPreview.entryCount, 2);
    expect(legacyPreview.accountBalances.single.balance, 90);
    expect(legacyPreview.legacyRefundMigrationPossible, isTrue);
    reopened.importDataJson(legacyJson);
    expect(reopened.entries, hasLength(2));
    expect(reopened.accountBalance(reopened.accounts.single), 90);
  });

  test(
    'exports a zip archive backup and re-imports with attachment intact',
    () async {
      final source = await makeController();
      final account = Account(
        id: 'acc-1',
        bookId: source.activeBook.id,
        name: '现金账户',
        type: AccountType.cash,
        groupId: null,
        initialBalance: 0,
        iconCode: 'wallet',
        note: '',
        includeInAssets: true,
        hidden: false,
      );
      source
        ..addAccount(account)
        ..addEntry(
          LedgerEntry(
            id: 'entry-att',
            bookId: source.activeBook.id,
            type: EntryType.expense,
            amount: 20,
            categoryId: 'dining',
            accountId: account.id,
            note: '带票据的午餐',
            occurredAt: DateTime(2026, 7, 4, 12),
          ),
        );
      final dataUrl =
          'data:image/jpeg;base64,${base64Encode(List<int>.generate(2048, (i) => i % 256))}';
      source.addAttachment('entry-att', dataUrl);

      final prepared = await BackupService.prepare(
        json: source.exportDataJson(),
        passphrase: '',
        now: DateTime(2026, 7, 4, 9),
        auto: false,
      );
      final archiveBytes = prepared.bytes;
      // 备份产物应为 zip（PK 头），且体积小于内嵌 base64 的 JSON。
      expect(archiveBytes.sublist(0, 2), <int>[0x50, 0x4B]);
      expect(
        archiveBytes.length,
        lessThan(utf8.encode(source.exportDataJson()).length),
      );

      final target = await makeController();
      final decoded =
          BackupService.decodeBackupBytes(archiveBytes) as PlainBackupJson;
      target.importDataJson(decoded.json);

      expect(target.entries.single.note, '带票据的午餐');
      final restored = target.attachmentsForEntry('entry-att');
      expect(restored.single.dataUrl, dataUrl);

      source.dispose();
      target.dispose();
    },
  );

  test('decodeBackupBytes 也兼容旧版纯 JSON 备份字节', () async {
    final source = await makeController();
    source.addAccount(
      Account(
        id: 'acc-legacy',
        bookId: source.activeBook.id,
        name: '旧备份账户',
        type: AccountType.cash,
        groupId: null,
        initialBalance: 5,
        iconCode: 'wallet',
        note: '',
        includeInAssets: true,
        hidden: false,
      ),
    );
    final jsonBytes = utf8.encode(source.exportDataJson());

    final target = await makeController();
    final decoded =
        BackupService.decodeBackupBytes(jsonBytes) as PlainBackupJson;
    target.importDataJson(decoded.json);

    expect(target.accounts.single.name, '旧备份账户');
    source.dispose();
    target.dispose();
  });

  test('exports and imports a local data backup', () async {
    final source = await makeController();
    final account = Account(
      id: 'cash-test',
      bookId: source.activeBook.id,
      name: '现金账户',
      type: AccountType.cash,
      groupId: null,
      initialBalance: 100,
      iconCode: 'wallet',
      note: '测试账户',
      includeInAssets: true,
      hidden: false,
    );
    source
      ..addAccount(account)
      ..addEntry(
        LedgerEntry(
          id: 'entry-test',
          bookId: source.activeBook.id,
          type: EntryType.expense,
          amount: 45,
          categoryId: 'dining',
          accountId: account.id,
          note: '午餐',
          occurredAt: DateTime(2026, 7, 2, 12),
        ),
      )
      ..setMonthlyBudget(DateTime(2026, 7), 2400)
      ..setCategoryBudget(DateTime(2026, 7), 'dining', 600)
      ..setThemePreference(ThemePreference.dark)
      ..setHapticsEnabled(false)
      ..setDefaultAccountId('cash-test')
      ..setFabActionMode(FabActionMode.ai)
      ..setAmountForceTwoDecimals(true)
      ..setMoneyDisplayPreferences(
        unitStyle: MoneyUnitStyle.code,
        hideInSingleCurrency: false,
      )
      ..setAutoSuggestEnabled(false)
      ..setHomeTrendConfig(
        HomeTrendConfig.defaults.copyWith(
          title: '概览测试',
          series: HomeTrendSeries.income,
        ),
      )
      ..addCategory(type: EntryType.expense, label: '咖啡', iconCode: 'dining');
    final coffeeIndex = source
        .categoriesForType(EntryType.expense)
        .indexWhere((category) => category.label == '咖啡');
    source.reorderCategories(EntryType.expense, null, coffeeIndex, 0);

    final backup = source.exportDataJson();
    final target = await makeController();
    target.importDataJson(backup);

    expect(target.accounts.single.name, '现金账户');
    expect(target.entries.single.amount, 45);
    expect(target.entries.single.note, '午餐');
    expect(target.monthlyBudget(DateTime(2026, 7)), 2400);
    expect(target.categoryBudget(DateTime(2026, 7), 'dining'), 600);
    expect(target.themePreference, ThemePreference.dark);
    expect(target.hapticsEnabled, isFalse);
    // 设备偏好也随备份还原：默认账户、记一笔按钮行为、金额两位小数、自动识别开关、
    // 首页指标配置。
    expect(target.defaultAccountId, 'cash-test');
    expect(target.fabActionMode, FabActionMode.ai);
    expect(target.amountForceTwoDecimals, isTrue);
    expect(target.moneyUnitStyle, MoneyUnitStyle.code);
    expect(target.hideUnitInSingleCurrency, isFalse);
    expect(target.autoSuggestEnabled, isFalse);
    expect(target.homeTrendConfig.title, '概览测试');
    expect(target.homeTrendConfig.series, HomeTrendSeries.income);
    expect(target.categories.any((category) => category.label == '咖啡'), isTrue);
    expect(target.categoriesForType(EntryType.expense).first.label, '咖啡');

    expect(
      () => target.importDataJson(
        '{"data":{"ledgerBooks":[],"entries":[],"accounts":"bad"}}',
      ),
      throwsFormatException,
    );
    expect(target.entries.single.id, 'entry-test');
    expect(target.accounts.single.id, account.id);

    source.dispose();
    target.dispose();
  });

  test(
    'v2 backup round-trip preserves currencies, frozen amounts and rates',
    () async {
      final source = await makeController();
      final book = source.activeBook;
      final account = Account(
        id: 'usd-cash',
        bookId: book.id,
        name: '美元现金',
        type: AccountType.cash,
        groupId: null,
        initialBalance: 100,
        iconCode: 'wallet',
        note: '',
        includeInAssets: true,
        hidden: false,
        currencyCode: 'USD',
      );
      source
        ..addAccount(account)
        ..addEntry(
          LedgerEntry(
            id: 'usd-expense',
            bookId: book.id,
            type: EntryType.expense,
            amount: 10,
            currencyCode: 'USD',
            accountAmount: 10,
            baseAmount: 72,
            conversionSource: ConversionSource.imported,
            categoryId: 'dining',
            accountId: account.id,
            note: '外币午餐',
            occurredAt: DateTime(2026, 7, 2, 12),
          ),
        );
      expect(
        await source.saveExchangeRateDraft(
          currencyCode: 'USD',
          effectiveDate: DateTime(2026, 7, 1),
          rateToBase: 7.2,
          source: ExchangeRateSource.imported,
        ),
        isTrue,
      );

      final backup = source.exportDataJson();
      final root = jsonDecode(backup) as Map<String, dynamic>;
      expect(root['version'], 8);
      final data = root['data'] as Map<String, dynamic>;
      expect(data['exchangeRates'], hasLength(1));
      expect(data['currencyFractionStyle'], isNotNull);
      expect(data['moneyUnitStyle'], 'symbol');
      expect(data['hideUnitInSingleCurrency'], isTrue);

      final target = await makeController();
      target.importDataJson(backup);
      final restoredAccount = target.accounts.single;
      final restoredEntry = target.entries.single;
      expect(target.activeBook.baseCurrencyCode, book.baseCurrencyCode);
      expect(
        target.activeBook.currencySetupStatus,
        CurrencySetupStatus.confirmed,
      );
      expect(restoredAccount.currencyCode, 'USD');
      expect(restoredEntry.currencyCode, 'USD');
      expect(restoredEntry.accountAmount, 10);
      expect(restoredEntry.baseAmount, 72);
      expect(restoredEntry.conversionSource, ConversionSource.imported);
      expect(target.exchangeRates.single.currencyCode, 'USD');
      expect(target.exchangeRates.single.rateToBase, 7.2);
      expect(target.exchangeRates.single.source, ExchangeRateSource.imported);

      source.dispose();
      target.dispose();
    },
  );

  test(
    'v1 backup reinterprets missing currency fields as legacy CNY',
    () async {
      final controller = await makeController();
      controller.importDataJson(
        jsonEncode(<String, Object?>{
          'app': 'verifin',
          'version': 1,
          'data': <String, Object?>{
            'ledgerBooks': <Object?>[
              <String, Object?>{
                'id': 'default',
                'name': '旧账本',
                'createdAt': '2026-01-01T00:00:00.000',
                'isDefault': true,
              },
            ],
            'activeBookId': 'default',
            'accounts': <Object?>[
              <String, Object?>{
                'id': 'legacy-cash',
                'bookId': 'default',
                'name': '现金',
                'type': 'cash',
                'initialBalance': 88,
              },
            ],
            'entries': <Object?>[
              <String, Object?>{
                'id': 'legacy-entry',
                'bookId': 'default',
                'type': 'expense',
                'amount': 12.34,
                'categoryId': 'dining',
                'accountId': 'legacy-cash',
                'note': '',
                'occurredAt': '2026-01-02T12:00:00.000',
              },
            ],
          },
        }),
      );

      expect(controller.activeBook.baseCurrencyCode, 'CNY');
      expect(
        controller.activeBook.currencySetupStatus,
        CurrencySetupStatus.legacyUnconfirmed,
      );
      expect(controller.accounts.single.currencyCode, 'CNY');
      final entry = controller.entries.single;
      expect(entry.amount, 12.34);
      expect(entry.accountAmount, 12.34);
      expect(entry.baseAmount, 12.34);
      expect(entry.conversionSource, ConversionSource.legacy);
      expect(controller.exchangeRates, isEmpty);

      controller.dispose();
    },
  );

  test(
    'invalid v2 currency data is rejected before existing data changes',
    () async {
      final controller = await makeController();
      controller.addAccount(
        Account(
          id: 'keep-account',
          bookId: controller.activeBook.id,
          name: '保留账户',
          type: AccountType.cash,
          groupId: null,
          initialBalance: 30,
          iconCode: 'wallet',
          note: '',
          includeInAssets: true,
          hidden: false,
        ),
      );
      final root =
          jsonDecode(controller.exportDataJson()) as Map<String, dynamic>;
      final data = root['data'] as Map<String, dynamic>;
      final accounts = data['accounts'] as List<dynamic>;
      (accounts.single as Map<String, dynamic>)['currencyCode'] = 'ZZZ';

      expect(
        () => controller.importDataJson(jsonEncode(root)),
        throwsFormatException,
      );
      expect(controller.accounts.single.id, 'keep-account');
      expect(controller.accounts.single.currencyCode, 'CNY');

      controller.dispose();
    },
  );

  test('legacy backup without panel fields falls back to defaults', () async {
    final source = await makeController();
    final exported = source.exportDataJson();
    source.dispose();

    final legacyJson = jsonEncode(
      Map<String, Object?>.from(jsonDecode(exported) as Map<dynamic, dynamic>)
        ..update('data', (value) {
          return Map<String, Object?>.from(value as Map<dynamic, dynamic>)
            ..remove('homePanels')
            ..remove('reportPanels');
        }),
    );

    final target = await makeController();
    target.importDataJson(legacyJson);

    expect(
      target.enabledPanelIds(PanelPageKind.home).length,
      homePanelSpecs.length,
    );
    expect(
      target.enabledPanelIds(PanelPageKind.reports).length,
      reportPanelSpecs.length,
    );

    target.dispose();
  });

  test('v4 信用账户备份导入时自动补一对一信用主体', () async {
    final source = await makeController();
    expect(
      await source.addAccountDraft(
        Account(
          id: 'legacy-card',
          bookId: source.activeBook.id,
          name: '旧版招商卡',
          type: AccountType.creditCard,
          groupId: null,
          initialBalance: -300,
          iconCode: 'credit',
          note: '',
          includeInAssets: true,
          hidden: false,
          currencyCode: 'CNY',
          cardLast4: '4185',
          creditLimit: 20000,
          statementDay: 25,
          dueDay: 13,
        ),
      ),
      isTrue,
    );
    final root = jsonDecode(source.exportDataJson()) as Map<String, dynamic>;
    root['version'] = 4;
    final data = root['data'] as Map<String, dynamic>;
    data.remove('creditAccounts');
    for (final rawAccount in data['accounts'] as List<dynamic>) {
      (rawAccount as Map<String, dynamic>).remove('creditAccountId');
    }

    final target = await makeController();
    target.importDataJson(jsonEncode(root));
    final child = target.accounts.singleWhere(
      (account) => account.id == 'legacy-card',
    );
    final creditAccount = target.creditAccountForAccount(child);
    expect(creditAccount, isNotNull);
    expect(creditAccount!.id, 'credit-account-legacy-card');
    expect(creditAccount.creditLimit, 20000);
    expect(creditAccount.statementDay, 25);
    expect(creditAccount.dueDay, 13);

    source.dispose();
    target.dispose();
  });

  test('sample backup imports into controller', () async {
    final rawJson = File(
      'docs/dev/verifin-sample-backup.json',
    ).readAsStringSync();
    final controller = await makeController();

    controller.importDataJson(rawJson);

    expect(controller.accounts.length, greaterThanOrEqualTo(9));
    expect(controller.entries.length, greaterThanOrEqualTo(20));
    expect(controller.accountGroups.length, greaterThanOrEqualTo(4));
    expect(
      controller.categories.any((category) => category.id == 'coffee'),
      isTrue,
    );
    // 多级分类：样例中「咖啡」是「餐饮」的子分类，导入后 parentId 应保留。
    expect(
      controller.categories
          .firstWhere((category) => category.id == 'coffee')
          .parentId,
      'dining',
    );
    expect(
      controller.childCategories('dining').map((c) => c.id),
      contains('coffee'),
    );
    // 标签系统：样例含标签，且首条交易带 tagIds，导入后应保留。
    expect(controller.tags.map((t) => t.label), contains('工作餐'));
    expect(
      controller.entries.firstWhere((e) => e.id == 'entry_20260703_001').tagIds,
      contains('tag_work_meal'),
    );
    // 图片附件：样例首条交易带一张附件，导入后应能读回。
    expect(controller.attachmentCountForEntry('entry_20260703_001'), 1);
    // 周期记账：样例含每月房租规则，导入后应能读回。
    expect(controller.recurringRules.map((r) => r.note), contains('房租'));
    final usdAccount = controller.accounts.firstWhere(
      (account) => account.id == 'acc_usd_cash',
    );
    expect(usdAccount.currencyCode, 'USD');
    final usdExpense = controller.entries.firstWhere(
      (entry) => entry.id == 'entry_usd_expense_001',
    );
    expect(usdExpense.currencyCode, 'USD');
    expect(usdExpense.accountAmount, 10);
    expect(usdExpense.baseAmount, 72);
    expect(usdExpense.refundedBaseAmount, 14.4);
    final crossTransfer = controller.entries.firstWhere(
      (entry) => entry.id == 'entry_cross_transfer_001',
    );
    expect(crossTransfer.accountAmount, 720);
    expect(crossTransfer.toAccountAmount, 100);
    expect(controller.exchangeRates.single.currencyCode, 'USD');
    expect(controller.exchangeRates.single.rateToBase, 7.2);
    // 设备偏好：样例含默认账户、记一笔按钮行为、金额两位小数、自动识别开关、首页指标
    // 配置，导入后应读回。
    expect(controller.defaultAccountId, 'acc_alipay');
    expect(controller.fabActionMode, FabActionMode.manualTapAiLongPress);
    expect(controller.amountForceTwoDecimals, isTrue);
    expect(controller.autoSuggestEnabled, isFalse);
    expect(controller.homeTrendConfig.title, '本月概览');
    expect(controller.homeTrendConfig.series, HomeTrendSeries.net);
    // 转账手续费：样例转账带 fee，导入后应保留。
    expect(
      controller.entries.firstWhere((e) => e.id == 'entry_20260703_003').fee,
      2.0,
    );
    // 报销/退款：样例首条支出标记待报销并部分退款，净额应为 28.5 - 8.5 = 20。
    final reimbursed = controller.entries.firstWhere(
      (e) => e.id == 'entry_20260703_001',
    );
    expect(reimbursed.reimbursable, isTrue);
    expect(reimbursed.netAmount, 20.0);
    // 样例带一条关联退款条目（新格式：refundOf + settledAt），导入后应能读回。
    final sampleRefunds = controller.refundsForEntry('entry_20260703_001');
    expect(sampleRefunds.length, 1);
    expect(sampleRefunds.single.amount, 8.5);
    expect(sampleRefunds.single.settledAt, isNotNull);
    expect(
      controller.categoryBudget(DateTime(2026, 7), 'dining'),
      greaterThan(0),
    );
    // 默认预算（每月自动沿用）：样例带默认月预算与分类默认预算，导入后应读回。
    expect(controller.defaultMonthlyBudget, 6000);
    expect(controller.defaultCategoryBudget('dining'), 1100);
    // 未设单月覆盖的月份沿用默认月预算。
    expect(controller.monthlyBudget(DateTime(2026, 9)), 6000);
    expect(
      controller.isAssetSectionCollapsed(
        mode: AssetAccountViewMode.type,
        sectionId: AccountType.investment.name,
      ),
      isTrue,
    );
    expect(
      controller
          .sortedAssetSections<String>(
            mode: AssetAccountViewMode.type,
            sections: AccountType.values.map((type) => type.name).toList(),
            idOf: (section) => section,
          )
          .first,
      AccountType.onlinePayment.name,
    );
    expect(controller.profile.occupation, '产品设计师');
    final creditChildAccount = controller.accounts.firstWhere(
      (account) => account.id == 'acc_credit',
    );
    expect(creditChildAccount.cardLast4, '8321');
    // 信用卡账期：样例信用卡设了账单日/还款日，导入后应保留。
    expect(creditChildAccount.statementDay, 5);
    expect(creditChildAccount.dueDay, 25);
    final creditAccount = controller.creditAccountForAccount(
      creditChildAccount,
    );
    expect(creditAccount, isNotNull);
    expect(creditAccount!.name, '招商信用卡 8321');
    expect(creditAccount.institution, '招商银行');
    expect(creditAccount.cycleBudget, 4000);
    expect(
      controller.entries
          .singleWhere((entry) => entry.id == 'entry_20260702_001')
          .billingCycleId,
      '2026-07-05',
    );
    expect(
      controller.accountsForCreditAccount(creditAccount.id).single.id,
      creditChildAccount.id,
    );
    expect(controller.enabledPanelIds(PanelPageKind.home), <String>[
      'trend',
      'budget',
      'recent',
    ]);
    expect(controller.enabledPanelIds(PanelPageKind.reports), <String>[
      'category_ring',
      'budget_execution',
      'category_rank',
      'monthly_structure',
      // tag_stats 是样例备份没有的新面板，归一化时按默认开启追加到末尾。
      'tag_stats',
    ]);

    controller.dispose();
  });

  test('拒绝导入非本应用的合法 JSON，且不清空现有数据', () async {
    final controller = await makeController();
    controller.addAccount(
      Account(
        id: 'keep-me',
        bookId: controller.activeBook.id,
        name: '要保住的账户',
        type: AccountType.cash,
        groupId: null,
        initialBalance: 30,
        iconCode: 'wallet',
        note: '',
        includeInAssets: true,
        hidden: false,
      ),
    );

    // 合法 JSON 但不是本应用备份：应报错，且现有数据原封不动。
    expect(
      () => controller.importDataJson('{"foo":1,"bar":[2,3]}'),
      throwsFormatException,
    );
    expect(controller.accounts.single.name, '要保住的账户');

    // 带 app 标记但 data 为空对象也应被拦截（无任何已知键）。
    expect(
      () => controller.importDataJson('{"app":"other","data":{"x":1}}'),
      throwsFormatException,
    );
    expect(controller.accounts.single.name, '要保住的账户');

    controller.dispose();
  });

  test('imports legacy backup budget keys into the default book', () async {
    // 旧备份里预算键没有 bookId 前缀，导入时应归入默认账本。
    final controller = await makeController();
    controller.importDataJson(
      jsonEncode(<String, Object?>{
        'data': <String, Object?>{
          'monthlyBudgets': <String, Object?>{'2026-07': 3000},
          'categoryBudgets': <String, Object?>{'2026-07:dining': 450},
        },
      }),
    );

    expect(controller.monthlyBudget(DateTime(2026, 7)), 3000);
    expect(controller.categoryBudget(DateTime(2026, 7), 'dining'), 450);
    controller.dispose();
  });
}
