import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/app_theme.dart';
import 'package:verifin/l10n/app_localizations.dart';
import 'package:verifin/pages/sheets.dart';

import 'support/test_harness.dart';

const _clearKey = Key('entry_picker_clear');
const _editorKey = Key('picker_test_editor');

enum _Picker { date, dial, input }

/// 使用真实选择器和独立编辑路由，额外 pop 会被编辑页存在性断言发现。
class _PickerProbe extends StatefulWidget {
  const _PickerProbe({required this.picker, this.clearable = true});

  final _Picker picker;
  final bool clearable;

  @override
  State<_PickerProbe> createState() => _PickerProbeState();
}

class _PickerProbeState extends State<_PickerProbe> {
  int clearCount = 0;
  int completionCount = 0;
  DateTime? result;

  Future<void> _open() async {
    void clear() => setState(() => clearCount += 1);
    final picker = widget.picker == _Picker.date
        ? showEntryDatePicker
        : showEntryTimePicker;
    final selected = await picker(
      context: context,
      initialDateTime: DateTime(2026, 11, 8, 13, 45),
      onClear: widget.clearable ? clear : null,
    );
    if (!mounted) return;
    setState(() {
      result = selected;
      completionCount += 1;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    key: _editorKey,
    body: Center(
      child: TextButton(
        key: const Key('open_picker'),
        onPressed: _open,
        child: const Text('Open picker'),
      ),
    ),
  );
}

/// 中文复用共享脚手架；英文使用相同本地化代理，避免把取消文案写死在 helper。
Future<void> _pumpProbe(
  WidgetTester tester, {
  required _Picker picker,
  String language = 'zh',
  double width = 393,
  double textScale = 1,
  bool clearable = true,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 852);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final home = Builder(
    builder: (context) => Scaffold(
      body: TextButton(
        key: const Key('open_editor'),
        onPressed: () => Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => _PickerProbe(picker: picker, clearable: clearable),
          ),
        ),
        child: const Text('Edit'),
      ),
    ),
  );
  final theme = buildVeriFinTheme(Brightness.light);
  await tester.pumpWidget(
    language == 'zh'
        ? zhMaterialApp(home: home, theme: theme)
        : MaterialApp(
            locale: const Locale('en'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            theme: theme,
            home: home,
          ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('open_editor')));
  await tester.pumpAndSettle();
}

Future<void> _openPicker(WidgetTester tester, _Picker picker) async {
  await tester.tap(find.byKey(const Key('open_picker')));
  await tester.pumpAndSettle();
  if (picker == _Picker.input) {
    await tester.tap(find.byIcon(Icons.keyboard_outlined));
    await tester.pumpAndSettle();
  }
}

/// 返回实际键盘焦点所属按钮，忽略内部 Focus/InkWell 的实现层级。
Widget? _focusedButton() {
  final context = FocusManager.instance.primaryFocus?.context;
  Widget? button;
  context?.visitAncestorElements((element) {
    if (element.widget is TextButton) {
      button = element.widget;
      return false;
    }
    return true;
  });
  return button;
}

void main() {
  const scenarios = [
    (language: 'zh', width: 393.0, scale: 1.0),
    (language: 'zh', width: 360.0, scale: 1.5),
    (language: 'zh', width: 360.0, scale: 2.0),
    (language: 'en', width: 360.0, scale: 1.0),
    (language: 'en', width: 393.0, scale: 1.5),
    (language: 'en', width: 360.0, scale: 2.0),
  ];

  for (final scenario in scenarios) {
    for (final picker in _Picker.values) {
      testWidgets(
        '${picker.name} ${scenario.language} ${scenario.width}dp ${scenario.scale} 倍字：清除和取消独立可用',
        (tester) async {
          await _pumpProbe(
            tester,
            picker: picker,
            language: scenario.language,
            width: scenario.width,
            textScale: scenario.scale,
          );
          await _openPicker(tester, picker);
          final clearLabel = scenario.language == 'zh' ? '清除' : 'Clear';
          final cancelLabel = scenario.language == 'zh' ? '取消' : 'Cancel';
          final clear = find.byKey(_clearKey);
          final cancel = find.text(cancelLabel);
          expect(clear.hitTestable(), findsOneWidget);
          expect(cancel.hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
          if (scenario.scale == 1) {
            expect(
              tester.getCenter(clear).dx,
              lessThan(tester.getCenter(cancel).dx),
            );
            expect(
              tester.getCenter(clear).dy,
              closeTo(tester.getCenter(cancel).dy, 1),
            );
          }

          final clearSemantics = tester.getSemantics(
            find.bySemanticsLabel(clearLabel),
          );
          final cancelSemantics = tester.getSemantics(
            find.bySemanticsLabel(cancelLabel),
          );
          expect(clearSemantics.id, isNot(cancelSemantics.id));
          expect(clearSemantics.label, clearLabel);
          expect(cancelSemantics.label, cancelLabel);
          expect(clearSemantics.flagsCollection.isButton, isTrue);
          expect(cancelSemantics.flagsCollection.isButton, isTrue);

          await tester.tap(clear);
          await tester.pumpAndSettle();
          final state = tester.state<_PickerProbeState>(
            find.byType(_PickerProbe),
          );
          expect(state.clearCount, 1);
          expect(state.completionCount, 1);
          expect(state.result, isNull);
          expect(find.byKey(_editorKey), findsOneWidget);
          expect(find.byType(DatePickerDialog), findsNothing);
          expect(find.byType(TimePickerDialog), findsNothing);

          await _openPicker(tester, picker);
          await tester.tap(find.text(cancelLabel));
          await tester.pumpAndSettle();
          expect(state.clearCount, 1);
          expect(state.completionCount, 2);
          expect(state.result, isNull);
          expect(find.byKey(_editorKey), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final picker in [_Picker.date, _Picker.dial]) {
    testWidgets('${picker.name} 清除与取消可分别用键盘触发', (tester) async {
      await _pumpProbe(tester, picker: picker);
      for (final clearAction in [true, false]) {
        await _openPicker(tester, picker);
        final action = clearAction
            ? find.byKey(_clearKey)
            : find.ancestor(
                of: find.text('取消'),
                matching: find.byType(TextButton),
              );
        var reached = false;
        for (var attempt = 0; attempt < 50; attempt += 1) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pumpAndSettle();
          if (identical(_focusedButton(), tester.widget(action))) {
            reached = true;
            break;
          }
        }
        expect(
          reached,
          isTrue,
          reason: clearAction ? '清除可独立获得焦点' : '取消可独立获得焦点',
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        final state = tester.state<_PickerProbeState>(
          find.byType(_PickerProbe),
        );
        expect(state.clearCount, 1);
        expect(state.completionCount, clearAction ? 1 : 2);
        expect(find.byKey(_editorKey), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('${picker.name} 必填选择器保留原有两按钮', (tester) async {
      await _pumpProbe(tester, picker: picker, clearable: false);
      await _openPicker(tester, picker);
      expect(find.byKey(_clearKey), findsNothing);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      final state = tester.state<_PickerProbeState>(find.byType(_PickerProbe));
      expect(state.clearCount, 0);
      expect(state.completionCount, 1);
      expect(find.byKey(_editorKey), findsOneWidget);
    });
  }
}
