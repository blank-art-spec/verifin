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
    /** 收到闹钟或系统重排广播；过期至隔天的闹钟不补发，防止误认消费日期。 */
    override fun onReceive(context: Context, intent: Intent) {
        try {
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
        private const val STORE = "verifin_account_entry_reminders"
        private const val CHANNEL = "verifin_account_entry_reminder"

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

        /** 从现在起寻找下一次选定星期；Calendar 按日历递增，避免夏令时的 23/25 小时偏移。 */
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
                val alarm = requireNotNull(context.getSystemService(AlarmManager::class.java))
                val pending = alarmIntent(context, rule, candidate.timeInMillis)
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarm.canScheduleExactAlarms()) {
                    try {
                        alarm.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, candidate.timeInMillis, pending)
                    } catch (_: SecurityException) {
                        // 用户可能在检查后撤销精确闹钟权限；改为系统允许的非精确排程。
                        alarm.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, candidate.timeInMillis, pending)
                    }
                } else {
                    alarm.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, candidate.timeInMillis, pending)
                }
                return
            }
        }

        /** 展示带两个自定义按钮的实色系统通知；按钮打开应用，由应用锁之后的 Dart 处理。 */
        private fun show(context: Context, rule: JSONObject, due: Long) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
            val manager = requireNotNull(context.getSystemService(NotificationManager::class.java))
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                manager.createNotificationChannel(NotificationChannel(CHANNEL,
                    rule.optString("channelName", context.getString(R.string.account_entry_reminder_channel)),
                    NotificationManager.IMPORTANCE_DEFAULT))
            }
            val notification = NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(rule.getString("title"))
                .setContentText(rule.getString("body"))
                .setStyle(NotificationCompat.BigTextStyle().bigText(rule.getString("body")))
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                .setAutoCancel(false)
                .setWhen(due)
                .setContentIntent(actionIntent(context, rule, due, "open"))
                .addAction(0, rule.getString("confirmLabel"), actionIntent(context, rule, due, "confirm"))
                .addAction(0, rule.getString("cancelLabel"), actionIntent(context, rule, due, "cancel"))
                .build()
            manager.notify(rule.getString("id"), 0, notification)
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
