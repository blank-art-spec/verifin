/// 显式运行的模拟器验收数据准备；默认测试跳过，不接触设备或真实账目。
library;

import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as paths;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:verifin/app/investments/investment_valuation.dart';
import 'package:verifin/app/investments/stock_cash_math.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/data/app_database.dart';
import 'package:verifin/data/ledger_repository.dart';
import 'package:verifin/local_storage/local_storage.dart';

/// 注册显式模拟器副本的三地证券准备用例，无参数、无返回值。
///
/// 仅在设置 VERIFIN_EMULATOR_DB 时运行；路径必须指向 build/validation
/// 内已存在的数据库副本。兼容旧版转账入金基线和新版模板的期初现金，
/// 所有事件使用稳定 ID，重复运行不会重复入金或追加同一笔买卖；港股、A 股
/// 从可导入模板读取，并仅补入未使用的模板账户，不替换设备中的其他账目。
void main() {
  final explicitPath = Platform.environment['VERIFIN_EMULATOR_DB'];
  test('在已备份的模拟器数据库副本中通过生产命令准备三地证券示例', () async {
    final path = paths.normalize(paths.absolute(explicitPath!));
    final allowed = paths.join(Directory.current.path, 'build', 'validation');
    if (!paths.isWithin(allowed, path) || !File(path).existsSync()) {
      throw const FormatException('只允许修改 build/validation 内已存在的模拟器数据库副本');
    }
    sqfliteFfiInit();
    final db = await AppDatabase.open(factory: databaseFactoryFfi, path: path);
    final store = LocalKeyValueStore()
      ..write('verifin.active_book.v1', 'book_investment');
    final c = await VeriFinController.create(
      store,
      repository: SqliteLedgerRepository(db),
    );
    try {
      expect(c.activeBook.id, 'book_investment');
      final usd = c.accounts.singleWhere((a) => a.id == 'acc_investment_usd');
      // 新模板已在证券聚合中记录 10,000 USD 期初现金，不再额外转入一笔。
      // 旧模拟器仍沿用零期初加银行转账，保留其原有资金来源和交易 ID。
      final needsDeposit = c.investmentFor(usd.id)?.openingCash != '10000';
      // 汇率也是明确标识的验收输入，只在该测试账本尚无相应汇率时补充。
      for (final rate in {'USD': 7.0, 'HKD': 0.9}.entries) {
        if (!c.exchangeRates.any((r) => r.currencyCode == rate.key)) {
          expect(
            await c.saveExchangeRateDraft(
              id: 'test_avgo_rate_${rate.key}',
              currencyCode: rate.key,
              effectiveDate: DateTime(2026, 10, 1),
              rateToBase: rate.value,
            ),
            isTrue,
          );
        }
      }
      const bankId = 'test_avgo_bank_usd';
      if (needsDeposit && !c.accounts.any((a) => a.id == bankId)) {
        c.addAccount(
          Account(
            id: bankId,
            bookId: usd.bookId,
            name: '博通验收入金.USD',
            type: AccountType.cash,
            groupId: null,
            initialBalance: 10000,
            iconCode: 'cash',
            note: '验收示例：虚构资金，不是实际银行余额',
            includeInAssets: true,
            hidden: false,
            currencyCode: 'USD',
          ),
        );
        await c.waitForPendingWrites();
      }
      if (c.investmentFor(usd.id) == null) {
        expect(
          await c.enableInvestment(
            accountId: usd.id,
            openingCash: '0',
            openedAt: DateTime(2026, 10, 1),
          ),
          isTrue,
        );
      }
      if (needsDeposit && !c.entries.any((e) => e.id == 'test_avgo_deposit')) {
        c.addEntry(
          LedgerEntry(
            id: 'test_avgo_deposit',
            bookId: usd.bookId,
            type: EntryType.transfer,
            amount: 10000,
            currencyCode: 'USD',
            accountAmount: 10000,
            toAccountAmount: 10000,
            baseAmount: 0,
            categoryId: c.categories
                .firstWhere((v) => v.type == EntryType.transfer)
                .id,
            accountId: bankId,
            toAccountId: usd.id,
            note: '验收示例：博通测试入金，不计日常收入',
            occurredAt: DateTime(2026, 10, 2, 10),
          ),
        );
        await c.waitForPendingWrites();
      }
      // 已有完整双标的时不重写 USD 聚合，保留设备上的原成交及其备注。
      final usdEventIds = c
          .investmentFor(usd.id)!
          .events
          .map((event) => event.id)
          .toSet();
      if (!usdEventIds.containsAll(const {
        'test_avgo_buy',
        'test_avgo_sell',
        'test_goog_buy',
        'test_goog_sell',
      })) {
        const avgo = StockSecurity(
          symbol: 'AVGO',
          name: '博通',
          market: StockMarket.us,
          currencyCode: 'USD',
        );
        expect(
          await _saveMissingUsdEvent(
            c,
            accountId: usd.id,
            security: avgo,
            event: StockEvent(
              id: 'test_avgo_buy',
              securityId: avgo.id,
              kind: StockEventKind.buy,
              occurredAt: DateTime(2026, 10, 3, 10),
              sequence: 1,
              quantity: '10',
              price: '300',
              fee: '1',
              note: '验收示例：固定测试价格，不是博通历史成交或现价',
            ),
            referencePrice: '330',
          ),
          isTrue,
        );
        expect(
          await _saveMissingUsdEvent(
            c,
            accountId: usd.id,
            security: avgo,
            event: StockEvent(
              id: 'test_avgo_sell',
              securityId: avgo.id,
              kind: StockEventKind.sell,
              occurredAt: DateTime(2026, 10, 4, 10),
              sequence: 2,
              quantity: '4',
              price: '330',
              fee: '1',
              note: '验收示例：部分卖出，保留六股用于查看估值',
            ),
            referencePrice: '330',
          ),
          isTrue,
        );
        // GOOG 与 AVGO 共用同一个真实 USD 子账户，不新建证券专属账户。
        // 金额固定为验收输入；GOOG 是本用例的代码，不与 GOOGL 混用。
        const goog = StockSecurity(
          symbol: 'GOOG',
          name: '谷歌',
          market: StockMarket.us,
          currencyCode: 'USD',
        );
        expect(
          await _saveMissingUsdEvent(
            c,
            accountId: usd.id,
            security: goog,
            event: StockEvent(
              id: 'test_goog_buy',
              securityId: goog.id,
              kind: StockEventKind.buy,
              occurredAt: DateTime(2026, 10, 5, 10),
              sequence: 3,
              quantity: '10',
              price: '100',
              fee: '1',
              note: '验收示例：谷歌 GOOG 固定测试买价，不是 GOOGL 或真实成交',
            ),
            referencePrice: '110',
          ),
          isTrue,
        );
        expect(
          await _saveMissingUsdEvent(
            c,
            accountId: usd.id,
            security: goog,
            event: StockEvent(
              id: 'test_goog_sell',
              securityId: goog.id,
              kind: StockEventKind.sell,
              occurredAt: DateTime(2026, 10, 6, 10),
              sequence: 4,
              quantity: '4',
              price: '110',
              fee: '1',
              note: '验收示例：谷歌固定测试卖价，部分卖出后保留六股',
            ),
            referencePrice: '110',
          ),
          isTrue,
        );
      }
      expect(c.accountBalance(usd), 7756);
      expect(c.accountAssetValue(usd), 10396);
      final positions = c.investmentProjection(usd.id)!.positions;
      expect(positions, hasLength(2));
      expect(
        positions
            .singleWhere((p) => p.securityId == 'us:stock:AVGO')
            .quantity
            .toString(),
        '6',
      );
      expect(
        positions
            .singleWhere((p) => p.securityId == 'us:stock:GOOG')
            .quantity
            .toString(),
        '6',
      );
      expect(
        c.accounts
            .singleWhere((a) => a.id == 'acc_investment_cny')
            .initialBalance,
        0,
      );
      expect(
        c.accounts
            .singleWhere((a) => a.id == 'acc_investment_hkd')
            .initialBalance,
        0,
      );
      await _ensureAdditionalMarketExamples(c);
      await c.waitForPendingWrites();
    } finally {
      c.dispose();
      await db.close();
    }
  }, skip: explicitPath == null ? '仅显式指定模拟器副本路径时准备验收数据' : false);
}

