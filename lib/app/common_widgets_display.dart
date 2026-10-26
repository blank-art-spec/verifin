part of 'common_widgets.dart';

// 图标与小型展示控件：账户/分类图标盒、筛选丸、详情行、汇总指标等。

class AccountIconBox extends StatelessWidget {
  const AccountIconBox({super.key, required this.iconCode, this.size = 28});

  final String iconCode;
  final double size;

  @override
  Widget build(BuildContext context) {
    final assetPath =
        accountIconAssetPath(iconCode) ??
        genericAccountIconAssetPaths['wallet']!;
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all((size * 0.10).clamp(2, 6).toDouble()),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(veriRadiusSm),
        border: Border.all(color: Colors.black.withValues(alpha: 0.08)),
      ),
      child: SvgPicture.asset(assetPath, fit: BoxFit.contain),
    );
  }
}

class FilterPill extends StatelessWidget {
  const FilterPill({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.showChevron = true,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: isDark ? veriSurfaceAltDark : veriSurfaceLight,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: isDark ? Colors.white.withValues(alpha: 0.10) : veriLine,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: 16),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.78),
                ),
              ),
              if (showChevron) ...<Widget>[
                const SizedBox(width: 4),
                const Icon(Icons.keyboard_arrow_down, size: 16),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class DetailInfoRow extends StatelessWidget {
  /// [label] 为字段名，[value] 为完整内容；[inline] 在普通字号下左右对齐，
  /// 窄容器或大字号自动上下排列。[valueColor] 仅供调用方传入已解析的语义色。
  /// 默认保留原有纵向详情样式，避免改变其他页面。
  const DetailInfoRow({
    super.key,
    required this.label,
    required this.value,
    this.placeholder = false,
    this.onTap,
    this.inline = false,
    this.valueColor,
  });

  final String label;
  final String value;
  final bool placeholder;
  final VoidCallback? onTap;
  final bool inline;
  final Color? valueColor;

  /// 根据可用宽度与系统文字缩放分配标签和值；不省略金额或长合约代码。
  @override
  Widget build(BuildContext context) {
    final textColor = Theme.of(context).colorScheme.onSurface;
    if (inline) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final stacked =
              constraints.maxWidth < 280 ||
              MediaQuery.textScalerOf(context).scale(13) > 18;
          final labelText = Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          );
          final valueText = Text(
            value,
            textAlign: stacked ? TextAlign.start : TextAlign.end,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: valueColor ?? textColor,
              fontWeight: FontWeight.w600,
            ),
          );
          final content = Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: stacked
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [labelText, const SizedBox(height: 4), valueText],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Expanded(flex: 4, child: labelText),
                      const SizedBox(width: 12),
                      Expanded(flex: 6, child: valueText),
                    ],
                  ),
          );
          return onTap == null
              ? content
              : InkWell(onTap: onTap, child: content);
        },
      );
    }
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      label,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: textColor.withValues(alpha: 0.36),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      value,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: textColor.withValues(
                          alpha: placeholder ? 0.32 : 0.88,
                        ),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              if (onTap != null)
                Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: textColor.withValues(alpha: 0.30),
                ),
            ],
          ),
        ),
        Divider(color: textColor.withValues(alpha: 0.07)),
      ],
    );
    if (onTap == null) {
      return content;
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: content,
    );
  }
}

/// Currency-aware editable amount row shared by transaction, refund and
/// recurring editors. A null amount is rendered as an explicit missing state.
class CurrencyAmountField extends StatelessWidget {
  const CurrencyAmountField({
    super.key,
    required this.label,
    required this.currencyCode,
    required this.amount,
    required this.missingText,
    this.onTap,
    this.forceUnit = true,
  });

  final String label;
  final String currencyCode;
  final double? amount;
  final String missingText;
  final VoidCallback? onTap;

  /// 是否强制显示单位，默认 true。
  ///
  /// **默认值不要改成跟随隐藏闸门**：记账页 / 交易详情页 / 周期规则页允许用币种选择器
  /// 临时选一个账本里还没有的币种，那一刻账本按已落库数据仍算单币种、闸门是关的，但同一
  /// 控件已经同时出现两个币种的金额，单位必须保留。退款表单两端金额被锁死为原支出币种，
  /// 不可能出现第二个币种，属例外（显式传 false）。
  final bool forceUnit;

  @override
  Widget build(BuildContext context) {
    return DetailInfoRow(
      label: label,
      value: amount == null
          ? missingText
          : formatUserMoney(amount!, currencyCode, forceUnit: forceUnit),
      placeholder: amount == null,
      onTap: onTap,
    );
  }
}

/// 页面 / 卡片副标题里的「单位：x」。
///
/// [prefix] 是副标题里与单位无关的上下文（书名、账户类型、日期范围、统计区间）。
/// 单位隐藏时：有 [prefix] 就只返回 [prefix]（不能把书名一起丢掉）；没有 [prefix] 的
/// 副标题整条返回 null，**调用方必须整段省略**，不要渲染只剩分隔符或空白的残句。
String? currencyUnitSubtitle(
  AppLocalizations l10n,
  String? prefix,
  String currencyCode,
) {
  final hasPrefix = prefix != null && prefix.isNotEmpty;
  final unit = optionalCurrencyUnit(currencyCode);
  if (unit == null) return hasPrefix ? prefix : null;
  final label = l10n.moneyUnitLabel(unit);
  return hasPrefix ? '$prefix · $label' : label;
}

