package top.talyra42.verifin

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import android.database.DatabaseErrorHandler
import android.database.sqlite.SQLiteDatabase
import java.io.File

/** 实际 SQLite 的通知日志回归；数据库、开关和原生队列全部使用隔离文件。 */
internal object NotificationCaptureLogChecks {
    private const val DATABASE_NAME = "history.sqlite"
    private const val DATABASE_PREFIX = "notification-capture-log-checks-"
    private const val PREFERENCES_NAME = "notification-capture-log-checks"
    private const val BANK_PACKAGE = "test.capture.bank"
    private const val OTHER_PACKAGE = "test.capture.other"
    private const val DAY_MS = 24L * 60L * 60L * 1_000L
    private const val RETENTION_MS = 3L * DAY_MS

    /** 只允许 diagnostic 包运行，并在结束时关闭和删除本套件自己创建的文件。 */
    fun runAll(base: Context) {
        check(base.packageName.endsWith(".graphicsdiagnostic")) { "通知日志回归只能运行于隔离应用" }
        val createdDatabases = mutableSetOf<String>()
        val context = object : ContextWrapper(base) {
            private fun isolatedName(name: String): String = (DATABASE_PREFIX + name).also {
                createdDatabases.add(it)
            }

            override fun getApplicationContext(): Context = this

            override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
                base.getSharedPreferences(PREFERENCES_NAME, mode)

            override fun getDatabasePath(name: String): File = base.getDatabasePath(isolatedName(name))

            override fun openOrCreateDatabase(
                name: String,
                mode: Int,
                factory: SQLiteDatabase.CursorFactory?,
            ): SQLiteDatabase = base.openOrCreateDatabase(isolatedName(name), mode, factory)

            override fun openOrCreateDatabase(
                name: String,
                mode: Int,
                factory: SQLiteDatabase.CursorFactory?,
                errorHandler: DatabaseErrorHandler?,
            ): SQLiteDatabase = base.openOrCreateDatabase(isolatedName(name), mode, factory, errorHandler)

            override fun deleteDatabase(name: String): Boolean = base.deleteDatabase(isolatedName(name))
        }
        val preferences = context.getSharedPreferences("ignored", Context.MODE_PRIVATE)
        val previousQueueCallback = AutoCaptureBridge.onQueueAvailable
        val now = 1_800_000_000_000L
        var store = NotificationCaptureLogStore(context, DATABASE_NAME) { now }

        fun configure(enabled: Boolean = true) {
            check(AutoCaptureBridge.writeConfig(
                context = context,
                notificationEnabled = enabled,
                smsEnabled = false,
                listenAll = false,
                packages = listOf(BANK_PACKAGE),
            )) { "隔离通知配置保存失败" }
        }

        fun record(
            sourceId: String = BANK_PACKAGE,
            financialFilter: String = "passed",
            textExtraction: String = "success",
            rawText: String = "尾号1234消费USD 12.34",
            occurredAt: Long = now,
            eventId: String = "notification-$now",
            outcome: String = "queued",
        ) = NotificationCaptureLogRecord(
            occurredAt = occurredAt,
            sourceId = sourceId,
            sourceLabel = "隔离银行",
            textExtraction = textExtraction,
            financialFilter = financialFilter,
            queueResult = "enqueued",
            outcome = outcome,
            sourceEventId = eventId,
            rawText = rawText,
        )

        // 模拟旧版已落库的时间戳，避免准备夹具时追加操作先清掉三至七天内的旧数据。
        fun seedRecordedTimes(logStore: NotificationCaptureLogStore, timestamps: List<Long>): List<String> {
            val ids = timestamps.indices.map { requireNotNull(logStore.append(record(eventId = "retention-$it"))) }
            ids.zip(timestamps).forEach { (id, recordedAt) ->
                logStore.writableDatabase.execSQL(
                    "UPDATE notification_capture_logs SET recorded_at = ? WHERE id = ?",
                    arrayOf(recordedAt, id.toLong()),
                )
            }
            return ids
        }

        try {
            check(preferences.edit().clear().commit())
            AutoCaptureBridge.onQueueAvailable = null
            configure()
            store.clear()

            // 时效按本机捕获时刻计算；补抓的旧通知仍应保留一个完整的三天窗口。
            val historicalPostTime = now - RETENTION_MS * 2
            val oldNoticeId = requireNotNull(store.append(record(occurredAt = historicalPostTime)))
            val oldNotice = entries(store.read()).single()
            check(oldNotice["id"] == oldNoticeId && oldNotice["recordedAt"] == now)
            check(oldNotice["occurredAt"] == historicalPostTime)
            store.close()
            store = NotificationCaptureLogStore(context, DATABASE_NAME) { now }
            check(entries(store.read()).single()["id"] == oldNoticeId) { "日志必须在关闭重开数据库后保留" }

            // 恰好三天和更早的旧记录过期；晚一毫秒的记录仍在保留窗口内。
            store.clear()
            val cutoff = now - RETENTION_MS
            val retainedId = seedRecordedTimes(
                store, listOf(now - 6L * DAY_MS, cutoff - 1, cutoff, cutoff + 1),
            ).last()
            check(storedIds(store).size == 4) { "读取前应存在旧保留期内的过期夹具" }
            check(entries(store.read()).map { it["id"] } == listOf(retainedId)) { "三天边界清理不正确" }
            check(storedIds(store) == listOf(retainedId)) { "读取时必须实际删除过期日志，而不只是隐藏" }

            // 新通知也清除三至七天内的旧日志，并保留三天边界内的记录。
            store.clear()
            val appendRetainedId = seedRecordedTimes(
                store, listOf(now - 6L * DAY_MS, cutoff, cutoff + 1),
            ).last()
            val appendedId = requireNotNull(store.append(record()))
            check(storedIds(store) == listOf(appendedId, appendRetainedId)) { "追加通知时必须清理过期日志" }

            // 配置同步走默认日志库；直接查表，防止后续 read 自行清理掩盖同步入口失效。
            NotificationCaptureLogStore(context).use { configStore ->
                configStore.clear()
                val syncTime = System.currentTimeMillis()
                val syncRetainedId = seedRecordedTimes(
                    configStore,
                    listOf(syncTime - 6L * DAY_MS, syncTime - 4L * DAY_MS,
                        syncTime - RETENTION_MS, syncTime - 2L * DAY_MS),
                ).last()
                check(storedIds(configStore).size == 4)
                configure()
                check(storedIds(configStore) == listOf(syncRetainedId)) { "配置同步必须按三天保留期清理旧日志" }
                configStore.clear()
            }

            // 同一毫秒的多条通知用稳定 id 分页；翻页期间的新通知不能造成重复或漏项。
            store.clear()
            val initialIds = (1..5).map { requireNotNull(store.append(record(eventId = "same-time-$it"))) }
            val firstPage = store.read(limit = 2)
            check(entries(firstPage).map { it["id"] } == initialIds.takeLast(2).reversed())
            check(firstPage["hasMore"] == true)
            val firstCursor = firstPage["nextBeforeId"] as? String ?: error("缺少下一页游标")
            val insertedId = requireNotNull(store.append(record(eventId = "inserted-while-paging")))
            val secondPage = store.read(beforeId = firstCursor, limit = 2)
            val secondCursor = secondPage["nextBeforeId"] as? String ?: error("缺少第二页游标")
            val lastPage = store.read(beforeId = secondCursor, limit = 2)
            val snapshotIds = entries(firstPage) + entries(secondPage) + entries(lastPage)
            check(snapshotIds.map { it["id"] } == initialIds.reversed()) { "游标分页不应受新通知插入影响" }
            check(lastPage["hasMore"] == false && lastPage["nextBeforeId"] == null)
            check(entries(store.read(limit = 1)).single()["id"] == insertedId)
            check(entries(store.read(limit = 0)).size == 1) { "分页下限必须为一条" }
            for (invalidCursor in listOf("", "0", "-1", "oops")) {
                val failure = runCatching { store.read(beforeId = invalidCursor) }.exceptionOrNull()
                check(failure is IllegalArgumentException) { "无效游标不能被当作第一页读取" }
            }

            // 内容边界由存储层再次检查，不能仅依赖通知监听器传入的阶段结果。
            store.clear()
            val acceptedId = requireNotNull(store.append(record(rawText = "  已选来源消费USD 12.34  ")))
            store.append(record(sourceId = OTHER_PACKAGE, rawText = "不允许来源的秘密正文"))
            store.append(record(financialFilter = "rejected", rawText = "普通聊天内容不应保存"))
            store.append(record(textExtraction = "failed", rawText = "正文提取失败不能保存残留文本"))
            store.append(record(outcome = "sourceBlocked", rawText = "来源阻止结果不能夹带正文"))
            store.append(record(outcome = "financialRejected", rawText = "被拒绝结果不能夹带正文"))
            val privacyRows = entries(store.read())
            check(privacyRows.size == 6)
            check(privacyRows.single { it["id"] == acceptedId }["rawText"] == "已选来源消费USD 12.34")
            check(privacyRows.filter { it["id"] != acceptedId }.all { it["rawText"] == "" && it["sourceEventId"] == "" }) {
                "未允许来源、非金融通知和提取失败的日志只能保留阶段元数据"
            }
            configure(enabled = false)
            check(store.append(record(rawText = "关闭后不能捕获")) == null)
            check(entries(store.read()).size == 6) { "总开关关闭后不得新增日志" }
            configure()
            val boundedId = requireNotNull(store.append(record(rawText = "消费USD 12.34 " + "x".repeat(8_100))))
            check((entries(store.read()).single { it["id"] == boundedId }["rawText"] as String).length == 8_000)

            // 日志清理不能删除等待 Flutter 消费的原生通知队列。
            check(AutoCaptureBridge.enqueue(
                context = context,
                sourceKind = "notification",
                sourceId = BANK_PACKAGE,
                sourceLabel = "隔离银行",
                sourceEventId = "queue-must-survive",
                rawText = "尾号1234消费USD 12.34",
                receivedAt = now,
            ) == AutoCaptureEnqueueResult.ENQUEUED)
            val queueBeforeClear = AutoCaptureBridge.read(context)
            check(queueBeforeClear.size == 1)
            check(store.clear() > 0)
            check(entries(store.read()).isEmpty())
            check(AutoCaptureBridge.notificationEnabled(context)) { "清空日志不能停用通知采集" }
            check(AutoCaptureBridge.read(context) == queueBeforeClear) { "清空日志不得删除待处理通知" }

            // 大请求也只能返回有限的一页；这是查询入口的内存和 IPC 上限。
            repeat(105) { store.append(record(eventId = "page-limit-$it")) }
            check(entries(store.read(limit = 1_000)).size == 100)

            // 用户可清空日志而继续采集；全部本地数据重置则先关闭各个采集入口。
            // 通过桥读取默认日志库，确保测试也覆盖真实 MethodChannel 使用的路径。
            check(AutoCaptureBridge.writeConfig(
                context = context,
                notificationEnabled = true,
                smsEnabled = true,
                listenAll = true,
                packages = listOf(BANK_PACKAGE),
                excludedPackages = listOf(OTHER_PACKAGE),
            ))
            fun appendDefaultLog(eventId: String) {
                AutoCaptureBridge.recordNotificationDiagnostic(
                    context = context,
                    sourceId = BANK_PACKAGE,
                    sourceLabel = "隔离银行",
                    textExtraction = "success",
                    financialFilter = "passed",
                    queueResult = "enqueued",
                    outcome = "queued",
                    occurredAt = now,
                    sourceEventId = eventId,
                    rawText = "尾号1234消费USD 12.34",
                )
            }
            appendDefaultLog("before-bridge-clear")
            check(entries(AutoCaptureBridge.readNotificationCaptureLogs(context)).isNotEmpty())
            check(AutoCaptureBridge.clearNotificationCaptureLogs(context))
            check(entries(AutoCaptureBridge.readNotificationCaptureLogs(context)).isEmpty())
            check(AutoCaptureBridge.notificationEnabled(context) && AutoCaptureBridge.smsEnabled(context)) {
                "清空日志不能关闭已有通知或短信采集配置"
            }
            check(AutoCaptureBridge.diagnostics(context, true)["nativeListenAll"] == true)
            check(AutoCaptureBridge.read(context) == queueBeforeClear)

            appendDefaultLog("before-bridge-reset")
            check(AutoCaptureBridge.diagnostics(context, true)["lastNotification"] != null)
            val separateDatabaseCount = entries(store.read(limit = 100)).size
            check(AutoCaptureBridge.resetNotificationCaptureLogs(context))
            check(!AutoCaptureBridge.notificationEnabled(context) && !AutoCaptureBridge.smsEnabled(context))
            val resetDiagnostics = AutoCaptureBridge.diagnostics(context, true)
            check(resetDiagnostics["nativeListenAll"] == false && resetDiagnostics["lastNotification"] == null)
            check(entries(AutoCaptureBridge.readNotificationCaptureLogs(context)).isEmpty())
            check(AutoCaptureBridge.read(context) == queueBeforeClear) { "重置通知日志不能删除已排队原文" }
            check(entries(store.read(limit = 100)).size == separateDatabaseCount) {
                "日志重置不得清除其他独立数据库"
            }
            check(store.append(record()) == null) { "重置后旧回调不能继续写入日志" }
            appendDefaultLog("stale-after-reset")
            check(AutoCaptureBridge.diagnostics(context, true)["lastNotification"] == null) {
                "重置后迟到的旧回调不能重新写入带来源的最新快照"
            }
            check(entries(AutoCaptureBridge.readNotificationCaptureLogs(context)).isEmpty())

            // 已关闭时仍允许原有的无来源状态诊断，但不能被后续旧回调替换成敏感来源。
            AutoCaptureBridge.recordNotificationDiagnostic(
                context = context,
                sourceId = "",
                sourceLabel = "",
                textExtraction = "notRun",
                financialFilter = "notRun",
                queueResult = "notRun",
                outcome = "nativeDisabled",
                occurredAt = now,
            )
            val disabledSnapshot = AutoCaptureBridge.diagnostics(context, true)["lastNotification"] as? Map<*, *>
                ?: error("关闭采集时应保留无来源 nativeDisabled 诊断")
            check(disabledSnapshot["sourceId"] == "" && disabledSnapshot["sourceLabel"] == "")
            check(disabledSnapshot["outcome"] == "nativeDisabled")
            appendDefaultLog("stale-after-disabled-snapshot")
            check(AutoCaptureBridge.diagnostics(context, true)["lastNotification"] == disabledSnapshot)
            check(entries(AutoCaptureBridge.readNotificationCaptureLogs(context)).isEmpty())
            check(AutoCaptureBridge.read(context) == queueBeforeClear)
        } finally {
            store.close()
            AutoCaptureBridge.onQueueAvailable = previousQueueCallback
            check(preferences.edit().clear().commit())
            for (name in createdDatabases.toList()) {
                check(name.startsWith(DATABASE_PREFIX))
                base.deleteDatabase(name)
            }
        }
    }

    /** 不触发到期清理，确认 read/append/配置同步已物理删除旧行。 */
    private fun storedIds(store: NotificationCaptureLogStore): List<String> =
        store.readableDatabase.rawQuery("SELECT id FROM notification_capture_logs ORDER BY id DESC", null).use { cursor ->
            buildList {
                while (cursor.moveToNext()) add(cursor.getLong(0).toString())
            }
        }

    /** 检查 MethodChannel 风格的分页结果，不把类型不符默默当成空日志。 */
    private fun entries(batch: Map<String, Any?>): List<Map<*, *>> {
        val rows = batch["entries"] as? List<*> ?: error("日志分页缺少 entries")
        return rows.map { it as? Map<*, *> ?: error("日志行不是 Map") }
    }
}
