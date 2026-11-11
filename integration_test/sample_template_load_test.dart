import 'dart:io';

import 'package:flutter/services.dart' show appFlavor;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite/sqflite.dart' as sqlite;
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/data/app_database.dart';
import 'package:verifin/data/ledger_repository.dart';
import 'package:verifin/local_storage/local_storage.dart';

import '../test/support/sample_investment_expectations.dart';

const _diagnosticPackage = 'top.talyra42.verifin.graphicsdiagnostic';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('完整测试模板导入真实数据库并冷重开后保持', (_) async {
    const confirmedPackage = String.fromEnvironment(
      'VERIFIN_SAMPLE_LOAD_TARGET_PACKAGE',
    );
    const inlineBackupJson = String.fromEnvironment(
      'VERIFIN_SAMPLE_BACKUP_JSON',
    );
    const templatePath = String.fromEnvironment('VERIFIN_SAMPLE_TEMPLATE_PATH');
    expect(
      confirmedPackage,
      _diagnosticPackage,
      reason: '只允许对独立 diagnostic 包运行模板加载测试',
    );
    expect(
      appFlavor,
      'diagnostic',
      reason: '当前 Flutter flavor 不是 diagnostic，拒绝导入',
    );
    final databasePath = (await sqlite.getDatabasesPath())
        .replaceAll('\\', '/')
        .replaceFirst(RegExp(r'/+$'), '');
    expect(
      databasePath,
      anyOf(
        '/data/user/0/$_diagnosticPackage/databases',
        '/data/data/$_diagnosticPackage/databases',
      ),
      reason: '运行时数据库不属于独立 diagnostic 包，拒绝导入',
    );
    final String rawJson;
    if (inlineBackupJson.isNotEmpty) {
      rawJson = inlineBackupJson;
    } else {
      expect(
        templatePath,
        startsWith('/data/user/0/$_diagnosticPackage/files/'),
        reason: '模板必须由脚本放入 diagnostic 应用私有目录',
      );
      final templateFile = File(templatePath);
      expect(
        await templateFile.exists(),
        isTrue,
        reason: '未找到 diagnostic 应用私有目录中的测试模板',
      );
      rawJson = await templateFile.readAsString();
    }
    expect(rawJson.trim(), isNotEmpty);

    final database = await AppDatabase.open();
    final controller = await VeriFinController.create(
      await LocalKeyValueStore.create(),
      repository: SqliteLedgerRepository(database),
    );
    try {
      final preview = controller.importDataJson(rawJson, dryRun: true);
      expect(preview.accountBalances, hasLength(22));
      expect(preview.missingAccountCount, 0);
      expect(preview.orphanRefundCount, 0);

      controller.importDataJson(rawJson);
      await controller.flushPendingWrites();
      expectSampleInvestmentPortfolio(controller);
      _expectThirdBrokerHasNoLedgerRecords(controller);
      await controller.flushPendingWrites();
    } finally {
      controller.dispose();
      await database.close();
    }

    // 用与正式入口相同的默认数据库路径重开，防止只在
    // Controller 内存中看到导入结果。测试成功后不删库，供正常应用启动查看。
    final reopenedDatabase = await AppDatabase.open();
    final reopened = await VeriFinController.create(
      await LocalKeyValueStore.create(),
      repository: SqliteLedgerRepository(reopenedDatabase),
    );
    try {
      expectSampleInvestmentPortfolio(reopened);
      _expectThirdBrokerHasNoLedgerRecords(reopened);
      await reopened.flushPendingWrites();
    } finally {
      reopened.dispose();
      await reopenedDatabase.close();
    }
  });
}

void _expectThirdBrokerHasNoLedgerRecords(VeriFinController controller) {
  const accountIds = {
    'acc_investment_3_cny',
    'acc_investment_3_usd',
    'acc_investment_3_hkd',
  };
  final originalBookId = controller.activeBook.id;
  try {
    controller.switchLedgerBook('book_investment');
    expect(
      controller.entries.where(
        (entry) =>
            accountIds.contains(entry.accountId) ||
            accountIds.contains(entry.toAccountId),
      ),
      isEmpty,
    );
    expect(
      controller.balanceAnchors.where(
        (anchor) => accountIds.contains(anchor.accountId),
      ),
      isEmpty,
    );
  } finally {
    controller.switchLedgerBook(originalBookId);
  }
}
