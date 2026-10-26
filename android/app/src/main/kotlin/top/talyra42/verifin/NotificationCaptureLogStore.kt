package top.talyra42.verifin

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper

/** 一次通知回调的阶段结果；与待复核事件和正式交易分别保存。 */
data class NotificationCaptureLogRecord(
    val occurredAt: Long,
    val sourceId: String,
    val sourceLabel: String,
    val textExtraction: String,
    val financialFilter: String,
    val queueResult: String,
    val outcome: String,
    val sourceEventId: String = "",
    val rawText: String = "",
    val textCompleteness: String = "legacy",
)

/**
 * 设备本地通知日志，滚动保留三个 24 小时；不参与账本备份或恢复。
 *
 * 独立 SQLite 文件避免每次通知重写整个历史 JSON。当前允许来源的通知可保留日志专用正文，
 * 不受金融过滤和识别阶段限制；未允许或已排除来源只保存状态。时钟和文件名可供隔离测试注入。
 */
class NotificationCaptureLogStore(
    private val context: Context,
    databaseName: String = DATABASE_NAME,
    private val now: () -> Long = System::currentTimeMillis,
) : SQLiteOpenHelper(context, databaseName, null, DATABASE_VERSION) {
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE $TABLE (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                recorded_at INTEGER NOT NULL,
                occurred_at INTEGER NOT NULL,
                source_id TEXT NOT NULL,
                source_label TEXT NOT NULL,
                text_extraction TEXT NOT NULL,
                financial_filter TEXT NOT NULL,
                queue_result TEXT NOT NULL,
                outcome TEXT NOT NULL,
                source_event_id TEXT NOT NULL,
                raw_text TEXT NOT NULL,
                text_completeness TEXT NOT NULL DEFAULT 'legacy'
            )
            """.trimIndent(),
        )
        db.execSQL("CREATE INDEX notification_capture_logs_recorded_at ON $TABLE(recorded_at)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        check(oldVersion == 1 && newVersion == 2) { "Unsupported notification capture log schema upgrade" }
        // 旧日志不补造完整性结论，也不删除或重建已有正文。
        db.execSQL("ALTER TABLE $TABLE ADD COLUMN text_completeness TEXT NOT NULL DEFAULT 'legacy'")
    }

    /** 与原生配置/重置共用锁，重置关停采集后不能再追加旧回调或敏感正文。 */
    fun append(record: NotificationCaptureLogRecord): String? = synchronized(AutoCaptureBridge) {
        val recordedAt = now()
        require(recordedAt > 0) { "Invalid capture log time" }
        val db = writableDatabase
        db.beginTransaction()
        try {
            purgeExpired(db, recordedAt)
            if (!AutoCaptureBridge.notificationEnabled(context) || record.sourceId.isBlank() ||
                record.sourceId == context.packageName || record.outcome == "nativeDisabled"
            ) {
                db.setTransactionSuccessful()
                return@synchronized null
            }
            // 日志与识别独立；再次核对来源许可，旧回调或误传正文仍不能越过隐私边界。
            val mayRetainText = AutoCaptureBridge.notificationSourceAllowed(context, record.sourceId) &&
                record.outcome !in setOf("sourceBlocked", "nativeDisabled")
            val normalizedText = if (mayRetainText) record.rawText.trim() else ""
            // UTF-16上限不能把代理对切开，避免桥编码后出现半个字符或替换符。
            val textLimit = if (normalizedText.length > MAX_TEXT_LENGTH &&
                Character.isHighSurrogate(normalizedText[MAX_TEXT_LENGTH - 1]) &&
                Character.isLowSurrogate(normalizedText[MAX_TEXT_LENGTH])
            ) MAX_TEXT_LENGTH - 1 else MAX_TEXT_LENGTH
            val storedText = normalizedText.take(textLimit)
            val completeness = when {
                !mayRetainText -> "notStored"
                normalizedText.length > MAX_TEXT_LENGTH -> "partial"
                record.textCompleteness == "partial" -> "partial"
                record.textCompleteness == "captured" && storedText.isEmpty() -> "unavailable"
                record.textCompleteness == "unavailable" && storedText.isNotEmpty() -> "partial"
                record.textCompleteness in setOf("captured", "unavailable", "legacy") -> record.textCompleteness
                else -> "legacy"
            }
            val values = ContentValues().apply {
                put("recorded_at", recordedAt)
                put("occurred_at", record.occurredAt.takeIf { it > 0 } ?: recordedAt)
                put("source_id", record.sourceId.take(MAX_SOURCE_LENGTH))
                put("source_label", record.sourceLabel.take(MAX_SOURCE_LENGTH))
                put("text_extraction", record.textExtraction.take(MAX_STAGE_LENGTH))
                put("financial_filter", record.financialFilter.take(MAX_STAGE_LENGTH))
                put("queue_result", record.queueResult.take(MAX_STAGE_LENGTH))
                put("outcome", record.outcome.take(MAX_STAGE_LENGTH))
                put("source_event_id", if (mayRetainText) record.sourceEventId else "")
                put("raw_text", storedText)
                put("text_completeness", completeness)
            }
            val id = db.insertOrThrow(TABLE, null, values)
            db.setTransactionSuccessful()
            id.toString()
        } finally {
            db.endTransaction()
        }
    }

    /** id 逆序游标避免新回调挤动后续页面；读取前清除到期记录。 */
    fun read(beforeId: String? = null, limit: Int = 50): Map<String, Any?> {
        val cursorId = beforeId?.let {
            requireNotNull(it.toLongOrNull()?.takeIf { id -> id > 0 }) { "Invalid capture log cursor" }
        }
        val pageSize = limit.coerceIn(1, 100)
        val timestamp = now()
        require(timestamp > 0) { "Invalid capture log time" }
        val db = writableDatabase
        db.beginTransaction()
        try {
            purgeExpired(db, timestamp)
            val entries = mutableListOf<Map<String, Any?>>()
            db.query(
                TABLE, COLUMNS,
                if (cursorId == null) null else "id < ?",
                if (cursorId == null) null else arrayOf(cursorId.toString()),
                null, null, "id DESC", (pageSize + 1).toString(),
            ).use { cursor ->
                while (cursor.moveToNext()) {
                    entries.add(
                        mapOf(
                            "id" to cursor.getLong(0).toString(),
                            "recordedAt" to cursor.getLong(1),
                            "occurredAt" to cursor.getLong(2),
                            "sourceId" to cursor.getString(3),
                            "sourceLabel" to cursor.getString(4),
                            "textExtraction" to cursor.getString(5),
                            "financialFilter" to cursor.getString(6),
                            "queueResult" to cursor.getString(7),
                            "outcome" to cursor.getString(8),
                            "sourceEventId" to cursor.getString(9),
                            "rawText" to cursor.getString(10),
                            "textCompleteness" to cursor.getString(11),
                        ),
                    )
                }
            }
            val hasMore = entries.size > pageSize
            val page = entries.take(pageSize)
            db.setTransactionSuccessful()
            return mapOf(
                "entries" to page,
                "hasMore" to hasMore,
                "nextBeforeId" to if (hasMore) page.last()["id"] else null,
            )
        } finally {
            db.endTransaction()
        }
    }

    /** 仅删除本日志表，不碰采集队列、待复核事件、设置或账目。 */
    fun clear(): Int = writableDatabase.delete(TABLE, null, null)

    /** 在配置同步时也清理；年龄达到三个 24 小时即到期。 */
    fun purgeExpired(): Int {
        val timestamp = now()
        require(timestamp > 0) { "Invalid capture log time" }
        return purgeExpired(writableDatabase, timestamp)
    }

    private fun purgeExpired(db: SQLiteDatabase, timestamp: Long): Int =
        db.delete(TABLE, "recorded_at <= ?", arrayOf((timestamp - RETENTION_MILLIS).toString()))

    companion object {
        private const val DATABASE_NAME = "verifin_notification_capture_logs.db"
        private const val DATABASE_VERSION = 2
        private const val TABLE = "notification_capture_logs"
        private const val RETENTION_MILLIS = 3L * 24L * 60L * 60L * 1_000L
        private const val MAX_TEXT_LENGTH = 65_536
        private const val MAX_SOURCE_LENGTH = 256
        private const val MAX_STAGE_LENGTH = 64
        private val COLUMNS = arrayOf(
            "id", "recorded_at", "occurred_at", "source_id", "source_label", "text_extraction",
            "financial_filter", "queue_result", "outcome", "source_event_id", "raw_text", "text_completeness",
        )
    }
}
