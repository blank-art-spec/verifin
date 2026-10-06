// 只读取 APK/AAB 的 ZIP 结构和资源，不安装、不执行应用。
// 防止 ABI 过滤误删 Flutter/OCR 库，或压缩资源未进入最终包。
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

const _timezoneAsset = 'assets/timezone/latest_all.tzf.gz';
const _requiredLibraries = <String>{
  'libapp.so',
  'libflutter.so',
  'libmlkit_google_ocr_pipeline.so',
};

Future<void> main(List<String> arguments) async {
  if (arguments.length < 2 ||
      arguments.length > 3 ||
      (arguments.length == 3 && arguments[2] != '--compressed')) {
    stderr.writeln(
      'Usage: dart scripts/verify_android_package.dart <apk|aab> <comma-separated-abis> [--compressed]',
    );
    exitCode = 64;
    return;
  }
  final artifact = File(arguments[0]);
  final bundle = artifact.path.endsWith('.aab');
  if (!bundle && !artifact.path.endsWith('.apk')) {
    stderr.writeln('Expected an APK or AAB file.');
    exitCode = 64;
    return;
  }
  final expected = arguments[1].split(',').map((abi) => abi.trim()).toSet();
  if (expected.isEmpty || expected.contains('')) {
    stderr.writeln('At least one ABI is required.');
    exitCode = 64;
    return;
  }
  final requireCompressed = arguments.length == 3;
  final archive = ZipDecoder().decodeBytes(await artifact.readAsBytes());
  final prefix = bundle ? 'base/' : '';
  final libraries = <String, Set<String>>{};
  final errors = <String>[];
  for (final file in archive.files) {
    if (!file.isFile ||
        !file.name.startsWith('${prefix}lib/') ||
        !file.name.endsWith('.so')) {
      continue;
    }
    final segments = file.name.substring(prefix.length).split('/');
    if (segments.length != 3) {
      errors.add('Unexpected native library path: ${file.name}');
      continue;
    }
    libraries.putIfAbsent(segments[1], () => <String>{}).add(segments[2]);
    if (requireCompressed && file.compression != CompressionType.deflate) {
      errors.add('Native library is not compressed: ${file.name}');
    }
  }
  for (final abi in libraries.keys) {
    if (!expected.contains(abi)) errors.add('Unexpected ABI: $abi');
  }
  for (final abi in expected) {
    for (final library in _requiredLibraries) {
      if (!(libraries[abi]?.contains(library) ?? false)) {
        errors.add('Missing native library: $abi/$library');
      }
    }
  }
  final timezone = archive.find(
    '${prefix}assets/flutter_assets/$_timezoneAsset',
  );
  final project = File.fromUri(Platform.script).parent.parent;
  final source = File('${project.path}/$_timezoneAsset');
  if (timezone == null || !timezone.isFile) {
    errors.add('Missing full timezone database asset.');
  } else if (sha256.convert(timezone.readBytes()!).toString() !=
      sha256.convert(await source.readAsBytes()).toString()) {
    errors.add('Packaged timezone asset differs from the verified source.');
  }
  if (errors.isNotEmpty) {
    for (final error in errors) {
      stderr.writeln(error);
    }
    exitCode = 1;
    return;
  }
  stdout.writeln(
    'Android package structure verified: ${artifact.path} (${expected.join(',')}).',
  );
}
