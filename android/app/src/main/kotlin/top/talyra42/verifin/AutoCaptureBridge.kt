package top.talyra42.verifin

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** 原生队列写入结果；用于区分幂等去重、无效正文与真正的持久化失败。 */
enum class AutoCaptureEnqueueResult(val diagnosticCode: String) {
    ENQUEUED("enqueued"),
    DUPLICATE("duplicate"),
    INVALID_TEXT("invalidText"),
    WRITE_FAILED("writeFailed"),
}

/**
 * 自动采集原生侧持久队列。
 *
 * 原生只做三件事：读取用户开关、捕获原始文本、在 Flutter 不运行时把事件安全存入
 * SharedPreferences。金额/账户/类型/去重与正式落账全部由 Dart 的 CaptureEvent 管线处理。
 */
object AutoCaptureBridge {
    private const val PREFS = "verifin_auto_capture_v2"
    private const val KEY_NOTIFICATION_ENABLED = "notificationEnabled"
    private const val KEY_SMS_ENABLED = "smsEnabled"
    private const val KEY_LISTEN_ALL = "listenAll"
    private const val KEY_PACKAGES = "packages"
    private const val KEY_QUEUE = "queue"
    private const val KEY_NOTIFICATION_ENABLED_AT = "notificationEnabledAt"
    private const val KEY_LISTENER_CONNECTED_AT = "listenerConnectedAt"
    private const val KEY_LISTENER_DISCONNECTED_AT = "listenerDisconnectedAt"
    private const val KEY_LAST_NOTIFICATION_DIAGNOSTIC = "lastNotificationDiagnostic"
    private const val MAX_QUEUE_SIZE = 200
    private const val MAX_TEXT_LENGTH = 8_000

    /**
     * 当前进程内通知监听服务是否已收到系统连接回调。
     *
     * 这个值不能只写入 SharedPreferences：进程被系统回收后，磁盘上的旧 true 并不代表
     * 新进程里的服务已经重新绑定。用进程内状态配合最近连接时间，页面才能区分“曾经
     * 连上过”和“此刻确实已连接”。
     */
    @Volatile
    private var notificationListenerConnected = false

    /**
     * 为一次通知发布生成稳定事件号。
     *
     * Android 的通知 key 代表“当前通知槽位”，同一 App 更新同一个通知时可能重复使用；
     * 只保存 key 会把后续真实交易误判为旧事件。这里把发布时间、原文长度与本地哈希一并
     * 纳入事件号：同一次系统回调可稳定去重，而同槽位的新内容仍会形成新原始事件。
     *
     * @param notificationKey 系统通知槽位 key，部分设备可能为空。
     * @param postTime 系统记录的本次发布时间（毫秒）。
     * @param rawText 本次提取的标题与正文，仅计算本地哈希，不写入事件号明文。
     * @return 仅在本机用于幂等判断的事件号。
     */
    fun notificationEventId(
        notificationKey: String?,
        postTime: Long,
        rawText: String,
    ): String = listOf(
        notificationKey.orEmpty(),
        postTime.toString(),
        rawText.length.toString(),
        rawText.hashCode().toString(),
    ).joinToString("|")

    /** Flutter 引擎存活时的轻量通知；进程被杀时为空，持久队列仍照常写入。 */
    @Volatile
    var onQueueAvailable: (() -> Unit)? = null

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /**
     * 保存 Dart 侧配置。
     *
     * @param notificationEnabled 是否允许 NLS 捕获通知。
     * @param smsEnabled 是否允许短信广播接收器捕获新短信。
     * @param listenAll 是否接收所有来源（仍会经过金融关键词前置过滤）。
     * @param packages 精确包名白名单；listenAll=false 时生效。
     */
    fun writeConfig(
        context: Context,
        notificationEnabled: Boolean,
        smsEnabled: Boolean,
        listenAll: Boolean,
        packages: List<String>,
    ): Boolean {
        val values = prefs(context)
        val wasNotificationEnabled = values.getBoolean(KEY_NOTIFICATION_ENABLED, false)
        val editor = values.edit()
            .putBoolean(KEY_NOTIFICATION_ENABLED, notificationEnabled)
            .putBoolean(KEY_SMS_ENABLED, smsEnabled)
            .putBoolean(KEY_LISTEN_ALL, listenAll)
            .putStringSet(KEY_PACKAGES, packages.map { it.trim() }.filter { it.isNotEmpty() }.toSet())
        if (notificationEnabled && !wasNotificationEnabled) {
            editor.putLong(KEY_NOTIFICATION_ENABLED_AT, System.currentTimeMillis())
        }
        if (!notificationEnabled) editor.remove(KEY_NOTIFICATION_ENABLED_AT)

        // 配置来自用户刚完成的显式操作。这里同步提交，保证应用随即退到后台或进程被
        // 系统回收时，NotificationListenerService 仍能读到已经确认的新开关。
        return editor.commit()
    }

