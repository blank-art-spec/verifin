package top.talyra42.verifin

import android.app.Notification
import android.content.Context
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews
import android.widget.FrameLayout
import android.widget.TextView
import android.widget.LinearLayout

/** 真正构造 Android Notification 和 RemoteViews，覆盖正文读取兜底而不写设备数据。 */
@Suppress("DEPRECATION")
internal object NotificationTextExtractionChecks {
    private var testResourceContext: Context? = null

    /** 只允许在隔离应用运行；调用方负责在主线程执行真实 View inflate。 */
    fun runAll(context: Context, resourceContext: Context) {
        check(NotificationTextExtractor.extract(context, null) == null) { "空通知应保持不可读取" }
        check(context.packageName.endsWith(".graphicsdiagnostic")) { "通知正文回归只能在隔离应用运行" }
        testResourceContext = resourceContext
        try {
            validateTestLayouts(context)
            standardFieldsKeepTheirExistingOrderAndDeduplication(context)
            titleOnlyNotificationReadsCustomBody(context)
            fullyCustomNotificationReadsBody(context)
            standardBodyDoesNotReadCustomViews(context)
            invalidCustomViewPreservesStandardText(context)
            duplicateCustomViewsAreMerged(context)
            hiddenAndBlankCustomTextIsIgnored(context)
            standardLinesMessagesAndTickerDoNotReadCustomViews(context)
            fallbackTextIsBoundedWithoutTruncatingExistingStandardText(context)
            hiddenAncestorSkipsVisibleDescendants(context)
            actionAndClockControlsAreNotBody(context)
            customTraversalStopsAtNodeLimit(context)
            logIncludesCustomEvenWhenStandardExists(context)
            logDeduplicatesFieldsAndAllLayoutVariants(context)
            logKeepsTextAboveLegacyLimit(context)
            logMarksExactLengthBoundaries(context)
            logPreservesStandardsOnLayoutFailure(context)
            logReportsUnavailableWithoutReadableText(context)
            logRespectsVisibilityAndControlBoundaries(context)
            logKeepsActionTitlesWithoutChangingRecognition(context)
            logReportsNodeBudgetCompleteness(context)
            logHandlesMalformedFieldsAndSurrogateBoundaries(context)
        } finally {
            testResourceContext = null
        }
    }

    /** 先直接验证合成布局可读取，让资源/控件错误直接给出异常而非被生产兜底吞掉。 */
    private fun validateTestLayouts(context: Context) {
        val root = customView("校验标题", "校验正文").apply(context, FrameLayout(context))
        check(root is LinearLayout && root.id == android.R.id.content)
        check(root.findViewById<TextView>(android.R.id.text1).text.toString() == "校验标题")
        check(root.findViewById<TextView>(android.R.id.text2).text.toString() == "校验正文")
        val line = testLayout("notification_text_extraction_line").apply {
            setTextViewText(android.R.id.text1, "校验单行")
        }.apply(context, FrameLayout(context))
        check(line is TextView && line.text.toString() == "校验单行")
        val controls = testLayout("notification_text_extraction_controls").apply(context, FrameLayout(context))
        check(controls is LinearLayout && controls.childCount == 4)
    }

