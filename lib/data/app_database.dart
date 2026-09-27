import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sqflite_common/sqlite_api.dart';

import 'database_factory.dart';

/// Veri Fin 本地 SQLite 数据库。负责建表、版本迁移与连接持有。
///
/// 具体的按类型读写在 [LedgerRepository]。数据库只承载「账目」类核心数据；
/// 偏好类小数据（主题、触感、面板配置、资产排序等）仍保留在 KV。
class AppDatabase {
  AppDatabase._(this.db);

  /// 底层 sqflite 连接，供仓储层执行 SQL。
  final Database db;

  static const String defaultDatabaseName = 'verifin.db';
  static const int schemaVersion = 18;

  /// 打开（或创建）数据库。测试通过 [factory]/[path] 注入 ffi 与内存路径；
  /// 真实平台留空则由 [resolveDatabaseFactory]/[resolveDatabasePath] 决定。
  static Future<AppDatabase> open({
    DatabaseFactory? factory,
    String? path,
  }) async {
    final resolvedFactory = factory ?? await resolveDatabaseFactory();
    final resolvedPath = path ?? await resolveDatabasePath(defaultDatabaseName);
    final database = await resolvedFactory.openDatabase(
      resolvedPath,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
    return AppDatabase._(database);
  }

  Future<void> close() => db.close();

  static Future<void> _onCreate(Database db, int version) async {
    final batch = db.batch();
    for (final statement in _schemaCurrent) {
      batch.execute(statement);
    }
    await batch.commit(noResult: true);
  }

  /// 版本迁移注册表：键 N 表示「升到 vN」的迁移段（v(N-1) → vN）。[_onUpgrade]
  /// 按 (oldVersion, newVersion] 升序逐段执行；段与段的顺序依赖（如 v10 去重
  /// 依赖 v7 已建 recurring_rules 表）由升序执行天然保证。
  ///
  /// 修改表结构 = 提升 [schemaVersion] + 同步 [_schemaCurrent] + 在此注册新段。
  /// **勿改动历史段**——存量用户升级时仍会按序经过它们。测试经 [migrations]
  /// 访问本表构造任意中间版本库（见 test/migration_matrix_test.dart 的迁移矩阵）。
  static final Map<int, Future<void> Function(Database db)> _migrations =
      <int, Future<void> Function(Database db)>{
        2: _migrateToV2,
        3: _migrateToV3,
        4: _migrateToV4,
        5: _migrateToV5,
        6: _migrateToV6,
        7: _migrateToV7,
        8: _migrateToV8,
        9: _migrateToV9,
        10: _migrateToV10,
        11: _migrateToV11,
        12: _migrateToV12,
        13: _migrateToV13,
        14: _migrateToV14,
        15: _migrateToV15,
        16: _migrateToV16,
        17: _migrateToV17,
        18: _migrateToV18,
      };

  /// 只读暴露迁移注册表，供迁移矩阵测试把库推进到任意中间版本。生产代码勿用。
  @visibleForTesting
  static Map<int, Future<void> Function(Database db)> get migrations =>
      Map<int, Future<void> Function(Database db)>.unmodifiable(_migrations);

  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    for (var version = oldVersion + 1; version <= newVersion; version++) {
      final migrate = _migrations[version];
      if (migrate == null) {
        // 提升了 schemaVersion 却忘了注册迁移段：宁可升级即刻失败，也不能
        // 静默跳段留下残缺 schema（后续读写会以更隐蔽的方式坏）。
        throw StateError('缺少升级到 v$version 的迁移段，需在 _migrations 注册');
      }
      await migrate(db);
    }
  }

  /// v1 → v2：分类支持多级树形结构，新增可空的 parent_id 列（顶级为 NULL）。
  static Future<void> _migrateToV2(Database db) async {
    await db.execute('ALTER TABLE categories ADD COLUMN parent_id TEXT');
  }

