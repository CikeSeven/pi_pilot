package com.pipilot.pi_pilot

import android.content.Context
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/// 持久诊断环形缓冲。
///
/// 为什么不用 logcat:这台验收机(小米 13 / Android 16)的 logcat 对应用自身
/// 标签不可靠 —— 实测 146720 行全量日志里应用自己的行数为 0,而系统组件的行
/// 正常。后台冻结类问题恰好只能靠客户端视角取证,所以诊断必须落到应用私有
/// 文件,再通过 MethodChannel 读回来。
///
/// 写入必须廉价:后台冻结的现场不能因为诊断本身引入阻塞。用追加写 + 有界行数,
/// 不做 fsync —— 丢掉最后几行远好过改变被观测的时序。
object WatcherDiagnostics {
    private const val FILE_NAME = "watcher-diag.log"
    private const val MAX_LINES = 2000
    private val stamp = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)

    @Volatile private var file: File? = null
    @Volatile private var enabled = false
    private var lineCount = 0

    fun init(context: Context) {
        if (file != null) return
        file = File(context.filesDir, FILE_NAME)
        enabled = true
    }

    /// 记一条事件。thread 名是关键证据:OEM 冻结时 OkHttp 回调线程会整体停摆,
    /// 而 handler 线程可能还活着,两者对照才能区分冻结与逻辑错误。
    fun log(event: String) {
        if (!enabled) return
        val target = file ?: return
        try {
            if (lineCount >= MAX_LINES) {
                target.writeText("")
                lineCount = 0
            }
            val line = "${stamp.format(Date())} [${Thread.currentThread().name}] $event\n"
            target.appendText(line)
            lineCount++
        } catch (_: Exception) {
            // 诊断失败绝不能影响被观测的路径。
        }
    }

    fun dump(): String {
        val target = file ?: return "(diagnostics not initialized)"
        return try {
            if (target.exists()) target.readText() else "(empty)"
        } catch (error: Exception) {
            "(read failed: ${error.message})"
        }
    }

    fun clear() {
        try {
            file?.writeText("")
            lineCount = 0
        } catch (_: Exception) {
        }
    }
}