/// 仅补齐旧 USD 基线缺失的股票事件，不重写已有事件或参考价。
///
/// [controller] 是当前数据库副本的控制器；[accountId] 指 USD 模板账户；
/// [security]、[event] 和 [referencePrice] 为历史固定示例输入。若已有同 ID
/// 事件或证券被编辑，校验失败即停止副本准备；完全一致则直接返回 true。
/// 返回值沿用生产保存命令的成功语义，不连接设备、不写其他账户。
Future<bool> _saveMissingUsdEvent(
  VeriFinController controller, {
  required String accountId,
  required StockSecurity security,
  required StockEvent event,
  required String referencePrice,
}) async {
  final portfolio = controller.investmentFor(accountId)!;
  final savedSecurity = portfolio.securities
      .where((value) => value.id == security.id)
      .firstOrNull;
  if (savedSecurity != null) {
    expect(
      savedSecurity.toJson(),
      security.toJson(),
      reason: '已有 USD 证券定义不能被示例覆盖',
    );
  }
  if (portfolio.manualPrices.containsKey(security.id)) {
    expect(
      portfolio.manualPrices[security.id],
      referencePrice,
      reason: '已有 USD 手填参考价不能被示例覆盖',
    );
  }
  final savedEvent = portfolio.events
      .where((value) => value.id == event.id)
      .firstOrNull;
  if (savedEvent != null) {
    expect(savedEvent.toJson(), event.toJson(), reason: '已有 USD 示例事件不能被重写');
    return true;
  }
  return controller.saveStockEvent(
    accountId: accountId,
    security: security,
    event: event,
    referencePrice: referencePrice,
  );
}

