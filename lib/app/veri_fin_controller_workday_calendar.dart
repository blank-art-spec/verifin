part of 'veri_fin_controller.dart';

/// 设备工作日日历的显式联网授权、受限下载、原子 KV 提交与跨年检查。
/// 网络等待不占用账目串行队列，关闭/初始化/销毁后不提交过时请求。
mixin _WorkdayCalendarOps on _ControllerState {
  /// 保存用户的 [enabled] 选择；先落盘再更新界面，关闭不删除已经下载的离线日历。
  /// 此方法本身不发请求，页面在开启成功后显式触发检查，启动/回前台也遵守开关。
  Future<bool> setWorkdayCalendarAutoUpdate(bool enabled) {
    // 单独识别初始化边界；连续开启/关闭仍按队列顺序保存，不能把最后一次关闭误作旧请求。
    final requestedReset = _workdayCalendarResetGeneration;
    if (!enabled) {
      _workdayCalendarPendingRevokes++;
      _workdayCalendarGeneration++;
    }
    return _enqueueCaptureMutation(() async {
      try {
        if (_controllerDisposed ||
            requestedReset != _workdayCalendarResetGeneration) {
          return false;
        }
        final current = workdayCalendarListenable.value;
        if (current.enabled == enabled) return true;
        final generation = ++_workdayCalendarGeneration;
        return await _writeWorkdayCalendarSettings(
          current.copyWith(enabled: enabled, updating: false),
          generation,
        );
      } finally {
        if (!enabled) _workdayCalendarPendingRevokes--;
      }
    });
  }

  /// 检查当前与下一年度；[force] 只绕过每日节流，不绕过用户联网授权。
  /// [client] 与 [now] 用于注入真实格式夹具和固定时钟；生产分别使用 HTTPS 与系统时间。
  /// 空占位和 404 记为尚无数据；失败年度保留原缓存，其他有效年度仍可独立保存。
  Future<WorkdayCalendarSyncResult> syncWorkdayCalendar({
    bool force = false,
    HolidayCalendarClient? client,
    DateTime? now,
  }) async {
    if (_controllerDisposed ||
        _workdayCalendarPendingRevokes > 0 ||
        !workdayCalendarListenable.value.enabled) {
      return WorkdayCalendarSyncResult.disabled;
    }
    if (_workdayCalendarBusy) return WorkdayCalendarSyncResult.skipped;
    final checkedAt = now ?? DateTime.now();
    final last = workdayCalendarListenable.value.checkedAt;
    // 这是实际网络频率控制，使用真实时长；跨年或系统时间回拨后必须重新检查。
    if (!force &&
        last != null &&
        last.year == checkedAt.year &&
        !checkedAt.isBefore(last) &&
        checkedAt.difference(last) < const Duration(hours: 24)) {
      return WorkdayCalendarSyncResult.skipped;
    }
    _workdayCalendarBusy = true;
    final generation = _workdayCalendarGeneration;
    final documents = {...workdayCalendarListenable.value.documents};
    final pending = <int>{};
    final failed = <int>{};
    var received = false;
    workdayCalendarListenable.value = workdayCalendarListenable.value.copyWith(
      updating: true,
    );
    try {
      for (final year in [checkedAt.year, checkedAt.year + 1]) {
        if (!_workdayCalendarRequestIsCurrent(generation)) {
          return WorkdayCalendarSyncResult.skipped;
        }
        try {
          final document = await (client ?? _workdayCalendarClient).fetchYear(
            year,
            shouldContinue: () => _workdayCalendarRequestIsCurrent(generation),
          );
          if (!_workdayCalendarRequestIsCurrent(generation)) {
            return WorkdayCalendarSyncResult.skipped;
          }
          if (document == null) {
            pending.add(year);
          } else {
            if (document.year != year) {
              throw const FormatException('下载年度与请求年份不符');
            }
            documents[year] = document;
            received = true;
          }
        } catch (error) {
          failed.add(year);
          _logger?.warning(
            '工作日日历下载或校验失败：年份=$year，异常=${error.runtimeType}',
            source: 'workday-calendar',
          );
        }
      }
      return await _enqueueCaptureMutation(() async {
        if (!_workdayCalendarRequestIsCurrent(generation)) {
          return WorkdayCalendarSyncResult.skipped;
        }
        // 保留上一年文件以处理十二月跨年修订；缓存上限为最近三份完整年度。
        documents.removeWhere(
          (year, _) => year < checkedAt.year - 1 || year > checkedAt.year + 1,
        );
        final next = workdayCalendarListenable.value.copyWith(
          documents: documents,
          checkedAt: checkedAt,
          pendingYears: pending,
          failedYears: failed,
          updating: false,
        );
        if (!await _writeWorkdayCalendarSettings(next, generation)) {
          return _workdayCalendarRequestIsCurrent(generation)
              ? WorkdayCalendarSyncResult.failed
              : WorkdayCalendarSyncResult.skipped;
        }
        if (failed.isNotEmpty) {
          return received
              ? WorkdayCalendarSyncResult.partial
              : WorkdayCalendarSyncResult.failed;
        }
        return pending.isNotEmpty
            ? WorkdayCalendarSyncResult.pending
            : WorkdayCalendarSyncResult.updated;
      });
    } finally {
      _workdayCalendarBusy = false;
      if (!_controllerDisposed && workdayCalendarListenable.value.updating) {
        workdayCalendarListenable.value = workdayCalendarListenable.value
            .copyWith(updating: false);
      }
    }
  }

  /// [generation] 必须仍属于当前授权；初始化或关闭开关使旧下载失效。
  bool _workdayCalendarRequestIsCurrent(int generation) =>
      !_controllerDisposed &&
      _workdayCalendarPendingRevokes == 0 &&
      generation == _workdayCalendarGeneration &&
      workdayCalendarListenable.value.enabled;

  /// 将 [next] 一次性保存到本机 KV；[generation] 防止异步落盘越过初始化边界。
  /// 失败保留原缓存与开关；异常交给统一 AppLogger/根级保存失败反馈。
  Future<bool> _writeWorkdayCalendarSettings(
    WorkdayCalendarSettings next,
    int generation,
  ) async {
    try {
      await _store.writeAndFlush(
        _workdayCalendarKey,
        jsonEncode(next.toJson()),
      );
      if (_controllerDisposed) return false;
      if (generation != _workdayCalendarGeneration) {
        // 初始化可能发生在 SharedPreferences 的 await 期间，恢复当前已撤权的状态。
        await _store.writeAndFlush(
          _workdayCalendarKey,
          jsonEncode(workdayCalendarListenable.value.toJson()),
        );
        return false;
      }
      workdayCalendarListenable.value = next;
      return true;
    } catch (error, stackTrace) {
      _handlePersistError(error, stackTrace);
      return false;
    }
  }
}
