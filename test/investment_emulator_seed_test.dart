/// 显式运行的模拟器验收数据准备；默认测试跳过，不接触设备或真实账目。
library;

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as paths;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/data/app_database.dart';
import 'package:verifin/data/ledger_repository.dart';
import 'package:verifin/local_storage/local_storage.dart';

/// 注册显式模拟器副本的双标的准备用例，无参数、无返回值。
///
/// 仅在设置 VERIFIN_EMULATOR_DB 时运行；路径必须指向 build/validation
/// 内已存在的数据库副本。兼容旧版转账入金基线和新版模板的期初现金，
/// 所有事件使用稳定 ID，重复运行不会重复入金或追加同一笔买卖。
void main() {
  final explicitPath = Platform.environment['VERIFIN_EMULATOR_DB'];
  test('在已备份的模拟器数据库副本中通过生产命令保留谷歌和博通验收数据', () async {
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
      const avgo = StockSecurity(
        symbol: 'AVGO',
        name: '博通',
        market: StockMarket.us,
        currencyCode: 'USD',
      );
      expect(
        await c.saveStockEvent(
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
        await c.saveStockEvent(
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
        await c.saveStockEvent(
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
        await c.saveStockEvent(
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
      expect(c.accountBalance(usd), 7756);
      expect(c.accountAssetValue(usd), 10396);
      final positions = c.investmentProjection(usd.id)!.positions;
      expect(positions, hasLength(2));
      expect(
        positions
            .singleWhere((p) => p.securityId == avgo.id)
            .quantity
            .toString(),
        '6',
      );
      expect(
        positions
            .singleWhere((p) => p.securityId == goog.id)
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
      await c.waitForPendingWrites();
    } finally {
      c.dispose();
      await db.close();
    }
  }, skip: explicitPath == null ? '仅显式指定模拟器副本路径时准备验收数据' : false);
}
