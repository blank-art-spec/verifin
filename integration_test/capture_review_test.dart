import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite/sqflite.dart' as sqlite;
import 'package:verifin/app/models.dart';
import 'package:verifin/app/auto_capture/capture_parser.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/data/app_database.dart';
import 'package:verifin/data/ledger_repository.dart';
import 'package:verifin/l10n/app_localizations.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'package:verifin/pages/auto_capture_page.dart';
import 'package:verifin/pages/entry_detail_page.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('真机复核保存、关闭重开数据库及重复回放后仍只记一次', (tester) async {
    const reopen = String.fromEnvironment('CAPTURE_REVIEW_PHASE') == 'reopen';
    final path =
        '${await sqlite.getDatabasesPath()}/capture_review_integration_test.db';
    if (!reopen) await sqlite.deleteDatabase(path);
    var database = await AppDatabase.open(path: path);
    final store = await LocalKeyValueStore.create();
    var controller = await VeriFinController.create(
      store,
      repository: SqliteLedgerRepository(database),
    );
    try {
      if (reopen) {
        // 第二次独立启动在强停进程后运行，读取上次真实保存的数据库。
        expect(controller.entries, hasLength(1));
        final event = controller.captureEvents.single;
        expect(event.status, CaptureStatus.confirmed);
        expect(event.linkedEntryId, controller.entries.single.id);
        expect(
          controller.entries.single.sourceRecords.single.fingerprint,
          event.fingerprint,
        );
        expect(
          await controller.ingestCaptureInputs([
            RawCaptureInput(
              sourceKind: event.sourceKind,
              sourceId: event.sourceId,
              sourceEventId: event.sourceEventId,
              rawText: event.rawText,
              receivedAt: event.receivedAt,
            ),
          ]),
          0,
        );
        expect(
          await controller.processPendingCaptureEvents(
            allowAutomaticActions: false,
          ),
          0,
        );
        expect(await controller.replayRecentCaptureEvents(), 0);
        expect(controller.entries, hasLength(1));
        expect(controller.autoCaptureStats().pendingReview, 0);
        return;
      }
      expect(
        await controller.saveAutoCaptureSettingsDraft(
          controller.autoCaptureSettings.copyWith(
            autoPostHighConfidence: false,
            aiAssistEnabled: false,
          ),
        ),
        isTrue,
      );
      final account = Account(
        id: 'phone-review-account',
        bookId: controller.activeBook.id,
        name: '复核验收账户',
        type: AccountType.cash,
        groupId: null,
        initialBalance: 0,
        iconCode: 'cash',
        note: '',
        includeInAssets: true,
        hidden: false,
      );
      expect(await controller.addAccountDraft(account), isTrue);
      final category = controller.categories.firstWhere(
        (category) => category.type == EntryType.expense,
      );
      expect(
        await controller.saveAutoCaptureRule(
          AutoCaptureRule(
            id: 'phone-review-rule',
            bookId: controller.activeBook.id,
            name: '复核验收规则',
            priority: 100,
            textContains: '复核验收商户',
            setKind: CaptureTransactionKind.expense,
            setAccountId: account.id,
            setCategoryId: category.id,
          ),
        ),
        isTrue,
      );
      final input = RawCaptureInput(
        sourceKind: CaptureSourceKind.notification,
        sourceId: 'review-test',
        sourceEventId: 'phone-review',
        rawText: '消费2.30元，商户复核验收商户',
        receivedAt: DateTime.now(),
      );
      expect(await controller.ingestCaptureInputs([input]), 1);
      final eventId = controller.captureEvents.single.id;
      expect(
        controller.captureEvents.single.status,
        CaptureStatus.pendingReview,
      );
      await tester.pumpWidget(
        VeriFinScope(
          controller: controller,
          child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const AutoCapturePage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final scrollable = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.text('复核记账'),
        180,
        scrollable: scrollable,
      );
      await tester.ensureVisible(find.text('复核记账'));
      await tester.tap(find.text('复核记账'));
      await tester.pumpAndSettle();
      expect(find.byType(EntryDetailPage), findsOneWidget);
      await tester.tap(find.text('保存').last);
      await tester.pumpAndSettle();
      expect(find.byType(EntryDetailPage), findsNothing);
      expect(controller.entries, hasLength(1));
      final entryId = controller.entries.single.id;
      expect(controller.captureEvents.single.status, CaptureStatus.confirmed);
      expect(controller.captureEvents.single.linkedEntryId, entryId);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await database.close();
      database = await AppDatabase.open(path: path);
      controller = await VeriFinController.create(
        store,
        repository: SqliteLedgerRepository(database),
      );
      expect(controller.entries.single.id, entryId);
      expect(controller.captureEvents.single.id, eventId);
      expect(controller.captureEvents.single.status, CaptureStatus.confirmed);
      expect(await controller.ingestCaptureInputs([input]), 0);
      expect(
        await controller.processPendingCaptureEvents(
          allowAutomaticActions: false,
        ),
        0,
      );
      expect(await controller.replayRecentCaptureEvents(), 0);
      expect(controller.entries, hasLength(1));
      expect(controller.autoCaptureStats().pendingReview, 0);
    } finally {
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await database.close();
      if (reopen) await sqlite.deleteDatabase(path);
    }
  });
}
