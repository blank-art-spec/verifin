package top.talyra42.verifin

import android.app.Notification
import android.content.Context
import android.os.Bundle
import android.util.Log
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.Chronometer
import android.widget.FrameLayout
import android.widget.TextClock
import android.widget.TextView

/** 通知正文的本地只读提取；调用方须先检查采集开关和允许的通知来源。 */
@Suppress("DEPRECATION")
internal object NotificationTextExtractor {
    private const val LOG_TAG = "VeriFinCapture"
    private const val MAX_FALLBACK_TEXT_LENGTH = 8_000
    private const val MAX_VIEW_NODES = 512
    private const val MAX_VIEW_DEPTH = 32

    /**
     * 保持标准字段的顺序、整串去重和内容不变；仅缺少标准正文时读取自定义布局。
     *
     * @param context 监听服务 Context，用于解析 RemoteViews 引用的来源资源。
     * @param notification 系统已经交付的通知；不展开通知栏、不点击控件、不启动界面。
     * @return 标题与正文；没有可读取文字时返回 null。
     */
    fun extract(context: Context, notification: Notification?): String? {
        notification ?: return null
        val extras = notification.extras ?: Bundle.EMPTY
        val values = linkedSetOf<String>()
        var hasStandardBody = false

        fun add(value: CharSequence?, body: Boolean = false) {
            val normalized = value?.toString()?.trim().orEmpty()
            if (normalized.isEmpty()) return
            values.add(normalized)
            if (body) hasStandardBody = true
        }

        add(extras.getCharSequence(Notification.EXTRA_TITLE))
        add(extras.getCharSequence(Notification.EXTRA_TITLE_BIG))
        add(extras.getCharSequence(Notification.EXTRA_BIG_TEXT), body = true)
        add(extras.getCharSequence(Notification.EXTRA_TEXT), body = true)
        add(extras.getCharSequence(Notification.EXTRA_SUB_TEXT))
        add(extras.getCharSequence(Notification.EXTRA_SUMMARY_TEXT))
        add(extras.getCharSequence(Notification.EXTRA_INFO_TEXT))
        add(extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE))
        extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)?.forEach { add(it, body = true) }
        appendMessageTexts(extras.get(Notification.EXTRA_MESSAGES)) { add(it, body = true) }
        appendMessageTexts(extras.get(Notification.EXTRA_HISTORIC_MESSAGES)) { add(it, body = true) }
        add(notification.tickerText, body = true)

        if (!hasStandardBody) {
            appendCustomText(context, notification, values)
        }
        return values.joinToString("\n").ifBlank { null }
    }

    /** 提取 MessagingStyle 当前/历史消息；异常元素保持原有的安全忽略行为。 */
    private fun appendMessageTexts(rawValue: Any?, add: (CharSequence?) -> Unit) {
        val messages = rawValue as? Array<*> ?: return
        for (message in messages) {
            val bundle = message as? Bundle ?: continue
            add(bundle.getCharSequence("text"))
        }
    }

    /** 在未挂载的布局上读取可见 TextView；优先展开正文，随后补折叠和横幅。 */
    private fun appendCustomText(context: Context, notification: Notification, values: LinkedHashSet<String>) {
        var textLength = values.sumOf { it.length } + (values.size - 1).coerceAtLeast(0)
        val layouts = listOfNotNull(notification.bigContentView, notification.contentView, notification.headsUpContentView)
            .distinct()
        for (layout in layouts) {
            if (textLength >= MAX_FALLBACK_TEXT_LENGTH) break
            try {
                val root = layout.apply(context, FrameLayout(context))
                var visited = 0

                fun visit(view: View, depth: Int) {
                    if (visited >= MAX_VIEW_NODES || depth > MAX_VIEW_DEPTH || textLength >= MAX_FALLBACK_TEXT_LENGTH) return
                    visited++
                    if (view.visibility != View.VISIBLE || view.alpha <= 0f) return
                    // 动作按钮、计时器和时钟不是正文，避免它们给金融预过滤带来数字噪声。
                    if (view is TextView && view !is Button && view !is Chronometer && view !is TextClock) {
                        val normalized = view.text?.toString()?.trim().orEmpty()
                        if (normalized.isNotEmpty() && normalized !in values) {
                            val separatorLength = if (values.isEmpty()) 0 else 1
                            val remaining = MAX_FALLBACK_TEXT_LENGTH - textLength - separatorLength
                            if (remaining > 0) {
                                val bounded = normalized.take(remaining)
                                if (values.add(bounded)) textLength += separatorLength + bounded.length
                            }
                        }
                    }
                    if (view is ViewGroup && depth < MAX_VIEW_DEPTH) {
                        for (index in 0 until view.childCount) {
                            if (visited >= MAX_VIEW_NODES || textLength >= MAX_FALLBACK_TEXT_LENGTH) break
                            visit(view.getChildAt(index), depth + 1)
                        }
                    }
                }

                visit(root, 0)
            } catch (_: RuntimeException) {
                // 资源失效或 ROM 不兼容时继续其他布局；不记录异常对象、正文或金额。
                Log.w(LOG_TAG, "通知自定义布局正文读取失败，保留标准字段")
            }
        }
    }
}
