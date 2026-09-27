package top.talyra42.verifin

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony

/**
 * 可选的新短信采集接收器。
 *
 * 仅在用户打开短信开关且已授予 RECEIVE_SMS 时处理未来新短信；不申请 READ_SMS、
 * 不扫描历史收件箱。多段短信按发送方和本次广播顺序拼接为一条原始事件。
 */
class SmsCaptureReceiver : BroadcastReceiver() {
    /** 收到 SMS_RECEIVED 广播时提取发送方与正文，经金融关键词过滤后写入原始队列。 */
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        if (!AutoCaptureBridge.smsEnabled(context)) return
        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent)
        if (messages.isEmpty()) return
        val sender = messages.firstOrNull()?.originatingAddress.orEmpty()
        val body = messages.joinToString(separator = "") { it.messageBody.orEmpty() }.trim()
        if (!AutoCaptureBridge.looksFinancial(body)) return
        val timestamp = messages.minOfOrNull { it.timestampMillis } ?: System.currentTimeMillis()
        val eventId = "$sender:$timestamp:${body.hashCode()}"
        AutoCaptureBridge.enqueue(
            context = context,
            sourceKind = "sms",
            sourceId = sender,
            sourceLabel = sender.ifBlank { "短信" },
            sourceEventId = eventId,
            rawText = body,
            receivedAt = timestamp,
        )
    }
}
