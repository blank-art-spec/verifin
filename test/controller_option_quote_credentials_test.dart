import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/alpaca_option_quote_adapter.dart';
import 'package:verifin/app/investments/investment_quote_sync.dart';
import 'package:verifin/app/investments/market_quote.dart';
import 'package:verifin/app/investments/option_quote_credential_store.dart';
import 'package:verifin/app/investments/production_market_quotes.dart';
import 'package:verifin/app/logging/app_logger.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/in_memory_ledger_repository.dart';
import 'support/investment_fixture.dart';

const _option = StockSecurity(
  symbol: 'AVGO261218C00300000',
  name: '本地凭证恢复测试合约',
  market: StockMarket.us,
  currencyCode: 'USD',
  option: OptionContract(
    underlyingId: 'us:stock:AVGO',
    expiry: '2026-12-18',
    right: OptionRight.call,
    strike: '300',
    premiumMultiplier: '100',
    settlement: OptionSettlement.unsupported,
  ),
);

/// 只模拟独立安全存储，不借用普通 KV；错误文本故意带标记以验证日志脱敏。
class _CredentialStore implements OptionQuoteCredentialStore {
  OptionQuoteCredentials? value;
  bool failRead = false, failWrite = false, failClear = false;
  int reads = 0, writes = 0, clears = 0;
  Completer<void>? entered, release;

  @override
  Future<OptionQuoteCredentials?> read() async {
    reads++;
    if (failRead) throw StateError('SECRET-MUST-NOT-LOG');
    return value;
  }

  @override
  Future<void> write(OptionQuoteCredentials credentials) async {
    writes++;
    entered?.complete();
    if (release != null) await release!.future;
    if (failWrite) throw StateError('SECRET-MUST-NOT-LOG');
    value = credentials;
  }

  @override
  Future<void> clear() async {
    clears++;
    if (failClear) throw StateError('SECRET-MUST-NOT-LOG');
    value = null;
  }
}

/// 记录所有普通偏好写入，证明凭证只交给独立存储；可单独破坏行情缓存清理。
class _PreferenceStore extends LocalKeyValueStore {
  final written = <String, String>{};
  bool failQuoteCache = false;

  @override
  void write(String key, String value) {
    written[key] = value;
    super.write(key, value);
  }

  @override
  Future<void> writeAndFlush(String key, String value) async {
    if (failQuoteCache && key == 'investment_quote_cache_v1') {
      throw StateError('模拟行情缓存写入失败');
    }
    written[key] = value;
    await super.writeAndFlush(key, value);
  }
}

/// 生产适配器仍执行字段校验，底层只返回本地合成的每单位期权延迟成交。
class _OptionTransport implements AlpacaOptionQuoteTransport {
  final keys = <String>[];

  /// [uri] 使用实际单合约请求，返回其免费查询截止时间前一分钟的成交。
  /// [keyId] 记录到内存供凭证恢复断言使用，[secretKey] 不写入输出或偏好。
  @override
  Future<AlpacaOptionQuoteResponse> get(
    Uri uri, {
    required String keyId,
    required String secretKey,
  }) async {
    keys.add(keyId);
    final time = DateTime.parse(
      uri.queryParameters['end']!,
    ).subtract(const Duration(minutes: 1)).toIso8601String();
    return AlpacaOptionQuoteResponse(
      statusCode: 200,
      body: Stream.value(
        utf8.encode(
          jsonEncode({
            'trades': {
              _option.symbol: [
                {'p': 5, 't': time, 'c': 'I', 's': 1, 'x': 'B'},
              ],
            },
            'next_page_token': null,
          }),
        ),
      ),
    );
  }

  @override
  void close() {}
}

/// 创建实际生产来源组合，但所有网络路径都由测试传输或立即失败保护。
MarketQuoteClient _client(_OptionTransport transport) =>
    buildProductionMarketQuoteClient(
      alpacaTransportFactory: () => transport,
      tencentTransportFactory: () => throw StateError('本测试不允许股票网络请求'),
      cmsTransportFactory: () => throw StateError('本测试不允许基金网络请求'),
    );

