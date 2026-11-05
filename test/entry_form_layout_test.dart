import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/app_theme.dart';
import 'package:verifin/app/common_widgets.dart';
import 'package:verifin/app/entry_sheets.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/pages/attachments_editor.dart';
import 'package:verifin/pages/entry_detail_page.dart';

import 'support/test_harness.dart';

/// 可真实解码的隔离缩略图；布局和全屏交互都不访问设备文件或网络。
const _attachmentPng =
    'data:image/png;base64,'
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

/// 检查附件标题 [title] 与数量 [count] 完整显示在编辑区内且互不遮挡。
/// [tester] 读取真实布局结果，不依赖头部采用 Row、Wrap 或其他具体实现。
void _expectAttachmentHeader(
  WidgetTester tester, {
  required String title,
  required String count,
}) {
  final titleFinder = find.text(title), countFinder = find.text(count);
  expect(titleFinder, findsOneWidget);
  expect(countFinder, findsOneWidget);
  final bounds = tester.getRect(find.byType(AttachmentsEditor));
  for (final text in [titleFinder, countFinder]) {
    final rect = tester.getRect(text);
    expect(rect.left, greaterThanOrEqualTo(bounds.left));
    expect(rect.right, lessThanOrEqualTo(bounds.right));
    expect(rect.top, greaterThanOrEqualTo(bounds.top));
    expect(rect.bottom, lessThanOrEqualTo(bounds.bottom));
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(of: text, matching: find.byType(RichText)),
    );
    expect(paragraph.didExceedMaxLines, isFalse);
  }
  expect(
    tester.getRect(titleFinder).overlaps(tester.getRect(countFinder)),
    isFalse,
  );
  expect(tester.takeException(), isNull);
}