    /** 常规通知的字段顺序与整串去重保持原样，长短正文并存也不重写。 */
    private fun standardFieldsKeepTheirExistingOrderAndDeduplication(context: Context) {
        val notice = Notification().apply {
            extras = Bundle().apply {
                putCharSequence(Notification.EXTRA_TITLE, "  银行提醒  ")
                putCharSequence(Notification.EXTRA_TITLE_BIG, "银行提醒")
                putCharSequence(Notification.EXTRA_BIG_TEXT, "尾号1234消费USD 12.34，完整正文")
                putCharSequence(Notification.EXTRA_TEXT, "尾号1234消费USD 12.34")
                putCharSequence(Notification.EXTRA_SUB_TEXT, "附加信息")
                putCharSequence(Notification.EXTRA_SUMMARY_TEXT, "摘要")
                putCharSequence(Notification.EXTRA_INFO_TEXT, "信息")
                putCharSequence(Notification.EXTRA_CONVERSATION_TITLE, "会话")
                putCharSequenceArray(Notification.EXTRA_TEXT_LINES, arrayOf("第一行", "摘要", "  "))
                putParcelableArray(Notification.EXTRA_MESSAGES, arrayOf(message("当前消息"), message("摘要")))
                putParcelableArray(Notification.EXTRA_HISTORIC_MESSAGES, arrayOf(message("历史消息")))
            }
            tickerText = "状态栏文本"
            contentView = customView("不应混入", "不应读取")
        }
        val expected = listOf(
            "银行提醒", "尾号1234消费USD 12.34，完整正文", "尾号1234消费USD 12.34",
            "附加信息", "摘要", "信息", "会话", "第一行", "当前消息", "历史消息", "状态栏文本",
        ).joinToString("\n")
        check(NotificationTextExtractor.extract(context, notice) == expected) { "标准通知提取内容、顺序或去重发生改变" }
    }

    /** 有标准标题但没有标准正文时，不能因为标题非空而跳过自定义正文。 */
    private fun titleOnlyNotificationReadsCustomBody(context: Context) {
        val notice = Notification().apply {
            extras = Bundle().apply { putCharSequence(Notification.EXTRA_TITLE, "银行提醒") }
            contentView = customView("银行提醒", "  尾号1234消费USD 12.34  ")
        }
        check(NotificationTextExtractor.extract(context, notice) == "银行提醒\n尾号1234消费USD 12.34") {
            "仅标题的通知没有补全自定义正文，或重复加入标题"
        }
    }

    /** 没有标准 extras 的完全自定义通知也能读取可见文字。 */
    private fun fullyCustomNotificationReadsBody(context: Context) {
        val notice = Notification().apply {
            extras = Bundle()
            bigContentView = customView("银行提醒", "尾号1234消费USD 12.34")
        }
        check(NotificationTextExtractor.extract(context, notice) == "银行提醒\n尾号1234消费USD 12.34") {
            "完全自定义通知未读取正文"
        }
    }

    /** 有标准正文时不引入自定义布局文字，避免改变既有事件指纹。 */
    private fun standardBodyDoesNotReadCustomViews(context: Context) {
        for (bodyKey in listOf(Notification.EXTRA_TEXT, Notification.EXTRA_BIG_TEXT)) {
            val notice = Notification().apply {
                extras = Bundle().apply { putCharSequence(bodyKey, "尾号1234消费USD 12.34") }
                contentView = customView("不应混入", "自定义辅助文字")
            }
            check(NotificationTextExtractor.extract(context, notice) == "尾号1234消费USD 12.34") {
                "已有标准正文时仍拼入自定义布局"
            }
        }
    }

    /** 自定义布局损坏只跳过对应视图，已有标题和其他可读布局仍被保留。 */
    private fun invalidCustomViewPreservesStandardText(context: Context) {
        val titleOnly = Notification().apply {
            extras = Bundle().apply { putCharSequence(Notification.EXTRA_TITLE, "银行提醒") }
            bigContentView = RemoteViews("android", Int.MAX_VALUE)
        }
        check(NotificationTextExtractor.extract(context, titleOnly) == "银行提醒") { "布局失败丢失已有标准标题" }
        titleOnly.contentView = customView("银行提醒", "尾号1234消费USD 12.34")
        check(NotificationTextExtractor.extract(context, titleOnly) == "银行提醒\n尾号1234消费USD 12.34") {
            "一个布局失败后未继续读取其他自定义布局"
        }
    }

    /** 展开、折叠及横幅重复同一段文字时只保存一份，保持优先读取顺序。 */
    private fun duplicateCustomViewsAreMerged(context: Context) {
        val notice = Notification().apply {
            extras = Bundle()
            bigContentView = customView("银行提醒", "尾号1234消费USD 12.34")
            contentView = customView("银行提醒", "尾号1234消费USD 12.34")
            headsUpContentView = customView("银行提醒", "尾号1234消费USD 12.34")
        }
        check(NotificationTextExtractor.extract(context, notice) == "银行提醒\n尾号1234消费USD 12.34") {
            "多个自定义布局产生重复正文"
        }
    }

