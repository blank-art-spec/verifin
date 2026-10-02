import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/entry_sheets.dart';
import 'package:verifin/app/models.dart';

import 'support/test_harness.dart';

void main() {
  testWidgets('单选维度替换旧标签，多选维度保留多个标签', (tester) async {
    const tags = <Tag>[
      Tag(id: 'trip-a', groupId: 'project', label: '旅行 A'),
      Tag(id: 'trip-b', groupId: 'project', label: '旅行 B'),
      Tag(id: 'person-a', groupId: 'person', label: '自己'),
      Tag(id: 'person-b', groupId: 'person', label: '家人'),
    ];
    await tester.pumpWidget(
      zhMaterialApp(
        home: Scaffold(
          body: TagSelectorSheet(
            tags: tags,
            groups: defaultTagGroups,
            selectedIds: const <String>['trip-a'],
            onCreateTag: (groupId) async => null,
          ),
        ),
      ),
    );

    await tester.tap(find.widgetWithText(FilterChip, '旅行 B'));
    await tester.pump();
    expect(
      tester
          .widget<FilterChip>(find.widgetWithText(FilterChip, '旅行 A'))
          .selected,
      isFalse,
    );
    expect(
      tester
          .widget<FilterChip>(find.widgetWithText(FilterChip, '旅行 B'))
          .selected,
      isTrue,
    );

    await tester.ensureVisible(find.widgetWithText(FilterChip, '自己'));
    await tester.tap(find.widgetWithText(FilterChip, '自己'));
    await tester.tap(find.widgetWithText(FilterChip, '家人'));
    await tester.pump();
    expect(
      tester.widget<FilterChip>(find.widgetWithText(FilterChip, '自己')).selected,
      isTrue,
    );
    expect(
      tester.widget<FilterChip>(find.widgetWithText(FilterChip, '家人')).selected,
      isTrue,
    );
  });
}