    /** 返回通知采集总开关。 */
    fun notificationEnabled(context: Context): Boolean =
        prefs(context).getBoolean(KEY_NOTIFICATION_ENABLED, false)

    /** 返回本次开启通知采集的时间；用于重连后只补抓开启之后的近期活动通知。 */
    fun notificationEnabledAt(context: Context): Long =
        prefs(context).getLong(KEY_NOTIFICATION_ENABLED_AT, 0L)

    /** 返回短信采集总开关。 */
    fun smsEnabled(context: Context): Boolean =
        prefs(context).getBoolean(KEY_SMS_ENABLED, false)

    /** 判断某通知来源是否在用户允许的范围内。 */
    fun notificationSourceAllowed(context: Context, packageName: String): Boolean {
        val values = prefs(context)
        if (values.getBoolean(KEY_LISTEN_ALL, false)) return true
        return values.getStringSet(KEY_PACKAGES, emptySet())?.contains(packageName) == true
    }

    /**
     * 将一条原始事件加入持久队列。
     *
     * @param sourceKind notification 或 sms。
     * @param sourceId 通知包名或短信发送号码。
     * @param sourceLabel 用户可读来源名。
     * @param sourceEventId 系统事件 id；存在时用于精确幂等。
     * @param rawText 原始标题与正文；最多保留 8000 字符。
     * @param receivedAt 系统收到事件的毫秒时间戳。
     * @return 明确区分成功、重复、空正文与磁盘提交失败的结果。
     */
    @Synchronized
    fun enqueue(
        context: Context,
        sourceKind: String,
        sourceId: String,
        sourceLabel: String,
        sourceEventId: String,
        rawText: String,
        receivedAt: Long,
    ): AutoCaptureEnqueueResult {
        val text = rawText.trim().take(MAX_TEXT_LENGTH)
        if (text.isEmpty()) return AutoCaptureEnqueueResult.INVALID_TEXT
        val values = prefs(context)
        val queue = try {
            JSONArray(values.getString(KEY_QUEUE, "[]"))
        } catch (_: Exception) {
            JSONArray()
        }
        for (index in 0 until queue.length()) {
            val existing = queue.optJSONObject(index) ?: continue
            if (sourceEventId.isNotEmpty() &&
                existing.optString("sourceId") == sourceId &&
                existing.optString("sourceEventId") == sourceEventId
            ) {
                return AutoCaptureEnqueueResult.DUPLICATE
            }
            // 只有任一侧缺少系统事件 id 时才用“同文 + 60 秒”回退幂等。
            // 两个不同的明确 id 可能是用户在一分钟内连续发生的两笔真实交易。
            val existingEventId = existing.optString("sourceEventId")
            if ((sourceEventId.isEmpty() || existingEventId.isEmpty()) &&
                existing.optString("sourceId") == sourceId &&
                existing.optString("rawText") == text &&
                kotlin.math.abs(existing.optLong("receivedAt") - receivedAt) < 60_000L
            ) {
                return AutoCaptureEnqueueResult.DUPLICATE
            }
        }
        queue.put(
            JSONObject()
                .put("queueId", UUID.randomUUID().toString())
                .put("sourceKind", sourceKind)
                .put("sourceId", sourceId)
                .put("sourceLabel", sourceLabel)
                .put("sourceEventId", sourceEventId)
                .put("rawText", text)
                .put("receivedAt", receivedAt),
        )
        while (queue.length() > MAX_QUEUE_SIZE) queue.remove(0)
        // 通知可能在应用进程即将被系统回收时到达。同步提交可保证 enqueue 返回成功时
        // 原文已经真正落盘，而不是仍停留在 SharedPreferences 的异步写队列里。
        val saved = values.edit().putString(KEY_QUEUE, queue.toString()).commit()
        if (!saved) return AutoCaptureEnqueueResult.WRITE_FAILED
        onQueueAvailable?.invoke()
        return AutoCaptureEnqueueResult.ENQUEUED
    }