    /** 空白、隐藏文字不能作为可见通知正文；不可读取时继续返回 null。 */
    private fun hiddenAndBlankCustomTextIsIgnored(context: Context) {
        for (visibility in listOf(View.GONE, View.INVISIBLE)) {
            val notice = Notification().apply {
                extras = Bundle()
                contentView = customView("  \n  ", "隐藏内容").apply {
                    setViewVisibility(android.R.id.text2, visibility)
                }
            }
            check(NotificationTextExtractor.extract(context, notice) == null) { "空白或隐藏文字被提取为正文" }
        }
        val notice = Notification().apply {
            extras = Bundle()
            contentView = customView("可见正文", "隐藏内容").apply {
                setViewVisibility(android.R.id.text2, View.GONE)
            }
        }
        check(NotificationTextExtractor.extract(context, notice) == "可见正文") { "隐藏正文影响可见正文读取" }
    }

    /** 多行、会话消息或 ticker 已提供正文时，同样保持旧输出而不读取布局。 */
    private fun standardLinesMessagesAndTickerDoNotReadCustomViews(context: Context) {
        val expected = "银行提醒\n尾号1234消费USD 12.34"
        val notices = listOf(
            Notification().apply {
                extras = Bundle().apply {
                    putCharSequence(Notification.EXTRA_TITLE, "银行提醒")
                    putCharSequenceArray(Notification.EXTRA_TEXT_LINES, arrayOf("尾号1234消费USD 12.34"))
                }
            },
            Notification().apply {
                extras = Bundle().apply {
                    putCharSequence(Notification.EXTRA_TITLE, "银行提醒")
                    putParcelableArray(Notification.EXTRA_MESSAGES, arrayOf(message("尾号1234消费USD 12.34")))
                }
            },
            Notification().apply {
                extras = Bundle().apply {
                    putCharSequence(Notification.EXTRA_TITLE, "银行提醒")
                    putParcelableArray(Notification.EXTRA_HISTORIC_MESSAGES, arrayOf(message("尾号1234消费USD 12.34")))
                }
            },
            Notification().apply {
                extras = Bundle().apply { putCharSequence(Notification.EXTRA_TITLE, "银行提醒") }
                tickerText = "尾号1234消费USD 12.34"
            },
        )
        for (notice in notices) {
            notice.contentView = customView("不应混入", "布局补充文字")
            check(NotificationTextExtractor.extract(context, notice) == expected) {
                "已有标准多行、消息或ticker正文时仍引入自定义文字"
            }
        }
    }

    /** 只约束新布局兜底的总长度；既有标准字段不因本次优化被裁剪。 */
    private fun fallbackTextIsBoundedWithoutTruncatingExistingStandardText(context: Context) {
        val longBody = "x".repeat(8_100)
        val fullyCustom = Notification().apply {
            extras = Bundle()
            bigContentView = customView(longBody, "")
        }
        check(NotificationTextExtractor.extract(context, fullyCustom) == "x".repeat(8_000)) {
            "完全自定义正文未遵守8000字符上限"
        }
        val title = "银行提醒"
        val withTitle = Notification().apply {
            extras = Bundle().apply { putCharSequence(Notification.EXTRA_TITLE, title) }
            contentView = customView(title, longBody)
        }
        check(NotificationTextExtractor.extract(context, withTitle) == title + "\n" + "x".repeat(8_000 - title.length - 1)) {
            "兜底正文长度未包含现有标题和换行"
        }
        val standardBody = Notification().apply {
            extras = Bundle().apply { putCharSequence(Notification.EXTRA_TEXT, longBody) }
            contentView = customView("不应读取", "不应混入")
        }
        check(NotificationTextExtractor.extract(context, standardBody) == longBody) { "既有标准正文被新增限制裁剪" }
        val standardTitle = Notification().apply {
            extras = Bundle().apply { putCharSequence(Notification.EXTRA_TITLE, longBody) }
            contentView = customView("不应追加", "剩余空间为零")
        }
        check(NotificationTextExtractor.extract(context, standardTitle) == longBody) {
            "既有标准标题超出兜底限额时被裁剪或继续追加布局文字"
        }
    }

