package top.talyra42.verifin

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/**
 * 支付通知监听服务。
 *
 * 用户必须在系统“通知使用权”页面显式授权。服务仅提取通知标题/正文并写原始队列，
 * 不启动界面、不调用 AI、不生成交易，也不会监听本应用自己的通知。
 */
class PaymentNotificationListenerService : NotificationListenerService() {
    /** 系统发布通知时调用；按用户白名单与金融关键词过滤后保存原文。 */
    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        sbn ?: return
        if (!AutoCaptureBridge.notificationEnabled(this)) return
        val sourcePackage = sbn.packageName ?: return
        if (sourcePackage == packageName) return
        if (!AutoCaptureBridge.notificationSourceAllowed(this, sourcePackage)) return
        val rawText = extractText(sbn) ?: return
        if (!AutoCaptureBridge.looksFinancial(rawText)) return
        AutoCaptureBridge.enqueue(
            context = this,
            sourceKind = "notification",
            sourceId = sourcePackage,
            sourceLabel = applicationLabel(sourcePackage),
            sourceEventId = sbn.key ?: "",
            rawText = rawText,
            receivedAt = sbn.postTime,
        )
    }

    /** 从标准 Notification extras 合并标题、大文本与正文，忽略空通知。 */
    private fun extractText(sbn: StatusBarNotification): String? {
        val extras = sbn.notification?.extras ?: return null
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim().orEmpty()
        val bigText = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()?.trim().orEmpty()
        val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()?.trim().orEmpty()
        val body = if (bigText.isNotEmpty()) bigText else text
        return listOf(title, body).filter { it.isNotEmpty() }.joinToString("\n").ifBlank { null }
    }

    /** 根据包名解析系统显示名；失败时保留包名，绝不影响原始事件保存。 */
    private fun applicationLabel(sourcePackage: String): String = try {
        val info = packageManager.getApplicationInfo(sourcePackage, 0)
        packageManager.getApplicationLabel(info).toString()
    } catch (_: Exception) {
        sourcePackage
    }
}