/// 将模板中的港股和 A 股示例补入已备份的模拟器数据库副本。
///
/// [controller] 必须已选择投资账本，且币种子账户已存在。只使用生产启用、股票
/// 和期权命令写入，因此每步都会经过正式账务校验；失败会让外层用例停止，调用方
/// 不应把未通过的副本写回设备。方法不连接设备，也不导入整份备份。
///
/// 首次启用前要求账户现金为零、没有普通交易或现金锚点，避免把用户已有资金解释
/// 为模板期初。重复执行仅接受相同期初和已有的同 ID 示例事件，遇到不同内容立即
/// 拒绝，不覆盖用户编辑；其他证券、账户和账本保持原样。
Future<void> _ensureAdditionalMarketExamples(
  VeriFinController controller,
) async {
  final root =
      jsonDecode(File('docs/dev/verifin-sample-backup.json').readAsStringSync())
          as Map<String, dynamic>;
  final data = root['data'] as Map<String, dynamic>;
  final templates = (data['investmentPortfolios'] as List)
      .map(
        (value) => InvestmentPortfolio.fromJson(
          Map<String, Object?>.from(value as Map),
        ),
      )
      .where(
        (value) => const {
          'acc_investment_cny',
          'acc_investment_hkd',
        }.contains(value.accountId),
      );
  expect(templates, hasLength(2));
  for (final template in templates) {
    final account = controller.accounts.singleWhere(
      (value) => value.id == template.accountId,
    );
    expect(account.bookId, template.bookId);
    expect(account.currencyCode, template.currencyCode);
    final original = controller.investmentFor(account.id);
    if (original == null) {
      expect(controller.accountBalance(account), 0, reason: '已有现金不能被测试期初覆盖');
      expect(
        controller.latestBalanceAnchor(account.id),
        isNull,
        reason: '已有现金核对不能被测试期初覆盖',
      );
      expect(
        controller.entries.where(
          (entry) =>
              entry.accountId == account.id || entry.toAccountId == account.id,
        ),
        isEmpty,
        reason: '已有普通交易的账户不能直接补入模板期初',
      );
      expect(
        await controller.enableInvestment(
          accountId: account.id,
          openingCash: template.openingCash,
          openedAt: template.openedAt,
        ),
        isTrue,
      );
    } else {
      expect(
        original.openingCash,
        template.openingCash,
        reason: '已有证券期初必须与模板一致',
      );
      expect(original.openedAt, template.openedAt);
      for (final security in template.securities) {
        final saved = original.securities
            .where((value) => value.id == security.id)
            .firstOrNull;
        if (saved != null) {
          expect(
            saved.toJson(),
            security.toJson(),
            reason: '已有证券名称和合约规格不能被模板覆盖',
          );
        }
        if (original.manualPrices.containsKey(security.id)) {
          expect(
            original.manualPrices[security.id],
            template.manualPrices[security.id],
            reason: '已有手填参考价不能被模板覆盖',
          );
        }
      }
    }
    for (final event in template.events) {
      final saved = controller
          .investmentFor(account.id)!
          .events
          .where((value) => value.id == event.id)
          .firstOrNull;
      if (saved != null) {
        expect(
          saved.toJson(),
          event.toJson(),
          reason: '同 ID 示例已被编辑时应停止，不覆盖用户内容',
        );
        continue;
      }
      final security = template.securities.singleWhere(
        (value) => value.id == event.securityId,
      );
      final option = security.option;
      final success = option == null
          ? await controller.saveStockEvent(
              accountId: account.id,
              security: security,
              event: event,
              referencePrice: template.manualPrices[security.id],
            )
          : await controller.saveOptionEvent(
              accountId: account.id,
              security: security,
              underlying: template.securities.singleWhere(
                (value) => value.id == option.underlyingId,
              ),
              event: event,
              referencePrice: template.manualPrices[security.id]!,
              underlyingReferencePrice:
                  template.manualPrices[option.underlyingId],
            );
      expect(success, isTrue, reason: '模板事件 ${event.id} 必须经过生产命令校验');
    }
    // 使用模板自身的投影核对实际保存结果；不额外复制一套量价或期权乘数常量。
    final expected = valueInvestmentAccount(
      template,
      investmentCashBalance(portfolio: template, entries: const []),
    );
    final actual = valueInvestmentAccount(
      controller.investmentFor(account.id)!,
      controller.accountBalance(account),
    );
    expect(actual.cash, expected.cash);
    expect(actual.longValue, expected.longValue);
    expect(actual.shortObligation, expected.shortObligation);
    expect(actual.frozen, expected.frozen);
    expect(actual.realized, expected.realized);
    expect(actual.unrealized, expected.unrealized);
  }
}