    /** 子 TextView 自身可见也不能越过隐藏/全透明的祖先容器。 */
    private fun hiddenAncestorSkipsVisibleDescendants(context: Context) {
        for (visibility in listOf(View.GONE, View.INVISIBLE)) {
            val notice = Notification().apply {
                extras = Bundle()
                contentView = customRootView().apply {
                    setViewVisibility(android.R.id.content, visibility)
                }
            }
            check(NotificationTextExtractor.extract(context, notice) == null) { "隐藏祖先容器下的正文被读取" }
        }
        val transparent = Notification().apply {
            extras = Bundle()
            contentView = customRootView().apply { setFloat(android.R.id.content, "setAlpha", 0f) }
        }
        check(NotificationTextExtractor.extract(context, transparent) == null) { "全透明祖先容器下的正文被读取" }
        val visible = Notification().apply {
            extras = Bundle()
            contentView = customRootView()
        }
        check(NotificationTextExtractor.extract(context, visible) == "可见标题\n可见正文") {
            "祖先可见性测试布局本身未能读取，不能证明隐藏行为"
        }
    }

    private fun customRootView(): RemoteViews =
        testLayout("notification_text_extraction_text").apply {
            setTextViewText(android.R.id.text1, "可见标题")
            setTextViewText(android.R.id.text2, "可见正文")
        }

    /** 真实控件中的操作按钮、动态计时器和时钟都不能混入交易正文。 */
    private fun actionAndClockControlsAreNotBody(context: Context) {
        val notice = Notification().apply {
            extras = Bundle()
            contentView = testLayout("notification_text_extraction_controls")
        }
        check(NotificationTextExtractor.extract(context, notice) == "尾号1234消费USD 12.34") {
            "操作按钮、Chronometer或TextClock被当作正文，或未能读取测试布局"
        }
    }

    /** 根节点计入512节点限额；边界内哨兵可读，边界外哨兵不可读。 */
    private fun customTraversalStopsAtNodeLimit(context: Context) {
        fun notification(childrenBeforeSentinel: Int): Notification = Notification().apply {
            extras = Bundle()
            contentView = nodeLimitView(childrenBeforeSentinel)
        }
        check(NotificationTextExtractor.extract(context, notification(510)) == "正文\n限额哨兵") {
            "512节点限额内的正文未被读取，或节点计数偏移"
        }
        check(NotificationTextExtractor.extract(context, notification(511)) == "正文") {
            "512节点限额外的正文仍被读取"
        }
    }

    /** 完整日志独立于识别正文：标准短文非空也继续读取展开布局。 */
    private fun logIncludesCustomEvenWhenStandardExists(context: Context) {
        val standard = "尾号1234消费USD"
        val complete = "尾号1234消费USD 12.34，商户TEST，交易已成功"
        val notice = Notification().apply {
            extras = Bundle().apply {
                putCharSequence(Notification.EXTRA_TITLE, "银行提醒")
                putCharSequence(Notification.EXTRA_TEXT, standard)
            }
            bigContentView = customView("银行提醒", complete)
        }
        val log = NotificationTextExtractor.extractForLog(context, notice)
        check(log.text == "银行提醒\n$standard\n$complete" && log.textCompleteness == "captured") {
            "标准正文非空时日志未补读完整自定义文字"
        }
        check(NotificationTextExtractor.extract(context, notice) == "银行提醒\n$standard") {
            "日志补文改变了自动识别输入"
        }
    }

