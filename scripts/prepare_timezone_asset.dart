// 从已解析的 timezone 依赖生成完整数据库的无损压缩资源。
// 不裁掉历史时区、别名或过渡规则；--check 只比对数据，不修改资源。
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  if (arguments.isNotEmpty &&
      (arguments.length != 1 || arguments.single != '--check')) {
    stderr.writeln('Usage: dart scripts/prepare_timezone_asset.dart [--check]');
    exitCode = 64;
    return;
  }
  final checkOnly = arguments.isNotEmpty;
  final project = File.fromUri(Platform.script).parent.parent;
  final packageConfig = File('${project.path}/.dart_tool/package_config.json');
  final config =
      jsonDecode(await packageConfig.readAsString()) as Map<String, dynamic>;
  final timezone = (config['packages'] as List<dynamic>)
      .cast<Map<String, dynamic>>()
      .singleWhere((package) => package['name'] == 'timezone');
  final rootUri = timezone['rootUri'] as String;
  final packageRoot = packageConfig.uri.resolve(
    rootUri.endsWith('/') ? rootUri : '$rootUri/',
  );
  final source = File.fromUri(packageRoot.resolve('lib/data/latest_all.tzf'));
  final original = await source.readAsBytes();
  final asset = File('${project.path}/assets/timezone/latest_all.tzf.gz');
  if (checkOnly) {
    if (!await asset.exists()) {
      stderr.writeln(
        'Missing timezone asset. Run dart scripts/prepare_timezone_asset.dart.',
      );
      exitCode = 1;
      return;
    }
    final restored = gzip.decode(await asset.readAsBytes());
    var matches = restored.length == original.length;
    if (matches) {
      for (var index = 0; index < original.length; index++) {
        if (restored[index] != original[index]) {
          matches = false;
          break;
        }
      }
    }
    if (!matches) {
      stderr.writeln(
        'Timezone asset differs from the resolved dependency. Regenerate and review it.',
      );
      exitCode = 1;
      return;
    }
    stdout.writeln(
      'Timezone asset matches the full dependency database (${original.length} bytes).',
    );
    return;
  }
  final compressed = GZipCodec(level: 9).encode(original);
  await asset.parent.create(recursive: true);
  await asset.writeAsBytes(compressed, flush: true);
  stdout.writeln(
    'Full timezone database: ${original.length} → ${compressed.length} bytes.',
  );
}
