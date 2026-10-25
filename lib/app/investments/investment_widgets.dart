/// 证券页面共享的展示组合；只负责排版，不读取或修改账务。
library;

import 'package:flutter/material.dart';
import '../app_theme.dart';
import '../common_widgets.dart';

/// [context] 提供当前主题；仅为输入区提供实色底色，聚焦与错误边框沿用主题。
/// 字段名由 [InvestmentInputField] 单独布局，避免浮动标签越界覆盖上一行说明。
InputDecoration investmentInputDecoration(BuildContext context) =>
    InputDecoration(
      filled: true,
      fillColor: Theme.of(context).scaffoldBackgroundColor,
    );

/// 证券表单的字段名与输入区各自占据实际高度，不把标签绘制在输入边界之外。
class InvestmentInputField extends StatelessWidget {
  /// [label] 是完整的本地化字段名，可随系统字号换行；[child] 为业务层构造的
  /// 输入框，保留原控制器、测试键、只读状态、键盘和修改回调，不由展示层持有草稿。
  const InvestmentInputField({
    super.key,
    required this.label,
    required this.child,
  });
  final String label;
  final TextField child;

  /// 上留 8dp 与说明分隔，标签和输入区间隔 6dp；文字自然测量，禁止固定标签高度。
  /// 可访问性名称挂在输入框上，视觉标签排除重复朗读，保留原输入编辑语义。
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExcludeSemantics(
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Semantics(label: label, child: child),
      ],
    ),
  );
}

/// 证券页面的次要按钮与已有主按钮使用相同圆角、内边距和最小触控高度。
/// [context] 用于继承当前主题；只覆盖形状与尺寸，不改变禁用态和回调。
ButtonStyle investmentOutlineButtonStyle(BuildContext context) =>
    (Theme.of(context).outlinedButtonTheme.style ?? const ButtonStyle()).merge(
      OutlinedButton.styleFrom(
        minimumSize: const Size(44, 44),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(veriRadiusMd),
        ),
      ),
    );

/// 用现有实色卡片统一证券表单、行情和观察点的分组。
class InvestmentSection extends StatelessWidget {
  /// [title] 是本地化分组标题，[children] 按业务顺序排列；外部控制组间距离。
  const InvestmentSection({
    super.key,
    required this.title,
    required this.children,
  });
  final String title;
  final List<Widget> children;

  /// 标题与内容共享左边界，内容占满卡片，字段长度决定实际高度。
  @override
  Widget build(BuildContext context) => VeriCard(
    // 卡片的实色装饰在外层；交互控件的墨水层放在装饰内，保证点击反馈可见。
    child: Material(
      type: MaterialType.transparency,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    ),
  );
}

/// 带图标的次级说明，避免长说明与金额混成同一段正文。
class InvestmentHint extends StatelessWidget {
  /// [text] 必须来自本地化；说明完整换行，不隐藏数据限制。
  const InvestmentHint(this.text, {super.key});
  final String text;

  /// 图标对齐首行，采用主题次级文字色，保留系统字号缩放。
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.info_outline,
          size: 16,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ),
      ],
    ),
  );
}
