package top.talyra42.verifin

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

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
    private const val MAX_QUEUE_SIZE = 200
    private const val MAX_TEXT_LENGTH = 8_000

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
    ) {
        prefs(context).edit()
            .putBoolean(KEY_NOTIFICATION_ENABLED, notificationEnabled)
            .putBoolean(KEY_SMS_ENABLED, smsEnabled)
            .putBoolean(KEY_LISTEN_ALL, listenAll)
            .putStringSet(KEY_PACKAGES, packages.map { it.trim() }.filter { it.isNotEmpty() }.toSet())
            .apply()
    }

    /** 返回通知采集总开关。 */
    fun notificationEnabled(context: Context): Boolean =
        prefs(context).getBoolean(KEY_NOTIFICATION_ENABLED, false)

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
    ) {
        val text = rawText.trim().take(MAX_TEXT_LENGTH)
        if (text.isEmpty()) return
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
                return
            }
            // 只有任一侧缺少系统事件 id 时才用“同文 + 60 秒”回退幂等。
            // 两个不同的明确 id 可能是用户在一分钟内连续发生的两笔真实交易。
            val existingEventId = existing.optString("sourceEventId")
            if ((sourceEventId.isEmpty() || existingEventId.isEmpty()) &&
                existing.optString("sourceId") == sourceId &&
                existing.optString("rawText") == text &&
                kotlin.math.abs(existing.optLong("receivedAt") - receivedAt) < 60_000L
            ) {
                return
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
        values.edit().putString(KEY_QUEUE, queue.toString()).apply()
        onQueueAvailable?.invoke()
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
