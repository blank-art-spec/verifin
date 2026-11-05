package top.talyra42.verifin

import android.content.Context
import android.content.ContextWrapper
import android.os.Build
import android.util.AtomicFile
import java.io.File
import java.security.KeyStore
import java.util.UUID

/**
 * 仅供未来显式 Android 诊断调用的原生检查，不在启动或 MethodChannel 中自动执行。
 * 使用独立临时目录、文件名和 Keystore 别名，绝不读取或清除用户的实际凭证。
 */
internal object OptionQuoteCredentialStoreChecks {
    fun runAll(base: Context) {
        check(base.packageName.endsWith(".graphicsdiagnostic")) {
            "凭证检查只允许诊断应用"
        }
        val identity = UUID.randomUUID().toString()
        val directory = File(base.noBackupFilesDir, "option_quote_check_$identity")
        check(directory.mkdir())
        val context = object : ContextWrapper(base) {
            override fun getNoBackupFilesDir(): File = directory
        }
        val alias = "verifin.option_quote.test.$identity"
        val fileName = "isolated_test_credentials.v1"
        val file = File(directory, fileName)
        val newFile = File(file.path + ".new")
        val backupFile = File(file.path + ".bak")
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        fun store() = OptionQuoteCredentialStore(context, alias, fileName)
        val expected = mapOf("keyId" to "synthetic-key-only", "secretKey" to "synthetic-secret-only")
        try {
            check(store().read() == null)
            check(!keyStore.containsAlias(alias)) { "空读取不得创建密钥" }

            store().write("  synthetic-key-only  ", " synthetic-secret-only ")
            val original = file.readBytes()
            check(store().read() == expected) { "新实例必须恢复整对凭证" }
            val raw = original.toString(Charsets.ISO_8859_1)
            check(!raw.contains("synthetic-key-only") && !raw.contains("synthetic-secret-only")) {
                "文件不得包含凭证明文"
            }
            check(keyStore.getKey(alias, null).encoded == null) { "设备密钥不可导出" }
            store().write("synthetic-key-only", "synthetic-secret-only")
            val committed = file.readBytes()
            check(!original.contentEquals(committed)) { "相同明文应使用不同随机 IV" }
            check(store().read() == expected)

            for ((key, secret) in listOf(
                "" to "synthetic-secret-only",
                "synthetic-key-only" to "",
                "" to "",
                "x".repeat(513) to "synthetic-secret-only",
                "synthetic-key-only" to "line\nbreak",
                "synthetic-key-only" to "非ASCII",
            )) {
                expectFailure { store().write(key, secret) }
                check(file.readBytes().contentEquals(committed)) { "无效保存必须保留旧密文" }
            }

            // 模拟进程在 startWrite 后中断：没有 finishWrite，冷读应恢复旧版本。
            val interrupted = AtomicFile(file).startWrite()
            interrupted.write(byteArrayOf(1, 2, 3, 4))
            interrupted.fd.sync()
            interrupted.close()
            check(store().read() == expected) { "中断写入不能覆盖已提交凭证" }
            check(file.readBytes().contentEquals(committed))

            // 新版 AtomicFile 使用 .new；真实打开失败不得动旧主文件。
            if (Build.VERSION.SDK_INT >= 30) {
                check(newFile.mkdir())
                val blocker = File(newFile, "blocker").apply { writeBytes(byteArrayOf(1)) }
                expectFailure { store().write("replacement-key", "replacement-secret") }
                check(file.readBytes().contentEquals(committed))
                check(blocker.delete() && newFile.delete())
                check(store().read() == expected)
            }

            // GCM 认证必须拒绝篡改，读取失败不能删除异常文件或回退成“未配置”。
            val tampered = committed.copyOf()
            tampered[tampered.lastIndex] = (tampered.last().toInt() xor 1).toByte()
            file.writeBytes(tampered)
            expectFailure { store().read() }
            check(file.readBytes().contentEquals(tampered))
            file.writeBytes(ByteArray(4097) { 1 })
            expectFailure { store().read() }
            check(file.length() == 4097L)
            file.writeBytes(committed)

            // 清除无法移走临时文件时应失败，保留主文件，不能误报已清除。
            check(newFile.mkdir())
            val blocker = File(newFile, "clear-blocker").apply { writeBytes(byteArrayOf(1)) }
            expectFailure { store().clear() }
            check(file.readBytes().contentEquals(committed))
            check(blocker.delete() && newFile.delete())

            // 旧版中断写入后 .bak 才是有效版本；清除后续失败仍必须保留可恢复凭证。
            backupFile.writeBytes(committed)
            file.writeBytes(byteArrayOf(1, 2, 3, 4))
            check(newFile.mkdir())
            val recoveryBlocker = File(newFile, "recovery-clear-blocker").apply {
                writeBytes(byteArrayOf(1))
            }
            expectFailure { store().clear() }
            check(!backupFile.exists()) { "必须先恢复权威备份到主文件" }
            check(file.readBytes().contentEquals(committed)) {
                "清除失败不能删除唯一有效备份并留下部分写入的主文件"
            }
            check(recoveryBlocker.delete() && newFile.delete())
            check(store().read() == expected)

            backupFile.writeBytes(committed)
            newFile.writeBytes(committed)
            store().clear()
            check(listOf(file, backupFile, newFile).none { it.exists() }) {
                "成功清除不能遗留能恢复的 AtomicFile 副本"
            }
            check(store().read() == null)
            check(keyStore.containsAlias(alias)) { "清除文件不应先破坏密钥" }

            store().write("synthetic-key-only", "synthetic-secret-only")
            val beforeMissingKey = file.readBytes()
            keyStore.deleteEntry(alias)
            expectFailure { store().read() }
            check(file.readBytes().contentEquals(beforeMissingKey))
            check(!keyStore.containsAlias(alias)) { "读失败不得重新生成密钥" }
            // 清除时恢复权威备份不需要解密；即使密钥丢失，也不能阻止用户主动清除。
            backupFile.writeBytes(beforeMissingKey)
            file.writeBytes(byteArrayOf(1, 2, 3, 4))
            store().clear()
            check(listOf(file, backupFile, newFile).none { it.exists() })
            check(!keyStore.containsAlias(alias)) { "清除恢复路径不得生成新密钥" }
        } finally {
            // 只清理本次随机目录与别名，不使用生产文件名或生产别名。
            directory.listFiles()?.forEach { child ->
                if (child.isDirectory) child.listFiles()?.forEach { it.delete() }
                child.delete()
            }
            directory.delete()
            if (keyStore.containsAlias(alias)) keyStore.deleteEntry(alias)
        }
    }

    private fun expectFailure(action: () -> Unit) {
        var failed = false
        try {
            action()
        } catch (_: Exception) {
            failed = true
        }
        check(failed) { "预期的失败未发生" }
    }
}
