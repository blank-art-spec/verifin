/// 标签维度的选择约束。单选维度在同一笔交易中最多保留一个标签。
enum TagSelectionMode { single, multiple }

/// 标签维度来源；系统维度使用稳定 id，自定义维度由用户创建。
enum TagGroupType { system, custom }

/// 标签维度。名称只用于展示；关联始终使用稳定的 [id]。
class TagGroup {
  const TagGroup({
    required this.id,
    required this.name,
    this.type = TagGroupType.custom,
    this.selectionMode = TagSelectionMode.multiple,
    this.iconCode,
    this.sortOrder = 0,
  });

  final String id;
  final String name;
  final TagGroupType type;
  final TagSelectionMode selectionMode;
  final String? iconCode;
  final int sortOrder;

  /// 复制维度并替换指定属性；未传的属性沿用原值。
  TagGroup copyWith({
    String? name,
    TagSelectionMode? selectionMode,
    int? sortOrder,
  }) {
    return TagGroup(
      id: id,
      name: name ?? this.name,
      type: type,
      selectionMode: selectionMode ?? this.selectionMode,
      iconCode: iconCode,
      sortOrder: sortOrder ?? this.sortOrder,
    );
  }

  /// 导出完整维度信息，供备份恢复和数据往返使用。
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'type': type.name,
    'selectionMode': selectionMode.name,
    if (iconCode != null) 'iconCode': iconCode,
    'sortOrder': sortOrder,
  };

  /// 从备份读取维度；未知枚举值安全回退到自定义、多选。
  static TagGroup fromJson(Map<String, Object?> json) => TagGroup(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    type:
        TagGroupType.values.where((v) => v.name == json['type']).firstOrNull ??
        TagGroupType.custom,
    selectionMode:
        TagSelectionMode.values
            .where((v) => v.name == json['selectionMode'])
            .firstOrNull ??
        TagSelectionMode.multiple,
    iconCode: json['iconCode'] as String?,
    sortOrder: (json['sortOrder'] as num?)?.toInt() ?? 0,
  );
}

/// 系统维度是账本无关的标签字典；固定 id 保证旧备份与新安装使用相同关联。
const List<TagGroup> defaultTagGroups = <TagGroup>[
  TagGroup(
    id: 'project',
    name: '项目',
    type: TagGroupType.system,
    selectionMode: TagSelectionMode.single,
  ),
  TagGroup(
    id: 'scene',
    name: '场景',
    type: TagGroupType.system,
    selectionMode: TagSelectionMode.single,
    sortOrder: 1,
  ),
  TagGroup(
    id: 'purpose',
    name: '用途',
    type: TagGroupType.system,
    selectionMode: TagSelectionMode.single,
    sortOrder: 2,
  ),
  TagGroup(id: 'person', name: '对象', type: TagGroupType.system, sortOrder: 3),
  TagGroup(
    id: 'place',
    name: '地点',
    type: TagGroupType.system,
    selectionMode: TagSelectionMode.single,
    sortOrder: 4,
  ),
  TagGroup(id: 'custom', name: '自定义', type: TagGroupType.system, sortOrder: 5),
];

/// 旧数据出现「项目类型:…」时才创建此自定义维度，不占用新用户的默认入口。
const TagGroup legacyProjectTypeGroup = TagGroup(
  id: 'project_type',
  name: '项目类型',
  selectionMode: TagSelectionMode.single,
  sortOrder: 6,
);

/// 将旧式「维度:值」标签拆开。未知前缀和普通标签保持原文，避免误改用户数据。
({String groupId, String label}) parseLegacyTagLabel(String label) {
  final separator = label.indexOf(':');
  if (separator <= 0 || separator == label.length - 1) {
    return (groupId: 'custom', label: label);
  }
  final prefix = label.substring(0, separator).trim();
  const groups = <String, String>{
    '项目': 'project',
    '项目类型': 'project_type',
    '场景': 'scene',
    '用途': 'purpose',
    '对象': 'person',
    '地点': 'place',
  };
  final groupId = groups[prefix];
  if (groupId == null) return (groupId: 'custom', label: label);
  return (groupId: groupId, label: label.substring(separator + 1).trim());
}

