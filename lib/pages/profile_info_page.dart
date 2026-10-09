import 'package:flutter/material.dart';

import '../app/avatar_picker.dart';
import '../app/app_theme.dart';
import '../app/common_widgets.dart';
import '../app/image_cropper.dart';
import '../l10n/app_localizations.dart';
import '../app/models.dart';
import '../app/veri_fin_scope.dart';
import 'profile_widgets.dart';

class ProfileInfoPage extends StatefulWidget {
  const ProfileInfoPage({super.key});

  @override
  State<ProfileInfoPage> createState() => _ProfileInfoPageState();
}

class _ProfileInfoPageState extends State<ProfileInfoPage> {
  final EditorExitController _exitController = EditorExitController();
  late TextEditingController _nicknameController;
  late TextEditingController _bioController;
  late TextEditingController _cityController;
  late TextEditingController _occupationController;
  late String _avatarDataUrl;
  late UserProfile _initialProfile;
  ProfileGender _gender = ProfileGender.unset;
  String _birthday = '';
  var _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) {
      return;
    }
    final profile = VeriFinScope.of(context).profile;
    _initialProfile = profile;
    _nicknameController = TextEditingController(text: profile.nickname);
    _bioController = TextEditingController(text: profile.bio);
    _cityController = TextEditingController(text: profile.city);
    _occupationController = TextEditingController(text: profile.occupation);
    _avatarDataUrl = profile.avatarDataUrl;
    _gender = profile.gender;
    _birthday = profile.birthday;
    _nicknameController.addListener(_handleDraftChanged);
    _bioController.addListener(_handleDraftChanged);
    _cityController.addListener(_handleDraftChanged);
    _occupationController.addListener(_handleDraftChanged);
    _initialized = true;
  }

  @override
  void dispose() {
    _nicknameController.removeListener(_handleDraftChanged);
    _bioController.removeListener(_handleDraftChanged);
    _cityController.removeListener(_handleDraftChanged);
    _occupationController.removeListener(_handleDraftChanged);
    _nicknameController.dispose();
    _bioController.dispose();
    _cityController.dispose();
    _occupationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = VeriFinScope.of(context);
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final identityColor = veriSemantic(context, veriBlue);
    final detailsColor = veriSemantic(context, veriIncome);

    return UnsavedChangesGuard(
      isDirty: _isDirty,
      onSave: _save,
      exitController: _exitController,
      child: Scaffold(
        body: SafeArea(
          child: VeriPage(
            child: Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
                  child: VeriHeader(
                    title: l10n.personalInfo,
                    showBack: true,
                    actions: <Widget>[
                      SaveHeaderAction(
                        onPressed: _isDirty ? _saveAndExit : null,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 28),
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    children: <Widget>[
                      VeriCard(
                        onTap: _pickAvatar,
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: <Widget>[
                            Stack(
                              children: <Widget>[
                                DecoratedBox(
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: theme.colorScheme.primaryContainer,
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.all(6),
                                    child: ProfileAvatar(
                                      profile: controller.profile.copyWith(
                                        nickname: _nicknameController.text,
                                        avatarDataUrl: _avatarDataUrl,
                                      ),
                                      radius: 32,
                                    ),
                                  ),
                                ),
                                Positioned(
                                  right: 0,
                                  bottom: 0,
                                  child: Container(
                                    padding: const EdgeInsets.all(6),
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme.primary,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: veriContentSurfaceColor(
                                          theme.brightness,
                                        ),
                                        width: 2,
                                      ),
                                    ),
                                    child: Icon(
                                      Icons.photo_camera_outlined,
                                      color: theme.colorScheme.onPrimary,
                                      size: 16,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    l10n.profileAvatarTitle,
                                    style: theme.textTheme.titleMedium
                                        ?.copyWith(fontWeight: FontWeight.w800),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    l10n.profileChangeAvatar,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: identityColor,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              Icons.chevron_right,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      _ProfileFormSection(
                        title: l10n.profileBasicSection,
                        icon: Icons.badge_outlined,
                        color: identityColor,
                        children: <Widget>[
                          TextField(
                            controller: _nicknameController,
                            textInputAction: TextInputAction.next,
                            decoration: InputDecoration(
                              labelText: l10n.nicknameLabel,
                              prefixIcon: const Icon(Icons.person_outline),
                            ),
                          ),
                          const SizedBox(height: 14),
                          TextField(
                            key: const Key('profile_bio_field'),
                            controller: _bioController,
                            minLines: 2,
                            maxLines: 4,
                            textAlignVertical: TextAlignVertical.top,
                            decoration: InputDecoration(
                              labelText: l10n.bioLabel,
                              prefixIcon: const Icon(Icons.notes_outlined),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      _ProfileFormSection(
                        title: l10n.profileDetailsSection,
                        icon: Icons.assignment_ind_outlined,
                        color: detailsColor,
                        children: <Widget>[
                          VeriAnchoredChoice<ProfileGender>(
                            key: const Key('profile_gender_choice'),
                            values: ProfileGender.values,
                            selected: _gender,
                            idOf: (value) => 'profile_gender_${value.name}',
                            labelOf: (value) => value.label(l10n),
                            iconOf: (value) => switch (value) {
                              ProfileGender.unset =>
                                Icons.remove_circle_outline,
                              ProfileGender.male => Icons.male_rounded,
                              ProfileGender.female => Icons.female_rounded,
                            },
                            onSelected: (value) =>
                                setState(() => _gender = value),
                            semanticLabel: l10n.pickGenderTitle,
                            builder: (context, openMenu, menuOpen) =>
                                SelectField(
                                  label: l10n.genderLabel,
                                  value: _gender.label(l10n),
                                  icon: Icons.person_outline,
                                  onTap: openMenu,
                                ),
                          ),
                          const SizedBox(height: 14),
                          SelectField(
                            key: const Key('profile_birthday_field'),
                            label: l10n.birthdayLabel,
                            value: _birthday.isEmpty
                                ? l10n.clearOption
                                : _birthday,
                            icon: Icons.cake_outlined,
                            suffixIcon: _birthday.isEmpty
                                ? null
                                : IconButton(
                                    key: const Key('profile_birthday_clear'),
                                    tooltip: l10n.birthdayClear,
                                    onPressed: _clearBirthday,
                                    icon: const Icon(Icons.close),
                                  ),
                            onTap: _pickBirthday,
                          ),
                          const SizedBox(height: 14),
                          TextField(
                            controller: _cityController,
                            textInputAction: TextInputAction.next,
                            decoration: InputDecoration(
                              labelText: l10n.cityLabel,
                              prefixIcon: const Icon(
                                Icons.location_on_outlined,
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          TextField(
                            controller: _occupationController,
                            textInputAction: TextInputAction.done,
                            decoration: InputDecoration(
                              labelText: l10n.occupationLabel,
                              prefixIcon: const Icon(Icons.work_outline),
                            ),
                          ),
                        ],
                      ),
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

  Future<void> _pickBirthday() async {
    final initial = DateTime.tryParse(_birthday) ?? DateTime(1998);
    final selected = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
    );
    if (selected != null && mounted) {
      setState(() {
        _birthday =
            '${selected.year}-${selected.month.toString().padLeft(2, '0')}-${selected.day.toString().padLeft(2, '0')}';
      });
    }
  }

  void _clearBirthday() {
    setState(() => _birthday = '');
  }

  Future<void> _pickAvatar() async {
    final rawImage = await pickRawImageDataUrl();
    if (rawImage == null || !mounted) {
      return;
    }
    final crop = await showImageCropper(
      context: context,
      imageDataUrl: rawImage,
      title: AppLocalizations.of(context).cropAvatarTitle,
      aspectRatio: 1,
      circlePreview: true,
    );
    if (crop == null || !mounted) {
      return;
    }
    final avatar = await runWithLoadingDialog<String?>(
      context: context,
      message: AppLocalizations.of(context).avatarGenerating,
      task: () => cropImageDataUrl(
        sourceDataUrl: rawImage,
        targetWidth: 512,
        targetHeight: 512,
        zoom: crop.zoom,
        offsetX: crop.offsetX,
        offsetY: crop.offsetY,
      ),
    );
    if (avatar != null && mounted) {
      setState(() => _avatarDataUrl = avatar);
    }
  }

  void _handleDraftChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  UserProfile _draftProfile({required bool useNicknameFallback}) {
    final nickname = _nicknameController.text.trim();
    return UserProfile(
      nickname: useNicknameFallback && nickname.isEmpty ? 'Veri Fin' : nickname,
      bio: _bioController.text.trim(),
      avatarDataUrl: _avatarDataUrl,
      gender: _gender,
      birthday: _birthday,
      city: _cityController.text.trim(),
      occupation: _occupationController.text.trim(),
    );
  }

  bool get _isDirty {
    final draft = _draftProfile(useNicknameFallback: false);
    return draft.nickname != _initialProfile.nickname ||
        draft.bio != _initialProfile.bio ||
        draft.avatarDataUrl != _initialProfile.avatarDataUrl ||
        draft.gender != _initialProfile.gender ||
        draft.birthday != _initialProfile.birthday ||
        draft.city != _initialProfile.city ||
        draft.occupation != _initialProfile.occupation;
  }

  Future<void> _saveAndExit() async {
    if (await _save() && mounted) {
      setState(() {
        _initialProfile = _draftProfile(useNicknameFallback: true);
      });
      _exitController.exit();
    }
  }

  Future<bool> _save() async {
    final l10n = AppLocalizations.of(context);
    final nickname = _nicknameController.text.trim();
    if (nickname.isEmpty) {
      final confirmed = await showConfirmDialog(
        context,
        title: l10n.nicknameEmptyTitle,
        message: l10n.nicknameEmptyMessage,
        confirmLabel: l10n.commonSave,
      );
      if (confirmed != true || !mounted) {
        return false;
      }
    }
    return VeriFinScope.of(
      context,
    ).saveProfileDraft(_draftProfile(useNicknameFallback: true));
  }
}

/// 个人资料的分组表单；局部填色不改变其它页面的输入框主题。
class _ProfileFormSection extends StatelessWidget {
  const _ProfileFormSection({
    required this.title,
    required this.icon,
    required this.color,
    required this.children,
  });

  final String title;
  final IconData icon;
  final Color color;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return VeriCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              VeriIconBox(icon: icon, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Theme(
            data: theme.copyWith(
              inputDecorationTheme: theme.inputDecorationTheme.copyWith(
                fillColor: theme.brightness == Brightness.dark
                    ? veriSurfaceAltDark
                    : veriSurfaceAltLight,
                floatingLabelBehavior: FloatingLabelBehavior.always,
                prefixIconColor: color,
              ),
            ),
            child: Column(children: children),
          ),
        ],
      ),
    );
  }
}
