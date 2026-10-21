package top.talyra42.verifin

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar
import java.util.Locale
import java.util.UUID

/**
 * 账户记账确认提醒：原生持久化排程，闹钟只展示通知，绝不写账目。
 * 每次触发按本地日历安排下次选定星期；冷启动、开机、升级和时区变化后可恢复。
 */
class AccountEntryReminderReceiver : BroadcastReceiver() {
    /**
     * [context] 为广播执行环境，[intent] 区分正式提醒、一次性测试和系统重排。
     * 测试从系统保存的 PendingIntent 读取文案，不依赖 Flutter 进程或正式提醒配置；
     * 正式提醒过期至隔天时不补发，防止误认消费日期。
     */
    override fun onReceive(context: Context, intent: Intent) {
        try {
            if (intent.action == TEST_FIRE) {
                val rule = JSONObject(intent.getStringExtra("testRule") ?: return)
                show(context, rule, intent.getLongExtra("due", 0L), isTest = true)
                return
            }
            val rules = readRules(context)
            if (intent.action != FIRE) {
                for (index in 0 until rules.length()) schedule(context, rules.getJSONObject(index))
                return
            }
            val rule = (0 until rules.length()).map { rules.getJSONObject(it) }
                .firstOrNull { it.optString("id") == intent.getStringExtra("id") } ?: return
            schedule(context, rule)
            val due = intent.getLongExtra("due", 0L)
            if (due <= 0 || dateKey(due) != dateKey(System.currentTimeMillis()) ||
                rule.optString("handledDate") == dateKey(due)) return
            show(context, rule, due)
        } catch (error: Exception) {
            // 广播没有 Flutter UI；仅记录阶段与异常类型，不记录账户名、金额或原文。
            Log.e("AccountEntryReminder", "账户提醒处理失败：${error.javaClass.simpleName}")
        }
    }