/// CSV 固定标签列缺少独立维度字段，内置维度以兼容前缀输出，导回时可还原。
/// 自定义维度需使用完整 JSON 备份迁移，CSV 仅保留标签原文。
String tagPortableLabel(Tag tag) => switch (tag.groupId) {
  'project' => '项目:${tag.label}',
  'project_type' => '项目类型:${tag.label}',
  'scene' => '场景:${tag.label}',
  'purpose' => '用途:${tag.label}',
  'person' => '对象:${tag.label}',
  'place' => '地点:${tag.label}',
  _ => tag.label,
};

/// 沿合并链解析稳定 [id] 在 [tags] 中的最终标签。
/// 找不到标签时返回 null；断链或循环时返回原标签，避免无限循环。
Tag? canonicalTagOf(String id, Iterable<Tag> tags) {
  final byId = <String, Tag>{for (final tag in tags) tag.id: tag};
  final original = byId[id];
  if (original == null) return null;
  var current = original;
  final seen = <String>{};
  while (current.mergedIntoId != null && seen.add(current.id)) {
    final next = byId[current.mergedIntoId];
    if (next == null) break;
    current = next;
  }
  return seen.contains(current.id) ? original : current;
}

/// 与交易以 id 多对多关联；[groupId] 表达维度，旧交易的 tagIds 无需重写。
class Tag {
  const Tag({
    required this.id,
    required this.label,
    this.groupId = 'custom',
    this.parentId,
    this.iconCode,
    this.sortOrder = 0,
    this.archived = false,
    this.aliases = const <String>[],
    this.mergedIntoId,
  });

  final String id;
  final String groupId;
  final String label;
  final String? parentId;
  final String? iconCode;
  final int sortOrder;
  final bool archived;
  final List<String> aliases;
  final String? mergedIntoId;

  /// 复制标签并替换传入的字段；未传字段保持原值，交易关联的 id 不变。
  /// [mergedIntoId] 是合并目标，调用方须保证与当前标签同维度且无循环。
  Tag copyWith({
    String? label,
    String? groupId,
    int? sortOrder,
    bool? archived,
    List<String>? aliases,
    String? mergedIntoId,
  }) => Tag(
    id: id,
    label: label ?? this.label,
    groupId: groupId ?? this.groupId,
    parentId: parentId,
    iconCode: iconCode,
    sortOrder: sortOrder ?? this.sortOrder,
    archived: archived ?? this.archived,
    aliases: aliases ?? this.aliases,
    mergedIntoId: mergedIntoId ?? this.mergedIntoId,
  );

  /// 导出结构化字段，历史备份读取仍由 [fromJson] 兼容。
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'groupId': groupId,
    'label': label,
    if (parentId != null) 'parentId': parentId,
    if (iconCode != null) 'iconCode': iconCode,
    'sortOrder': sortOrder,
    'archived': archived,
    if (aliases.isNotEmpty) 'aliases': aliases,
    if (mergedIntoId != null) 'mergedIntoId': mergedIntoId,
  };

  /// 解析新旧备份；旧格式按已知中文前缀自动归入系统维度。
  static Tag fromJson(Map<String, Object?> json) {
    final rawLabel = json['label'] as String? ?? '未命名标签';
    final legacy = parseLegacyTagLabel(rawLabel);
    final explicitGroupId = json['groupId'] as String?;
    // 新备份为了兼容旧版，也把内置维度写成「维度:名称」。同组前缀在新版
    // 读取时需去掉；旧版曾保存为 custom 的「项目类型」也升级为独立维度。
    final migrateProjectType =
        legacy.groupId == 'project_type' && explicitGroupId == 'custom';
    final groupId = migrateProjectType
        ? 'project_type'
        : explicitGroupId ?? legacy.groupId;
    final label =
        explicitGroupId == null ||
            explicitGroupId == legacy.groupId ||
            migrateProjectType
        ? legacy.label
        : rawLabel;
    return Tag(
      id: json['id'] as String,
      groupId: groupId,
      label: label,
      parentId: json['parentId'] as String?,
      iconCode: json['iconCode'] as String?,
      sortOrder: (json['sortOrder'] as num?)?.toInt() ?? 0,
      archived: json['archived'] as bool? ?? false,
      aliases:
          (json['aliases'] as List?)?.whereType<String>().toList() ??
          const <String>[],
      mergedIntoId: json['mergedIntoId'] as String?,
    );
  }
}