  /// v2 → v3：标签系统。新增 tags 表；交易新增可空 tag_ids 列（JSON 数组）。
  static Future<void> _migrateToV3(Database db) async {
    await db.execute('ALTER TABLE entries ADD COLUMN tag_ids TEXT');
    await db.execute('''
      CREATE TABLE tags (
        id TEXT PRIMARY KEY,
        label TEXT NOT NULL,
        sort_order INTEGER NOT NULL
      )
    ''');
  }

  /// v3 → v4：图片附件。独立表，按 entry_id 关联，data_url 存压缩 JPEG。
  static Future<void> _migrateToV4(Database db) async {
    await db.execute('''
      CREATE TABLE attachments (
        id TEXT PRIMARY KEY,
        entry_id TEXT NOT NULL,
        data_url TEXT NOT NULL,
        sort_order INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_attachments_entry ON attachments (entry_id)',
    );
  }

  /// v4 → v5：转账手续费。交易新增 fee 列，默认 0。
  static Future<void> _migrateToV5(Database db) async {
    await db.execute(
      'ALTER TABLE entries ADD COLUMN fee REAL NOT NULL DEFAULT 0',
    );
  }

  /// v5 → v6：报销/退款。交易新增待报销标记与已冲抵金额。
  static Future<void> _migrateToV6(Database db) async {
    await db.execute(
      'ALTER TABLE entries ADD COLUMN reimbursable INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(
      'ALTER TABLE entries ADD COLUMN refunded_amount REAL NOT NULL DEFAULT 0',
    );
  }

  /// v6 → v7：周期记账规则表。
  static Future<void> _migrateToV7(Database db) async {
    await db.execute(_recurringRulesTableV7);
  }

  /// v7 → v8：信用卡账单日/还款日（可选）。
  static Future<void> _migrateToV8(Database db) async {
    await db.execute('ALTER TABLE accounts ADD COLUMN statement_day INTEGER');
    await db.execute('ALTER TABLE accounts ADD COLUMN due_day INTEGER');
  }

  /// v8 → v9：按日预算维度。键为 `bookId:yyyy-MM-dd`。
  static Future<void> _migrateToV9(Database db) async {
    await db.execute(_dailyBudgetsTable);
  }

  /// v9 → v10：分类唯一性约束。历史/异构备份可能带入重复同名分类（「幽灵分类」根因），
  /// 先按 (label,type,IFNULL(parent_id,'')) 去重（交易/周期规则/子分类引用改指向保留者、
  /// 删掉重复），再建唯一索引。**必须先去重再建索引**，否则 CREATE UNIQUE INDEX 会因已有
  /// 重复行失败。悬空引用/孤儿 parentId 不违反唯一性、由 controller 载入时的 _healCategoryData
  /// 处理，此处只管重复行。
  static Future<void> _migrateToV10(Database db) async {
    // 真实库自 v1 起必有 categories/entries；recurring_rules 由 v7 段保证在前。
    // 判存在只为兼容迁移测试的最小桩库，并顺带抵御异常损坏的安装。
    if (await _tableExists(db, 'categories')) {
      await _dedupeCategories(db);
      await db.execute(_categoriesUniqueIndex);
    }
  }

  /// v10 → v11：完整卡号（信用卡/储蓄卡）与信用额度（信用卡/信用账户，可空）。
  /// 判 accounts 存在只为兼容迁移测试的最小桩库（真实库自 v1 起必有 accounts）。
  static Future<void> _migrateToV11(Database db) async {
    if (!await _tableExists(db, 'accounts')) {
      return;
    }
    await db.execute(
      "ALTER TABLE accounts ADD COLUMN card_number TEXT NOT NULL DEFAULT ''",
    );
    await db.execute('ALTER TABLE accounts ADD COLUMN credit_limit REAL');
  }

  /// v11 → v12：「后四位跟随完整卡号」开关持久化。旧账户默认 0（不跟随），
  /// 保留其可能手填的后四位、不因跟随空卡号被冲成空。
  static Future<void> _migrateToV12(Database db) async {
    if (!await _tableExists(db, 'accounts')) {
      return;
    }
    await db.execute(
      'ALTER TABLE accounts ADD COLUMN card_last4_follows INTEGER NOT NULL DEFAULT 0',
    );
  }

  /// v12 → v13：退款独立条目。交易新增 refund_of（指向原支出，退款条目专用）与
  /// settled_at（到账日期毫秒，NULL=待到账）。历史 refunded_amount 标量在 controller
  /// 载入时的 _syncRefundData() 里合成为已到账退款条目并作缓存重算，此处只加列。
  /// 判 entries 存在只为兼容迁移测试的最小桩库（真实库自 v1 起必有 entries）。
  static Future<void> _migrateToV13(Database db) async {
    if (!await _tableExists(db, 'entries')) {
      return;
    }
    await db.execute('ALTER TABLE entries ADD COLUMN refund_of TEXT');
    await db.execute('ALTER TABLE entries ADD COLUMN settled_at INTEGER');
  }

  /// v13 → v14：离线多币种。本位币/账户币种、交易与周期规则的冻结金额，以及
  /// 按账本和生效日维护的本地汇率表。旧数据的数字不换算，只按 CNY 原样重解释。
  static Future<void> _migrateToV14(Database db) async {
    if (await _tableExists(db, 'ledger_books')) {
      await db.execute(
        "ALTER TABLE ledger_books ADD COLUMN base_currency_code TEXT NOT NULL DEFAULT 'CNY'",
      );
      await db.execute(
        "ALTER TABLE ledger_books ADD COLUMN currency_setup_status TEXT NOT NULL DEFAULT 'legacyUnconfirmed'",
      );
    }
    if (await _tableExists(db, 'accounts')) {
      await db.execute(
        "ALTER TABLE accounts ADD COLUMN currency_code TEXT NOT NULL DEFAULT 'CNY'",
      );
    }
    if (await _tableExists(db, 'entries')) {
      await db.execute(
        "ALTER TABLE entries ADD COLUMN currency_code TEXT NOT NULL DEFAULT 'CNY'",
      );
      await db.execute('ALTER TABLE entries ADD COLUMN account_amount REAL');
      await db.execute('ALTER TABLE entries ADD COLUMN to_account_amount REAL');
      await db.execute(
        'ALTER TABLE entries ADD COLUMN base_amount REAL NOT NULL DEFAULT 0',
      );
      await db.execute(
        "ALTER TABLE entries ADD COLUMN conversion_source TEXT NOT NULL DEFAULT 'legacy'",
      );
      // 条件判断只为兼容历史迁移的最小桩库；真实 entries 自 v1 起字段完整。
      if (await _columnsExist(db, 'entries', const <String>[
        'account_id',
        'amount',
      ])) {
        await db.execute('''
          UPDATE entries SET account_amount =
            CASE WHEN account_id <> '' THEN amount ELSE NULL END
        ''');
      }
      if (await _columnsExist(db, 'entries', const <String>[
        'to_account_id',
        'amount',
      ])) {
        await db.execute('''
          UPDATE entries SET to_account_amount = CASE
            WHEN to_account_id IS NOT NULL AND to_account_id <> '' THEN amount
            ELSE NULL
          END
        ''');
      }
      if (await _columnsExist(db, 'entries', const <String>[
        'type',
        'amount',
      ])) {
        await db.execute('''
          UPDATE entries SET base_amount =
            CASE WHEN type = 'transfer' THEN 0 ELSE amount END
        ''');
      }
    }
    if (await _tableExists(db, 'recurring_rules')) {
      await db.execute(
        "ALTER TABLE recurring_rules ADD COLUMN currency_code TEXT NOT NULL DEFAULT 'CNY'",
      );
      await db.execute(
        'ALTER TABLE recurring_rules ADD COLUMN account_amount REAL',
      );
      await db.execute(
        'ALTER TABLE recurring_rules ADD COLUMN to_account_amount REAL',
      );
      await db.execute(
        'ALTER TABLE recurring_rules ADD COLUMN base_amount REAL NOT NULL DEFAULT 0',
      );
      await db.execute(
        "ALTER TABLE recurring_rules ADD COLUMN rate_policy TEXT NOT NULL DEFAULT 'fixedAmounts'",
      );
      await db.execute('''
        UPDATE recurring_rules
        SET account_amount = CASE WHEN account_id <> '' THEN amount ELSE NULL END,
            to_account_amount = CASE
              WHEN to_account_id IS NOT NULL AND to_account_id <> '' THEN amount
              ELSE NULL
            END,
            base_amount = CASE WHEN type = 'transfer' THEN 0 ELSE amount END
      ''');
    }
    await db.execute(_exchangeRatesTable);
    await db.execute(_exchangeRatesLookupIndex);
  }

  /// v14 → v15：账户分组回归纯文件夹语义，移除可自定义图标字段。
  /// 分组 id、名称、账本归属和排序全部原样保留；账户的 group_id 无需改写。
  static Future<void> _migrateToV15(Database db) async {
    if (!await _tableExists(db, 'account_groups')) {
      return;
    }
    await db.execute('DROP INDEX IF EXISTS idx_account_groups_book');
    await db.execute('ALTER TABLE account_groups RENAME TO account_groups_v14');
    await db.execute(_accountGroupsTableCurrent);
    await db.execute('''
      INSERT INTO account_groups (id, book_id, name, sort_order)
      SELECT id, book_id, name, sort_order FROM account_groups_v14
    ''');
    await db.execute('DROP TABLE account_groups_v14');
    await db.execute(_accountGroupsBookIndex);
  }

  /// v15 → v16：账户图标统一进入 SVG 目录。三个旧 code 只在此处
  /// 做一次性转换，后续渲染层不再保留历史兼容分支。
  static Future<void> _migrateToV16(Database db) async {
    if (!await _tableExists(db, 'accounts')) {
      return;
    }
    await db.execute('''
      UPDATE accounts SET icon_code = CASE icon_code
        WHEN 'alipay' THEN 'asset:payment_006'
        WHEN 'wechat' THEN 'asset:payment_004'
        WHEN 'folder' THEN 'wallet'
        ELSE icon_code
      END
      WHERE icon_code IN ('alipay', 'wechat', 'folder')
    ''');
  }

  /// v16 → v17：账务正确性第一批底层结构。
  ///
  /// 余额锚点、正式账单和还款分配各自独立建表；交易只追加核准状态与来源证据 JSON，
  /// 不复制正式账单流水。旧交易默认未核准且无来源证据，余额行为在未创建锚点时不变。
  static Future<void> _migrateToV17(Database db) async {
    if (await _tableExists(db, 'entries')) {
      // 迁移矩阵会把“当前结构的临时库”降写 user_version 后重跑历史迁移，
      // 因此逐列判存在，保证恢复中断迁移与测试降版本两种场景都可安全重入。
      if (!await _columnsExist(db, 'entries', <String>[
        'reconciliation_status',
      ])) {
        await db.execute(
          "ALTER TABLE entries ADD COLUMN reconciliation_status TEXT NOT NULL DEFAULT 'unverified'",
        );
      }
      if (!await _columnsExist(db, 'entries', <String>['source_records'])) {
        await db.execute('ALTER TABLE entries ADD COLUMN source_records TEXT');
      }
    }
    await db.execute(_balanceAnchorsTable);
    await db.execute(_balanceAnchorsLookupIndex);
    await db.execute(_billingStatementsTable);
    await db.execute(_billingStatementsLookupIndex);
    await db.execute(_billingStatementsSourceIndex);
    await db.execute(_statementRepaymentAllocationsTable);
    await db.execute(_statementRepaymentStatementIndex);
    await db.execute(_statementRepaymentEntryIndex);
  }

  /// v17 → v18：把共享额度、账期/还款规则和账期预算提升为独立信用主体。
  ///
  /// 每个旧信用账户先自动生成一个一对一主体，保持原有行为；用户随后可把不同币种
  /// 子账户挂到同一主体。旧 accounts 上的额度/日期列暂留作备份兼容镜像，新功能只以
  /// credit_accounts 为权威，避免一次迁移同时破坏旧备份的可读性。
  static Future<void> _migrateToV18(Database db) async {
    await db.execute(_creditAccountsTable);
    await db.execute(_creditAccountsBookIndex);
    if (!await _tableExists(db, 'accounts')) return;
    if (!await _columnsExist(db, 'accounts', <String>['credit_account_id'])) {
      await db.execute(
        'ALTER TABLE accounts ADD COLUMN credit_account_id TEXT',
      );
    }
    await db.execute('''
      INSERT OR IGNORE INTO credit_accounts (
        id, book_id, name, institution, card_last4, currency_code,
        credit_limit, statement_day, due_rule_type, due_day,
        days_after_statement, cycle_budget, sort_order
      )
      SELECT
        'credit-account-' || id, book_id, name, '', card_last4,
        currency_code, credit_limit, statement_day, 'fixedDay', due_day,
        NULL, NULL, sort_order
      FROM accounts
      WHERE type IN ('creditCard', 'creditAccount')
    ''');
    await db.execute('''
      UPDATE accounts
      SET credit_account_id = 'credit-account-' || id
      WHERE type IN ('creditCard', 'creditAccount')
        AND credit_account_id IS NULL
    ''');
  }

  static Future<bool> _tableExists(Database db, String name) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name = ?",
      <Object?>[name],
    );
    return rows.isNotEmpty;
  }

  static Future<bool> _columnsExist(
    Database db,
    String table,
    List<String> names,
  ) async {
    final rows = await db.rawQuery('PRAGMA table_info($table)');
    final existing = rows.map((row) => row['name']).whereType<String>().toSet();
    return names.every(existing.contains);
  }

  /// 合并重复分类：保留每个 (label,type,IFNULL(parent_id,'')) 组内 rowid 最小的一条，
  /// 其余的交易/周期规则/子分类 parent_id 引用改指向保留者后删除。仅在对应表存在时改写引用
  /// （真实库都在，判存在是为兼容最小桩库）。
  static Future<void> _dedupeCategories(Database db) async {
    await db.execute('''
      CREATE TEMP TABLE _cat_keep AS
        SELECT id AS keep_id, label, type, IFNULL(parent_id, '') AS pkey
        FROM categories
        WHERE rowid IN (
          SELECT MIN(rowid) FROM categories
          GROUP BY label, type, IFNULL(parent_id, '')
        )
    ''');
    await db.execute('''
      CREATE TEMP TABLE _cat_map AS
        SELECT c.id AS old_id, k.keep_id AS keep_id
        FROM categories c
        JOIN _cat_keep k
          ON c.label = k.label AND c.type = k.type
          AND IFNULL(c.parent_id, '') = k.pkey
    ''');
    if (await _tableExists(db, 'entries')) {
      await db.execute('''
        UPDATE entries
          SET category_id =
            (SELECT keep_id FROM _cat_map WHERE old_id = entries.category_id)
          WHERE category_id IN
            (SELECT old_id FROM _cat_map WHERE old_id <> keep_id)
      ''');
    }
    if (await _tableExists(db, 'recurring_rules')) {
      await db.execute('''
        UPDATE recurring_rules
          SET category_id =
            (SELECT keep_id FROM _cat_map WHERE old_id = recurring_rules.category_id)
          WHERE category_id IN
            (SELECT old_id FROM _cat_map WHERE old_id <> keep_id)
      ''');
    }
    await db.execute('''
      UPDATE categories
        SET parent_id =
          (SELECT keep_id FROM _cat_map WHERE old_id = categories.parent_id)
        WHERE parent_id IN (SELECT old_id FROM _cat_map WHERE old_id <> keep_id)
    ''');
    await db.execute('''
      DELETE FROM categories
        WHERE id IN (SELECT old_id FROM _cat_map WHERE old_id <> keep_id)
    ''');
    await db.execute('DROP TABLE _cat_map');
    await db.execute('DROP TABLE _cat_keep');
  }

  /// 分类唯一约束：同一父级（顶级按空串归一）下不允许同 label+type 的重复分类。
  static const String _categoriesUniqueIndex =
      "CREATE UNIQUE INDEX idx_categories_unique "
      "ON categories (label, type, IFNULL(parent_id, ''))";

  static const String _dailyBudgetsTable = '''
    CREATE TABLE daily_budgets (
      scope_key TEXT PRIMARY KEY,
      amount REAL NOT NULL
    )
  ''';

  /// v7 历史建表语句冻结副本。后续字段只能在新迁移段追加。
  static const String _recurringRulesTableV7 = '''
    CREATE TABLE recurring_rules (
      id TEXT PRIMARY KEY,
      book_id TEXT NOT NULL,
      type TEXT NOT NULL,
      amount REAL NOT NULL,
      category_id TEXT NOT NULL,
      account_id TEXT NOT NULL,
      to_account_id TEXT,
      note TEXT NOT NULL,
      frequency TEXT NOT NULL,
      start_date INTEGER NOT NULL,
      next_run_date INTEGER NOT NULL,
      active INTEGER NOT NULL,
      sort_order INTEGER NOT NULL
    )
  ''';

  static const String _recurringRulesTableCurrent = '''
    CREATE TABLE recurring_rules (
      id TEXT PRIMARY KEY,
      book_id TEXT NOT NULL,
      type TEXT NOT NULL,
      amount REAL NOT NULL,
      currency_code TEXT NOT NULL DEFAULT 'CNY',
      account_amount REAL,
      to_account_amount REAL,
      base_amount REAL NOT NULL DEFAULT 0,
      rate_policy TEXT NOT NULL DEFAULT 'fixedAmounts',
      category_id TEXT NOT NULL,
      account_id TEXT NOT NULL,
      to_account_id TEXT,
      note TEXT NOT NULL,
      frequency TEXT NOT NULL,
      start_date INTEGER NOT NULL,
      next_run_date INTEGER NOT NULL,
      active INTEGER NOT NULL,
      sort_order INTEGER NOT NULL
    )
  ''';

  static const String _exchangeRatesTable = '''
    CREATE TABLE exchange_rates (
      id TEXT PRIMARY KEY,
      book_id TEXT NOT NULL,
      base_currency_code TEXT NOT NULL,
      currency_code TEXT NOT NULL,
      effective_date TEXT NOT NULL,
      rate_to_base REAL NOT NULL,
      source TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      UNIQUE (book_id, base_currency_code, currency_code, effective_date)
    )
  ''';

  static const String _exchangeRatesLookupIndex =
      'CREATE INDEX idx_exchange_rates_book_currency_date '
      'ON exchange_rates (book_id, currency_code, effective_date)';

  static const String _balanceAnchorsTable = '''
    CREATE TABLE IF NOT EXISTS balance_anchors (
      id TEXT PRIMARY KEY,
      book_id TEXT NOT NULL,
      account_id TEXT NOT NULL,
      effective_at INTEGER NOT NULL,
      balance REAL NOT NULL,
      created_at INTEGER NOT NULL,
      note TEXT NOT NULL
    )
  ''';

  static const String _balanceAnchorsLookupIndex =
      'CREATE INDEX IF NOT EXISTS idx_balance_anchors_account_date '
      'ON balance_anchors (account_id, effective_at DESC)';

  static const String _billingStatementsTable = '''
    CREATE TABLE IF NOT EXISTS billing_statements (
      id TEXT PRIMARY KEY,
      book_id TEXT NOT NULL,
      account_id TEXT NOT NULL,
      statement_date INTEGER NOT NULL,
      period_start INTEGER NOT NULL,
      period_end INTEGER NOT NULL,
      statement_amount REAL NOT NULL,
      minimum_payment REAL NOT NULL,
      due_date INTEGER NOT NULL,
      paid_amount REAL NOT NULL,
      status TEXT NOT NULL,
      currency_code TEXT NOT NULL,
      source_id TEXT NOT NULL,
      source_statement_id TEXT NOT NULL,
      note TEXT NOT NULL
    )
  ''';

  static const String _billingStatementsLookupIndex =
      'CREATE INDEX IF NOT EXISTS idx_billing_statements_account_date '
      'ON billing_statements (account_id, statement_date DESC)';

  static const String _billingStatementsSourceIndex =
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_billing_statements_source '
      'ON billing_statements (book_id, account_id, source_id, source_statement_id) '
      "WHERE source_id <> '' AND source_statement_id <> ''";

  static const String _statementRepaymentAllocationsTable = '''
    CREATE TABLE IF NOT EXISTS statement_repayment_allocations (
      id TEXT PRIMARY KEY,
      book_id TEXT NOT NULL,
      statement_id TEXT NOT NULL,
      repayment_entry_id TEXT NOT NULL,
      amount REAL NOT NULL,
      created_at INTEGER NOT NULL,
      UNIQUE (statement_id, repayment_entry_id)
    )
  ''';

  static const String _statementRepaymentStatementIndex =
      'CREATE INDEX IF NOT EXISTS idx_statement_allocations_statement '
      'ON statement_repayment_allocations (statement_id)';

  static const String _statementRepaymentEntryIndex =
      'CREATE INDEX IF NOT EXISTS idx_statement_allocations_entry '
      'ON statement_repayment_allocations (repayment_entry_id)';

  static const String _creditAccountsTable = '''
    CREATE TABLE IF NOT EXISTS credit_accounts (
      id TEXT PRIMARY KEY,
      book_id TEXT NOT NULL,
      name TEXT NOT NULL,
      institution TEXT NOT NULL,
      card_last4 TEXT NOT NULL,
      currency_code TEXT NOT NULL,
      credit_limit REAL,
      statement_day INTEGER,
      due_rule_type TEXT NOT NULL,
      due_day INTEGER,
      days_after_statement INTEGER,
      cycle_budget REAL,
      sort_order INTEGER NOT NULL
    )
  ''';

  static const String _creditAccountsBookIndex =
      'CREATE INDEX IF NOT EXISTS idx_credit_accounts_book '
      'ON credit_accounts (book_id, sort_order)';

  static const String _accountGroupsTableCurrent = '''
    CREATE TABLE account_groups (
      id TEXT PRIMARY KEY,
      book_id TEXT NOT NULL,
      name TEXT NOT NULL,
      sort_order INTEGER NOT NULL
    )
  ''';

  static const String _accountGroupsBookIndex =
      'CREATE INDEX idx_account_groups_book ON account_groups (book_id)';

  /// 当前完整建表语句（供全新数据库 onCreate 用）。字段命名用 snake_case；
  /// 布尔存 0/1；时间存毫秒时间戳。已含历次迁移引入的列/表（parent_id、tags 等）。
  static const List<String> _schemaCurrent = <String>[
    '''
    CREATE TABLE ledger_books (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      is_default INTEGER NOT NULL,
      base_currency_code TEXT NOT NULL DEFAULT 'CNY',
      currency_setup_status TEXT NOT NULL DEFAULT 'legacyUnconfirmed',
      sort_order INTEGER NOT NULL
    )
    ''',
    '''
    CREATE TABLE entries (
      id TEXT PRIMARY KEY,
      book_id TEXT NOT NULL,
      type TEXT NOT NULL,
      amount REAL NOT NULL,
      currency_code TEXT NOT NULL DEFAULT 'CNY',
      account_amount REAL,
      to_account_amount REAL,
      base_amount REAL NOT NULL DEFAULT 0,
      conversion_source TEXT NOT NULL DEFAULT 'legacy',
      category_id TEXT NOT NULL,
      account_id TEXT NOT NULL,
      to_account_id TEXT,
      note TEXT NOT NULL,
      occurred_at INTEGER NOT NULL,
      tag_ids TEXT,
      fee REAL NOT NULL DEFAULT 0,
      reimbursable INTEGER NOT NULL DEFAULT 0,
      refunded_amount REAL NOT NULL DEFAULT 0,
      refund_of TEXT,
      settled_at INTEGER,
      reconciliation_status TEXT NOT NULL DEFAULT 'unverified',
      source_records TEXT
    )
    ''',
    'CREATE INDEX idx_entries_book ON entries (book_id)',
    'CREATE INDEX idx_entries_occurred ON entries (occurred_at)',
    '''
    CREATE TABLE accounts (
      id TEXT PRIMARY KEY,
      book_id TEXT NOT NULL,
      name TEXT NOT NULL,
      type TEXT NOT NULL,
      group_id TEXT,
      initial_balance REAL NOT NULL,
      currency_code TEXT NOT NULL DEFAULT 'CNY',
      icon_code TEXT NOT NULL,
      note TEXT NOT NULL,
      include_in_assets INTEGER NOT NULL,
      hidden INTEGER NOT NULL,
      card_last4 TEXT NOT NULL,
      card_number TEXT NOT NULL DEFAULT '',
      card_last4_follows INTEGER NOT NULL DEFAULT 1,
      credit_limit REAL,
      sort_order INTEGER NOT NULL,
      statement_day INTEGER,
      due_day INTEGER,
      credit_account_id TEXT
    )
    ''',
    'CREATE INDEX idx_accounts_book ON accounts (book_id)',
    _accountGroupsTableCurrent,
    _accountGroupsBookIndex,
    '''
    CREATE TABLE categories (
      id TEXT PRIMARY KEY,
      label TEXT NOT NULL,
      type TEXT NOT NULL,
      icon_code TEXT NOT NULL,
      sort_order INTEGER NOT NULL,
      parent_id TEXT
    )
    ''',
    _categoriesUniqueIndex,
    '''
    CREATE TABLE monthly_budgets (
      scope_key TEXT PRIMARY KEY,
      amount REAL NOT NULL
    )
    ''',
    '''
    CREATE TABLE category_budgets (
      scope_key TEXT PRIMARY KEY,
      amount REAL NOT NULL
    )
    ''',
    _dailyBudgetsTable,
    '''
    CREATE TABLE tags (
      id TEXT PRIMARY KEY,
      label TEXT NOT NULL,
      sort_order INTEGER NOT NULL
    )
    ''',
    '''
    CREATE TABLE attachments (
      id TEXT PRIMARY KEY,
      entry_id TEXT NOT NULL,
      data_url TEXT NOT NULL,
      sort_order INTEGER NOT NULL
    )
    ''',
    'CREATE INDEX idx_attachments_entry ON attachments (entry_id)',
    _recurringRulesTableCurrent,
    _exchangeRatesTable,
    _exchangeRatesLookupIndex,
    _balanceAnchorsTable,
    _balanceAnchorsLookupIndex,
    _billingStatementsTable,
    _billingStatementsLookupIndex,
    _billingStatementsSourceIndex,
    _statementRepaymentAllocationsTable,
    _statementRepaymentStatementIndex,
    _statementRepaymentEntryIndex,
    _creditAccountsTable,
    _creditAccountsBookIndex,
  ];
}
