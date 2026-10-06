import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/ai/ai_entry_parser.dart';
import 'package:verifin/app/auto_capture/capture_parser.dart';
import 'package:verifin/app/common_widgets.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/l10n/app_localizations.dart';
import 'package:verifin/pages/auto_capture_sources_page.dart';

import 'support/test_harness.dart';

const _package = 'com.example.bank';
const _channel = MethodChannel('verifin/app');

Account _account(
  String id,
  AccountType type, {
  String name = '账户',
  String bookId = 'default',
  bool hidden = false,
  String cardLast4 = '',
  String currencyCode = 'CNY',
}) => Account(
  id: id,
  bookId: bookId,
  name: name,
  type: type,
  groupId: null,
  initialBalance: 0,
  iconCode: 'asset:payment_001',
  note: '',
  includeInAssets: true,
  hidden: hidden,
  cardLast4: cardLast4,
  currencyCode: currencyCode,
);

CaptureEvent _event({
  String text = '支付59.49元，商户麦当劳',
  CaptureSourceKind source = CaptureSourceKind.notification,
}) => captureEventFromInput(
  id: 'event',
  bookId: 'default',
  input: RawCaptureInput(
    sourceKind: source,
    sourceId: _package,
    sourceEventId: 'event',
    rawText: text,
    receivedAt: DateTime(2026, 10, 6, 12),
  ),
);

