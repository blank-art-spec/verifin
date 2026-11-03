/// 证券代码的共享下拉；外部持有草稿，组件只管理焦点和候选展示。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_theme.dart';
import 'investment_security_suggestions.dart';
import 'investment_widgets.dart';

/// 输入代码或名称时展示匹配证券；未命中仍可直接手工填写。
class InvestmentSecurityAutocomplete extends StatefulWidget {
  /// [controller] 属于调用方，组件不释放或替换它，原有草稿监听保持有效。
  /// [fieldKey] 沿用业务表单的输入框定位键，[label] 提供本地化字段名；
  /// [suggestions] 为已隔离上下文的候选，[onSelected] 仅回传明确点选的身份。
  /// [openRequest] 递增时主动展开新候选，供用户点击联网查询后显示异步结果；
  /// 本组件不发网络请求。[readOnly] 保护既有事件/转仓的证券身份。
  const InvestmentSecurityAutocomplete({
    super.key,
    required this.controller,
    required this.fieldKey,
    required this.label,
    required this.suggestions,
    required this.onSelected,
    this.openRequest = 0,
    this.readOnly = false,
  });

  final TextEditingController controller;
  final Key fieldKey;
  final String label;
  final List<InvestmentSecuritySuggestion> suggestions;
  final ValueChanged<InvestmentSecuritySuggestion> onSelected;
  final int openRequest;
  final bool readOnly;

  /// 每份输入创建独立焦点、浮层及滚动状态，不借用其他草稿资源。
  @override
  State<InvestmentSecurityAutocomplete> createState() =>
      _InvestmentSecurityAutocompleteState();
}

