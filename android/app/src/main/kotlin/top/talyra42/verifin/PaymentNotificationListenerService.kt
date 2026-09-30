package top.talyra42.verifin

import android.app.Notification
import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log

/**
 * 支付通知监听服务。
 *
 * 用户必须在系统“通知使用权”页面显式授权。服务仅提取通知标题/正文并写原始队列，
 * 不启动界面、不调用 AI、不生成交易，也不会监听本应用自己的通知。服务连接状态和
 * 最近一次处理阶段会写入不含正文的本机诊断快照，方便区分系统未连接、正文提取失败、
 * 金融过滤未通过和成功入队。
 */
class PaymentNotificationListenerService : NotificationListenerService() {
    /**
     * 系统确认监听服务已连接时调用。
     *
     * 除了更新实时连接状态，还补抓最近 24 小时内、且不早于用户开启采集时间的活动
     * 通知。这样服务短暂被系统回收后，只要支付通知仍在通知栏，重连时仍有机会入队；
     * 稳定事件号会挡住系统重复回调。
     */
    override fun onListenerConnected() {
        super.onListenerConnected()
        val recoveryStart = recoveryStartTime()
        AutoCaptureBridge.updateNotificationListenerConnection(this, true)
        Log.i(LOG_TAG, "通知监听服务已连接")
        if (!AutoCaptureBridge.notificationEnabled(this)) return
        try {
            activeNotifications
                ?.asSequence()
                ?.filter { it.postTime >= recoveryStart }
                ?.forEach(::captureNotification)
        } catch (error: SecurityException) {
            // 部分 ROM 在授权刚切换时会短暂拒绝读取活动通知；后续实时回调仍可继续工作。
            Log.w(LOG_TAG, "通知监听服务重连后读取活动通知失败", error)
        }
    }