    /**
     * 记录 NotificationListenerService 的当前连接状态。
     *
     * @param connected true 表示系统已调用 onListenerConnected；false 表示已断开或销毁。
     */
    fun updateNotificationListenerConnection(context: Context, connected: Boolean) {
        notificationListenerConnected = connected
        prefs(context).edit()
            .putLong(
                if (connected) KEY_LISTENER_CONNECTED_AT else KEY_LISTENER_DISCONNECTED_AT,
                System.currentTimeMillis(),
            )
            .apply()
    }

    /** 返回当前进程内监听服务是否已经与 Android 系统建立连接。 */
    fun notificationListenerConnected(): Boolean = notificationListenerConnected

    /** 返回系统上一次确认监听服务断开的时间；仅用于限定重连补抓窗口。 */
    fun notificationListenerDisconnectedAt(context: Context): Long =
        prefs(context).getLong(KEY_LISTENER_DISCONNECTED_AT, 0L)

    /**
     * 记录最近一次通知在原生采集管线中的停留位置，不保存通知正文。
     *
     * @param sourceId 通知来源包名；原生总开关关闭时传空，避免额外记录无关来源。
     * @param sourceLabel 通知来源显示名；解析失败时回退包名。
     * @param textExtraction notRun、success 或 failed。
     * @param financialFilter notRun、passed 或 rejected。
     * @param queueResult notRun、enqueued 或 duplicate。
     * @param outcome 页面用于解释结果的稳定代码，不直接作为用户可见文案。
     */
    fun recordNotificationDiagnostic(
        context: Context,
        sourceId: String,
        sourceLabel: String,
        textExtraction: String,
        financialFilter: String,
        queueResult: String,
        outcome: String,
        occurredAt: Long = System.currentTimeMillis(),
    ) {
        val diagnostic = JSONObject()
            .put("occurredAt", occurredAt)
            .put("sourceId", sourceId)
            .put("sourceLabel", sourceLabel)
            .put("textExtraction", textExtraction)
            .put("financialFilter", financialFilter)
            .put("queueResult", queueResult)
            .put("outcome", outcome)
        prefs(context).edit()
            .putString(KEY_LAST_NOTIFICATION_DIAGNOSTIC, diagnostic.toString())
            .apply()
    }