    /** 标准字段及展开、折叠和横幅均读取，重复片段按整串保留一份。 */
    private fun logDeduplicatesFieldsAndAllLayoutVariants(context: Context) {
        val notice = Notification().apply {
            extras = Bundle().apply {
                putCharSequence(Notification.EXTRA_TITLE, "银行提醒")
                putCharSequence(Notification.EXTRA_TITLE_BIG, "展开标题")
                putCharSequence(Notification.EXTRA_TEXT, "短通知")
                putCharSequence(Notification.EXTRA_BIG_TEXT, "展开正文")
                putCharSequence(Notification.EXTRA_SUB_TEXT, "副标题")
                putCharSequence(Notification.EXTRA_SUMMARY_TEXT, "摘要")
                putCharSequence(Notification.EXTRA_INFO_TEXT, "信息文字")
                putCharSequence(Notification.EXTRA_CONVERSATION_TITLE, "会话标题")
                putCharSequenceArray(Notification.EXTRA_TEXT_LINES, arrayOf("短通知", "多行补充"))
                putParcelableArray(Notification.EXTRA_MESSAGES, arrayOf(message("当前消息")))
                putParcelableArray(Notification.EXTRA_HISTORIC_MESSAGES, arrayOf(message("历史消息")))
            }
            tickerText = "状态栏文字"
            bigContentView = customView("银行提醒", "展开正文")
            contentView = customView("短通知", "折叠补充")
            headsUpContentView = customView("展开正文", "横幅补充")
        }
        val expected = listOf(
            "银行提醒", "展开标题", "展开正文", "短通知", "副标题", "摘要", "信息文字", "会话标题",
            "多行补充", "当前消息", "历史消息", "状态栏文字", "折叠补充", "横幅补充",
        ).joinToString("\n")
        val log = NotificationTextExtractor.extractForLog(context, notice)
        check(log.text == expected && log.textCompleteness == "captured") {
            "日志未覆盖全部布局或标准文字，或出现重复片段"
        }
    }

    /** 日志不再在旧8000字符处静默截断，识别兜底仍保持原有上限。 */
    private fun logKeepsTextAboveLegacyLimit(context: Context) {
        val longBody = "x".repeat(8_100)
        val customNotice = Notification().apply {
            extras = Bundle()
            bigContentView = customView("", longBody)
        }
        val customLog = NotificationTextExtractor.extractForLog(context, customNotice)
        check(customLog.text == longBody && customLog.textCompleteness == "captured") {
            "完整日志仍按旧8000字符上限截断"
        }
        check(NotificationTextExtractor.extract(context, customNotice) == "x".repeat(8_000)) {
            "日志扩容改变了原识别文本预算"
        }
        val standardNotice = Notification().apply {
            extras = Bundle().apply { putCharSequence(Notification.EXTRA_TEXT, longBody) }
        }
        val standardLog = NotificationTextExtractor.extractForLog(context, standardNotice)
        check(standardLog.text == longBody && standardLog.textCompleteness == "captured") {
            "完整标准日志被旧显示上限截断"
        }
    }

    /** 精确长度不误报截断；超长及标题换行占用预算时明确标记partial。 */
    private fun logMarksExactLengthBoundaries(context: Context) {
        fun standard(body: String, title: String? = null): Notification = Notification().apply {
            extras = Bundle().apply {
                putCharSequence(Notification.EXTRA_TITLE, title)
                putCharSequence(Notification.EXTRA_TEXT, body)
            }
        }
        val atLimit = NotificationTextExtractor.extractForLog(context, standard("x".repeat(65_536)))
        check(atLimit.text.length == 65_536 && atLimit.textCompleteness == "captured") {
            "精确65536字符被错误标记为部分内容"
        }
        val overLimit = NotificationTextExtractor.extractForLog(context, standard("x".repeat(65_537)))
        check(overLimit.text == "x".repeat(65_536) && overLimit.textCompleteness == "partial") {
            "超长标准日志未限长或未提示部分内容"
        }
        val title = "银行提醒"
        val exactBody = "x".repeat(65_536 - title.length - 1)
        val withTitle = NotificationTextExtractor.extractForLog(context, standard(exactBody, title))
        check(withTitle.text == "$title\n$exactBody" && withTitle.textCompleteness == "captured") {
            "标题及换行计入预算后的精确边界不正确"
        }
        val extraBody = NotificationTextExtractor.extractForLog(context, standard(exactBody + "x", title))
        check(extraBody.text == withTitle.text && extraBody.textCompleteness == "partial") {
            "正文上限未包含标题和换行"
        }
        val customNotice = Notification().apply {
            extras = Bundle()
            contentView = customView("", "x".repeat(65_537))
        }
        val customLog = NotificationTextExtractor.extractForLog(context, customNotice)
        check(customLog.text == "x".repeat(65_536) && customLog.textCompleteness == "partial") {
            "超长自定义日志未限长或未提示部分内容"
        }
    }

