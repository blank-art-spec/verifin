import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/data/app_database.dart';
import 'package:verifin/data/ledger_repository.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'package:verifin/pages/ledger_books_page.dart';

import 'support/in_memory_ledger_repository.dart';
import 'support/test_harness.dart';

/// 注入账本保存失败，验证失败前后内存和仓储都保留原状态。
class _FailingBooksRepository extends InMemoryLedgerRepository {
  bool failBooks = false;

  /// 仅在当前用例开启 [failBooks] 时拒绝保存，不改动仓储原有账本。
  @override
  Future<void> saveBooks(List<LedgerBook> books) async {
    if (failBooks) throw StateError('账本保存失败测试');
    await super.saveBooks(books);
  }
}

/// 独立注入设备当前账本指针失败，区分账本已创建与切换失败。
class _FailingActiveBookStore extends LocalKeyValueStore {
  bool failActiveBook = false;

  /// 只阻止当前账本指针的显式保存，其他启动偏好按内存实现正常写入。
  @override
  Future<void> writeAndFlush(String key, String value) async {
    if (failActiveBook && key == 'verifin.active_book.v1') {
      throw StateError('当前账本指针失败测试');
    }
    await super.writeAndFlush(key, value);
  }
}

void main() {
  useTestDatabases();
  setUpAll(sqfliteFfiInit);

  test('账本类型 JSON 缺字段默认普通，显式非法值拒绝，不根据名称推断', () {
    final legacy = <String, Object?>{
      'id': 'legacy-investment',
      'name': '投资账本',
      'createdAt': '2026-10-01T00:00:00.000',
      'isDefault': false,
    };
    final book = LedgerBook.fromJson(legacy);
    expect(book.bookType, LedgerBookType.normal);
    final investment = book.copyWith(bookType: LedgerBookType.investment);
    expect(investment.copyWith(name: '改名').bookType, LedgerBookType.investment);
    expect(
      LedgerBook.fromJson(investment.toJson()).bookType,
      LedgerBookType.investment,
    );
    expect(
      () => LedgerBook.fromJson({...legacy, 'bookType': 'future'}),
      throwsFormatException,
    );
    expect(
      () => LedgerBook.fromJson({...legacy, 'bookType': null}),
      throwsFormatException,
    );
  });

  test('创建和修改类型等待落库，重建 Controller 后保留', () async {
    final db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    final repo = SqliteLedgerRepository(db);
    final store = LocalKeyValueStore();
    var controller = await VeriFinController.create(store, repository: repo);
    try {
      expect(controller.activeBook.bookType, LedgerBookType.normal);
      expect(
        await controller.createLedgerBook(
          '投资',
          bookType: LedgerBookType.investment,
        ),
        isTrue,
      );
      final createdId = controller.activeBook.id;
      expect(controller.activeBook.bookType, LedgerBookType.investment);
      controller.dispose();
      controller = await VeriFinController.create(store, repository: repo);
      expect(controller.activeBook.id, createdId);
      expect(controller.activeBook.bookType, LedgerBookType.investment);
      final before =
          (jsonDecode(controller.exportDataJson()) as Map)['data'] as Map;
      expect(
        await controller.changeLedgerBookType(createdId, LedgerBookType.normal),
        isTrue,
      );
      final after =
          (jsonDecode(controller.exportDataJson()) as Map)['data'] as Map;
      expect(
        {...after}..remove('ledgerBooks'),
        {...before}..remove('ledgerBooks'),
      );
      expect(
        (await repo.loadBooks())
            .singleWhere((book) => book.id == createdId)
            .bookType,
        LedgerBookType.normal,
      );
    } finally {
      controller.dispose();
      await db.close();
    }
  });

  test('创建或更改类型失败保留数据库与内存，后续重试仍能成功', () async {
    final repo = _FailingBooksRepository();
    final c = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: repo,
    );
    addTearDown(c.dispose);
    final originalId = c.activeBook.id;
    repo.failBooks = true;
    expect(
      await c.createLedgerBook('不能创建', bookType: LedgerBookType.investment),
      isFalse,
    );
    expect(c.ledgerBooks, hasLength(1));
    expect(c.activeBook.id, originalId);
    expect(
      await c.changeLedgerBookType(originalId, LedgerBookType.investment),
      isFalse,
    );
    expect(c.activeBook.bookType, LedgerBookType.normal);
    expect((await repo.loadBooks()).single.bookType, LedgerBookType.normal);
    repo.failBooks = false;
    expect(
      await c.changeLedgerBookType(originalId, LedgerBookType.investment),
      isTrue,
    );
    expect(c.activeBook.bookType, LedgerBookType.investment);
  });

  test('新版样例显式类型，旧 v15 缺字段即使已有证券仍恢复为普通', () async {
    final c = await makeController();
    addTearDown(c.dispose);
    final sample =
        jsonDecode(
              File('docs/dev/verifin-sample-backup.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    c.importDataJson(jsonEncode(sample));
    expect(
      c.ledgerBooks.singleWhere((b) => b.id == 'book_investment').bookType,
      LedgerBookType.investment,
    );
    final legacy = jsonDecode(jsonEncode(sample)) as Map<String, dynamic>;
    legacy['version'] = 15;
    for (final book in (legacy['data'] as Map)['ledgerBooks'] as List) {
      (book as Map).remove('bookType');
    }
    final before = c.exportDataJson();
    c.importDataJson(jsonEncode(legacy), dryRun: true);
    final afterPreview = jsonDecode(c.exportDataJson()) as Map;
    final beforePreview = jsonDecode(before) as Map;
    expect(afterPreview['data'], beforePreview['data']);
    c.importDataJson(jsonEncode(legacy));
    expect(
      c.ledgerBooks.every((b) => b.bookType == LedgerBookType.normal),
      isTrue,
    );
    c.switchLedgerBook('book_investment');
    expect(c.investmentFor('acc_investment_usd'), isNotNull);
  });

  test('非法类型在预览和真实导入均拒绝，原账目不改变', () async {
    final c = await makeController();
    addTearDown(c.dispose);
    final dataBefore = (jsonDecode(c.exportDataJson()) as Map)['data'];
    final invalid = jsonDecode(c.exportDataJson()) as Map;
    (((invalid['data'] as Map)['ledgerBooks'] as List).first
            as Map)['bookType'] =
        'invalid';
    for (final dryRun in [true, false]) {
      expect(
        () => c.importDataJson(jsonEncode(invalid), dryRun: dryRun),
        throwsFormatException,
      );
      expect((jsonDecode(c.exportDataJson()) as Map)['data'], dataBefore);
    }
  });

  test('账本保存成功但指针失败时保留新账本，重建仍能显式选择', () async {
    final repo = InMemoryLedgerRepository();
    final store = _FailingActiveBookStore();
    var c = await VeriFinController.create(store, repository: repo);
    try {
      final previousId = c.activeBook.id;
      store.failActiveBook = true;
      expect(
        await c.createLedgerBook(
          '保存成功但未切换',
          bookType: LedgerBookType.investment,
        ),
        isTrue,
      );
      expect(c.activeBook.id, previousId);
      expect(c.ledgerBooks, hasLength(2));
      final created = c.ledgerBooks.last;
      expect(created.bookType, LedgerBookType.investment);
      c.dispose();
      c = await VeriFinController.create(store, repository: repo);
      expect(c.activeBook.id, previousId);
      expect(c.ledgerBooks.last.id, created.id);
      expect(c.ledgerBooks.last.bookType, LedgerBookType.investment);
    } finally {
      c.dispose();
    }
  });

  testWidgets('账本新建可选择投资，保存后列表显示类型', (tester) async {
    final c = await makeController();
    addTearDown(c.dispose);
    await tester.pumpWidget(
      VeriFinScope(
        controller: c,
        child: zhMaterialApp(home: const LedgerBooksPage()),
      ),
    );
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.text('普通账本'), findsWidgets);
    await tester.enterText(
      find.byKey(const Key('ledger_book_name_field')),
      '投资录入测试',
    );
    await tester.tap(find.byKey(const Key('ledger_book_type_field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('投资账本').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ledger_book_save_button')));
    await tester.pumpAndSettle();
    expect(c.activeBook.name, '投资录入测试');
    expect(c.activeBook.bookType, LedgerBookType.investment);
    expect(find.textContaining('投资账本'), findsWidgets);
  });

  testWidgets('账本新建失败留住草稿，类型修改取消不落库', (tester) async {
    final repo = _FailingBooksRepository();
    final c = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: repo,
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      VeriFinScope(
        controller: c,
        child: zhMaterialApp(home: const LedgerBooksPage()),
      ),
    );
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('ledger_book_name_field')),
      '保留草稿',
    );
    repo.failBooks = true;
    await tester.tap(find.byKey(const Key('ledger_book_save_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ledger_book_name_field')), findsOneWidget);
    expect(find.text('保留草稿'), findsOneWidget);
    expect(c.ledgerBooks, hasLength(1));
    repo.failBooks = false;
    await tester.tap(find.byKey(const Key('ledger_book_save_button')));
    await tester.pumpAndSettle();
    expect(c.ledgerBooks, hasLength(2));
    await tester.tap(find.byTooltip('账本操作').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('账本类型'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ledger_book_type_field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('投资账本').last);
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(c.activeBook.bookType, LedgerBookType.normal);
  });

  testWidgets('修改类型保存失败保留选择，重试成功后才关闭', (tester) async {
    final repo = _FailingBooksRepository();
    final c = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: repo,
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      VeriFinScope(
        controller: c,
        child: zhMaterialApp(home: const LedgerBooksPage()),
      ),
    );
    await tester.tap(find.byTooltip('账本操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('账本类型'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ledger_book_type_field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('投资账本').last);
    await tester.pumpAndSettle();
    repo.failBooks = true;
    await tester.tap(find.byKey(const Key('ledger_book_type_save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ledger_book_type_save')), findsOneWidget);
    expect(find.text('投资账本'), findsOneWidget);
    expect(c.activeBook.bookType, LedgerBookType.normal);
    repo.failBooks = false;
    await tester.tap(find.byKey(const Key('ledger_book_type_save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ledger_book_type_save')), findsNothing);
    expect(c.activeBook.bookType, LedgerBookType.investment);
  });
}
