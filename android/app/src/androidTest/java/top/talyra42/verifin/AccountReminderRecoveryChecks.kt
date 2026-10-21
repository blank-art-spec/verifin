package top.talyra42.verifin

import android.app.AlarmManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.os.SystemClock
import org.json.JSONObject

/** 实际 Android 持久化/通知回归；仅允许 diagnostic 包，私有配置另行隔离并在最后清理。 */
internal object AccountReminderRecoveryChecks {
    private const val action = "top.talyra42.verifin.ACCOUNT_REMINDER_TEST"
    private const val tag = "account_reminder_test"

    fun runAll(base: Context) {
        check(base.packageName.endsWith(".graphicsdiagnostic")) { "恢复回归只能运行于隔离应用" }
        val context = object : ContextWrapper(base) {
            override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
                base.getSharedPreferences("account-reminder-recovery-test", mode)
        }
        val preferences = context.getSharedPreferences("ignored", Context.MODE_PRIVATE)
        val alarms = requireNotNull(context.getSystemService(AlarmManager::class.java))
        val notifications = requireNotNull(context.getSystemService(NotificationManager::class.java))
        fun record() = JSONObject(requireNotNull(preferences.getString("test", null)))
        fun save(rule: JSONObject) { check(preferences.edit().putString("test", rule.toString()).commit()) }
        fun intent(revision: String) = Intent(context, AccountEntryReminderReceiver::class.java).apply {
            this.action = AccountReminderRecoveryChecks.action
            data = Uri.parse("verifin://account-reminder/test/alarm")
            putExtra("revision", revision)
        }
        fun pending() = PendingIntent.getBroadcast(context, 0, intent(""),
            PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE)
        fun awaitNotification(present: Boolean) {
            val end = SystemClock.elapsedRealtime() + 2_000L
            while (notifications.activeNotifications.any { it.tag == tag } != present &&
                SystemClock.elapsedRealtime() < end) SystemClock.sleep(20L)
            check(notifications.activeNotifications.any { it.tag == tag } == present) { "系统通知状态不符" }
        }
        try {
            check(preferences.edit().clear().commit())
            AccountEntryReminderReceiver.scheduleTest(context, "恢复回归", "测试不会记账", "账户记账提醒")
            val first = record()
            val oldRevision = first.getString("revision")
            alarms.cancel(requireNotNull(pending()))
            // 正式配置为空也不能清掉独立测试；覆盖未启用提醒和初始化账目后的同步路径。
            AccountEntryReminderReceiver.sync(context, org.json.JSONArray())
            check(record().getString("revision") == oldRevision && record().getLong("due") == first.getLong("due")) {
                "系统任务丢失后恢复必须保留原截止时间及修订"
            }
            check(AccountEntryReminderReceiver.deliveryStatus(context)["testState"] == "pending")
            AccountEntryReminderReceiver.scheduleTest(context, "替换测试", "不记账", "账户记账提醒")
            val next = record()
            check(next.getString("revision") != oldRevision)
            AccountEntryReminderReceiver().onReceive(context, intent(oldRevision))
            check(record().getString("state") == "pending" && notifications.activeNotifications.none { it.tag == tag }) {
                "旧广播不得把替换后的测试提前发出"
            }
            next.put("due", System.currentTimeMillis() - 1_000L)
            save(next)
            AccountEntryReminderReceiver().onReceive(context, intent(next.getString("revision")))
            check(record().getString("state") == "posted")
            awaitNotification(true)
            check(notifications.activeNotifications.count { it.tag == tag } == 1)
            // 清掉已发布的通知后重放，若去重失败会重新出现。
            notifications.cancel(tag, 0)
            awaitNotification(false)
            AccountEntryReminderReceiver().onReceive(context, intent(next.getString("revision")))
            AccountEntryReminderReceiver.restore(context)
            check(notifications.activeNotifications.none { it.tag == tag }) { "已发布测试不得在恢复时重发" }
            AccountEntryReminderReceiver.scheduleTest(context, "过期测试", "不记账", "账户记账提醒")
            save(record().put("due", System.currentTimeMillis() - 600_000L)
                .put("expiresAt", System.currentTimeMillis() - 1_000L))
            AccountEntryReminderReceiver.restore(context)
            check(record().getString("state") == "expired")
            check(notifications.activeNotifications.none { it.tag == tag }) { "过期测试不得补发" }
            check(preferences.edit().putString("test", "损坏记录").commit())
            AccountEntryReminderReceiver.restore(context)
            AccountEntryReminderReceiver.sync(context, org.json.JSONArray())
            check(AccountEntryReminderReceiver.deliveryStatus(context)["testState"] == "failed") {
                "损坏测试不得伪报成功或阻止正式规则同步"
            }
        } finally {
            pending()?.let { alarms.cancel(it); it.cancel() }
            notifications.cancel(tag, 0)
            check(preferences.edit().clear().commit())
        }
    }
}