    /** 系统发布通知时调用；按用户白名单与金融关键词过滤后保存原文。 */
    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        sbn ?: return
        captureNotification(sbn)
    }

    /**
     * 系统断开监听服务时调用。Android 7.0 及以上立即请求重新绑定；旧系统只能等待
     * 系统自行恢复。请求重绑不会打开界面，也不会改变用户的通知使用权授权。
     */
    override fun onListenerDisconnected() {
        AutoCaptureBridge.updateNotificationListenerConnection(this, false)
        Log.w(LOG_TAG, "通知监听服务已断开，正在请求系统重新连接")
        requestReconnect(this)
        super.onListenerDisconnected()
    }

    /** 服务实例销毁时清掉进程内连接标记，避免页面把历史连接误显示为当前连接。 */
    override fun onDestroy() {
        AutoCaptureBridge.updateNotificationListenerConnection(this, false)
        Log.i(LOG_TAG, "通知监听服务已销毁")
        super.onDestroy()
    }

    /**
     * 执行一条通知的完整原生采集管线，并在每个提前返回点留下不含正文的诊断结果。
     *
     * @param sbn Android 交给监听服务的状态栏通知。
     */
    private fun captureNotification(sbn: StatusBarNotification) {
        val sourcePackage = sbn.packageName ?: return
        if (sourcePackage == packageName) return
        if (!AutoCaptureBridge.notificationEnabled(this)) {
            AutoCaptureBridge.recordNotificationDiagnostic(
                context = this,
                sourceId = "",
                sourceLabel = "",
                textExtraction = "notRun",
                financialFilter = "notRun",
                queueResult = "notRun",
                outcome = "nativeDisabled",
                occurredAt = sbn.postTime,
            )
            return
        }
        val sourceLabel = applicationLabel(sourcePackage)
        if (!AutoCaptureBridge.notificationSourceAllowed(this, sourcePackage)) {
            AutoCaptureBridge.recordNotificationDiagnostic(
                context = this,
                sourceId = sourcePackage,
                sourceLabel = sourceLabel,
                textExtraction = "notRun",
                financialFilter = "notRun",
                queueResult = "notRun",
                outcome = "sourceBlocked",
                occurredAt = sbn.postTime,
            )
            return
        }
        val rawText = extractText(sbn)
        if (rawText == null) {
            AutoCaptureBridge.recordNotificationDiagnostic(
                context = this,
                sourceId = sourcePackage,
                sourceLabel = sourceLabel,
                textExtraction = "failed",
                financialFilter = "notRun",
                queueResult = "notRun",
                outcome = "textUnavailable",
                occurredAt = sbn.postTime,
            )
            return
        }
        if (!AutoCaptureBridge.looksFinancial(rawText)) {
            AutoCaptureBridge.recordNotificationDiagnostic(
                context = this,
                sourceId = sourcePackage,
                sourceLabel = sourceLabel,
                textExtraction = "success",
                financialFilter = "rejected",
                queueResult = "notRun",
                outcome = "financialRejected",
                occurredAt = sbn.postTime,
            )
            return
        }
        val queueResult = AutoCaptureBridge.enqueue(
            context = this,
            sourceKind = "notification",
            sourceId = sourcePackage,
            sourceLabel = sourceLabel,
            sourceEventId = AutoCaptureBridge.notificationEventId(
                notificationKey = sbn.key,
                postTime = sbn.postTime,
                rawText = rawText,
            ),
            rawText = rawText,
            receivedAt = sbn.postTime,
        )
        if (queueResult == AutoCaptureEnqueueResult.WRITE_FAILED) {
            // 只记录来源包名，不输出通知正文或金额等敏感信息。
            Log.e(LOG_TAG, "自动采集原生队列保存失败：$sourcePackage")
        }
        AutoCaptureBridge.recordNotificationDiagnostic(
            context = this,
            sourceId = sourcePackage,
            sourceLabel = sourceLabel,
            textExtraction = "success",
            financialFilter = "passed",
            queueResult = queueResult.diagnosticCode,
            outcome = when (queueResult) {
                AutoCaptureEnqueueResult.ENQUEUED -> "queued"
                AutoCaptureEnqueueResult.DUPLICATE -> "duplicate"
                AutoCaptureEnqueueResult.INVALID_TEXT -> "textUnavailable"
                AutoCaptureEnqueueResult.WRITE_FAILED -> "queueWriteFailed"
            },
            occurredAt = sbn.postTime,
        )
    }

    /**
     * 从常见 Notification 样式合并用户可见文字。
     *
     * 除标题、大文本和正文外，同时兼容多行文本、副标题、摘要、信息文字、会话标题、
     * MessagingStyle 当前/历史消息以及 tickerText。使用有序集合去重，避免同一句正文
     * 在多个 extras 字段重复出现。完全由自定义 RemoteViews 绘制且没有任何标准 extras
     * 或 ticker 的通知仍会明确记录为 textUnavailable，而不是静默消失。
     *
     * @param sbn Android 状态栏通知。
     * @return 合并后的非空正文；没有可读取文字时返回 null。
     */
    private fun extractText(sbn: StatusBarNotification): String? {
        val notification = sbn.notification ?: return null
        val extras = notification.extras
        val values = linkedSetOf<String>()

        /** 归一化一段可见文本并加入有序集合；空白不会进入结果。 */
        fun add(value: CharSequence?) {
            val normalized = value?.toString()?.trim().orEmpty()
            if (normalized.isNotEmpty()) values.add(normalized)
        }

        add(extras.getCharSequence(Notification.EXTRA_TITLE))
        add(extras.getCharSequence(Notification.EXTRA_TITLE_BIG))
        add(extras.getCharSequence(Notification.EXTRA_BIG_TEXT))
        add(extras.getCharSequence(Notification.EXTRA_TEXT))
        add(extras.getCharSequence(Notification.EXTRA_SUB_TEXT))
        add(extras.getCharSequence(Notification.EXTRA_SUMMARY_TEXT))
        add(extras.getCharSequence(Notification.EXTRA_INFO_TEXT))
        add(extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE))
        extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)?.forEach(::add)
        appendMessageTexts(extras.get(Notification.EXTRA_MESSAGES), ::add)
        appendMessageTexts(extras.get(Notification.EXTRA_HISTORIC_MESSAGES), ::add)
        add(notification.tickerText)
        return values.joinToString("\n").ifBlank { null }
    }

    /**
     * 提取 MessagingStyle bundle 数组中的消息正文。
     *
     * @param rawValue Notification extras 中的消息数组；类型异常时安全忽略。
     * @param add 由调用方提供的文本归一化与去重函数。
     */
    private fun appendMessageTexts(rawValue: Any?, add: (CharSequence?) -> Unit) {
        val messages = rawValue as? Array<*> ?: return
        for (message in messages) {
            val bundle = message as? Bundle ?: continue
            add(bundle.getCharSequence("text"))
        }
    }

    /**
     * 计算服务重连后补抓活动通知的起点。
     *
     * 起点取“用户本次开启采集”“上次服务断开”“最近 24 小时”三者中最晚者，既尽量
     * 找回短暂断线期间的支付通知，也不会在一次重连后翻出很久以前仍驻留的通知。
     */
    private fun recoveryStartTime(): Long {
        val now = System.currentTimeMillis()
        return maxOf(
            AutoCaptureBridge.notificationEnabledAt(this),
            AutoCaptureBridge.notificationListenerDisconnectedAt(this),
            now - ACTIVE_NOTIFICATION_RECOVERY_WINDOW_MS,
        )
    }

    /** 根据包名解析系统显示名；失败时保留包名，绝不影响原始事件保存。 */
    private fun applicationLabel(sourcePackage: String): String = try {
        val info = packageManager.getApplicationInfo(sourcePackage, 0)
        packageManager.getApplicationLabel(info).toString()
    } catch (_: Exception) {
        sourcePackage
    }

    companion object {
        private const val LOG_TAG = "VeriFinCapture"
        private const val ACTIVE_NOTIFICATION_RECOVERY_WINDOW_MS = 24L * 60L * 60L * 1_000L

        /**
         * 请求 Android 重新绑定通知监听服务。
         *
         * @param context 任意应用 Context，用于定位本应用的监听服务组件。
         * @return 已向系统发出请求时为 true；Android 7.0 以下或系统拒绝时为 false。
         */
        fun requestReconnect(context: Context): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return false
            return try {
                NotificationListenerService.requestRebind(
                    ComponentName(context, PaymentNotificationListenerService::class.java),
                )
                true
            } catch (error: RuntimeException) {
                Log.w(LOG_TAG, "请求系统重新连接通知监听服务失败", error)
                false
            }
        }
    }
}
