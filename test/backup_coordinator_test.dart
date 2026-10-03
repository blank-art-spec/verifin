import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/backup/backup_coordinator.dart';
import 'package:verifin/app/backup/backup_settings.dart';

import 'support/test_harness.dart';

void main() {
  useTestDatabases();

  Directory makeTempDir() {
    final dir = Directory.systemTemp.createTempSync('verifin_backup');
    addTearDown(() {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    });
    return dir;
  }

  List<File> autoBackupsIn(Directory dir) {
    return dir
        .listSync()
        .whereType<File>()
        .where((file) => file.path.contains('verifin-auto-'))
        .toList();
  }

  test('恢复包即使设置 onOpen 也不自动备份或清理旧备份', () async {
    final dir = makeTempDir();
    final controller = await makeController();
    controller.setBackupDirectory(dir.path, 'temp');
    controller.setBackupFrequency(BackupFrequency.onOpen);

    await BackupCoordinator.maybeBackupOnOpen(controller);

    expect(autoBackupsIn(dir), isEmpty);
    expect(controller.backupSettings.lastBackupAt, isNull);
  });

  test('manual 频率不产生自动备份', () async {
    final dir = makeTempDir();
    final controller = await makeController();
    controller.setBackupDirectory(dir.path, 'temp');
    // 默认频率即 manual。
    await BackupCoordinator.maybeBackupOnOpen(controller);
    await BackupCoordinator.maybeBackupAfterEntry(controller);

    expect(autoBackupsIn(dir), isEmpty);
    expect(controller.backupSettings.lastBackupAt, isNull);
  });

  test('恢复包即使设置 onEntry 也不在记账后自动备份', () async {
    final dir = makeTempDir();
    final controller = await makeController();
    controller.setBackupDirectory(dir.path, 'temp');
    controller.setBackupFrequency(BackupFrequency.onEntry);

    await BackupCoordinator.maybeBackupOnOpen(controller);
    expect(autoBackupsIn(dir), isEmpty);

    await BackupCoordinator.maybeBackupAfterEntry(controller);
    expect(autoBackupsIn(dir), isEmpty);
    expect(controller.backupSettings.lastBackupAt, isNull);
  });

  test('未选目录时不产生备份', () async {
    final controller = await makeController();
    controller.setBackupFrequency(BackupFrequency.onOpen);
    // 无目录，应安全跳过而不抛异常。
    await BackupCoordinator.maybeBackupOnOpen(controller);
    expect(controller.backupSettings.lastBackupAt, isNull);
  });
}
