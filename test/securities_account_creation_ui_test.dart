import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'package:verifin/pages/assets_pages.dart';

import 'support/in_memory_ledger_repository.dart';
import 'support/test_harness.dart';

/// 将最终开户事务暂挂，模拟设备慢磁盘；启动和普通读取仍使用真实的内存契约。
class _DelayedSecuritiesRepository extends InMemoryLedgerRepository {
  final Completer<void> release = Completer<void>();
  int creationCalls = 0;

  /// 记录提交次数并等待测试释放；释放前不改变账户、主体或组合。
  @override
  Future<void> saveSecuritiesAccountAggregate({
    required List<CreditAccount> creditAccounts,
    required List<Account> accounts,
    required List<InvestmentPortfolio> investmentPortfolios,
  }) async {
    creationCalls++;
    await release.future;
    await super.saveSecuritiesAccountAggregate(
      creditAccounts: creditAccounts,
      accounts: accounts,
      investmentPortfolios: investmentPortfolios,
    );
  }
}

/// 在可返回的真实路由中打开证券表单；[controller] 提供目标账本，
/// 测试不经首页分流，专门验证开户表单、系统返回和最终持久化行为。
Future<void> _openSecuritiesForm(
  WidgetTester tester,
  VeriFinController controller,
) async {
  await tester.pumpWidget(
    VeriFinScope(
      controller: controller,
      child: zhMaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () {
                unawaited(
                  Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => AddAccountPage(
                        securities: true,
                        bookId: controller.activeBook.id,
                      ),
                    ),
                  ),
                );
              },
              child: const Text('打开证券开户'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开证券开户'));
  await tester.pumpAndSettle();
}

void main() {
  useTestDatabases();

  testWidgets('慢磁盘保存时系统返回不允许丢弃，输入锁定且最终只创建一份聚合', (tester) async {
    final repo = _DelayedSecuritiesRepository();
    final c = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: repo,
    );
    addTearDown(c.dispose);
    addTearDown(() {
      if (!repo.release.isCompleted) repo.release.complete();
    });
    await _openSecuritiesForm(tester, c);
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.first, '延迟开户证券账户');
    await tester.enterText(fields.at(1), '123.45');
    final nameController = tester
        .widget<TextFormField>(fields.first)
        .controller!;
    final cashController = tester
        .widget<TextFormField>(fields.at(1))
        .controller!;
    expect(tester.testTextInput.hasAnyClients, isTrue);

    await tester.tap(find.byTooltip('保存'));
    await tester.pump();
    await tester.pump();
    expect(repo.creationCalls, 1);
    expect(c.accounts, isEmpty);
    expect(await repo.loadAccounts(), isEmpty);
    expect(await repo.loadInvestmentPortfolios(), isEmpty);

    // 忙时除了不能点字段，还要断开保存前仍聚焦的输入客户端，防止软键盘继续改值。
    expect(tester.testTextInput.hasAnyClients, isFalse);
    await tester.tap(fields.first, warnIfMissed: false);
    await tester.pump();
    expect(tester.testTextInput.hasAnyClients, isFalse);
    expect(nameController.text, '延迟开户证券账户');
    expect(cashController.text, '123.45');

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('保存修改？'), findsNothing);
    expect(find.text('不保存'), findsNothing);
    expect(find.byType(AddAccountPage), findsOneWidget);
    await tester.tap(find.byTooltip('保存'), warnIfMissed: false);
    await tester.pump();
    expect(repo.creationCalls, 1);

    repo.release.complete();
    await tester.pumpAndSettle();
    expect(find.byType(AddAccountPage), findsNothing);
    expect(find.text('打开证券开户'), findsOneWidget);
    expect(c.accounts, hasLength(1));
    final saved = c.accounts.single;
    expect(saved.name, '延迟开户证券账户');
    expect(saved.initialBalance, 0);
    expect(c.accountBalance(saved), 123.45);
    expect(c.investmentFor(saved.id)!.openingCash, '123.45');
    expect(await repo.loadAccounts(), hasLength(1));
    expect(await repo.loadCreditAccounts(), hasLength(1));
    expect(await repo.loadInvestmentPortfolios(), hasLength(1));
    expect(c.entries, isEmpty);
    expect(repo.creationCalls, 1);
  });

  testWidgets('证券期初现金留空不能保存，显式填写零后才允许零现金开户', (tester) async {
    final repo = InMemoryLedgerRepository();
    final c = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: repo,
    );
    addTearDown(c.dispose);
    await _openSecuritiesForm(tester, c);
    await tester.enterText(find.byType(TextFormField).first, '明确零现金账户');
    // 名称输入使保存按钮从禁用变为可用，等真实下一帧再点击。
    await tester.pump();
    await tester.tap(find.byTooltip('保存'));
    await tester.pumpAndSettle();
    expect(find.text('请填写不小于 0 的期初现金'), findsOneWidget);
    expect(find.byType(AddAccountPage), findsOneWidget);
    expect(await repo.loadAccounts(), isEmpty);
    expect(await repo.loadCreditAccounts(), isEmpty);
    expect(await repo.loadInvestmentPortfolios(), isEmpty);

    await tester.enterText(find.byType(TextFormField).at(1), '0');
    await tester.tap(find.byTooltip('保存'));
    await tester.pumpAndSettle();
    expect(find.byType(AddAccountPage), findsNothing);
    expect(c.accounts, hasLength(1));
    final saved = c.accounts.single;
    expect(c.accountBalance(saved), 0);
    expect(c.investmentFor(saved.id)!.openingCash, '0');
    expect(await repo.loadInvestmentPortfolios(), hasLength(1));
    expect(c.entries, isEmpty);
  });

  testWidgets('填好证券资料后明确不保存，账户主体和期初组合均不落库', (tester) async {
    final repo = InMemoryLedgerRepository();
    final c = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: repo,
    );
    addTearDown(c.dispose);
    await _openSecuritiesForm(tester, c);
    await tester.enterText(find.byType(TextFormField).first, '取消的证券账户');
    await tester.enterText(find.byType(TextFormField).at(1), '0');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('保存修改？'), findsOneWidget);
    await tester.tap(find.text('不保存'));
    await tester.pumpAndSettle();
    expect(find.byType(AddAccountPage), findsNothing);
    expect(c.accounts, isEmpty);
    expect(c.accountParents, isEmpty);
    expect(await repo.loadAccounts(), isEmpty);
    expect(await repo.loadCreditAccounts(), isEmpty);
    expect(await repo.loadInvestmentPortfolios(), isEmpty);
    expect(await repo.loadEntries(), isEmpty);
  });
}
