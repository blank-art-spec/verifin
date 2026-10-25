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
)

/**
 * 设备本地通知日志，滚动保留七个 24 小时；不参与账本备份或恢复。
 *
 * 独立 SQLite 文件避免每次通知重写整个历史 JSON。只有当前允许来源、已成功提取且通过
 * 金融过滤的通知才能保留正文，其余只保存来源和阶段状态。时钟和文件名可供隔离测试注入。
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
                raw_text TEXT NOT NULL
            )
            """.trimIndent(),
        )
        db.execSQL("CREATE INDEX notification_capture_logs_recorded_at ON $TABLE(recorded_at)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        // 未来升级必须显式迁移，不以重建表的方式静默删除历史。
        check(oldVersion == newVersion) { "Unsupported notification capture log schema upgrade" }
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
            // 存储层重新核对权限与结果；调用方误传正文也不能越过来源/金融过滤边界。
            val mayRetainText = AutoCaptureBridge.notificationSourceAllowed(context, record.sourceId) &&
                record.textExtraction == "success" && record.financialFilter == "passed" &&
                record.outcome in setOf("queued", "duplicate", "queueWriteFailed")
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
                put("raw_text", if (mayRetainText) record.rawText.trim().take(MAX_TEXT_LENGTH) else "")
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

    /** 在配置同步时也清理；年龄达到七个 24 小时即到期。 */
    fun purgeExpired(): Int {
        val timestamp = now()
        require(timestamp > 0) { "Invalid capture log time" }
        return purgeExpired(writableDatabase, timestamp)
    }

    private fun purgeExpired(db: SQLiteDatabase, timestamp: Long): Int =
        db.delete(TABLE, "recorded_at <= ?", arrayOf((timestamp - RETENTION_MILLIS).toString()))

    companion object {
        private const val DATABASE_NAME = "verifin_notification_capture_logs.db"
        private const val DATABASE_VERSION = 1
        private const val TABLE = "notification_capture_logs"
        private const val RETENTION_MILLIS = 7L * 24L * 60L * 60L * 1_000L
        private const val MAX_TEXT_LENGTH = 8_000
        private const val MAX_SOURCE_LENGTH = 256
        private const val MAX_STAGE_LENGTH = 64
        private val COLUMNS = arrayOf(
            "id", "recorded_at", "occurred_at", "source_id", "source_label", "text_extraction",
            "financial_filter", "queue_result", "outcome", "source_event_id", "raw_text",
        )
    }
}