/// 在真实 Controller 命令路径中创建期权期初持仓，不直接改内部状态。
Future<InvestmentPortfolio> _holding(VeriFinController controller) async {
  final account = investmentAccountFixture();
  controller.addAccount(account);
  await controller.waitForPendingWrites();
  expect(
    await controller.enableInvestment(
      accountId: account.id,
      openingCash: '1000',
      openedAt: DateTime.utc(2026, 10, 1),
      securities: const [avgoFixture, _option],
      openingHoldings: [
        StockHolding(
          securityId: _option.id,
          short: false,
          quantity: '2',
          cost: '300',
        ),
      ],
      manualPrices: {_option.id: '2'},
    ),
    isTrue,
  );
  return controller.investmentFor(account.id)!;
}

/// 重建 Controller 模拟冷启动恢复，验证失败和并发边界；不调用真实平台或凭证服务。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('凭证先于行情缓存恢复，冷启动不联网，清除后重启也不复活', () async {
    final preferences = _PreferenceStore();
    final credentials = _CredentialStore();
    final repository = InMemoryLedgerRepository();
    final transport = _OptionTransport();
    final firstClient = _client(transport);
    final first = await VeriFinController.create(
      preferences,
      repository: repository,
      marketQuoteClient: firstClient,
      optionQuoteCredentialStore: credentials,
    );
    final portfolio = await _holding(first);
    final facts = portfolio.toJson();
    expect(
      await first.saveOptionQuoteCredentials(
        'persistent-fixture-key',
        'persistent-fixture-secret',
      ),
      isTrue,
    );
    final sync = first.investmentQuoteSync;
    expect(sync.state.value.enabled, isFalse);
    expect(sync.state.value.automatic, isFalse);
    expect(transport.keys, isEmpty);
    expect(await sync.configure(enabled: true, automatic: true), isTrue);
    sync.setVisible(portfolio);
    expect(
      await sync.refresh(portfolio, isCurrent: () => true, automatic: true),
      isTrue,
    );
    final cooldown = sync.stateFor(portfolio).cooldownUntil;
    expect(transport.keys, ['persistent-fixture-key']);
    first.dispose();

    final secondClient = _client(transport);
    final second = await VeriFinController.create(
      preferences,
      repository: repository,
      marketQuoteClient: secondClient,
      optionQuoteCredentialStore: credentials,
    );
    final restored = second.investmentFor(portfolio.accountId)!;
    expect(second.optionQuoteCredentialsLoadFailed, isFalse);
    expect(
      secondClient.adapterFor(MarketQuoteRequest(_option)),
      isA<AlpacaOptionQuoteAdapter>(),
    );
    expect(second.investmentQuoteSync.quotesFor(restored), hasLength(1));
    expect(second.investmentQuoteSync.state.value.enabled, isTrue);
    expect(second.investmentQuoteSync.state.value.automatic, isTrue);
    expect(
      second.investmentQuoteSync.stateFor(restored).cooldownUntil,
      cooldown,
    );
    expect(restored.toJson(), facts);
    expect(credentials.reads, 2);
    expect(transport.keys, hasLength(1));
    for (final secret in [
      'persistent-fixture-key',
      'persistent-fixture-secret',
    ]) {
      expect(jsonEncode(preferences.written), isNot(contains(secret)));
      expect(second.exportDataJson(), isNot(contains(secret)));
    }
    expect(await second.saveOptionQuoteCredentials('', ''), isTrue);
    expect(credentials.value, isNull);
    expect(second.investmentQuoteSync.quotesFor(restored), isEmpty);
    second.dispose();

    final thirdClient = _client(transport);
    final third = await VeriFinController.create(
      preferences,
      repository: repository,
      marketQuoteClient: thirdClient,
      optionQuoteCredentialStore: credentials,
    );
    addTearDown(third.dispose);
    expect(thirdClient.adapterFor(MarketQuoteRequest(_option)), isNull);
    expect(
      third.investmentQuoteSync.quotesFor(
        third.investmentFor(portfolio.accountId)!,
      ),
      isEmpty,
    );
    expect(third.investmentQuoteSync.state.value.enabled, isTrue);
    expect(third.investmentQuoteSync.state.value.automatic, isTrue);
    expect(credentials.clears, 1);
    expect(transport.keys, hasLength(1));
  });

  test('默认未注入存储不调用原生，不把只改内存当作保存成功', () async {
    const channel = MethodChannel('verifin/app');
    final calls = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final client = _client(_OptionTransport());
    final controller = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: InMemoryLedgerRepository(),
      marketQuoteClient: client,
    );
    addTearDown(controller.dispose);
    expect(
      await controller.saveOptionQuoteCredentials(
        'fixture-key',
        'fixture-secret',
      ),
      isFalse,
    );
    expect(
      client.adapters.whereType<AlpacaOptionQuoteAdapter>().single.configured,
      isFalse,
    );
    expect(controller.optionQuoteCredentialsLoadFailed, isFalse);
    expect(
      calls.where((method) => method.contains('OptionQuoteCredentials')),
      isEmpty,
    );
  });

  test('读取失败仍能打开账本，不清毁保存数据，重新保存后清除失败标志', () async {
    final preferences = _PreferenceStore();
    final logger = AppLogger(preferences);
    addTearDown(logger.dispose);
    final credentials = _CredentialStore()
      ..value = OptionQuoteCredentials(
        keyId: 'old-fixture-key',
        secretKey: 'old-fixture-secret',
      )
      ..failRead = true;
    final client = _client(_OptionTransport());
    final controller = await VeriFinController.create(
      preferences,
      repository: InMemoryLedgerRepository(),
      logger: logger,
      marketQuoteClient: client,
      optionQuoteCredentialStore: credentials,
    );
    addTearDown(controller.dispose);
    expect(controller.activeBook.id, isNotEmpty);
    expect(controller.optionQuoteCredentialsLoadFailed, isTrue);
    expect(
      client.adapters.whereType<AlpacaOptionQuoteAdapter>().single.configured,
      isFalse,
    );
    expect(credentials.value!.keyId, 'old-fixture-key');
    expect(credentials.writes, 0);
    expect(credentials.clears, 0);
    expect(
      logger.records.any((record) => record.message.contains('期权行情凭证读取失败')),
      isTrue,
    );
    expect(
      jsonEncode(preferences.written),
      isNot(contains('SECRET-MUST-NOT-LOG')),
    );
    expect(
      await controller.saveOptionQuoteCredentials(
        'new-fixture-key',
        'new-fixture-secret',
      ),
      isTrue,
    );
    expect(controller.optionQuoteCredentialsLoadFailed, isFalse);
    expect(credentials.value!.keyId, 'new-fixture-key');
  });

  test('持久写入或清除失败保留旧内存凭证，敏感错误不进日志', () async {
    final preferences = _PreferenceStore();
    final logger = AppLogger(preferences);
    addTearDown(logger.dispose);
    final credentials = _CredentialStore()
      ..value = OptionQuoteCredentials(
        keyId: 'old-fixture-key',
        secretKey: 'old-fixture-secret',
      );
    final transport = _OptionTransport();
    final client = _client(transport);
    final controller = await VeriFinController.create(
      preferences,
      repository: InMemoryLedgerRepository(),
      logger: logger,
      marketQuoteClient: client,
      optionQuoteCredentialStore: credentials,
    );
    addTearDown(controller.dispose);
    final portfolio = await _holding(controller);
    final sync = controller.investmentQuoteSync;
    sync.setVisible(portfolio);
    expect(await sync.configure(enabled: true, automatic: false), isTrue);
    expect(await sync.refresh(portfolio, isCurrent: () => true), isTrue);
    credentials.failWrite = true;
    expect(
      await controller.saveOptionQuoteCredentials(
        'new-fixture-key',
        'new-fixture-secret',
      ),
      isFalse,
    );
    expect(credentials.value!.keyId, 'old-fixture-key');
    expect(sync.quotesFor(portfolio), isEmpty);
    expect(sync.state.value.status, QuoteSyncStatus.failed);
    expect(await sync.refresh(portfolio, isCurrent: () => true), isTrue);
    credentials.failClear = true;
    expect(await controller.saveOptionQuoteCredentials('', ''), isFalse);
    expect(await sync.refresh(portfolio, isCurrent: () => true), isTrue);
    expect(transport.keys, everyElement('old-fixture-key'));
    expect(
      jsonEncode(preferences.written),
      isNot(contains('SECRET-MUST-NOT-LOG')),
    );
    expect(controller.exportDataJson(), isNot(contains('old-fixture-secret')));
    expect(
      client.adapters.whereType<AlpacaOptionQuoteAdapter>().single.configured,
      isTrue,
    );
  });

  test('缓存清理失败不写新凭证，成对字段校验失败也不触碰安全存储', () async {
    final preferences = _PreferenceStore();
    final credentials = _CredentialStore()
      ..value = OptionQuoteCredentials(
        keyId: 'old-fixture-key',
        secretKey: 'old-fixture-secret',
      );
    final controller = await VeriFinController.create(
      preferences,
      repository: InMemoryLedgerRepository(),
      marketQuoteClient: _client(_OptionTransport()),
      optionQuoteCredentialStore: credentials,
    );
    addTearDown(controller.dispose);
    expect(
      await controller.saveOptionQuoteCredentials('', 'only-secret'),
      isFalse,
    );
    expect(
      await controller.saveOptionQuoteCredentials('key', 'bad\nheader'),
      isFalse,
    );
    preferences.failQuoteCache = true;
    expect(
      await controller.saveOptionQuoteCredentials(
        'new-fixture-key',
        'new-fixture-secret',
      ),
      isFalse,
    );
    expect(credentials.writes, 0);
    expect(credentials.clears, 0);
    expect(credentials.value!.keyId, 'old-fixture-key');
  });

  test('保存等待中拒绝重复保存与刷新，持久成功后才采用新凭证', () async {
    final credentials = _CredentialStore()
      ..value = OptionQuoteCredentials(
        keyId: 'old-fixture-key',
        secretKey: 'old-fixture-secret',
      )
      ..entered = Completer<void>()
      ..release = Completer<void>();
    final transport = _OptionTransport();
    final controller = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: InMemoryLedgerRepository(),
      marketQuoteClient: _client(transport),
      optionQuoteCredentialStore: credentials,
    );
    addTearDown(controller.dispose);
    final portfolio = await _holding(controller);
    final sync = controller.investmentQuoteSync;
    sync.setVisible(portfolio);
    expect(await sync.configure(enabled: true, automatic: false), isTrue);
    final saving = controller.saveOptionQuoteCredentials(
      'new-fixture-key',
      'new-fixture-secret',
    );
    await credentials.entered!.future;
    expect(credentials.value!.keyId, 'old-fixture-key');
    expect(
      await controller.saveOptionQuoteCredentials('third-key', 'third-secret'),
      isFalse,
    );
    expect(await controller.saveOptionQuoteCredentials('', ''), isFalse);
    expect(await sync.refresh(portfolio, isCurrent: () => true), isFalse);
    expect(transport.keys, isEmpty);
    credentials.release!.complete();
    expect(await saving, isTrue);
    expect(credentials.writes, 1);
    expect(credentials.clears, 0);
    expect(await sync.refresh(portfolio, isCurrent: () => true), isTrue);
    expect(transport.keys, ['new-fixture-key']);
  });
}
