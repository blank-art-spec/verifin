import 'dart:async';

import 'package:flutter/material.dart';

import '../app/common_widgets.dart';
import '../app/models.dart';
import '../app/platform_bridge.dart';
import '../l10n/app_localizations.dart';

/// 自动匹配是有效业务选项，不与取消选择的 null 混用。
const String _automaticAccountType = 'automatic';

class AutoCaptureSourcesPage extends StatefulWidget {
  const AutoCaptureSourcesPage({
    super.key,
    required this.settings,
    required this.onSave,
    this.knownApps = const <String, String>{},
  });

  final AutoCaptureSettings settings;
  final Future<bool> Function(AutoCaptureSettings) onSave;
  final Map<String, String> knownApps;

  @override
  State<AutoCaptureSourcesPage> createState() => _AutoCaptureSourcesPageState();
}

class _AutoCaptureSourcesPageState extends State<AutoCaptureSourcesPage> {
  late bool _listenAll;
  late final Set<String> _allowed;
  late final Set<String> _excluded;
  late final Map<String, AccountType> _accountTypes;
  final Map<String, String> _apps = <String, String>{};
  final Set<String> _installed = <String>{};
  bool _loading = true;
  bool _loadFailed = false;
  bool _saving = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _listenAll = widget.settings.listenAllNotificationSources;
    _excluded = widget.settings.excludedSourcePackages.toSet();
    _allowed = widget.settings.sourcePackages.toSet()..removeAll(_excluded);
    _accountTypes = Map<String, AccountType>.of(
      widget.settings.notificationAccountTypes,
    );
    _apps.addAll(widget.knownApps);
    for (final package in <String>{
      ..._allowed,
      ..._excluded,
      ..._accountTypes.keys,
    }) {
      _apps.putIfAbsent(package, () => package);
    }
    unawaited(_loadApps());
  }

  Future<void> _loadApps() async {
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    final apps = await AppAutoCaptureBridge.installedNotificationApps(
      knownPackages: _apps.keys.toList(),
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      _loadFailed = apps == null;
      if (apps != null) {
        _installed.clear();
        for (final app in apps) {
          _apps[app.packageName] = app.label;
          _installed.add(app.packageName);
        }
      }
    });
  }

  Future<void> _save() async {
    if (_saving || _loading) return;
    setState(() => _saving = true);
    final next = widget.settings.copyWith(
      listenAllNotificationSources: _listenAll,
      sourcePackages: _allowed.toList()..sort(),
      excludedSourcePackages: _excluded.toList()..sort(),
      sourcePackagesConfigured: true,
      notificationAccountTypes: Map<String, AccountType>.of(_accountTypes),
    );
    final saved = await widget.onSave(next);
    if (!mounted) return;
    setState(() => _saving = false);
    if (saved) Navigator.of(context).pop();
  }

  void _toggleApp(String package, bool selected) {
    setState(() {
      final selection = _listenAll ? _excluded : _allowed;
      if (selected) {
        selection.add(package);
        // 两个模式保持互斥，避免界面显示允许、原生却被旧排除配置拦截。
        (_listenAll ? _allowed : _excluded).remove(package);
      } else {
        selection.remove(package);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final query = _query.trim().toLowerCase();
    final apps =
        _apps.entries
            .where(
              (entry) =>
                  entry.key.toLowerCase().contains(query) ||
                  entry.value.toLowerCase().contains(query),
            )
            .toList()
          ..sort((a, b) {
            final labels = a.value.toLowerCase().compareTo(
              b.value.toLowerCase(),
            );
            return labels == 0 ? a.key.compareTo(b.key) : labels;
          });
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        body: SafeArea(
          child: VeriPage(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 36),
              itemCount: apps.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      VeriHeader(
                        title: l10n.autoCaptureAppSourcesTitle,
                        subtitle: l10n.autoCaptureAppSourcesDesc,
                        showBack: true,
                        onBack: _saving ? () {} : null,
                        actions: <Widget>[
                          SaveHeaderAction(
                            onPressed: _saving || _loading ? null : _save,
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      VeriCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            VeriAnchoredChoice<bool>(
                              values: const <bool>[false, true],
                              selected: _listenAll,
                              idOf: (value) => value ? 'excluded' : 'allowed',
                              labelOf: (value) => value
                                  ? l10n.autoCaptureExcludedMode
                                  : l10n.autoCaptureAllowedMode,
                              onSelected: (value) =>
                                  setState(() => _listenAll = value),
                              semanticLabel: l10n.autoCaptureAppSourcesTitle,
                              builder: (context, openMenu, menuOpen) =>
                                  TextButton.icon(
                                    onPressed: _saving ? null : openMenu,
                                    icon: const Icon(Icons.filter_list),
                                    label: Text(
                                      _listenAll
                                          ? l10n.autoCaptureExcludedMode
                                          : l10n.autoCaptureAllowedMode,
                                    ),
                                  ),
                            ),
                            Text(
                              _listenAll
                                  ? l10n.autoCaptureExcludedModeHint
                                  : l10n.autoCaptureAllowedModeHint,
                            ),
                            const SizedBox(height: 8),
                            Text(l10n.autoCaptureAccountTypeHint),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        enabled: !_saving,
                        onChanged: (value) => setState(() => _query = value),
                        decoration: InputDecoration(
                          hintText: l10n.autoCaptureAppsSearch,
                          prefixIcon: const Icon(Icons.search),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        l10n.autoCaptureAppsVisibilityHint,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (_loading) const LinearProgressIndicator(),
                      if (_loadFailed) ...<Widget>[
                        Text(l10n.autoCaptureAppsReadFailed),
                        TextButton.icon(
                          onPressed: _saving ? null : _loadApps,
                          icon: const Icon(Icons.refresh),
                          label: Text(l10n.retryLabel),
                        ),
                      ],
                      if (!_loading && apps.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Text(l10n.autoCaptureAppsEmpty),
                        ),
                      const SizedBox(height: 12),
                    ],
                  );
                }
                final app = apps[index - 1];
                final selected = (_listenAll ? _excluded : _allowed).contains(
                  app.key,
                );
                final type = _accountTypes[app.key];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: VeriCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text(app.value.isEmpty ? app.key : app.value),
                          subtitle: Text(app.key),
                          value: selected,
                          onChanged: _saving
                              ? null
                              : (value) => _toggleApp(app.key, value ?? false),
                        ),
                        if (!_loading &&
                            !_loadFailed &&
                            !_installed.contains(app.key))
                          Text(
                            l10n.autoCaptureAppNotVisible,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        VeriAnchoredChoice<String>(
                          values: <String>[
                            _automaticAccountType,
                            ...AccountType.values.map((type) => type.name),
                          ],
                          selected: type?.name ?? _automaticAccountType,
                          idOf: (value) => value,
                          labelOf: (value) => value == _automaticAccountType
                              ? l10n.autoCaptureAccountTypeAuto
                              : AccountType.values
                                    .firstWhere((type) => type.name == value)
                                    .label(l10n),
                          onSelected: (value) => setState(() {
                            if (value == _automaticAccountType) {
                              _accountTypes.remove(app.key);
                            } else {
                              _accountTypes[app.key] = AccountType.values
                                  .firstWhere((type) => type.name == value);
                            }
                          }),
                          semanticLabel: l10n.autoCaptureAppAccountType,
                          builder: (context, openMenu, menuOpen) => TextButton.icon(
                            onPressed: _saving ? null : openMenu,
                            icon: const Icon(
                              Icons.account_balance_wallet_outlined,
                            ),
                            label: Text(
                              '${l10n.autoCaptureAppAccountType} · ${type?.label(l10n) ?? l10n.autoCaptureAccountTypeAuto}',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
