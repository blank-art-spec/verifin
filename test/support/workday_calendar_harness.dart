import 'package:verifin/app/reminder/workday_calendar_client.dart';
import 'package:verifin/app/reminder/workday_calendar_sync.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'in_memory_ledger_repository.dart';

/// 记录请求年份并使用 [reply] 的隔离响应；任何测试均不会访问公网。
class FakeHolidayCalendarClient extends HolidayCalendarClient {
  /// [reply] 可返回真实格式模型、空占位或可控 Future，以测试请求撤销和失败。
  FakeHolidayCalendarClient(this.reply);

  final Future<HolidayCalendarDocument?> Function(int year) reply;
  final List<int> calls = [];

  /// 记录 [year] 后返回预设结果，不执行生产 HTTPS 逻辑。
  @override
  Future<HolidayCalendarDocument?> fetchYear(
    int year, {
    bool Function()? shouldContinue,
  }) {
    calls.add(year);
    return reply(year);
  }
}

/// 使用独立存储、内存仓储与 [client] 创建日历测试控制器。
/// 冷启动测试须显式复用 [store] 和 [repository]，才能验证持久化而非重新播种。
Future<VeriFinController> makeWorkdayCalendarController({
  required HolidayCalendarClient client,
  LocalKeyValueStore? store,
  InMemoryLedgerRepository? repository,
}) {
  final target = store ?? LocalKeyValueStore();
  target.write('verifin.locale.v1', 'zh');
  target.write('verifin.privacy_consent.v1', 'true');
  target.write('verifin.onboarding.v1', 'true');
  return VeriFinController.create(
    target,
    repository: repository ?? InMemoryLedgerRepository(),
    workdayCalendarClient: client,
  );
}
