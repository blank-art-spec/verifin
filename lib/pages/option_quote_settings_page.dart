/// 美股期权行情凭证草稿；加密保存交由调用方，本页不读取既有秘密或直接访问文件及网络。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../app/common_widgets.dart';
import '../app/feedback.dart';
import '../app/investments/investment_widgets.dart';
import '../l10n/app_localizations.dart';

/// 只通过显式保存向调用方交付凭证，调用方完成本机加密保存后才能返回成功。
class OptionQuoteSettingsPage extends StatefulWidget {
  /// [configured] 仅表示已有配置，不向表单提供已保存的凭证。
  /// [loadFailed] 表示旧凭证读取失败，仍允许主动替换或清除，不伪装成未配置。
  /// [onSave] 加密保存或删除落盘成功后返回 true；两个空串表示明确清除。
  const OptionQuoteSettingsPage({
    super.key,
    required this.configured,
    required this.onSave,
    this.loadFailed = false,
  });

  final bool configured;
  final bool loadFailed;
  final Future<bool> Function(String keyId, String secretKey) onSave;

  @override
  State<OptionQuoteSettingsPage> createState() =>
      _OptionQuoteSettingsPageState();
}

class _OptionQuoteSettingsPageState extends State<OptionQuoteSettingsPage> {
  final _keyId = TextEditingController();
  final _secretKey = TextEditingController();
  final _exitController = EditorExitController();
  bool _saving = false;
  bool _saved = false;

  /// 首尾空格可由粘贴带入；与来源校验一致，只接受有界可见 ASCII 凭证。
  bool _validCredential(String raw) {
    final value = raw.trim();
    return RegExp(r'^[\x21-\x7e]{1,512}$').hasMatch(value);
  }

  bool get _isDirty => _keyId.text.isNotEmpty || _secretKey.text.isNotEmpty;
  bool get _canSave =>
      !_saving &&
      _validCredential(_keyId.text) &&
      _validCredential(_secretKey.text);

  /// 控制器仅属于当前表单；退出时释放，不加入恢复状态、备份或偏好存储。
  @override
  void dispose() {
    _keyId.dispose();
    _secretKey.dispose();
    super.dispose();
  }

  /// [keyId]/[secretKey] 只交付给调用方；异常统一降级，不展示或记录异常原文。
  Future<bool> _commit(String keyId, String secretKey) async {
    if (_saving) return false;
    FocusScope.of(context).unfocus();
    setState(() => _saving = true);
    var saved = false;
    try {
      saved = await widget.onSave(keyId, secretKey);
    } catch (_) {
      // 回调可能包含凭证相关错误信息；不允许其进入界面或日志。
      saved = false;
    }
    if (!mounted) return false;
    setState(() {
      _saving = false;
      _saved = saved;
      if (saved) {
        _keyId.clear();
        _secretKey.clear();
      }
    });
    if (!saved) {
      unawaited(
        VeriFeedbackHost.of(context).showMessage(
          message: AppLocalizations.of(context).optionQuoteSaveFailed,
          tone: VeriFeedbackTone.error,
        ),
      );
    }
    return saved;
  }

  /// 两项凭证必须同时填写；空表单不表示清除，也不会重复提交。
  Future<bool> _save() async {
    if (!_canSave) return false;
    return _commit(_keyId.text.trim(), _secretKey.text.trim());
  }

  /// 显式保存成功后走统一受控退出，返回 true 供行情页更新配置状态。
  Future<void> _saveAndExit() async {
    if (await _save() && mounted) _exitController.exit(result: () => true);
  }

  /// 清除是独立显式动作；普通返回或输入空白不会清掉现有配置。
  Future<void> _clearAndExit() async {
    if ((!widget.configured && !widget.loadFailed) || _saving) return;
    if (await _commit('', '') && mounted) {
      _exitController.exit(result: () => true);
    }
  }

  /// 固定保存 Header；正文按 16dp 边距滚动，窄屏及大字号仍能编辑完整字段。
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return UnsavedChangesGuard(
      isDirty: _isDirty,
      canSave: _canSave,
      isSaving: _saving,
      onSave: _save,
      popResult: () => _saved ? true : null,
      exitController: _exitController,
      child: Scaffold(
        body: SafeArea(
          child: VeriPage(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: VeriHeader(
                    title: l10n.optionQuoteTitle,
                    showBack: true,
                    actions: [
                      SaveHeaderAction(
                        onPressed: _canSave ? _saveAndExit : null,
                      ),
                    ],
                  ),
                ),
                if (_saving) const LinearProgressIndicator(),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                    children: [
                      InvestmentHint(l10n.optionQuoteIntro),
                      const SizedBox(height: 12),
                      InvestmentSection(
                        title: l10n.optionQuoteCredentials,
                        children: [
                          InvestmentHint(
                            widget.loadFailed
                                ? l10n.optionQuoteLoadFailed
                                : widget.configured
                                ? l10n.optionQuoteReplaceHint
                                : l10n.optionQuoteSetupHint,
                          ),
                          InvestmentInputField(
                            label: l10n.optionQuoteKeyId,
                            child: TextField(
                              key: const ValueKey('optionQuoteKeyId'),
                              controller: _keyId,
                              enabled: !_saving,
                              obscureText: true,
                              autocorrect: false,
                              enableSuggestions: false,
                              enableIMEPersonalizedLearning: false,
                              autofillHints: const [],
                              textInputAction: TextInputAction.next,
                              onChanged: (_) => setState(() {}),
                              decoration: investmentInputDecoration(context)
                                  .copyWith(
                                    errorText:
                                        _keyId.text.isNotEmpty &&
                                            !_validCredential(_keyId.text)
                                        ? l10n.optionQuoteCredentialInvalid
                                        : null,
                                    errorMaxLines: 3,
                                  ),
                            ),
                          ),
                          InvestmentInputField(
                            label: l10n.optionQuoteSecretKey,
                            child: TextField(
                              key: const ValueKey('optionQuoteSecretKey'),
                              controller: _secretKey,
                              enabled: !_saving,
                              obscureText: true,
                              autocorrect: false,
                              enableSuggestions: false,
                              enableIMEPersonalizedLearning: false,
                              autofillHints: const [],
                              textInputAction: TextInputAction.done,
                              onChanged: (_) => setState(() {}),
                              decoration: investmentInputDecoration(context)
                                  .copyWith(
                                    errorText:
                                        _secretKey.text.isNotEmpty &&
                                            !_validCredential(_secretKey.text)
                                        ? l10n.optionQuoteCredentialInvalid
                                        : null,
                                    errorMaxLines: 3,
                                  ),
                            ),
                          ),
                          if (widget.configured || widget.loadFailed)
                            OutlinedButton.icon(
                              onPressed: _saving ? null : _clearAndExit,
                              style: investmentOutlineButtonStyle(context),
                              icon: const Icon(Icons.delete_outline),
                              label: Text(l10n.optionQuoteClear),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      InvestmentHint(l10n.optionQuoteLocalStorage),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
