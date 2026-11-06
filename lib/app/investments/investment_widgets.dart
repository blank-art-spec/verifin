/// 证券页面共享的展示组合；只负责排版，不读取或修改账务。
library;

import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../app_theme.dart';
import '../common_widgets.dart';

/// 证券概览中两项指标的响应式排版，复用标准 SummaryMetric 的标签与数值样式。
class InvestmentMetricPair extends StatelessWidget {
  /// [first] 与 [second] 按业务顺序排列，均由调用方传入已格式化的展示内容。
  /// [filled] 为 true 时使用实色浅底与统一圆角突出现金/持仓，为 false 时
  /// 仅排列次级指标，不增加表面层；本组件不读取 Controller 或计算金额。
  const InvestmentMetricPair({
    super.key,
    required this.first,
    required this.second,
    this.filled = true,
  });

  final SummaryMetric first, second;
  final bool filled;

  /// 用 [context] 的画布实色包裹 [metric]；内部 Row 保持其 Expanded 父子关系合法。
  /// 面板不设固定高度，长标签、长金额和占比均由标准指标自身测量并换行。
  Widget _panel(BuildContext context, SummaryMetric metric) {
    final content = Row(children: [metric]);
    if (!filled) return content;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: BorderRadius.circular(veriRadiusSm),
      ),
      child: Padding(padding: const EdgeInsets.all(10), child: content),
    );
  }

  /// 普通手机及中等大字号保持等宽双列，只有每列连基本文字宽度都不足才改单列。
  /// [context] 提供主题与系统字号；双列仅对这两个静态指标测量固有高度，
  /// 让两块实色面板等高，不在整页列表上使用固有尺寸测量。
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      // 为每列保留至少五个正文汉字的宽度（最低 96dp），再加面板内边距
      // 和列间距。三组使用相同门槛，避免 360dp 手机或 1.5 倍字号整页竖排。
      // 长金额仍按真实字号完整换行，不缩小字号或省略数字。
      final labelSize = Theme.of(context).textTheme.bodySmall?.fontSize ?? 12;
      final minimumTextWidth =
          (MediaQuery.textScalerOf(context).scale(labelSize) * 5).clamp(
            96.0,
            double.infinity,
          );
      final stacked = constraints.maxWidth < minimumTextWidth * 2 + 52;
      final firstPanel = _panel(context, first);
      final secondPanel = _panel(context, second);
      if (stacked) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [firstPanel, const SizedBox(height: 12), secondPanel],
        );
      }
      return IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: firstPanel),
            const SizedBox(width: 12),
            Expanded(child: secondPanel),
          ],
        ),
      );
    },
  );
}

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
  /// [header] 可用整行交互标题替换默认文字标题，供折叠分组复用同一张实色卡片。
  /// 折叠状态仍由页面持有；无内容时不预留标题到正文的空隙。
  const InvestmentSection({
    super.key,
    required this.title,
    required this.children,
    this.header,
  });
  final String title;
  final List<Widget> children;
  final Widget? header;

  /// 标题与内容共享左边界，内容占满卡片，字段长度决定实际高度。
  @override
  Widget build(BuildContext context) => VeriCard(
    // 卡片的实色装饰在外层；交互控件的墨水层放在装饰内，保证点击反馈可见。
    child: Material(
      type: MaterialType.transparency,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header ??
              Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
          if (children.isNotEmpty) const SizedBox(height: 12),
          ...children,
        ],
      ),
    ),
  );
}

/// 持仓卡内已采用报价的来源说明，独立于数量、成本及盈亏指标排列。
class InvestmentQuoteDetails extends StatelessWidget {
  /// [source] 为报价返回的公开来源名称；[quoteTime] 为调用方已按应用语言、
  /// 设备时区格式化的来源报价时刻，不得传入抓取时间来代替来源时间。
  /// 本组件只负责展示，不读取行情缓存或改变估值，长文字随字号自然换行。
  /// [dateOnly] 为 true 时将来源标签显示为净值日期，避免把日精度宣称为报价时刻。
  const InvestmentQuoteDetails({
    super.key,
    required this.source,
    required this.quoteTime,
    this.dateOnly = false,
    this.olderThanOneDay = false,
    this.delayMinutes,
  });