    /** 一个布局异常不丢失标准内容或其他布局，日志明确表示内容不完整。 */
    private fun logPreservesStandardsOnLayoutFailure(context: Context) {
        val notice = Notification().apply {
            extras = Bundle().apply { putCharSequence(Notification.EXTRA_TEXT, "标准短文") }
            bigContentView = RemoteViews("android", Int.MAX_VALUE)
            contentView = customView("", "可读取补充")
        }
        val log = NotificationTextExtractor.extractForLog(context, notice)
        check(log.text == "标准短文\n可读取补充" && log.textCompleteness == "partial") {
            "布局失败未保留可用文字或被错误标记为已完整读取"
        }
        check(NotificationTextExtractor.extract(context, notice) == "标准短文") {
            "日志异常改变了原识别结果"
        }
    }

    /** 确实没有可读文字与有读取失败分别表示，不能伪装为captured。 */
    private fun logReportsUnavailableWithoutReadableText(context: Context) {
        for (notice in listOf(null, Notification().apply { extras = Bundle() })) {
            val log = NotificationTextExtractor.extractForLog(context, notice)
            check(log.text.isEmpty() && log.textCompleteness == "unavailable") { "空通知日志应显示无可读文字" }
        }
        val unreadable = Notification().apply {
            extras = Bundle()
            contentView = RemoteViews("android", Int.MAX_VALUE)
        }
        val failedLog = NotificationTextExtractor.extractForLog(context, unreadable)
        check(failedLog.text.isEmpty() && failedLog.textCompleteness == "partial") {
            "读取失败的空日志未标明不完整"
        }
    }

    /** 日志跳过隐藏文字，但保留可见操作按钮与时钟文字供查看。 */
    private fun logRespectsVisibilityAndControlBoundaries(context: Context) {
        for (visibility in listOf(View.GONE, View.INVISIBLE)) {
            val notice = Notification().apply {
                extras = Bundle()
                contentView = customRootView().apply { setViewVisibility(android.R.id.content, visibility) }
            }
            val log = NotificationTextExtractor.extractForLog(context, notice)
            check(log.text.isEmpty() && log.textCompleteness == "unavailable") { "日志读取了隐藏父容器下的内容" }
        }
        val controls = Notification().apply {
            extras = Bundle()
            contentView = testLayout("notification_text_extraction_controls").apply {
                setTextViewText(android.R.id.progress, "计时器文字999")
                setTextViewText(android.R.id.summary, "时钟噪声999")
            }
        }
        val rendered = requireNotNull(controls.contentView).apply(context, FrameLayout(context)) as LinearLayout
        val visibleControlTexts = (0 until rendered.childCount).mapNotNull { index ->
            (rendered.getChildAt(index) as? TextView)?.text?.toString()?.trim()?.takeIf { it.isNotEmpty() }
        }
        check(visibleControlTexts.contains("立即支付999元") && visibleControlTexts.contains("时钟噪声999")) {
            "日志控件测试布局未包含按钮或可读时钟"
        }
        val log = NotificationTextExtractor.extractForLog(context, controls)
        val loggedLines = log.text.lines()
        check(log.textCompleteness == "captured" && visibleControlTexts.all { it in loggedLines }) {
            "日志遗漏可见按钮、Chronometer或TextClock文字"
        }
        check(NotificationTextExtractor.extract(context, controls) == "尾号1234消费USD 12.34") {
            "展示日志中的操作文字改变了原识别输入"
        }
    }

