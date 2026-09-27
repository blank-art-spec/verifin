import 'dart:typed_data';

import 'raw_import.dart';
import 'text_format.dart';

/// 支付宝「交易明细」CSV：GBK 编码、前置多行说明，表头含「交易时间 / 收/支 / 金额 /
/// 交易分类 / 收付款方式 / 商品说明 / 交易对方」。「不计收支」（花呗还款、余额宝转入、
/// 理财收益等账户内部资金流转）跳过以免重复记账。基于用户真实导出样例，禁止编造格式。
ParsedImport parseAlipay(Uint8List bytes) {
  final rows = parseCsv(decodeGbkBytes(bytes));
  final headerIndex = findHeaderRow(
    rows,
    mustHave: const <String>['交易时间', '收/支'],
  );
  if (headerIndex == null) {
    throw const FormatException('未找到支付宝账单表头（交易时间/收/支），请确认选择的是支付宝导出的 CSV');
  }
  final cols = columnIndex(rows[headerIndex]);
  final records = <RawImportRecord>[];
  final errors = <ImportRowError>[];
  for (var i = headerIndex + 1; i < rows.length; i++) {
    final row = rows[i];
    final direction = cellAt(row, cols['收/支']);
    if (direction != '支出' && direction != '收入') {
      continue;
    }
    final account = firstSegment(cellAt(row, cols['收/付款方式']));
    final line = i + 1;
    final record = buildRecordFromStrings(
      date: cellAt(row, cols['交易时间']),
      type: direction,
      amount: cellAt(row, cols['金额']),
      category: cellAt(row, cols['交易分类']),
      account: account.isEmpty ? '支付宝' : account,
      merchant: cellAt(row, cols['交易对方']),
      sourceTransactionId: cellAt(row, cols['交易订单号']),
      note: joinNote(<String>[
        cellAt(row, cols['商品说明']),
        cellAt(row, cols['交易对方']),
      ]),
      sourceLine: line,
      onError: (message) =>
          errors.add(ImportRowError(line: line, message: message)),
    );
    if (record != null) {
      records.add(record);
    }
  }
  return ParsedImport(records: records, errors: errors);
}
