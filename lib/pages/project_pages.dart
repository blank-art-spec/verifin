import 'dart:async';

import 'package:flutter/material.dart';

import '../app/common_widgets.dart';
import '../app/feedback.dart';
import '../app/ledger_math.dart';
import '../app/models.dart';
import '../app/report_analysis.dart';
import '../app/veri_fin_scope.dart';
import '../l10n/app_localizations.dart';
import 'sheets.dart';
import 'transactions_pages.dart';

/// 当前账本项目入口：独立展示预算、已花与状态，历史归档项目仍可查看。
class ProjectManagementPage extends StatelessWidget {
  const ProjectManagementPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = VeriFinScope.of(context);
    final l10n = AppLocalizations.of(context);
    final projects = controller.projects;
    return Scaffold(
      body: SafeArea(
        child: VeriPage(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
            children: <Widget>[
              VeriHeader(
                title: l10n.projectsTitle,
                showBack: true,
                actions: <Widget>[
                  HeaderAction(
                    icon: Icons.add,
                    tooltip: l10n.projectAdd,
                    onPressed: () => Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => const ProjectEditorPage(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (projects.isEmpty) VeriCard(child: Text(l10n.projectsEmpty)),
              for (final project in projects) ...<Widget>[
                VeriCard(
                  onTap: () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => ProjectDetailPage(projectId: project.id),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              project.name,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          Text(_projectStatusLabel(l10n, project.status)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        l10n.projectSpent(
                          formatAmount(controller.projectSpent(project)),
                        ),
                      ),
                      if (project.budget != null)
                        Text(
                          l10n.projectRemaining(
                            formatAmount(
                              project.budget! -
                                  controller.projectSpent(project),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 项目详情汇总关联交易，按分类查看开支构成并可跳转交易列表。
class ProjectDetailPage extends StatelessWidget {
  const ProjectDetailPage({super.key, required this.projectId});
  final String projectId;

  @override
  Widget build(BuildContext context) {
    final controller = VeriFinScope.of(context);
    final l10n = AppLocalizations.of(context);
    final project = controller.projects
        .where((item) => item.id == projectId)
        .firstOrNull;
    if (project == null) {
      return Scaffold(
        body: SafeArea(
          child: VeriPage(child: Center(child: Text(l10n.projectsEmpty))),
        ),
      );
    }
    final entries = controller.entries
        .where(
          (entry) =>
              entry.bookId == project.bookId &&
              entry.tagIds.any(
                (id) => controller.tagById(id)?.id == project.tagId,
              ),
        )
        .toList();
    final stats = reportCategoryStats(
      entries,
      controller.categories,
      EntryType.expense,
    );
    final dateFormat = MaterialLocalizations.of(context);
    return Scaffold(
      body: SafeArea(
        child: VeriPage(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
            children: <Widget>[
              VeriHeader(
                title: project.name,
                showBack: true,
                actions: <Widget>[
                  HeaderAction(
                    icon: Icons.edit_outlined,
                    tooltip: l10n.commonEdit,
                    onPressed: () => Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => ProjectEditorPage(original: project),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              VeriCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      l10n.projectSpent(
                        formatAmount(controller.projectSpent(project)),
                      ),
                    ),
                    if (project.budget != null) ...<Widget>[
                      Text(
                        l10n.projectBudgetValue(formatAmount(project.budget!)),
                      ),
                      Text(
                        l10n.projectRemaining(
                          formatAmount(
                            project.budget! - controller.projectSpent(project),
                          ),
                        ),
                      ),
                    ],
                    Text(_projectStatusLabel(l10n, project.status)),
                    if (project.startDate != null)
                      Text(
                        l10n.projectStartValue(
                          dateFormat.formatMediumDate(project.startDate!),
                        ),
                      ),
                    if (project.endDate != null)
                      Text(
                        l10n.projectEndValue(
                          dateFormat.formatMediumDate(project.endDate!),
                        ),
                      ),
                    if (project.note.isNotEmpty) Text(project.note),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              VeriCard(
                onTap: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => TransactionsPage(
                      initialTagId: project.tagId,
                      title: project.name,
                    ),
                  ),
                ),
                child: Row(
                  children: <Widget>[
                    Expanded(child: Text(l10n.projectEntries(entries.length))),
                    const Icon(Icons.chevron_right),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Text(
                l10n.projectCategoryBreakdown,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              for (final stat in stats) ...<Widget>[
                const SizedBox(height: 8),
                VeriCard(
                  child: Row(
                    children: <Widget>[
                      Expanded(child: Text(stat.category.label)),
                      Text(formatAmount(stat.amount)),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 项目编辑页只收集项目元数据；保存时由控制器原子提交项目及关联标签。
class ProjectEditorPage extends StatefulWidget {
  const ProjectEditorPage({super.key, this.original});
  final Project? original;

  @override
  State<ProjectEditorPage> createState() => _ProjectEditorPageState();
}

class _ProjectEditorPageState extends State<ProjectEditorPage> {
  late final TextEditingController _name;
  late final TextEditingController _budget;
  late final TextEditingController _note;
  DateTime? _startDate;
  DateTime? _endDate;
  ProjectStatus _status = ProjectStatus.active;

  @override
  void initState() {
    super.initState();
    final project = widget.original;
    _name = TextEditingController(text: project?.name ?? '');
    _budget = TextEditingController(text: project?.budget?.toString() ?? '');
    _note = TextEditingController(text: project?.note ?? '');
    _startDate = project?.startDate;
    _endDate = project?.endDate;
    _status = project?.status ?? ProjectStatus.active;
  }

  @override
  void dispose() {
    _name.dispose();
    _budget.dispose();
    _note.dispose();
    super.dispose();
  }

  /// 打开系统日期选择器，返回后只更新页面草稿。
  Future<void> _pickDate({required bool start}) async {
    final selected = await showDatePicker(
      context: context,
      initialDate: (start ? _startDate : _endDate) ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (!mounted || selected == null) return;
    setState(() {
      if (start) {
        _startDate = selected;
      } else {
        _endDate = selected;
      }
    });
  }

  /// 按用户选择更新项目状态，归档后标签将从新记账选择器隐藏。
  Future<void> _pickStatus() async {
    final selected = await showOptionSheet<ProjectStatus>(
      context: context,
      title: AppLocalizations.of(context).projectStatus,
      values: ProjectStatus.values,
      selected: _status,
      labelOf: (value) =>
          _projectStatusLabel(AppLocalizations.of(context), value),
    );
    if (!mounted || selected == null) return;
    setState(() => _status = selected);
  }

  /// 校验预算和日期，保存项目后返回上一页；失败提示并保留草稿供修正。
  Future<void> _save() async {
    final budgetText = _budget.text.trim();
    final budget = budgetText.isEmpty ? null : double.tryParse(budgetText);
    if (_name.text.trim().isEmpty ||
        (budgetText.isNotEmpty && budget == null) ||
        (budget != null && (!budget.isFinite || budget < 0)) ||
        (_startDate != null &&
            _endDate != null &&
            _startDate!.isAfter(_endDate!))) {
      if (mounted) {
        unawaited(
          VeriFeedbackHost.of(context).showMessage(
            message: AppLocalizations.of(context).projectInvalid,
            tone: VeriFeedbackTone.warning,
          ),
        );
      }
      return;
    }
    final result = await VeriFinScope.of(context).saveProject(
      original: widget.original,
      name: _name.text,
      budget: budget,
      startDate: _startDate,
      endDate: _endDate,
      status: _status,
      note: _note.text,
    );
    if (!mounted) return;
    if (result != null) {
      Navigator.of(context).pop();
    } else {
      unawaited(
        VeriFeedbackHost.of(context).showMessage(
          message: AppLocalizations.of(context).saveFailed,
          tone: VeriFeedbackTone.warning,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final dateFormat = MaterialLocalizations.of(context);
    return Scaffold(
      body: SafeArea(
        child: VeriPage(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
            children: <Widget>[
              VeriHeader(
                title: widget.original == null
                    ? l10n.projectAdd
                    : l10n.projectEdit,
                showBack: true,
                actions: <Widget>[SaveHeaderAction(onPressed: _save)],
              ),
              const SizedBox(height: 10),
              VeriCard(
                child: Column(
                  children: <Widget>[
                    TextField(
                      controller: _name,
                      decoration: InputDecoration(labelText: l10n.projectName),
                    ),
                    TextField(
                      controller: _budget,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: l10n.projectBudget,
                      ),
                    ),
                    TextField(
                      controller: _note,
                      maxLines: 3,
                      decoration: InputDecoration(labelText: l10n.projectNote),
                    ),
                    SettingsRow(
                      icon: Icons.event_available_outlined,
                      title: l10n.tagRuleStartDate,
                      trailing: _startDate == null
                          ? l10n.commonNoneShort
                          : dateFormat.formatMediumDate(_startDate!),
                      trailingIcon: Icons.chevron_right,
                      onTap: () => _pickDate(start: true),
                    ),
                    if (_startDate != null)
                      TextButton(
                        onPressed: () => setState(() => _startDate = null),
                        child: Text(l10n.commonClear),
                      ),
                    SettingsRow(
                      icon: Icons.event_outlined,
                      title: l10n.tagRuleEndDate,
                      trailing: _endDate == null
                          ? l10n.commonNoneShort
                          : dateFormat.formatMediumDate(_endDate!),
                      trailingIcon: Icons.chevron_right,
                      onTap: () => _pickDate(start: false),
                    ),
                    if (_endDate != null)
                      TextButton(
                        onPressed: () => setState(() => _endDate = null),
                        child: Text(l10n.commonClear),
                      ),
                    SettingsRow(
                      icon: Icons.flag_outlined,
                      title: l10n.projectStatus,
                      trailing: _projectStatusLabel(l10n, _status),
                      trailingIcon: Icons.chevron_right,
                      onTap: _pickStatus,
                    ),
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

/// 项目状态集中本地化，管理、详情和编辑页共用同一含义。
String _projectStatusLabel(AppLocalizations l10n, ProjectStatus status) =>
    switch (status) {
      ProjectStatus.active => l10n.projectStatusActive,
      ProjectStatus.completed => l10n.projectStatusCompleted,
      ProjectStatus.archived => l10n.projectStatusArchived,
    };