    /** 系统独立Action标题也保留并去重，且不能进入识别输入。 */
    private fun logKeepsActionTitlesWithoutChangingRecognition(context: Context) {
        val notice = Notification().apply {
            extras = Bundle().apply { putCharSequence(Notification.EXTRA_TEXT, "识别短文") }
            actions = arrayOf(
                Notification.Action.Builder(0, "打开账单", null).build(),
                Notification.Action.Builder(0, "复制通知", null).build(),
                Notification.Action.Builder(0, "打开账单", null).build(),
            )
        }
        val log = NotificationTextExtractor.extractForLog(context, notice)
        check(log.text == "识别短文\n打开账单\n复制通知" && log.textCompleteness == "captured") {
            "日志遗漏系统Action标题，或出现重复操作文字"
        }
        check(NotificationTextExtractor.extract(context, notice) == "识别短文") {
            "操作标题进入了原识别正文"
        }
    }

    /** 限额内外必须同时校验正文与完整性标记，避免截断后仍显示已完整读取。 */
    private fun logReportsNodeBudgetCompleteness(context: Context) {
        fun notice(childrenBeforeSentinel: Int): Notification = Notification().apply {
            extras = Bundle()
            contentView = nodeLimitView(childrenBeforeSentinel)
        }
        val within = NotificationTextExtractor.extractForLog(context, notice(510))
        check(within.text == "正文\n限额哨兵" && within.textCompleteness == "captured") {
            "节点限额内完整日志未被完整读取"
        }
        val over = NotificationTextExtractor.extractForLog(context, notice(511))
        check(over.text == "正文" && over.textCompleteness == "partial") {
            "节点预算跳过内容时没有提示日志不完整"
        }
    }
    /** 异常字段不打断其他正文读取；UTF-16截断保留完整字符。 */
    private fun logHandlesMalformedFieldsAndSurrogateBoundaries(context: Context) {
        val malformed = Notification().apply {
            extras = Bundle().apply {
                putInt(Notification.EXTRA_TEXT, 42)
                putCharSequence(Notification.EXTRA_BIG_TEXT, "可读正文")
            }
        }
        val malformedLog = NotificationTextExtractor.extractForLog(context, malformed)
        check(malformedLog.text == "可读正文" && malformedLog.textCompleteness == "partial") {
            "异常标准字段丢失其他文字或没有标明部分内容"
        }
        val emoji = Notification().apply {
            extras = Bundle().apply {
                putCharSequence(Notification.EXTRA_TEXT, "x".repeat(65_535) + "\uD83D\uDCB0")
            }
        }
        val emojiLog = NotificationTextExtractor.extractForLog(context, emoji)
        check(emojiLog.text == "x".repeat(65_535) && emojiLog.textCompleteness == "partial") {
            "日志预算在UTF-16代理对中间截断，产生不完整字符"
        }
    }

    private fun nodeLimitView(childrenBeforeSentinel: Int): RemoteViews =
        testLayout("notification_text_extraction_text").apply {
            removeAllViews(android.R.id.content)
            repeat(childrenBeforeSentinel) {
                addView(android.R.id.content, testLayout("notification_text_extraction_line").apply {
                    setTextViewText(android.R.id.text1, "正文")
                })
            }
            addView(android.R.id.content, testLayout("notification_text_extraction_line").apply {
                setTextViewText(android.R.id.text1, "限额哨兵")
            })
        }

    /** 测试 APK 自有的安全 RemoteViews 布局，不依赖平台 TwoLineListItem 的注解状态。 */
    private fun testLayout(name: String): RemoteViews {
        val resourceContext = requireNotNull(testResourceContext)
        val layoutId = resourceContext.resources.getIdentifier(name, "layout", resourceContext.packageName)
        check(layoutId != 0) { "通知正文测试布局未打包：$name" }
        return RemoteViews(resourceContext.packageName, layoutId)
    }

    private fun message(text: String): Bundle = Bundle().apply { putCharSequence("text", text) }

    private fun customView(first: String, second: String): RemoteViews =
        testLayout("notification_text_extraction_text").apply {
            setTextViewText(android.R.id.text1, first)
            setTextViewText(android.R.id.text2, second)
        }
}
