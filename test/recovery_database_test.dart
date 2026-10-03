import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/data/app_database.dart';
import 'package:verifin/data/ledger_repository.dart';
import 'package:verifin/local_storage/local_storage.dart';

/// 验证恢复包能打开已升级的数据库，并在导出前保留新表和原版本号。
void main() {
  setUpAll(sqfliteFfiInit);

  test('v25 账本打开后仍是 v25，旧版界面可导出账目', () async {
    final directory = await Directory.systemTemp.createTemp(
      'verifin-recovery-',
    );
    final path = '${directory.path}${Platform.pathSeparator}ledger.db';
    try {
      final original = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: path,
      );
      final originalController = await VeriFinController.create(
        LocalKeyValueStore(),
        repository: SqliteLedgerRepository(original),
      );
      originalController.dispose();
      await original.db.execute(
        "ALTER TABLE tags ADD COLUMN group_id TEXT NOT NULL DEFAULT 'custom'",
      );
      await original.db.execute(
        'CREATE TABLE tag_groups (id TEXT PRIMARY KEY, name TEXT NOT NULL)',
      );
      await original.db.insert('tag_groups', <String, Object?>{
        'id': 'project',
        'name': '项目',
      });
      await original.db.execute(
        'CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT NOT NULL)',
      );
      await original.db.insert('projects', <String, Object?>{
        'id': 'trip',
        'name': '返乡',
      });
      await original.db.setVersion(25);
      await original.close();

      final recovered = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: path,
      );
      try {
        expect(await recovered.db.getVersion(), 25);
        final controller = await VeriFinController.create(
          LocalKeyValueStore(),
          repository: SqliteLedgerRepository(recovered),
        );
        expect(controller.exportDataJson(), contains('ledgerBooks'));
        controller.dispose();
        expect(await recovered.db.query('tag_groups'), hasLength(1));
        expect(await recovered.db.query('projects'), hasLength(1));
        expect(await recovered.db.getVersion(), 25);
      } finally {
        await recovered.close();
      }
    } finally {
      // 仅清理本测试刚创建、位于系统临时目录下的独立目录。
      if (directory.absolute.path.startsWith(
        Directory.systemTemp.absolute.path,
      )) {
        await directory.delete(recursive: true);
      }
    }
  });
}
