import '../l10n/app_localizations.dart';
import 'models.dart';

/// 系统维度按当前界面语言显示；用户创建的维度保留原始名称。
String tagGroupDisplayName(TagGroup group, AppLocalizations l10n) =>
    switch (group.id) {
      'project' => l10n.tagGroupProject,
      'scene' => l10n.tagGroupScene,
      'purpose' => l10n.tagGroupPurpose,
      'person' => l10n.tagGroupPerson,
      'place' => l10n.tagGroupPlace,
      'custom' => l10n.tagGroupCustom,
      _ => group.name,
    };