class _InvestmentSecurityAutocompleteState
    extends State<InvestmentSecurityAutocomplete> {
  final _focusNode = FocusNode();
  final _overlay = OverlayPortalController();
  final _scrollController = ScrollController();
  final _optionKeys = <String, GlobalKey>{};
  int _highlighted = 0;
  bool _refreshScheduled = false;
  String? _dismissedText;

  /// 只按当前文本筛选调用方提供的身份；不对外部控制器做镜像或格式转换。
  List<InvestmentSecuritySuggestion> get _options =>
      matchInvestmentSecuritySuggestions(
        widget.suggestions,
        widget.controller.text,
      );

  /// 监听原草稿控制器与组件自身焦点，外部既有监听器仍照常收到变化。
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_textChanged);
    _focusNode.addListener(_scheduleRefresh);
  }

  /// 父表单更新异步候选后刷新浮层；仅明确递增 openRequest 才主动获取输入焦点。
  /// 更换外部控制器时解除旧监听，避免已销毁草稿继续影响本组件。
  @override
  void didUpdateWidget(InvestmentSecurityAutocomplete oldWidget) {
    super.didUpdateWidget(oldWidget);
    _highlighted = _highlighted.clamp(0, math.max(0, _options.length - 1));
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_textChanged);
      widget.controller.addListener(_textChanged);
    }
    if (oldWidget.openRequest != widget.openRequest && !widget.readOnly) {
      _dismissedText = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            Visibility.of(context) &&
            (ModalRoute.of(context)?.isCurrent ?? true) &&
            !_hasOtherEditableFocus()) {
          _focusNode.requestFocus();
        }
      });
    }
    _scheduleRefresh();
  }

  /// 用户等候搜索时可能已经继续填写数量或成交价；异步结果不能夺走其他输入框焦点。
  /// 搜索按钮等非输入控件不阻止候选展开；留存的候选在用户返回代码框时仍可选择。
  bool _hasOtherEditableFocus() {
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null || primary == _focusNode) return false;
    final focusedContext = primary.context;
    return focusedContext?.widget is EditableText ||
        focusedContext?.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  /// IndexedStack 的隐藏页签不可抢占当前页焦点，也不在其他业务表单上方显示候选。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!Visibility.of(context)) _focusNode.unfocus();
    _scheduleRefresh();
  }

  /// 文本变化重新从第一项匹配；选项不会反向修改数量、成交价或其他草稿字段。
  void _textChanged() {
    _highlighted = 0;
    if (mounted) setState(() {});
    _scheduleRefresh();
  }

  /// 合并一帧内的输入、候选和焦点更新，避免在父表单构建中直接修改浮层树。
  /// 只有可编辑、已聚焦且存在匹配候选时显示；选中后的相同代码保持收起。
  void _scheduleRefresh() {
    if (_refreshScheduled || !mounted) return;
    _refreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshScheduled = false;
      if (!mounted) return;
      final shouldShow =
          !widget.readOnly &&
          Visibility.of(context) &&
          (ModalRoute.of(context)?.isCurrent ?? true) &&
          _focusNode.hasFocus &&
          widget.controller.text != _dismissedText &&
          _options.isNotEmpty;
      if (shouldShow) {
        if (!_overlay.isShowing) _overlay.show();
      } else if (_overlay.isShowing) {
        _overlay.hide();
      }
    });
  }

  /// 将 [suggestion] 的原始证券代码写回同一个控制器，再让业务层填充身份资料。
  /// 收起后继续保留键盘和输入焦点，用户可以立即修改代码或跳转下一字段。
  void _select(InvestmentSecuritySuggestion suggestion) {
    final symbol = suggestion.security.symbol;
    _dismissedText = symbol;
    widget.controller.value = TextEditingValue(
      text: symbol,
      selection: TextSelection.collapsed(offset: symbol.length),
    );
    widget.onSelected(suggestion);
    if (_overlay.isShowing) _overlay.hide();
  }

  /// [delta] 为上下键的步长，越界停在首/末项；滚动使当前高亮项可见。
  /// 列表项随字号自然增高，因此按实际 RenderObject 可见位置滚动，不假定行高。
  /// 延后回调再次核对当前候选身份，远端列表替换后不使用旧数组或旧索引。
  void _moveHighlight(int delta) {
    final options = _options;
    if (!_overlay.isShowing || options.isEmpty) return;
    setState(() {
      _highlighted = (_highlighted + delta).clamp(0, options.length - 1);
    });
    final targetId = options[_highlighted].security.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_overlay.isShowing || !_scrollController.hasClients) {
        return;
      }
      final current = _options;
      if (current.isEmpty ||
          current[_highlighted.clamp(0, current.length - 1)].security.id !=
              targetId) {
        return;
      }
      final itemContext = _optionKeys[targetId]?.currentContext;
      if (itemContext != null) {
        unawaited(Scrollable.ensureVisible(itemContext, alignment: 0.5));
      } else {
        _scrollController.jumpTo(
          _highlighted == 0 ? 0 : _scrollController.position.maxScrollExtent,
        );
      }
    });
  }

  /// 回车只在候选浮层可见时采用高亮项；普通手填且未命中时保持输入原样。
  void _submit() {
    final options = _options;
    if (_overlay.isShowing && options.isNotEmpty) {
      _select(options[_highlighted.clamp(0, options.length - 1)]);
    }
  }

  /// Esc 收起下拉并保留文字，不影响草稿，也不会触发页面返回。
  void _dismiss() {
    _dismissedText = widget.controller.text;
    if (_overlay.isShowing) _overlay.hide();
  }

  /// [context] 提供主题；名称与代码各占一行并完整换行，触控目标至少 48dp。
  /// 浮层使用不透明表面和统一圆角；长列表由自身滚动，不撑高整个表单。
  Widget _optionsList(BuildContext context) {
    final options = _options;
    final theme = Theme.of(context);
    return TextFieldTapRegion(
      child: Material(
        key: const Key('investment-security-options'),
        color: veriElevatedSurfaceColor(theme.brightness),
        surfaceTintColor: Colors.transparent,
        elevation: 4,
        borderRadius: BorderRadius.circular(veriRadiusMd),
        clipBehavior: Clip.antiAlias,
        child: ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.all(6),
          shrinkWrap: true,
          itemCount: options.length,
          itemBuilder: (context, index) {
            final entry = options[index];
            final itemKey = _optionKeys.putIfAbsent(
              entry.security.id,
              GlobalKey.new,
            );
            return Semantics(
              key: itemKey,
              button: true,
              selected: index == _highlighted,
              child: InkWell(
                key: ValueKey('investment-security-${entry.security.id}'),
                canRequestFocus: false,
                borderRadius: BorderRadius.circular(veriRadiusSm),
                onTap: () => _select(entry),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 48),
                  decoration: BoxDecoration(
                    color: index == _highlighted
                        ? theme.scaffoldBackgroundColor
                        : null,
                    borderRadius: BorderRadius.circular(veriRadiusSm),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        entry.security.symbol,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (entry.security.name.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          entry.security.name,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 根据 [layoutInfo] 的实际输入框位置，把候选放在键盘上方空间较多的一侧。
  /// 最大高度为 240dp，宽度不超过输入框；安全区和键盘遮挡先扣除。
  /// 隐藏页签或不可绘制的输入不显示浮层，不借用整屏居中占位。
  Widget _buildOverlay(
    BuildContext context,
    OverlayChildLayoutInfo layoutInfo,
  ) {
    if (layoutInfo.childPaintTransform.determinant() == 0) {
      return const SizedBox.shrink();
    }
    final inverse = layoutInfo.childPaintTransform.clone()..invert();
    final visible = MediaQuery.paddingOf(context).deflateRect(
      MediaQuery.viewInsetsOf(
        context,
      ).deflateRect(Offset.zero & layoutInfo.overlaySize),
    );
    final visibleInField = MatrixUtils.transformRect(inverse, visible);
    // 聚焦字段也可能被用户滚出视口；可逆变换不代表它仍然可见。
    // 完全离开安全区/键盘以上区域时不绘制残留候选，避免覆盖新滚入的表单内容。
    if (!visibleInField.overlaps(Offset.zero & layoutInfo.childSize)) {
      return const SizedBox.shrink();
    }
    final above = math.max(0.0, -visibleInField.top);
    final below = math.max(
      0.0,
      visibleInField.bottom - layoutInfo.childSize.height,
    );
    final opensUp = above > below;
    final height = math.min(240.0, opensUp ? above : below);
    if (height <= 0) return const SizedBox.shrink();
    final transform = layoutInfo.childPaintTransform.clone()
      ..translateByDouble(
        0,
        opensUp ? -height : layoutInfo.childSize.height,
        0,
        1,
      );
    return Transform(
      transform: transform,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: layoutInfo.childSize.width,
          height: height,
          child: Align(
            alignment: opensUp ? Alignment.bottomLeft : Alignment.topLeft,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: height),
              child: _optionsList(context),
            ),
          ),
        ),
      ),
    );
  }

  /// 解除外部控制器监听，再释放本组件创建的焦点和滚动资源；绝不释放草稿控制器。
  @override
  void dispose() {
    widget.controller.removeListener(_textChanged);
    _focusNode.removeListener(_scheduleRefresh);
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 输入框继续使用证券表单既有标签、实色底和原定位键；外部候选变化自动刷新。
  /// 点击字段可重新展开已收起候选；点外部关闭焦点，避免下拉遮挡其他操作。
  @override
  Widget build(BuildContext context) => OverlayPortal.overlayChildLayoutBuilder(
    controller: _overlay,
    overlayChildBuilder: _buildOverlay,
    child: CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            _moveHighlight(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            _moveHighlight(-1),
        const SingleActivator(LogicalKeyboardKey.escape): _dismiss,
      },
      child: InvestmentInputField(
        label: widget.label,
        child: TextField(
          key: widget.fieldKey,
          controller: widget.controller,
          focusNode: _focusNode,
          readOnly: widget.readOnly,
          textCapitalization: TextCapitalization.characters,
          onSubmitted: (_) => _submit(),
          onTap: () {
            _dismissedText = null;
            _scheduleRefresh();
          },
          onTapOutside: (_) => _focusNode.unfocus(),
          decoration: investmentInputDecoration(context),
        ),
      ),
    ),
  );
}
