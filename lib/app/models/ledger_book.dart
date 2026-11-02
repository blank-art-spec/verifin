/// 账本模型。多账本隔离的锚点：交易/账户/分组都带 bookId。
library;

import 'currency.dart';
import '../../l10n/app_localizations.dart';

const String defaultLedgerBookId = 'default';

/// 账本的默认录入用途；它只决定入口，不限制账本可以保存的账户或投资记录。
enum LedgerBookType {
  normal,
  investment;

  /// 根据应用当前语言取得展示名称；[l10n] 为页面提供的本地化资源。
  String label(AppLocalizations l10n) => switch (this) {
    normal => l10n.ledgerBookTypeNormal,
    investment => l10n.ledgerBookTypeInvestment,
  };

  /// 解析持久化值。[value] 缺失时兼容旧账本为普通；显式非法值拒绝读取，
  /// 避免损坏的备份静默改变新增交易入口。存储值与显示名称无关。
  static LedgerBookType fromStorage(Object? value) {
    if (value == null) return LedgerBookType.normal;
    for (final type in values) {
      if (type.name == value) return type;
    }
    throw const FormatException('账本类型不正确');
  }
}

class LedgerBook {
  const LedgerBook({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.isDefault,
    this.baseCurrencyCode = defaultCurrencyCode,
    this.currencySetupStatus = CurrencySetupStatus.confirmed,
    this.bookType = LedgerBookType.normal,
  });

  final String id;
  final String name;
  final DateTime createdAt;
  final bool isDefault;
  final String baseCurrencyCode;
  final CurrencySetupStatus currencySetupStatus;
  final LedgerBookType bookType;

  /// 复制账本并替换指定字段；未传入的属性保留，类型变化不重新解释财务数据。
  LedgerBook copyWith({
    String? id,
    String? name,
    DateTime? createdAt,
    String? baseCurrencyCode,
    CurrencySetupStatus? currencySetupStatus,
    LedgerBookType? bookType,
  }) {
    return LedgerBook(
      id: id ?? this.id,
      name: name ?? this.name,
      createdAt: createdAt ?? this.createdAt,
      isDefault: isDefault,
      baseCurrencyCode: baseCurrencyCode ?? this.baseCurrencyCode,
      currencySetupStatus: currencySetupStatus ?? this.currencySetupStatus,
      bookType: bookType ?? this.bookType,
    );
  }

  /// 导出可迁移账本资料；[bookType] 使用稳定枚举值，不保存翻译后的名称。
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'name': name,
      'createdAt': createdAt.toIso8601String(),
      'isDefault': isDefault,
      'baseCurrencyCode': baseCurrencyCode,
      'currencySetupStatus': currencySetupStatus.name,
      'bookType': bookType.name,
    };
  }

  /// 由备份 [json] 恢复账本，缺失类型的旧备份统一为普通，不按名称或账户猜测。
  static LedgerBook fromJson(Map<String, Object?> json) {
    if (json.containsKey('bookType') && json['bookType'] == null) {
      throw const FormatException('账本类型不正确');
    }
    final id = json['id'] as String? ?? defaultLedgerBookId;
    return LedgerBook(
      id: id,
      name: json['name'] as String? ?? '日常账本',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      isDefault: json['isDefault'] as bool? ?? id == defaultLedgerBookId,
      bookType: LedgerBookType.fromStorage(json['bookType']),
      baseCurrencyCode:
          (json['baseCurrencyCode'] as String? ?? defaultCurrencyCode)
              .toUpperCase(),
      // 无字段的是 v1 备份，必须让用户确认数字原本代表什么币种。
      currencySetupStatus: json.containsKey('currencySetupStatus')
          ? CurrencySetupStatus.fromStorage(
              json['currencySetupStatus'] as String?,
            )
          : CurrencySetupStatus.legacyUnconfirmed,
    );
  }
}