    companion object {
        const val ACTION = "top.talyra42.verifin.ACCOUNT_REMINDER_ACTION"
        private const val FIRE = "top.talyra42.verifin.ACCOUNT_REMINDER_FIRE"
        private const val TEST_FIRE = "top.talyra42.verifin.ACCOUNT_REMINDER_TEST"
        // 固定测试身份：连续测试只替换上一条测试，不覆盖任一账户的正式闹钟或通知。
        private const val TEST_ID = "account_reminder_test"
        private const val TEST_DELAY_MILLIS = 60_000L
        private const val STORE = "verifin_account_entry_reminders"
        private const val CHANNEL = "verifin_account_entry_reminder"

        /**
         * 安排一分钟后的一次性测试；[context] 提供系统服务，[title]、[body] 和
         * [channelName] 为 Flutter 传入的本地化通知文案及渠道名。
         * 返回是否使用精确闹钟；通知或渠道被禁用时抛错，不能向页面谎报成功。
         * 文案随 PendingIntent 交给系统保存，进程被回收后仍可触发；重启不恢复测试。
         */
        fun scheduleTest(context: Context, title: String, body: String, channelName: String): Boolean {
            val manager = requireNotNull(context.getSystemService(NotificationManager::class.java))
            ensureChannel(manager, channelName)
            check(NotificationManagerCompat.from(context).areNotificationsEnabled() &&
                (Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                    manager.getNotificationChannel(CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE)) {
                "系统通知或账户提醒渠道已关闭"
            }
            val due = System.currentTimeMillis() + TEST_DELAY_MILLIS
            val rule = JSONObject().put("id", TEST_ID).put("title", title)
                .put("body", body).put("channelName", channelName)
            val pending = PendingIntent.getBroadcast(context, 0,
                Intent(context, AccountEntryReminderReceiver::class.java).apply {
                    action = TEST_FIRE
                    data = Uri.parse("verifin://account-reminder/test/alarm")
                    putExtra("testRule", rule.toString())
                    putExtra("due", due)
                }, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            manager.cancel(TEST_ID, 0)
            return scheduleAlarm(context, due, pending)
        }

        /** 读取私有原生配置；内容损坏时交给同步入口报告，不猜测预设交易。 */
        private fun readRules(context: Context): JSONArray = JSONArray(
            context.getSharedPreferences(STORE, Context.MODE_PRIVATE).getString("rules", "[]"),
        )

        /** 同步 Dart 投影 [rules]；提交成功后撤销旧闹钟并重排，不依赖当前账本。 */
        fun sync(context: Context, rules: JSONArray) {
            val preferences = context.getSharedPreferences(STORE, Context.MODE_PRIVATE)
            val old = readRules(context)
            val token = preferences.getString("token", null) ?: UUID.randomUUID().toString()
            check(preferences.edit().putString("rules", rules.toString()).putString("token", token).commit()) {
                "账户提醒配置保存失败"
            }
            val nextIds = (0 until rules.length()).map { rules.getJSONObject(it).getString("id") }.toSet()
            for (index in 0 until old.length()) {
                val previous = old.getJSONObject(index)
                requireNotNull(context.getSystemService(AlarmManager::class.java)).cancel(alarmIntent(context, previous, 0))
                if (previous.getString("id") !in nextIds) {
                    requireNotNull(context.getSystemService(NotificationManager::class.java)).cancel(previous.getString("id"), 0)
                }
            }
            for (index in 0 until rules.length()) {
                val rule = rules.getJSONObject(index)
                if (rule.optString("handledDate") == dateKey(System.currentTimeMillis())) {
                    requireNotNull(context.getSystemService(NotificationManager::class.java)).cancel(rule.getString("id"), 0)
                }
                schedule(context, rule)
            }
        }

        /** 构造账户修订专属的闹钟身份；[due] 用于固定该次通知的真实日期。 */
        private fun alarmIntent(context: Context, rule: JSONObject, due: Long): PendingIntent =
            PendingIntent.getBroadcast(context, 0,
                Intent(context, AccountEntryReminderReceiver::class.java).apply {
                    action = FIRE
                    data = Uri.parse("verifin://account-reminder/alarm/${Uri.encode(rule.getString("id"))}")
                    putExtra("id", rule.getString("id"))
                    putExtra("due", due)
                }, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

        /**
         * 为 [rule] 的选定星期及本地时刻寻找下一次提醒，用 [context] 交给系统排程。
         * Calendar 按日历递增，避免夏令时的 23/25 小时偏移；跳过当天已处理的提醒。
         */
        private fun schedule(context: Context, rule: JSONObject) {
            val now = System.currentTimeMillis()
            val days = rule.getJSONArray("weekdays")
            val selected = (0 until days.length()).map { days.getInt(it) }.toSet()
            val candidate = Calendar.getInstance()
            for (offset in 0..7) {
                if (offset > 0) candidate.add(Calendar.DAY_OF_MONTH, 1)
                candidate.set(Calendar.HOUR_OF_DAY, rule.getInt("hour"))
                candidate.set(Calendar.MINUTE, rule.getInt("minute"))
                candidate.set(Calendar.SECOND, 0)
                candidate.set(Calendar.MILLISECOND, 0)
                val weekday = (candidate.get(Calendar.DAY_OF_WEEK) + 5) % 7 + 1
                if (weekday !in selected || candidate.timeInMillis <= now ||
                    rule.optString("handledDate") == dateKey(candidate.timeInMillis)) continue
                val pending = alarmIntent(context, rule, candidate.timeInMillis)
                scheduleAlarm(context, candidate.timeInMillis, pending)
                return
            }
        }

        /**
         * 正式提醒与测试共用排程：[context] 提供 AlarmManager，[due] 为触发时间戳，
         * [pending] 为系统届时发送的广播。优先精确闹钟；权限不足或检查后撤销时降级。
         * 返回 true 表示精确，false 表示非精确；不吞掉实际排程失败。
         */
        private fun scheduleAlarm(context: Context, due: Long, pending: PendingIntent): Boolean {
            val alarm = requireNotNull(context.getSystemService(AlarmManager::class.java))
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarm.canScheduleExactAlarms()) {
                try {
                    alarm.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, due, pending)
                    return true
                } catch (_: SecurityException) {
                    // 权限可能刚被用户撤销；仅此情况允许改用系统准许的非精确闹钟。
                }
            }
            alarm.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, due, pending)
            return false
        }

        /** 创建共用渠道；[manager] 是系统通知服务，[name] 是当前 app 语言下的渠道名。 */
        private fun ensureChannel(manager: NotificationManager, name: String) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                manager.createNotificationChannel(NotificationChannel(CHANNEL, name,
                    NotificationManager.IMPORTANCE_DEFAULT))
            }
        }

        /**
         * 通过 [context] 展示 [rule] 的标题/正文，[due] 标记计划时间。
         * 正式提醒保留两个自定义动作；[isTest] 为 true 时只允许打开应用，
         * 不生成确认/取消操作，避免测试消耗正式提醒的当天次数或误写真实账目。
         */
        private fun show(context: Context, rule: JSONObject, due: Long, isTest: Boolean = false) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
            val manager = requireNotNull(context.getSystemService(NotificationManager::class.java))
            ensureChannel(manager, rule.optString("channelName", context.getString(R.string.account_entry_reminder_channel)))
            val notification = NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(rule.getString("title"))
                .setContentText(rule.getString("body"))
                .setStyle(NotificationCompat.BigTextStyle().bigText(rule.getString("body")))
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                .setAutoCancel(isTest)
                .setWhen(due)
            if (isTest) {
                // 测试点击仅普通启动 MainActivity，不携带正式提醒 ACTION、令牌或交易参数。
                notification.setContentIntent(PendingIntent.getActivity(context, 0,
                    Intent(context, MainActivity::class.java).apply {
                        action = Intent.ACTION_MAIN
                        data = Uri.parse("verifin://account-reminder/test/open")
                        flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                    }, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            } else {
                notification.setContentIntent(actionIntent(context, rule, due, "open"))
                    .addAction(0, rule.getString("confirmLabel"), actionIntent(context, rule, due, "confirm"))
                    .addAction(0, rule.getString("cancelLabel"), actionIntent(context, rule, due, "cancel"))
            }
            manager.notify(rule.getString("id"), 0, notification.build())
        }

        /** 生成不可变操作 PendingIntent；私有随机令牌阻止其他应用伪造导出 Activity 操作。 */
        private fun actionIntent(context: Context, rule: JSONObject, due: Long, choice: String): PendingIntent =
            PendingIntent.getActivity(context, 0, Intent(context, MainActivity::class.java).apply {
                action = ACTION
                data = Uri.parse("verifin://account-reminder/action/${Uri.encode(rule.getString("id"))}/${dateKey(due)}/$choice")
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra("id", rule.getString("id"))
                putExtra("date", dateKey(due))
                putExtra("choice", choice)
                putExtra("token", context.getSharedPreferences(STORE, Context.MODE_PRIVATE).getString("token", ""))
            }, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

        /** 将点击写入持久队列；[intent] 只有来自本应用有效通知的令牌才允许入队。 */
        fun rememberAction(context: Context, intent: Intent?): Boolean {
            if (intent?.action != ACTION) return false
            val preferences = context.getSharedPreferences(STORE, Context.MODE_PRIVATE)
            val token = preferences.getString("token", null) ?: return false
            if (intent.getStringExtra("token") != token) return false
            val id = intent.getStringExtra("id") ?: return false
            val date = intent.getStringExtra("date") ?: return false
            val choice = intent.getStringExtra("choice") ?: return false
            if (choice !in setOf("open", "confirm", "cancel")) return false
            val key = "$id|$date|$choice"
            val queue = JSONArray(preferences.getString("actions", "[]"))
            val next = JSONArray()
            // 同一日期以最后一次显式选择为准；确认因缺汇率待重试时，取消仍能跳过它。
            for (index in 0 until queue.length()) {
                val item = queue.getJSONObject(index)
                if (item.optString("id") != id || item.optString("date") != date) next.put(item)
            }
            next.put(JSONObject().put("key", key).put("id", id).put("date", date).put("choice", choice))
            check(preferences.edit().putString("actions", next.toString()).commit()) { "账户提醒操作保存失败" }
            return true
        }

        /** 读取未确认消费的首项；失败或应用锁未通过时不会丢弃用户的点击。 */
        fun consumeAction(context: Context): Map<String, String>? {
            val queue = JSONArray(context.getSharedPreferences(STORE, Context.MODE_PRIVATE).getString("actions", "[]"))
            if (queue.length() == 0) return null
            val item = queue.getJSONObject(0)
            return listOf("key", "id", "date", "choice").associateWith { item.getString(it) }
        }

        /** 业务成功或通知已过期后移除 [key]，并关闭同修订的系统通知。 */
        fun acknowledgeAction(context: Context, key: String) {
            val preferences = context.getSharedPreferences(STORE, Context.MODE_PRIVATE)
            val queue = JSONArray(preferences.getString("actions", "[]"))
            val next = JSONArray()
            var id: String? = null
            for (index in 0 until queue.length()) {
                val item = queue.getJSONObject(index)
                if (item.getString("key") == key) id = item.getString("id") else next.put(item)
            }
            check(preferences.edit().putString("actions", next.toString()).commit()) { "账户提醒操作确认失败" }
            id?.let { requireNotNull(context.getSystemService(NotificationManager::class.java)).cancel(it, 0) }
        }

        /** 将时间戳格式化为本地日期键；仅用于持久幂等标识，不作为用户可见日期。 */
        private fun dateKey(time: Long): String {
            val calendar = Calendar.getInstance().apply { timeInMillis = time }
            return String.format(Locale.ROOT, "%04d-%02d-%02d", calendar.get(Calendar.YEAR),
                calendar.get(Calendar.MONTH) + 1, calendar.get(Calendar.DAY_OF_MONTH))
        }
    }
}
