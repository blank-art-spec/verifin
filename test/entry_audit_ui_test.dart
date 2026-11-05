import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/app_theme.dart';
import 'package:verifin/app/common_widgets.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'package:verifin/pages/transaction_detail_page.dart';

import 'support/in_memory_ledger_repository.dart';
import 'support/test_harness.dart';

/// 构造两次按提交顺序保存的修改；固定时间与字段值便于核对倒序和逐条展开。
/// 两条记录故意使用相同时间，避免折叠状态错误地按时间串联。
List<EntryAuditRecord> _history() => <EntryAuditRecord>[
  EntryAuditRecord(
    at: DateTime(2026, 11, 5, 9, 42),
    actor: EntryAuditActor.autoCapture,
    reason: EntryAuditReason.created,
    changes: const <String, EntryAuditChange>{
      'amount': EntryAuditChange(before: '', after: '14.7'),
    },
  ),
  EntryAuditRecord(
    at: DateTime(2026, 11, 5, 9, 42),
    actor: EntryAuditActor.user,
    reason: EntryAuditReason.edited,
    changes: const <String, EntryAuditChange>{
      'note': EntryAuditChange(before: '原备注', after: '午餐'),
    },
  ),
];

/// 直接在隔离内存仓储预置 [history]，再按真实冷启动路径读取交易。
/// 不调用新增交易命令，避免命令自动补上创建记录，无法覆盖旧交易的空历史。
Future<VeriFinController> _controllerWithHistory(
  List<EntryAuditRecord> history,
) async {
  final repository = InMemoryLedgerRepository();
  await repository.saveBooks(<LedgerBook>[
    LedgerBook(
      id: defaultLedgerBookId,
      name: '测试账本',
      createdAt: DateTime(2026, 11, 1),
      isDefault: true,
    ),
  ]);
  await repository.saveCategories(const <Category>[
    Category(
      id: 'audit-dining',
      label: '餐饮',
      type: EntryType.expense,
      iconCode: 'dining',
    ),
  ]);
  await repository.saveEntries(<LedgerEntry>[
    LedgerEntry(
      id: 'audit-entry',
      bookId: defaultLedgerBookId,
      type: EntryType.expense,
      amount: 14.7,
      categoryId: 'audit-dining',
      accountId: '',
      note: '午餐',
      occurredAt: DateTime(2026, 11, 5, 9, 19),
      auditHistory: history,
    ),
  ]);
  final store = LocalKeyValueStore()..write('verifin.locale.v1', 'zh');
  final controller = await VeriFinController.create(
    store,
    repository: repository,
  );
  addTearDown(controller.dispose);
  return controller;
}