/// 独立项目的生命周期；归档项目仍参与历史统计。
enum ProjectStatus { active, completed, archived }

/// 项目实体的元数据。[tagId] 是交易侧稳定关联键，项目本身保存预算和周期。
class Project {
  const Project({
    required this.id,
    required this.bookId,
    required this.tagId,
    required this.name,
    this.startDate,
    this.endDate,
    this.budget,
    this.status = ProjectStatus.active,
    this.note = '',
  });

  final String id;
  final String bookId;
  final String tagId;
  final String name;
  final DateTime? startDate;
  final DateTime? endDate;
  final double? budget;
  final ProjectStatus status;
  final String note;

  /// 复制项目并更新可编辑元数据；交易关联键 [tagId] 保持稳定。
  /// [startDate] / [endDate] 是活动边界，[budget] 使用账本本位币，
  /// [status] 控制是否归档，[note] 保存用户备注；传 null 表示沿用原值。
  Project copyWith({
    String? name,
    DateTime? startDate,
    DateTime? endDate,
    double? budget,
    ProjectStatus? status,
    String? note,
  }) => Project(
    id: id,
    bookId: bookId,
    tagId: tagId,
    name: name ?? this.name,
    startDate: startDate ?? this.startDate,
    endDate: endDate ?? this.endDate,
    budget: budget ?? this.budget,
    status: status ?? this.status,
    note: note ?? this.note,
  );

  /// 把项目元数据写入账本备份；金额使用账本本位币。
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'bookId': bookId,
    'tagId': tagId,
    'name': name,
    if (startDate != null) 'startDate': startDate!.toIso8601String(),
    if (endDate != null) 'endDate': endDate!.toIso8601String(),
    if (budget != null) 'budget': budget,
    'status': status.name,
    'note': note,
  };

  /// 从备份恢复项目；未知状态回退进行中，旧备份缺项目由控制器迁移。
  static Project fromJson(Map<String, Object?> json) => Project(
    id: json['id'] as String,
    bookId: json['bookId'] as String,
    tagId: json['tagId'] as String,
    name: json['name'] as String? ?? '',
    startDate: DateTime.tryParse(json['startDate'] as String? ?? ''),
    endDate: DateTime.tryParse(json['endDate'] as String? ?? ''),
    budget: (json['budget'] as num?)?.toDouble(),
    status:
        ProjectStatus.values
            .where((value) => value.name == json['status'])
            .firstOrNull ??
        ProjectStatus.active,
    note: json['note'] as String? ?? '',
  );
}

/// 一键套用的标签组合；模板随账本备份，标签仍引用全局稳定 id。
class TagTemplate {
  const TagTemplate({
    required this.id,
    required this.bookId,
    required this.name,
    required this.tagIds,
  });

  final String id;
  final String bookId;
  final String name;
  final List<String> tagIds;

  /// 导出模板和引用的标签 id，供跨设备恢复。
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'bookId': bookId,
    'name': name,
    'tagIds': tagIds,
  };

  /// 从备份恢复模板；不存在的标签由控制器在导入校验时拒绝。
  static TagTemplate fromJson(Map<String, Object?> json) => TagTemplate(
    id: json['id'] as String,
    bookId: json['bookId'] as String,
    name: json['name'] as String? ?? '',
    tagIds:
        (json['tagIds'] as List?)?.whereType<String>().toList() ??
        const <String>[],
  );
}