CaptureParseContext _context(
  List<Account> accounts, {
  List<AutoCaptureRule> rules = const <AutoCaptureRule>[],
}) => CaptureParseContext(
  book: LedgerBook(
    id: 'default',
    name: '日常账本',
    createdAt: DateTime(2026),
    isDefault: true,
  ),
  accounts: accounts,
  creditAccounts: const <CreditAccount>[],
  categories: const <Category>[],
  tags: const <Tag>[],
  entries: const <LedgerEntry>[],
  rules: rules,
  notificationAccountTypes: const <String, AccountType>{
    _package: AccountType.creditCard,
  },
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useTestDatabases();
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null),
  );

  test('来源设置恢复旧配置并保留显式空白名单及账户类型', () {
    final legacy = AutoCaptureSettings.decode(
      jsonEncode(<String, Object?>{
        'notificationEnabled': true,
        'sourcePackages': <String>[_package],
      }),
    );
    expect(legacy.sourcePackagesConfigured, isTrue);
    expect(legacy.excludedSourcePackages, isEmpty);
    expect(legacy.notificationAccountTypes, isEmpty);
    final current = AutoCaptureSettings.decode(
      const AutoCaptureSettings(
        notificationEnabled: true,
        sourcePackagesConfigured: true,
        excludedSourcePackages: <String>['com.example.ad'],
        notificationAccountTypes: <String, AccountType>{
          _package: AccountType.creditCard,
        },
      ).encode(),
    );
    expect(current.sourcePackagesConfigured, isTrue);
    expect(current.sourcePackages, isEmpty);
    expect(current.allowsNotificationSource(_package), isFalse);
    expect(current.excludedSourcePackages, <String>['com.example.ad']);
    expect(current.notificationAccountTypes[_package], AccountType.creditCard);
    expect(
      current.copyWith(smsEnabled: true).notificationAccountTypes,
      current.notificationAccountTypes,
    );
    final unknown = AutoCaptureSettings.decode(
      jsonEncode(<String, Object?>{
        'notificationAccountTypes': <String, String>{
          _package: 'future-type',
          'known': 'cash',
        },
      }),
    );
    expect(unknown.notificationAccountTypes, <String, AccountType>{
      'known': AccountType.cash,
    });
  });

  test('排除优先于全部模式和旧白名单重叠', () {
    const settings = AutoCaptureSettings(
      sourcePackages: <String>[_package],
      excludedSourcePackages: <String>[_package],
    );
    expect(settings.allowsNotificationSource(_package), isFalse);
    expect(
      settings
          .copyWith(listenAllNotificationSources: true)
          .allowsNotificationSource(_package),
      isFalse,
    );
    expect(
      settings
          .copyWith(listenAllNotificationSources: true)
          .allowsNotificationSource('other'),
      isTrue,
    );
    expect(settings.allowsNotificationSource('other'), isFalse);
  });

  test('APP 类型只匹配本账本可见且币种相符的唯一账户', () {
    final parsed = parseCaptureEvent(
      _event(),
      _context(<Account>[
        _account('online', AccountType.onlinePayment),
        _account('card', AccountType.creditCard),
        _account('other-book', AccountType.creditCard, bookId: 'other'),
        _account('hidden', AccountType.creditCard, hidden: true),
        _account('usd', AccountType.creditCard, currencyCode: 'USD'),
      ]),
    );
    expect(parsed.accountCandidateId, 'card');
    expect(
      parseCaptureEvent(
        _event(),
        _context(<Account>[_account('online', AccountType.onlinePayment)]),
      ).accountCandidateId,
      isNull,
    );
  });

  test('同类多账户保留待复核，卡尾号或账户名可唯一匹配', () {
    final accounts = <Account>[
      _account(
        'card-1',
        AccountType.creditCard,
        cardLast4: '1234',
        name: '招商信用卡',
      ),
      _account(
        'card-2',
        AccountType.creditCard,
        cardLast4: '5678',
        name: '中行信用卡',
      ),
    ];
    final ambiguous = parseCaptureEvent(_event(), _context(accounts));
    expect(ambiguous.accountCandidateId, isNull);
    expect(ambiguous.status, CaptureStatus.pendingReview);
    expect(
      parseCaptureEvent(
        _event(text: '尾号5678消费59.49元'),
        _context(accounts),
      ).accountCandidateId,
      'card-2',
    );
    expect(
      parseCaptureEvent(
        _event(text: '招商信用卡消费59.49元'),
        _context(accounts),
      ).accountCandidateId,
      'card-1',
    );
    expect(
      parseCaptureEvent(
        _event(text: '尾号9999消费59.49元，招商信用卡'),
        _context(accounts),
      ).accountCandidateId,
      isNull,
    );
    expect(
      parseCaptureEvent(
        _event(text: '尾号9999消费59.49元'),
        _context(<Account>[accounts.first]),
      ).accountCandidateId,
      isNull,
    );
  });

  test('类型映射不影响短信，冲突规则不能绑定其他类型', () {
    final accounts = <Account>[
      _account('online', AccountType.onlinePayment, name: '支付钱包'),
      _account('card', AccountType.creditCard),
    ];
    expect(
      parseCaptureEvent(
        _event(text: '支付钱包支付59.49元', source: CaptureSourceKind.sms),
        _context(accounts),
      ).accountCandidateId,
      'online',
    );
    final parsed = parseCaptureEvent(
      _event(),
      _context(
        accounts,
        rules: const <AutoCaptureRule>[
          AutoCaptureRule(
            id: 'rule',
            bookId: 'default',
            name: '冲突规则',
            priority: 100,
            setAccountId: 'online',
          ),
        ],
      ),
    );
    expect(parsed.accountCandidateId, isNull);
  });

  test('APP 映射下去重不能合并到其他账户或绕过账户歧义', () {
    final accounts = <Account>[
      _account('card', AccountType.creditCard),
      _account('online', AccountType.onlinePayment),
    ];
    final event = parseCaptureEvent(_event(), _context(accounts));
    final entry = LedgerEntry(
      id: 'entry',
      bookId: 'default',
      type: EntryType.expense,
      amount: 59.49,
      categoryId: '',
      accountId: 'online',
      occurredAt: event.receivedAt,
      note: '麦当劳',
      tagIds: const <String>[],
    );
    expect(
      findCaptureDuplicate(event, <LedgerEntry>[entry])?.safeToMerge,
      isTrue,
    );
    expect(
      findCaptureDuplicate(event, <LedgerEntry>[
        entry,
      ], requireMatchedAccount: true),
      isNull,
    );
    expect(
      findCaptureDuplicate(event, <LedgerEntry>[
        entry.copyWith(accountId: 'card'),
      ], requireMatchedAccount: true)?.safeToMerge,
      isTrue,
    );
    expect(
      findCaptureDuplicate(
        event.copyWith(clearAccountCandidateId: true),
        <LedgerEntry>[entry],
        requireMatchedAccount: true,
      ),
      isNull,
    );
  });

  test('AI 不能绕过类型映射或在多个同类账户中猜选', () {
    final accounts = <Account>[
      _account('online', AccountType.onlinePayment),
      _account('card-1', AccountType.creditCard),
      _account('card-2', AccountType.creditCard),
    ];
    final context = _context(accounts);
    final local = parseCaptureEvent(_event(), context);
    for (final id in <String>['online', 'card-1']) {
      final result = applyAiCaptureSupplement(
        local,
        AiEntryDraft(
          type: EntryType.expense,
          amount: 59.49,
          currencyCode: 'CNY',
          categoryId: '',
          accountId: id,
          toAccountId: null,
          note: '麦当劳',
          occurredAt: DateTime(2026, 10, 6, 12),
        ),
        context,
      );
      expect(result.accountCandidateId, isNull);
      expect(result.status, CaptureStatus.pendingReview);
    }
  });

  testWidgets('来源编辑可搜索、指定账户类型，保存失败保留草稿', (tester) async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          _channel,
          (call) async => <Object?>[
            <String, String>{'packageName': _package, 'label': '测试银行'},
            <String, String>{
              'packageName': 'com.example.wallet',
              'label': '支付钱包',
            },
          ],
        );
    AutoCaptureSettings? draft;
    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AutoCaptureSourcesPage(
            settings: AutoCaptureSettings.disabled,
            onSave: (settings) async {
              draft = settings;
              return false;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), _package);
    await tester.pumpAndSettle();
    expect(find.text('支付钱包'), findsNothing);
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    final typeChoice = find.byType(VeriAnchoredChoice<String>);
    await tester.ensureVisible(typeChoice);
    await tester.tap(
      find.descendant(of: typeChoice, matching: find.textContaining('识别账户类型')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('信用卡'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(SaveHeaderAction));
    await tester.tap(find.byType(SaveHeaderAction));
    await tester.pumpAndSettle();
    expect(draft?.sourcePackages, <String>[_package]);
    expect(draft?.notificationAccountTypes[_package], AccountType.creditCard);
    expect(draft?.sourcePackagesConfigured, isTrue);
    expect(find.byType(AutoCaptureSourcesPage), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'wallet');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(SaveHeaderAction));
    await tester.tap(find.byType(SaveHeaderAction));
    await tester.pumpAndSettle();
    expect(draft?.sourcePackages, <String>[_package]);
  });
}
