/// 新建交易页面与可独立使用的领域表单之间的轻量草稿协议。
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import '../app/common_widgets.dart';

/// 将领域表单的文本与选择事实组成可比较的会话快照。
/// [fields] 保留原文本，避免未保存的格式改动丢失；[values] 由各表单明确列出日期、
/// 动作和开关等非文本事实。此字符串仅留内存，不输出日志或写入设备。
String editorDraftSnapshot({
  required Map<String, TextEditingController> fields,
  required List<Object?> values,
}) => jsonEncode({
  'fields': {for (final field in fields.entries) field.key: field.value.text},
  'values': values,
});

/// 一份表单的临时编辑会话，不持久化用户输入或账目。
///
/// 外壳读取 [isDirty] 和 [canSave] 决定保存与退出；真正的校验、原子保存仍由
/// 原领域表单通过 [update] 注册的回调完成。每个账户、品种分别持有一份实例。
class EntryEditorSession extends ChangeNotifier {
  bool _dirty = false;
  bool _canSave = false;
  bool _saving = false;
  bool _saved = false;
  bool _disposed = false;
  bool _notificationScheduled = false;
  Future<bool> Function()? _onSave;

  /// 当前会话是否仍有未提交内容；已成功保存的记录不再次视为新草稿。
  bool get isDirty => _dirty && !_saved;

  /// 当前表单允许保存且确有改动时才可提交；写入期间禁用重复操作。
  bool get canSave => _canSave && isDirty && !_saving;

  /// 当前记录是否正在等待领域命令完成，用于外壳锁定返回及输入。
  bool get isSaving => _saving;

  /// 当前记录已提交成功；只读保留其表单以供用户切回查看。
  bool get isSaved => _saved;

  /// 由表单每次构建同步当前草稿状态。
  /// [onSave] 只保存这一份记录，成功返回 true，不得自行退出宿主页。
  /// 构建期间延后发送通知，避免父页面在子页面构建中被要求重新构建。
  void update({
    required bool isDirty,
    required bool canSave,
    required Future<bool> Function() onSave,
  }) {
    final changed = _dirty != isDirty || _canSave != canSave;
    _dirty = isDirty;
    _canSave = canSave;
    _onSave = onSave;
    if (changed) _scheduleNotification();
  }

  /// 保存当前会话，并在成功后立刻更新基线。
  /// 已保存会话不能再次新增同一条记录；失败保留表单，允许使用同一稳定 ID 重试。
  Future<bool> save() async {
    if (!canSave || _onSave == null) return false;
    FocusManager.instance.primaryFocus?.unfocus();
    _saving = true;
    notifyListeners();
    try {
      final success = await _onSave!();
      if (success) {
        _saved = true;
        _dirty = false;
        _canSave = false;
      }
      return success;
    } finally {
      _saving = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// 合并同一帧的字段变化；会话释放后，尚未触发的回调不再通知父页面。
  void _scheduleNotification() {
    if (_notificationScheduled || _disposed) return;
    _notificationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _notificationScheduled = false;
      if (!_disposed) notifyListeners();
    });
  }

  /// 只释放通知资源，绝不在离页或释放时隐式保存。
  @override
  void dispose() {
    _disposed = true;
    _onSave = null;
    super.dispose();
  }
}

/// 领域表单共用的页面表面：独立时有 Scaffold 和离页保护，嵌入时只有表单内容。
class EntryEditorSurface extends StatelessWidget {
  /// [session] 非空表示由新增页外壳管理保存和整页返回；[body] 不包含 Scaffold。
  /// [bottomNavigationBar] 仅用于原独立页面，嵌入模式由外壳统一绘制保存区。
  const EntryEditorSurface({
    super.key,
    required this.body,
    required this.isDirty,
    required this.canSave,
    required this.onSave,
    required this.exitController,
    this.session,
    this.bottomNavigationBar,
    this.popResult,
    this.isSaving = false,
  });

  final Widget body;
  final bool isDirty, canSave;
  final Future<bool> Function() onSave;
  final EditorExitController exitController;
  final EntryEditorSession? session;
  final Widget? bottomNavigationBar;
  final Object? Function()? popResult;

  /// 保存进行中阻止退出和输入，避免请求提交后用户误以为已经丢弃。
  final bool isSaving;

  /// 嵌入时注册领域保存回调并移除重复的页面外壳。
  /// 保存过的草稿保持只读，便于返回查看，并防止第二次提交同一条新建记录。
  @override
  Widget build(BuildContext context) {
    final editor = session;
    if (editor != null) {
      editor.update(isDirty: isDirty, canSave: canSave, onSave: onSave);
      return ListenableBuilder(
        listenable: editor,
        child: body,
        builder: (context, child) => ExcludeFocus(
          excluding: editor.isSaved || editor.isSaving,
          child: IgnorePointer(
            ignoring: editor.isSaved || editor.isSaving,
            child: child,
          ),
        ),
      );
    }
    return UnsavedChangesGuard(
      isDirty: isDirty,
      isSaving: isSaving,
      canSave: canSave,
      onSave: onSave,
      exitController: exitController,
      popResult: popResult,
      child: Scaffold(
        body: ExcludeFocus(
          excluding: isSaving,
          child: AbsorbPointer(absorbing: isSaving, child: body),
        ),
        bottomNavigationBar: bottomNavigationBar,
      ),
    );
  }
}