void main() {
  useTestDatabases();

  testWidgets('快速记账使用优化类型切换和无分割线底部保存', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1000);
    addTearDown(tester.view.reset);

    final controller = await makeController();
    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: zhMaterialApp(home: const EntryDetailPage(initialAmount: 30)),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('entry_type_segmented_button')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('entry_type_selected_expense')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.save_outlined), findsNothing);
    expect(find.byKey(const Key('save_entry_button')), findsOneWidget);
    final saveButton = tester.widget<FilledButton>(
      find.byKey(const Key('save_entry_button')),
    );
    expect(saveButton.style?.backgroundColor, isNotNull);
    expect(saveButton.style?.foregroundColor, isNotNull);
    // 禁用态用淡蓝而非主题灰，且不得因 onPressed 为 null 而丢失。
    expect(
      saveButton.style!.backgroundColor!.resolve(<WidgetState>{
        WidgetState.disabled,
      }),
      veriRoyal.withValues(alpha: 0.38),
    );
    expect(
      saveButton.style!.foregroundColor!.resolve(<WidgetState>{
        WidgetState.disabled,
      }),
      Colors.white.withValues(alpha: 0.78),
    );
    expect(
      tester
          .widget<Padding>(find.byKey(const Key('entry_bottom_save_padding')))
          .padding,
      const EdgeInsets.fromLTRB(22, 10, 22, 18),
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('entry_bottom_save_bar')),
        matching: find.byType(Divider),
      ),
      findsNothing,
    );
    expect(
      tester
          .widget<ColoredBox>(find.byKey(const Key('entry_bottom_save_bar')))
          .color,
      Colors.transparent,
    );
    expect(
      tester
          .widget<CategoryGlyph>(
            find.descendant(
              of: find.byKey(const Key('entry_category_dining')),
              matching: find.byType(CategoryGlyph),
            ),
          )
          .color,
      veriSemanticFor(Brightness.light, veriExpense),
    );

    await tester.tap(find.text('收入'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('entry_type_selected_income')), findsOneWidget);
    expect(
      tester
          .widget<CategoryGlyph>(
            find.descendant(
              of: find.byKey(const Key('entry_category_salary')),
              matching: find.byType(CategoryGlyph),
            ),
          )
          .color,
      veriSemanticFor(Brightness.light, veriIncome),
    );

    await tester.tap(find.text('转账'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CategoryGlyph>(
            find.descendant(
              of: find.byKey(const Key('entry_category_transfer_out')),
              matching: find.byType(CategoryGlyph),
            ),
          )
          .color,
      veriSemanticFor(Brightness.light, veriBlue),
    );
  });

  testWidgets('更多信息收纳日期时间标签报销附件与币种', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1100);
    addTearDown(tester.view.reset);

    final controller = await makeController();
    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: zhMaterialApp(home: const EntryDetailPage(initialAmount: 30)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('更多信息'), findsOneWidget);
    expect(find.byKey(const Key('entry_metadata_date')), findsOneWidget);
    expect(find.byKey(const Key('entry_metadata_time')), findsOneWidget);
    expect(find.byKey(const Key('entry_metadata_tags')), findsNothing);
    expect(find.byKey(const Key('entry_metadata_tag_custom')), findsOneWidget);
    expect(find.byKey(const Key('entry_metadata_templates')), findsOneWidget);
    expect(
      find.byKey(const Key('entry_metadata_reimbursable')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('entry_metadata_attachments')), findsOneWidget);
    expect(find.byKey(const Key('entry_currency_button')), findsOneWidget);

    await tester.tap(find.byKey(const Key('entry_metadata_tag_custom')));
    await tester.pumpAndSettle();
    expect(find.byType(TagSelectorSheet), findsOneWidget);
    expect(
      tester
          .widget<TagSelectorSheet>(find.byType(TagSelectorSheet))
          .groups
          .single
          .id,
      'custom',
    );
    await tester.tap(find.widgetWithText(TextButton, '完成'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('entry_metadata_templates')));
    await tester.pumpAndSettle();
    final templateSheet = tester.widget<TagSelectorSheet>(
      find.byType(TagSelectorSheet),
    );
    expect(templateSheet.templatesOnly, isTrue);
    expect(templateSheet.groups, isEmpty);
  });

  testWidgets('紧凑附件条展示多张图片和小型删除按钮', (tester) async {
    final removed = <int>[];

    await tester.pumpWidget(
      zhMaterialApp(
        home: Scaffold(
          body: AttachmentsEditor(
            dataUrls: const <String>[
              _attachmentPng,
              _attachmentPng,
              _attachmentPng,
            ],
            onAddDataUrl: (_) {},
            onRemoveIndex: removed.add,
            showHeader: false,
            showAddButton: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('图片附件'), findsNothing);
    expect(find.byKey(const Key('attachment_remove_visual_0')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('attachment_remove_visual_0'))),
      const Size(16, 16),
    );

    await tester.tap(find.byKey(const Key('attachment_remove_visual_1')));
    expect(removed, <int>[1]);
  });

  for (final layout in [
    (language: 'en', width: 264.0, scale: 1.5),
    (language: 'zh', width: 337.0, scale: 1.0),
  ]) {
    for (final initialCount in [0, 3]) {
      testWidgets(
        '附件头部完整布局并保留查看删除 ${layout.language}/${layout.width}/${layout.scale}/$initialCount',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(layout.width + 56, 852);
          addTearDown(tester.view.reset);
          final images = List<String>.filled(
            initialCount,
            _attachmentPng,
            growable: true,
          );
          final removed = <int>[];
          final english = layout.language == 'en';
          final title = english ? 'Attachments' : '图片附件';

          await tester.pumpWidget(
            zhMaterialApp(
              theme: buildVeriFinTheme(Brightness.light),
              home: Builder(
                builder: (context) => Localizations.override(
                  context: context,
                  locale: Locale(layout.language),
                  child: MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: TextScaler.linear(layout.scale)),
                    child: Scaffold(
                      body: StatefulBuilder(
                        builder: (context, setState) => Align(
                          alignment: Alignment.topCenter,
                          child: SizedBox(
                            width: layout.width,
                            child: AttachmentsEditor(
                              dataUrls: images,
                              onAddDataUrl: (_) {},
                              onRemoveIndex: (index) => setState(() {
                                removed.add(index);
                                images.removeAt(index);
                              }),
                              showAddButton: false,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          _expectAttachmentHeader(
            tester,
            title: title,
            count: english ? '$initialCount images' : '$initialCount 张',
          );

          if (initialCount == 0) {
            expect(find.byType(Image), findsNothing);
            return;
          }
          // 点击第二张真实缩略图，确认头部换行后查看页仍对应原来的索引。
          await tester.tap(find.byType(Image).at(1));
          await tester.pumpAndSettle();
          expect(find.text('2 / 3'), findsOneWidget);
          await tester.tap(find.byIcon(Icons.delete_outline));
          await tester.pumpAndSettle();
          expect(removed, [1]);
          expect(images, hasLength(2));
          _expectAttachmentHeader(
            tester,
            title: title,
            count: english ? '2 images' : '2 张',
          );
        },
      );
    }
  }

  testWidgets('记账页类型分段条的转账选中色是语义蓝，与下方金额一致', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1000);
    addTearDown(tester.view.reset);

    final controller = await makeController();
    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: zhMaterialApp(home: const EntryDetailPage(initialAmount: 30)),
      ),
    );
    await tester.pumpAndSettle();

    // 选中项的文字色由调用点的 accentOf 提供；`entry_type_selected_*` 这个 Key
    // 只挂在当前选中项上，取到的就是分段条里那一份。
    Color? accentOf(String type) => tester
        .widget<Text>(find.byKey(Key('entry_type_selected_$type')))
        .style
        ?.color;

    expect(accentOf('expense'), veriSemanticFor(Brightness.light, veriExpense));

    await tester.tap(find.text('收入'));
    await tester.pumpAndSettle();
    expect(accentOf('income'), veriSemanticFor(Brightness.light, veriIncome));

    await tester.tap(find.text('转账'));
    await tester.pumpAndSettle();

    // 转账此前留中性色（浅色主题下近乎全黑、深色下近乎全白），与下方的大金额
    // （veriSemantic(context, veriBlue)）对不上。
    expect(
      accentOf('transfer'),
      veriSemanticFor(Brightness.light, veriBlue),
      reason: '转账选中色应与本页下方金额用的是同一支语义蓝',
    );
  });
}
