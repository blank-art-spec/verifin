package top.talyra42.verifin

import org.json.JSONObject
import java.util.Calendar
import java.util.Locale
import java.util.TimeZone

/**
 * 账户提醒的纯日期规则，不访问账目、网络、系统权限或 Flutter。
 * 公共年度日历由 Dart 同步到规则的 workdayCalendar，避免两端各维护一份调休表。
 */
internal object AccountReminderSchedule {
    // 搜索一个完整日历年，覆盖春节等超过一周的连休；无匹配结果安全暂停。
    private const val MAX_SEARCH_DAYS = 366

    /**
     * [rule] 为已持久化的提醒，[day] 为设备时区下的候选日。
     * 旧规则没有 repeatMode 时仍按星期；工作日模式不受自定义星期限制。
     * 缺少年度数据默认不提醒，仅明确选择 weekdays 时才按周一至周五降级。
     */
    fun matches(rule: JSONObject, day: Calendar): Boolean {
        val weekday = (day.get(Calendar.DAY_OF_WEEK) + 5) % 7 + 1
        return when (rule.optString("repeatMode", "weekdays")) {
            "weekdays" -> {
                val days = rule.optJSONArray("weekdays") ?: return false
                (0 until days.length()).any { days.optInt(it) == weekday }
            }
            "chinaWorkdays" -> {
                val calendar = rule.optJSONObject("workdayCalendar")
                val year = if (calendar?.optInt("version") == 1)
                    calendar.optJSONObject("years")?.optJSONObject(day.get(Calendar.YEAR).toString())
                else null
                if (year == null) {
                    rule.optString("missingCalendarPolicy") == "weekdays" && weekday <= 5
                } else {
                    // 年份存在但结构损坏时停止，不能当作全年没有节假日。
                    val holidays = year.optJSONArray("holidays") ?: return false
                    val workdays = year.optJSONArray("workdays") ?: return false
                    val monthDay = (day.get(Calendar.MONTH) + 1) * 100 + day.get(Calendar.DAY_OF_MONTH)
                    when {
                        (0 until workdays.length()).any { workdays.optInt(it) == monthDay } -> true
                        (0 until holidays.length()).any { holidays.optInt(it) == monthDay } -> false
                        else -> weekday <= 5
                    }
                }
            }
            else -> false // 未知重复模式不擅自变更用户授权范围。
        }
    }

    /**
     * 从 [now] 之后寻找 [rule] 的下一次时刻；[timeZone] 默认跟随设备，可在测试中注入。
     * 按日历日推进并重设时分，避免把一天固定算作 24 小时造成夏令时偏移。
     * 当天已确认或取消、年度日历缺失且选择暂停、配置非法时均不制造补发。
     */
    fun nextTime(rule: JSONObject, now: Long, timeZone: TimeZone = TimeZone.getDefault()): Long? {
        val hour = rule.optInt("hour", -1)
        val minute = rule.optInt("minute", -1)
        if (hour !in 0..23 || minute !in 0..59) return null
        val candidate = Calendar.getInstance(timeZone).apply { timeInMillis = now }
        for (offset in 0..MAX_SEARCH_DAYS) {
            if (offset > 0) candidate.add(Calendar.DAY_OF_MONTH, 1)
            candidate.set(Calendar.HOUR_OF_DAY, hour)
            candidate.set(Calendar.MINUTE, minute)
            candidate.set(Calendar.SECOND, 0)
            candidate.set(Calendar.MILLISECOND, 0)
            if (candidate.timeInMillis <= now || !matches(rule, candidate) ||
                rule.optString("handledDate") == dateKey(candidate)) continue
            return candidate.timeInMillis
        }
        return null
    }

    /** 将 [day] 的本地年月日编码为稳定幂等键，不用于用户可见的日期展示。 */
    fun dateKey(day: Calendar): String = String.format(Locale.ROOT, "%04d-%02d-%02d",
        day.get(Calendar.YEAR), day.get(Calendar.MONTH) + 1, day.get(Calendar.DAY_OF_MONTH))
}
