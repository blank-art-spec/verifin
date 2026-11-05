package top.talyra42.verifin

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.IOException
import java.security.KeyStore
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * 仅保存一对期权行情凭证。密钥留在 AndroidKeyStore，磁盘只有有界的认证密文。
 * noBackupFilesDir 不参与系统备份；此文件不属于账目、偏好或应用导出目录。
 * [keyAlias] 和 [fileName] 仅允许原生诊断用例选择独立测试身份，平台通道不接收它们。
 */
internal class OptionQuoteCredentialStore(
    context: Context,
    private val keyAlias: String = KEY_ALIAS,
    fileName: String = FILE_NAME,
) {
    private val file: File
    private val atomicFile: AtomicFile

    init {
        require(fileName.matches(Regex("[A-Za-z0-9_.-]{1,80}")))
        file = File(context.noBackupFilesDir, fileName)
        atomicFile = AtomicFile(file)
    }

    /** 不存在返回 null；损坏、认证失败、密钥丢失或不可用均报错，绝不删除或重置。 */
    fun read(): Map<String, String>? = synchronized(storageLock) {
        val encoded = readEncoded() ?: return@synchronized null
        if (encoded.size < HEADER.size + IV_BYTES + TAG_BYTES + 6 ||
            !encoded.copyOfRange(0, HEADER.size).contentEquals(HEADER)
        ) throw IOException("Invalid credential envelope")
        val iv = encoded.copyOfRange(HEADER.size, HEADER.size + IV_BYTES)
        val ciphertext = encoded.copyOfRange(HEADER.size + IV_BYTES, encoded.size)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, getKey(create = false), GCMParameterSpec(TAG_BITS, iv))
        cipher.updateAAD(HEADER)
        val plaintext = cipher.doFinal(ciphertext)
        try {
            DataInputStream(ByteArrayInputStream(plaintext)).use { input ->
                val key = readCredential(input)
                val secret = readCredential(input)
                if (input.available() != 0) throw IOException("Invalid credential payload")
                mapOf("keyId" to key, "secretKey" to secret)
            }
        } finally {
            plaintext.fill(0)
        }
    }

    /** 先校验并完成加密，再原子替换整对凭证；失败由 AtomicFile 回滚旧密文。 */
    fun write(keyId: String, secretKey: String) = synchronized(storageLock) {
        val key = validatedCredential(keyId)
        val secret = validatedCredential(secretKey)
        val plaintext = ByteArrayOutputStream().use { bytes ->
            DataOutputStream(bytes).use { output ->
                writeCredential(output, key)
                writeCredential(output, secret)
            }
            bytes.toByteArray()
        }
        val encoded = try {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            // 由 Keystore provider 生成随机 IV；不接受外部 nonce，也不导出密钥。
            cipher.init(Cipher.ENCRYPT_MODE, getKey(create = true))
            if (cipher.iv.size != IV_BYTES) throw IOException("Invalid credential IV")
            cipher.updateAAD(HEADER)
            HEADER + cipher.iv + cipher.doFinal(plaintext)
        } finally {
            plaintext.fill(0)
        }
        if (encoded.size > MAX_FILE_BYTES) throw IOException("Credential envelope too large")
        var output: FileOutputStream? = null
        try {
            output = atomicFile.startWrite()
            output.write(encoded)
            // 显式同步可把磁盘失败交给调用方；不只依赖 finishWrite 的内部日志。
            output.fd.sync()
            atomicFile.finishWrite(output)
            output = null
            if (readEncoded()?.contentEquals(encoded) != true) {
                throw IOException("Credential commit failed")
            }
        } catch (error: Exception) {
            output?.let { atomicFile.failWrite(it) }
            throw error
        }
    }

    /**
     * 先恢复旧 AtomicFile 的权威备份，再删除未提交文件和主文件。
     * 恢复只处理密文文件，不解密，缺少密钥或密文损坏时仍可由用户明确清除。
     * 任何清除前置步骤失败都保留主文件或其权威备份，不先删除唯一可恢复版本。
     * 保留不可导出的 Keystore key，避免先删 key 后文件删除失败损坏仍存在的凭证。
     */
    fun clear() = synchronized(storageLock) {
        val backup = File(file.path + ".bak")
        val pending = File(file.path + ".new")
        if (backup.exists()) {
            // 新旧 AtomicFile 均会在 openRead 恢复 .bak；旧主文件可能只是中断写入的残片。
            atomicFile.openRead().use { /* 不解析、不解密，只完成原子文件恢复并关闭句柄。 */ }
            // 部分系统实现只记录 rename 失败；备份未消失时不能继续破坏性删除。
            if (backup.exists()) throw IOException("Credential recovery failed")
        }
        for (candidate in listOf(pending, file)) {
            if (candidate.exists() && !candidate.delete()) {
                throw IOException("Credential deletion failed")
            }
        }
        if (listOf(backup, pending, file).any { it.exists() }) {
            throw IOException("Credential deletion incomplete")
        }
    }

    /** 流式上限在读取时生效；不把损坏或异常大文件一次加载进内存。 */
    private fun readEncoded(): ByteArray? {
        val input = try {
            atomicFile.openRead()
        } catch (error: FileNotFoundException) {
            if (!file.exists() && !File(file.path + ".bak").exists()) return null
            throw error
        }
        return input.use { source ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(512)
            while (true) {
                val size = source.read(buffer)
                if (size < 0) break
                if (output.size() + size > MAX_FILE_BYTES) {
                    throw IOException("Credential envelope too large")
                }
                output.write(buffer, 0, size)
            }
            output.toByteArray()
        }
    }

    /** 读取路径不会生成密钥；既有别名异常时也不删除或静默重新生成。 */
    private fun getKey(create: Boolean): SecretKey {
        val keyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        if (keyStore.containsAlias(keyAlias)) {
            return keyStore.getKey(keyAlias, null) as? SecretKey
                ?: throw IOException("Credential key unavailable")
        }
        if (!create) throw IOException("Credential key missing")
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE).apply {
            init(KeyGenParameterSpec.Builder(
                keyAlias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            ).setKeySize(256)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .setUserAuthenticationRequired(false)
                .build())
        }.generateKey()
    }

    private fun validatedCredential(raw: String): String {
        val value = raw.trim()
        if (value.length !in 1..512 || value.any { it.code !in 0x21..0x7e }) {
            throw IllegalArgumentException("Invalid option quote credentials")
        }
        return value
    }

    private fun writeCredential(output: DataOutputStream, value: String) {
        val bytes = value.toByteArray(Charsets.US_ASCII)
        output.writeShort(bytes.size)
        output.write(bytes)
        bytes.fill(0)
    }

    private fun readCredential(input: DataInputStream): String {
        val length = input.readUnsignedShort()
        if (length !in 1..512 || input.available() < length) {
            throw IOException("Invalid credential length")
        }
        val bytes = ByteArray(length)
        input.readFully(bytes)
        try {
            if (bytes.any { it.toInt() !in 0x21..0x7e }) {
                throw IOException("Invalid credential encoding")
            }
            return String(bytes, Charsets.US_ASCII)
        } finally {
            bytes.fill(0)
        }
    }

    companion object {
        private const val FILE_NAME = "option_quote_credentials.v1"
        private const val KEY_ALIAS = "verifin.option_quote.credentials.aes.v1"
        private const val KEYSTORE = "AndroidKeyStore"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val IV_BYTES = 12
        private const val TAG_BITS = 128
        private const val TAG_BYTES = TAG_BITS / 8
        private const val MAX_FILE_BYTES = 4096
        private val HEADER = byteArrayOf(0x56, 0x46, 0x51, 0x43, 0x01)
        private val storageLock = Any()
        private val executor = Executors.newSingleThreadExecutor()

        /** 全进程共用串行队列，Activity 重建后也不能并发写同一个 AtomicFile。 */
        fun execute(action: () -> Unit) {
            executor.execute(action)
        }
    }
}
