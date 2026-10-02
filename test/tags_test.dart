import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/report_analysis.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/test_harness.dart';

void main() {
  useTestDatabases();

  test('addTag 去重、renameTag、reorderTags', () async {
    final controller = await makeController();
    final a = controller.addTag('工作');
    final b = controller.addTag('  工作  '); // 去空白后重复，返回同一 id
    expect(a, isNotNull);
    expect(b, a);
    expect(controller.tags.length, 1);

    controller.addTag('旅行');
    expect(controller.tags.map((t) => t.label).toList(), <String>['工作', '旅行']);
    controller.reorderTags(1, 0);
    expect(controller.tags.map((t) => t.label).toList(), <String>['旅行', '工作']);

    expect(await controller.renameTag(a!, '上班'), isTrue);
    expect(controller.tagById(a)!.label, '上班');
    controller.dispose();
  });

  test('deleteTag 同时从交易移除引用', () async {
    final controller = await makeController();
    final tagId = controller.addTag('报销')!;
    controller.addEntry(
      LedgerEntry(
        id: 'e1',
        bookId: controller.activeBook.id,
        type: EntryType.expense,
        amount: 30,
        categoryId: 'dining',
        accountId: 'cash',
        note: '',
        occurredAt: DateTime(2026, 7, 4),
        tagIds: <String>[tagId],
      ),
    );
    expect(controller.tagUsageCount(tagId), 1);

    await controller.deleteTag(tagId);
    expect(controller.tagById(tagId), isNull);
    expect(controller.entries.single.tagIds, isEmpty);
    controller.dispose();
  });

  test('标签与交易标签随导出/导入往返', () async {
    final source = await makeController();
    final tagId = source.addTag('必要开销')!;
    source.addEntry(
      LedgerEntry(
        id: 'e1',
        bookId: source.activeBook.id,
        type: EntryType.expense,
        amount: 12,
        categoryId: 'dining',
        accountId: 'cash',
        note: '',
        occurredAt: DateTime(2026, 7, 4),
        tagIds: <String>[tagId],
      ),
    );
    final backup = source.exportDataJson();
    source.dispose();

    final target = await makeController();
    target.importDataJson(backup);
    expect(target.tags.map((t) => t.label), contains('必要开销'));
    expect(target.entries.single.tagIds, <String>[tagId]);
    target.dispose();
  });

  test('标签写入仓储并被同 store 的新控制器读回', () async {
    final store = LocalKeyValueStore();
    final first = await makeController(store);
    first.addTag('复购');
    first.dispose();

    final second = await makeController(store);
    expect(second.tags.map((t) => t.label), contains('复购'));
    second.dispose();
  });

  test('结构化维度与旧前缀标签随备份往返且保留交易关联', () async {
    final source = await makeController();
    final projectId = source.addTag('项目:2026国庆返乡')!;
    expect(source.tagById(projectId)!.label, '2026国庆返乡');
    expect(source.tagById(projectId)!.groupId, 'project');
    final customGroupId = await source.addTagGroup(
      '活动',
      selectionMode: TagSelectionMode.single,
    );
    expect(
      await source.setTagGroupSelectionMode(
        'project',
        TagSelectionMode.multiple,
      ),
      isTrue,
    );
    expect(customGroupId, isNotNull);
    final customTagId = source.addTag('假期', groupId: customGroupId)!;
    source.addEntry(
      LedgerEntry(
        id: 'dimension-entry',
        bookId: source.activeBook.id,
        type: EntryType.expense,
        amount: 38.5,
        categoryId: 'dining',
        accountId: 'cash',
        note: '',
        occurredAt: DateTime(2026, 10, 1),
        tagIds: <String>[projectId, customTagId],
      ),
    );
    final backup = source.exportDataJson();
    source.dispose();

    final target = await makeController();
    target.importDataJson(backup);
    expect(
      target.tagGroups
          .singleWhere((group) => group.id == customGroupId)
          .selectionMode,
      TagSelectionMode.single,
    );
    expect(
      target.tagGroups
          .singleWhere((group) => group.id == 'project')
          .selectionMode,
      TagSelectionMode.multiple,
    );
    expect(target.tagById(projectId)!.groupId, 'project');
    expect(target.entries.single.tagIds, <String>[projectId, customTagId]);
    target.dispose();
  });

  test('CSV 标签列可表示内置维度，未知维度不改原文', () {
    expect(
      tagPortableLabel(const Tag(id: 'p', groupId: 'project', label: '国庆返乡')),
      '项目:国庆返乡',
    );
    expect(parseLegacyTagLabel('项目:国庆返乡').groupId, 'project');
    expect(
      tagPortableLabel(const Tag(id: 'c', groupId: 'custom', label: '项目类型:旅行')),
      '项目类型:旅行',
    );
  });

  test('旧版 JSON 备份的前缀标签转换后仍被原交易引用', () async {
    final source = await makeController();
    final tagId = source.addTag('场景:返乡途中')!;
    source.addEntry(
      LedgerEntry(
        id: 'legacy-entry',
        bookId: source.activeBook.id,
        type: EntryType.expense,
        amount: 12,
        categoryId: 'dining',
        accountId: 'cash',
        note: '',
        occurredAt: DateTime(2026, 10, 1),
        tagIds: <String>[tagId],
      ),
    );
    final root = jsonDecode(source.exportDataJson()) as Map<String, dynamic>;
    final data = root['data'] as Map<String, dynamic>;
    data.remove('tagGroups');
    data['tags'] = <Map<String, Object?>>[
      <String, Object?>{'id': tagId, 'label': '场景:返乡途中'},
    ];
    source.dispose();

    final target = await makeController();
    target.importDataJson(jsonEncode(root));
    expect(target.tagById(tagId)!.groupId, 'scene');
    expect(target.tagById(tagId)!.label, '返乡途中');
    expect(target.entries.single.tagIds, <String>[tagId]);
    target.dispose();
  });

  test('项目元数据、模板和归档状态随备份往返', () async {
    final source = await makeController();
    final project = await source.saveProject(
      name: '2026 国庆返乡',
      startDate: DateTime(2026, 10, 1),
      endDate: DateTime(2026, 10, 7),
      budget: 2500,
      note: '回家',
    );
    expect(project, isNotNull);
    final sceneId = source.addTag('场景:返乡途中')!;
    source.addEntry(
      LedgerEntry(
        id: 'project-expense',
        bookId: source.activeBook.id,
        type: EntryType.expense,
        amount: 38.5,
        categoryId: 'dining',
        accountId: 'cash',
        note: '',
        occurredAt: DateTime(2026, 10, 2),
        tagIds: <String>[project!.tagId, sceneId],
      ),
    );
    expect(source.projectSpent(project), 38.5);
    final template = await source.saveTagTemplate('回老家', <String>[
      project.tagId,
      sceneId,
    ]);
    expect(template?.tagIds, <String>[project.tagId, sceneId]);
    expect(
      await source.saveProject(
        original: project,
        name: project.name,
        budget: 2500,
        status: ProjectStatus.archived,
      ),
      isNotNull,
    );
    expect(source.tagById(project.tagId)!.archived, isTrue);
    final backup = source.exportDataJson();
    source.dispose();

    final target = await makeController();
    target.importDataJson(backup);
    final restored = target.projects.singleWhere(
      (item) => item.id == project.id,
    );
    expect(restored.status, ProjectStatus.archived);
    expect(restored.budget, 2500);
    expect(target.projectSpent(restored), 38.5);
    expect(target.tagTemplates.single.name, '回老家');
    expect(target.entries.single.tagIds, <String>[project.tagId, sceneId]);
    target.dispose();
  });

  test('标签合并保留交易原始 id，别名去重且多维筛选识别旧关联', () async {
    final controller = await makeController();
    final oldPlace = controller.addTag('地点:深圳市')!;
    final place = controller.addTag('地点:深圳')!;
    final scene = controller.addTag('场景:旅行')!;
    final otherScene = controller.addTag('场景:上班')!;
    controller.addEntry(
      LedgerEntry(
        id: 'merged-expense',
        bookId: controller.activeBook.id,
        type: EntryType.expense,
        amount: 25,
        categoryId: 'dining',
        accountId: 'cash',
        note: '',
        occurredAt: DateTime(2026, 10, 2),
        tagIds: <String>[oldPlace, scene],
      ),
    );
    controller.addEntry(
      LedgerEntry(
        id: 'other-scene-expense',
        bookId: controller.activeBook.id,
        type: EntryType.expense,
        amount: 15,
        categoryId: 'dining',
        accountId: 'cash',
        note: '',
        occurredAt: DateTime(2026, 10, 1),
        tagIds: <String>[place, otherScene],
      ),
    );
    expect(await controller.mergeTag(oldPlace, place), isTrue);
    expect(
      controller.entries
          .firstWhere((entry) => entry.id == 'merged-expense')
          .tagIds,
      <String>[oldPlace, scene],
    );
    expect(controller.tagById(oldPlace)?.id, place);
    expect(controller.addTag('深圳市', groupId: 'place'), place);
    expect(
      reportTagStats(
        controller.entries,
        controller.tags,
        EntryType.expense,
      ).singleWhere((stat) => stat.tag.id == place).amount,
      40,
    );
    expect(
      filterEntriesByTagDimensions(
        controller.entries,
        controller.tags,
        <String>[place, scene],
      ).map((entry) => entry.id),
      <String>['merged-expense'],
    );
    expect(
      filterEntriesByTagDimensions(
        controller.entries,
        controller.tags,
        <String>[place],
        categoryId: 'missing',
      ),
      isEmpty,
    );
    expect(await controller.deleteTag(place), isFalse);
    controller.dispose();
  });

  test('单选维度替换、多选维度追加，归档标签不再新选', () async {
    final controller = await makeController();
    final placeA = controller.addTag('地点:深圳')!;
    final placeB = controller.addTag('地点:湛江')!;
    final personA = controller.addTag('对象:自己')!;
    final personB = controller.addTag('对象:父母')!;
    expect(
      controller.resolveTagSelection(
        <String>[placeA, personA],
        <String>[placeB, personB],
      ),
      <String>[personA, placeB, personB],
    );
    expect(await controller.setTagArchived(personB, true), isTrue);
    expect(
      controller.resolveTagSelection(const <String>[], <String>[personB]),
      isEmpty,
    );
    controller.dispose();
  });
}
