package top.talyra42.verifin

import org.json.JSONObject
import java.util.Calendar
import java.util.TimeZone

/** 原生排程回归：不申请权限、不创建闹钟，也不读写设备中的真实提醒或账目。 */
internal object AccountReminderScheduleChecks {
    private val china = TimeZone.getTimeZone("Asia/Shanghai")

    /** 由现有 Instrumentation 的 account-reminder 套件调用，覆盖原生真实日期计算。 */
    fun runAll() {
        val rule = rule()
        check(!AccountReminderSchedule.matches(rule, day(2026, 10, 1))) { "国庆工作日不得提醒" }
        check(AccountReminderSchedule.matches(rule, day(2026, 10, 10))) { "周六补班不得被空星期列表过滤" }
        check(!AccountReminderSchedule.matches(rule, day(2026, 10, 11))) { "普通周日应跳过" }
        check(AccountReminderSchedule.nextTime(rule, day(2026, 2, 14, 13).timeInMillis, china) ==
            day(2026, 2, 24, 12, 30).timeInMillis) { "春节连休超过七天后仍须恢复提醒" }
        check(AccountReminderSchedule.nextTime(rule, day(2026, 10, 9, 13).timeInMillis, china) ==
            day(2026, 10, 10, 12, 30).timeInMillis) { "下一次须包含周末补班" }
        check(AccountReminderSchedule.nextTime(rule, day(2026, 12, 31, 13).timeInMillis, china) == null) {
            "跨入未知年度时必须默认暂停"
        }
        val persisted = JSONObject(rule.toString())
        check(AccountReminderSchedule.nextTime(persisted, day(2026, 2, 14, 13).timeInMillis, china) ==
            day(2026, 2, 24, 12, 30).timeInMillis) { "持久化快照重载后仍须独立跨长假排程" }
        val fallback = JSONObject(rule.toString()).put("missingCalendarPolicy", "weekdays")
        check(AccountReminderSchedule.nextTime(fallback, day(2026, 12, 31, 13).timeInMillis, china) ==
            day(2027, 1, 1, 12, 30).timeInMillis) { "明确选择后才按普通工作周降级" }
        check(!AccountReminderSchedule.matches(fallback, day(2027, 1, 2))) { "降级也应排除普通周末" }
        check(!AccountReminderSchedule.matches(fallback, day(2026, 10, 1))) { "已知年份不能套用降级策略" }
        val malformed = JSONObject(fallback.toString())
        malformed.getJSONObject("workdayCalendar").getJSONObject("years").put("2026", JSONObject())
        check(!AccountReminderSchedule.matches(malformed, day(2026, 10, 9))) { "损坏年度不能当作没有节假日" }
        val handled = JSONObject(rule.toString()).put("handledDate", "2026-10-09")
        check(AccountReminderSchedule.nextTime(handled, day(2026, 10, 9, 10).timeInMillis, china) ==
            day(2026, 10, 10, 12, 30).timeInMillis) { "处理后不重复安排当天" }
        val weekly = JSONObject(rule.toString()).put("repeatMode", "weekdays")
            .put("weekdays", org.json.JSONArray(listOf(1, 2, 3, 4, 5)))
        check(AccountReminderSchedule.matches(weekly, day(2026, 10, 1))) { "自定义星期保留旧行为" }
        check(!AccountReminderSchedule.matches(weekly, day(2026, 10, 10))) { "自定义星期不擅自加入调休" }
        weekly.remove("repeatMode")
        check(AccountReminderSchedule.matches(weekly, day(2026, 10, 1))) { "旧原生快照继续按星期" }
        val la = TimeZone.getTimeZone("America/Los_Angeles")
        weekly.put("weekdays", org.json.JSONArray(listOf(1, 2, 3, 4, 5, 6, 7)))
        check(AccountReminderSchedule.nextTime(weekly, day(2026, 3, 7, 13, zone = la).timeInMillis, la) ==
            day(2026, 3, 8, 12, 30, la).timeInMillis) { "夏令时切换后必须保留本地时刻" }
        check(AccountReminderSchedule.nextTime(weekly, day(2026, 10, 31, 13, zone = la).timeInMillis, la) ==
            day(2026, 11, 1, 12, 30, la).timeInMillis) { "夏令时结束后必须保留本地时刻" }
    }

    /** 构造隔离规则；年度片段只用于边界测试，完整官方数据另由 Dart 逐日核验。 */
    private fun rule(): JSONObject = JSONObject("""
        {"repeatMode":"chinaWorkdays","weekdays":[],"hour":12,"minute":30,
         "missingCalendarPolicy":"pause","handledDate":"",
         "workdayCalendar":{"version":1,"years":{"2026":{
           "holidays":[215,216,217,218,219,220,221,222,223,1001,1002,1003,1004,1005,1006,1007],
           "workdays":[214,1010]}}}}
    """.trimIndent())

    /** 将 [year]/[month]/[date] 和 [hour]/[minute] 解释为 [zone] 的本地日历时刻。 */
    private fun day(year: Int, month: Int, date: Int, hour: Int = 0, minute: Int = 0,
                    zone: TimeZone = china): Calendar = Calendar.getInstance(zone).apply {
        clear()
        set(year, month - 1, date, hour, minute)
    }
}