  final String source, quoteTime;
  final bool dateOnly;
  final bool olderThanOneDay;
  final int? delayMinutes;

  /// 以主题画布实色弱化来源区；来源与时间分两层，避免长说明打断金额行。
  /// 装饰图标不重复朗读；不固定高度、不省略日期，保留系统大字号和浅深主题。
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context), l = AppLocalizations.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    final caption = theme.textTheme.labelMedium?.copyWith(
      color: color,
      height: 1.4,
    );
    return MergeSemantics(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.scaffoldBackgroundColor,
          borderRadius: BorderRadius.circular(veriRadiusSm),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: Icon(Icons.cloud_outlined, size: 16, color: color),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      source,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: color,
                        fontWeight: FontWeight.w600,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 2,
                      children: [
                        Text(
                          dateOnly ? l.marketNavDate : l.marketQuoteTime,
                          style: caption,
                        ),
                        Text(quoteTime, style: caption),
                      ],
                    ),
                    if (delayMinutes != null)
                      Text(l.marketDelayKnown(delayMinutes!), style: caption),
                    if (olderThanOneDay)
                      Text(l.marketQuoteOlderThanOneDay, style: caption),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 带图标的次级说明，避免长说明与金额混成同一段正文。
class InvestmentHint extends StatelessWidget {
  /// [text] 必须来自本地化；说明完整换行，不隐藏数据限制。
  const InvestmentHint(this.text, {super.key});
  final String text;

  /// 测量 [style] 在 [maxWidth] 内实际排出的首行高度，包含字体回退与行间距。
  /// [context] 提供与正文一致的语言、文字方向及系统字号；[heightBehavior] 保持首尾行
  /// 留白规则一致。只读取文字布局，不写入状态；测量完成后立即释放排版资源。
  double _firstLineHeight(
    BuildContext context,
    TextStyle style,
    double maxWidth,
    TextHeightBehavior? heightBehavior,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
      textHeightBehavior: heightBehavior,
      maxLines: 1,
    );
    try {
      painter.layout(maxWidth: maxWidth);
      final lines = painter.computeLineMetrics();
      return lines.isEmpty ? painter.preferredLineHeight : lines.first.height;
    } finally {
      painter.dispose();
    }
  }

  /// 图标在首行实际行高中居中，避免顶端对齐让图标高于中文字及大字号正文。
  /// 正文仍独占右侧列，换行保持悬挂缩进；不将图标居中到整段说明，也不添加固定偏移。
  /// 系统粗体及文字间距偏好同时用于测量与显示，保证辅助设置下仍能对齐。
  @override
  Widget build(BuildContext context) {
    const iconSize = 16.0, gap = 8.0;
    final theme = Theme.of(context);
    final inherited = DefaultTextStyle.of(context);
    final style = inherited.style
        .merge(theme.textTheme.bodySmall)
        .copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: MediaQuery.boldTextOf(context) ? FontWeight.bold : null,
          height:
              MediaQuery.maybeLineHeightScaleFactorOverrideOf(context) ?? 1.5,
          letterSpacing: MediaQuery.maybeLetterSpacingOverrideOf(context),
          wordSpacing: MediaQuery.maybeWordSpacingOverrideOf(context),
        );
    final heightBehavior =
        inherited.textHeightBehavior ??
        DefaultTextHeightBehavior.maybeOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final firstLineHeight = _firstLineHeight(
          context,
          style,
          (constraints.maxWidth - iconSize - gap).clamp(0.0, double.infinity),
          heightBehavior,
        );
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: iconSize,
                height: firstLineHeight,
                child: Center(
                  child: Icon(
                    Icons.info_outline,
                    size: firstLineHeight.clamp(0.0, iconSize),
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: gap),
              Expanded(
                child: Text(
                  text,
                  style: style,
                  textHeightBehavior: heightBehavior,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