/// 在真实交易详情页挂载 [controller]；[locale] 控制按钮和摘要语言，
/// [width] 与 [textScale] 分别覆盖常规手机、窄屏和系统放大字体。
Future<void> _pumpDetail(
  WidgetTester tester,
  VeriFinController controller, {
  Locale locale = const Locale('zh'),
  double width = 393,
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 852);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    VeriFinScope(
      controller: controller,
      child: zhMaterialApp(
        theme: buildVeriFinTheme(Brightness.light),
        home: Builder(
          builder: (context) => Localizations.override(
            context: context,
            locale: locale,
            child: MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: const TransactionDetailPage(entryId: 'audit-entry'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 把 [target] 滚入可点击范围；[delta] 为正时向下查找，为负时回到上方。
/// 等待布局稳定后再点击，避免列表缓存中尚在屏幕外的按钮被误当作可见。
Future<void> _reveal(
  WidgetTester tester,
  Finder target, {
  double delta = 220,
}) async {
  await tester.scrollUntilVisible(
    target,
    delta,
    scrollable: firstVerticalScrollable(),
  );
  await tester.pumpAndSettle();
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

/// 注册修改历史的可见交互测试；仅浏览展开状态，不提交或修改交易草稿。
void main() {
  useTestDatabases();

  for (final english in <bool>[false, true]) {
    testWidgets(english ? '窄屏英文大字号下修改历史逐条展开和收起' : '修改历史默认收起，按倒序保留摘要且逐条独立切换', (
      tester,
    ) async {
      final controller = await _controllerWithHistory(_history());
      final savedBefore = controller.entries.single.toJson();
      await _pumpDetail(
        tester,
        controller,
        locale: Locale(english ? 'en' : 'zh'),
        width: english ? 320 : 393,
        textScale: english ? 1.3 : 1,
      );
      final newest = find.byKey(const Key('entry_audit_record_1'));
      final oldest = find.byKey(const Key('entry_audit_record_0'));
      final newestToggle = find.byKey(const Key('entry_audit_toggle_1'));
      final oldestToggle = find.byKey(const Key('entry_audit_toggle_0'));
      final expand = english ? 'Expand' : '展开';
      final collapse = english ? 'Collapse' : '收起';
      final amountChange = english
          ? 'Transaction amount：∅ → 14.7'
          : '交易金额：∅ → 14.7';
      final noteChange = english ? 'Note：原备注 → 午餐' : '备注：原备注 → 午餐';

      await _reveal(tester, oldestToggle);
      expect(
        find.descendant(of: newest, matching: find.text(expand)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: oldest, matching: find.text(expand)),
        findsOneWidget,
      );
      expect(
        find.text(english ? 'User · Edited transaction' : '用户 · 修改交易'),
        findsOneWidget,
      );
      expect(
        find.text(
          english ? 'Auto capture · Created transaction' : '自动采集 · 创建交易',
        ),
        findsOneWidget,
      );
      final material = MaterialLocalizations.of(tester.element(newest));
      final at = _history().first.at;
      final time =
          '${material.formatFullDate(at)} '
          '${material.formatTimeOfDay(TimeOfDay.fromDateTime(at))}';
      expect(find.text(time), findsNWidgets(2));
      expect(
        tester.getTopLeft(newest).dy,
        lessThan(tester.getTopLeft(oldest).dy),
      );
      expect(find.text(amountChange), findsNothing);
      expect(find.text(noteChange), findsNothing);

      await _reveal(tester, newestToggle, delta: -220);
      await tester.tap(newestToggle);
      await tester.pumpAndSettle();
      expect(find.text(noteChange), findsOneWidget);
      expect(find.text(amountChange), findsNothing);
      expect(
        find.descendant(of: newest, matching: find.text(collapse)),
        findsOneWidget,
      );

      await _reveal(tester, oldestToggle);
      await tester.tap(oldestToggle);
      await tester.pumpAndSettle();
      expect(find.text(amountChange), findsOneWidget);
      expect(find.text(noteChange), findsOneWidget);
      await _reveal(tester, newestToggle, delta: -220);
      await tester.tap(newestToggle);
      await tester.pumpAndSettle();
      expect(find.text(noteChange), findsNothing);
      expect(find.text(amountChange), findsOneWidget);

      // 滚回页首再返回历史区，已经展开的旧记录仍保留展开状态。
      await _reveal(tester, find.byType(VeriHeader), delta: -220);
      await _reveal(tester, oldestToggle);
      expect(find.text(amountChange), findsOneWidget);
      expect(
        tester
            .widget<UnsavedChangesGuard>(find.byType(UnsavedChangesGuard))
            .isDirty,
        isFalse,
      );
      expect(controller.entries.single.toJson(), savedBefore);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('没有修改历史的旧交易不显示历史标题和展开按钮', (tester) async {
    final controller = await _controllerWithHistory(const <EntryAuditRecord>[]);
    await _pumpDetail(tester, controller);
    await _reveal(tester, find.text('暂无退款，点下方添加'));
    expect(find.text('修改历史'), findsNothing);
    expect(find.text('展开'), findsNothing);
    expect(find.text('收起'), findsNothing);
    expect(controller.entries.single.auditHistory, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
