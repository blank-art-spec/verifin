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

void main() {
  final explicitPath = Platform.environment['VERIFIN_EMULATOR_DB'];
  test('在已备份的模拟器数据库副本中通过生产命令保留博通验收数据', () async {
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
      if (!c.accounts.any((a) => a.id == bankId)) {
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
      if (!c.entries.any((e) => e.id == 'test_avgo_deposit')) {
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
      expect(c.accountBalance(usd), 8318);
      expect(c.accountAssetValue(usd), 10298);
      expect(
        c.investmentProjection(usd.id)!.positions.single.quantity.toString(),
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