    /**
     * 返回自动采集诊断快照。快照只包含开关、连接时间、队列数量和阶段结果，绝不返回
     * 最近通知正文，避免诊断面板扩大敏感数据暴露范围。
     *
     * @param notificationAccessGranted Android 系统“通知使用权”的实时授权状态。
     */
    @Synchronized
    fun diagnostics(
        context: Context,
        notificationAccessGranted: Boolean,
    ): Map<String, Any?> {
        val values = prefs(context)
        val queueLength = try {
            JSONArray(values.getString(KEY_QUEUE, "[]")).length()
        } catch (_: Exception) {
            0
        }
        val recent = try {
            val raw = values.getString(KEY_LAST_NOTIFICATION_DIAGNOSTIC, null)
            if (raw.isNullOrBlank()) null else JSONObject(raw)
        } catch (_: Exception) {
            null
        }
        val recentMap = recent?.let {
            mapOf(
                "occurredAt" to it.optLong("occurredAt"),
                "sourceId" to it.optString("sourceId"),
                "sourceLabel" to it.optString("sourceLabel"),
                "textExtraction" to it.optString("textExtraction", "notRun"),
                "financialFilter" to it.optString("financialFilter", "notRun"),
                "queueResult" to it.optString("queueResult", "notRun"),
                "outcome" to it.optString("outcome", "none"),
            )
        }
        return mapOf(
            "available" to true,
            "notificationAccessGranted" to notificationAccessGranted,
            "listenerConnected" to notificationListenerConnected,
            "nativeNotificationEnabled" to values.getBoolean(KEY_NOTIFICATION_ENABLED, false),
            "nativeListenAll" to values.getBoolean(KEY_LISTEN_ALL, false),
            "pendingQueueCount" to queueLength,
            "listenerConnectedAt" to values.getLong(KEY_LISTENER_CONNECTED_AT, 0L),
            "listenerDisconnectedAt" to values.getLong(KEY_LISTENER_DISCONNECTED_AT, 0L),
            "lastNotification" to recentMap,
        )
    }

    /** 读取当前队列但不删除；Flutter 把原文写入 SQLite 后再按 queueId 确认。 */
    @Synchronized
    fun read(context: Context): List<Map<String, Any?>> {
        val values = prefs(context)
        val queue = try {
            JSONArray(values.getString(KEY_QUEUE, "[]"))
        } catch (_: Exception) {
            JSONArray()
        }
        val result = ArrayList<Map<String, Any?>>(queue.length())
        for (index in 0 until queue.length()) {
            val item = queue.optJSONObject(index) ?: continue
            result.add(
                mapOf(
                    "sourceKind" to item.optString("sourceKind"),
                    "queueId" to queueIdOf(item),
                    "sourceId" to item.optString("sourceId"),
                    "sourceLabel" to item.optString("sourceLabel"),
                    "sourceEventId" to item.optString("sourceEventId"),
                    "rawText" to item.optString("rawText"),
                    "receivedAt" to item.optLong("receivedAt"),
                ),
            )
        }
        return result
    }

    /**
     * 删除 Flutter 已确认写入 SQLite（或已存在于 SQLite）的原生队列项。
     *
     * 只按本次返回的 queueId 删除，读取后新到达的通知不会被误清空。应用在落库前
     * 崩溃时不会发送确认，下一次启动仍能重新读取原文。
     */
    @Synchronized
    fun acknowledge(context: Context, queueIds: List<String>) {
        if (queueIds.isEmpty()) return
        val acknowledged = queueIds.toSet()
        val values = prefs(context)
        val queue = try {
            JSONArray(values.getString(KEY_QUEUE, "[]"))
        } catch (_: Exception) {
            JSONArray()
        }
        val kept = JSONArray()
        for (index in 0 until queue.length()) {
            val item = queue.optJSONObject(index) ?: continue
            if (!acknowledged.contains(queueIdOf(item))) kept.put(item)
        }
        values.edit().putString(KEY_QUEUE, kept.toString()).apply()
    }

    /** 为升级前没有 queueId 的队列项生成稳定回执 id，保证它们也能被安全确认。 */
    private fun queueIdOf(item: JSONObject): String {
        val stored = item.optString("queueId")
        if (stored.isNotEmpty()) return stored
        return listOf(
            item.optString("sourceId"),
            item.optString("sourceEventId"),
            item.optLong("receivedAt").toString(),
            item.optString("rawText").hashCode().toString(),
        ).joinToString("|")
    }

    /** 金融通知/短信的廉价前置过滤：必须同时含数字与交易关键词，减少无关敏感原文落库。 */
    fun looksFinancial(text: String): Boolean {
        if (!text.any { it.isDigit() }) return false
        val keywords = listOf(
            "消费", "支付", "付款", "扣款", "收款", "入账", "到账", "退款",
            "还款", "转账", "交易", "金额", "余额", "人民币", "元", "USD", "CNY",
        )
        return keywords.any { text.contains(it, ignoreCase = true) }
    }
}