/// 聚合卡片/页面使用的轻量金额单位提示，避免在每个数字旁重复堆叠货币标识。
class MoneyUnitLabel extends StatelessWidget {
  const MoneyUnitLabel({super.key, required this.currencyCode, this.color});

  final String currencyCode;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    // 单币种账本按偏好隐藏单位时整块不渲染：聚合卡片里的数字本身已经不带单位，
    // 只在卡片角落留一句「单位：¥」是纯噪声（空态卡片里连数字都没有，更明显）。
    final unit = optionalCurrencyUnit(currencyCode);
    if (unit == null) return const SizedBox.shrink();
    final foreground =
        color ??
        Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.46);
    return Text(
      AppLocalizations.of(context).moneyUnitLabel(unit),
      key: Key('money_unit_$currencyCode'),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: foreground,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class SummaryMetric extends StatelessWidget {
  /// 创建标准的“标签、数值、补充说明”指标，必须放在 Row 的子级中。
  ///
  /// [label] 为本地化指标名，[value] 为已格式化的完整数值，
  /// [color] 为调用方解析后的数值颜色，[detail] 为可选占比等次级说明。
  /// [allowValueWrap] 默认为 false，沿用既有单行数值；证券概览显式开启时，
  /// 标签、数值和说明均居中完整换行，避免大字号或长金额被省略。
  const SummaryMetric({
    super.key,
    required this.label,
    required this.value,
    required this.color,
    this.detail,
    this.allowValueWrap = false,
  });

  final String label;
  final String value;
  final Color color;
  final String? detail;
  final bool allowValueWrap;

  /// 根据 [context] 的主题渲染指标，保留 Expanded 以均分父 Row 的宽度。
  /// 开启完整换行时不限定数值行数，其余页面继续使用原有的单行显示行为。
  @override
  Widget build(BuildContext context) {
    final textColor = Theme.of(context).colorScheme.onSurface;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Text(
            label,
            textAlign: allowValueWrap ? TextAlign.center : null,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: textColor.withValues(
                alpha: veriUnifiedDesignPreview ? 0.68 : 0.54,
              ),
            ),
          ),
          const SizedBox(height: 7),
          Text(
            value,
            textAlign: allowValueWrap ? TextAlign.center : null,
            maxLines: allowValueWrap ? null : 1,
            overflow: allowValueWrap ? null : TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: color,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          if (detail != null) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              detail!,
              textAlign: allowValueWrap ? TextAlign.center : null,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: textColor.withValues(
                  alpha: veriUnifiedDesignPreview ? 0.62 : 0.42,
                ),
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class VeriIconBox extends StatelessWidget {
  const VeriIconBox({
    super.key,
    required this.icon,
    this.color = veriRoyal,
    this.size = 30,
  });

  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(veriRadiusSm),
      ),
      child: Icon(icon, size: size * 0.54, color: color),
    );
  }
}

/// 分类图标盒：内置图标走 [iconForCode] 上色渲染；emoji 自定义图标（`emoji:` 前缀）
/// 以原色字符居中渲染（emoji 自带颜色，不上色）。统一分类图标的展示入口。
class CategoryIconBox extends StatelessWidget {
  const CategoryIconBox({
    super.key,
    required this.iconCode,
    this.color = veriRoyal,
    this.size = 30,
  });

  final String iconCode;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (isEmojiIconCode(iconCode)) {
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.13),
          borderRadius: BorderRadius.circular(veriRadiusSm),
        ),
        child: Text(
          emojiOfIconCode(iconCode),
          style: TextStyle(fontSize: size * 0.56, height: 1),
        ),
      );
    }
    return VeriIconBox(icon: iconForCode(iconCode), color: color, size: size);
  }
}

/// 分类图标的裸字形（无背景盒）：内置图标为 [Icon]，emoji 为 [Text]。
/// 用于 Chip avatar、内联小图标等不需要色块背景的场景。
class CategoryGlyph extends StatelessWidget {
  const CategoryGlyph({
    super.key,
    required this.iconCode,
    this.size = 18,
    this.color,
  });

  final String iconCode;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    if (isEmojiIconCode(iconCode)) {
      return Text(
        emojiOfIconCode(iconCode),
        style: TextStyle(fontSize: size, height: 1),
      );
    }
    return Icon(iconForCode(iconCode), size: size, color: color);
  }
}

class VeriSectionAction extends StatelessWidget {
  const VeriSectionAction({
    super.key,
    required this.icon,
    this.onPressed,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return IconButton.filledTonal(
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        fixedSize: const Size(32, 32),
        minimumSize: const Size(32, 32),
        padding: EdgeInsets.zero,
        backgroundColor: veriSemantic(
          context,
          veriBlue,
        ).withValues(alpha: 0.10),
        foregroundColor: veriRoyal,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(veriRadiusSm),
        ),
      ),
      icon: Icon(icon, size: 18),
    );
  }
}
