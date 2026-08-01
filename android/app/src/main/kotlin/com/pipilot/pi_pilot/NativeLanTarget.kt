package com.pipilot.pi_pilot

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/// 连接目标的凭据加密接口。生产用 Keystore 实现;JVM 单测没有 AndroidKeyStore,
/// 用明文直通实现隔离——序列化与重建逻辑因此可以纯 JVM 测。
interface TokenCipher {
    fun wrap(plain: String): String
    fun unwrap(wrapped: String): String?
}

/// 明文直通,仅用于 JVM 单测。
class PlainTokenCipher : TokenCipher {
    override fun wrap(plain: String): String = "plain:$plain"
    override fun unwrap(wrapped: String): String? =
        if (wrapped.startsWith("plain:")) wrapped.removePrefix("plain:") else null
}

/// Android Keystore AES/GCM 包装。密钥只存在于硬件/TEE,导不出;
/// 重启后首次解锁前 Keystore 可能不可用,unwrap 返回 null 时调用方
/// 只保留路由元数据、绝不落明文替代。
class KeystoreTokenCipher(
    private val keyAlias: String = "pipilot_lan_token_v1",
) : TokenCipher {
    private val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private fun key(): SecretKey {
        (keyStore.getEntry(keyAlias, null) as? KeyStore.SecretKeyEntry)?.let {
            return it.secretKey
        }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                keyAlias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    override fun wrap(plain: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val encrypted = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        val iv = cipher.iv
        val blob = ByteArray(iv.size + encrypted.size)
        System.arraycopy(iv, 0, blob, 0, iv.size)
        System.arraycopy(encrypted, 0, blob, iv.size, encrypted.size)
        return "gcm:" + android.util.Base64.encodeToString(blob, android.util.Base64.NO_WRAP)
    }

    override fun unwrap(wrapped: String): String? {
        if (!wrapped.startsWith("gcm:")) return null
        return runCatching {
            val blob = android.util.Base64.decode(wrapped.removePrefix("gcm:"), android.util.Base64.NO_WRAP)
            val iv = blob.copyOfRange(0, 12)
            val encrypted = blob.copyOfRange(12, blob.size)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, iv))
            String(cipher.doFinal(encrypted), Charsets.UTF_8)
        }.getOrNull()
    }
}

/// 原生 LAN owner 的持久连接目标。
///
/// 存 noBackupFilesDir:配对 token 不能进云备份/设备迁移——换机恢复出旧 token
/// 会静默连到旧 Bridge 且用户无从察觉。文件 JSON 明文存元数据,token 只存
/// Keystore 包装后的密文。
data class NativeLanTarget(
    val deviceId: String,
    val host: String,
    val port: Int,
    val wrappedToken: String,
    val clientId: String,
    val bridgeInstallationId: String?,
    val savedAtMillis: Long,
) {
    /// 无依赖序列化:org.json 在 JVM 单测里是 stub,假解析会让 fromJson
    /// 静默返回垃圾——与 NotificationGate 去重记录同一教训,用字段分隔符。
    /// 字段域受控(host 是 IP/主机名,token 是 gcm:base64),不含分隔符。
    fun serialize(): String {
        val fields = listOf(
            SCHEMA,
            deviceId,
            host,
            port.toString(),
            wrappedToken,
            clientId,
            bridgeInstallationId.orEmpty(),
            savedAtMillis.toString(),
        )
        return fields.joinToString(FIELD_SEP)
    }

    companion object {
        const val FILE_NAME = "native_lan_target_v1.json"
        private const val SCHEMA = "1"
        private const val FIELD_SEP = "\u001f"

        fun deserialize(raw: String): NativeLanTarget? = runCatching {
            val parts = raw.split(FIELD_SEP)
            if (parts.size != 8 || parts[0] != SCHEMA) return null
            NativeLanTarget(
                deviceId = parts[1],
                host = parts[2],
                port = parts[3].toInt(),
                wrappedToken = parts[4],
                clientId = parts[5],
                bridgeInstallationId = parts[6].ifEmpty { null },
                savedAtMillis = parts[7].toLong(),
            ).takeIf {
                // 关键字段为空视为损坏,宁可重建也不拿半个目标去连。
                it.deviceId.isNotEmpty() && it.host.isNotEmpty() &&
                    it.wrappedToken.isNotEmpty() && it.clientId.isNotEmpty()
            }
        }.getOrNull()

        /// 用文件系统读写。返回 false 表示写失败——调用方不得声称已持久。
        fun save(context: Context, target: NativeLanTarget, cipher: TokenCipher): Boolean = runCatching {
            val dir = context.noBackupFilesDir
            val tmp = File(dir, "$FILE_NAME.tmp")
            val dst = File(dir, FILE_NAME)
            tmp.writeText(target.serialize())
            // 原子替换:先写临时文件再 rename,进程死在半途不会留下半个记录。
            if (!tmp.renameTo(dst)) {
                dst.delete()
                if (!tmp.renameTo(dst)) return@runCatching false
            }
            true
        }.getOrDefault(false)

        fun load(context: Context): NativeLanTarget? = runCatching {
            val f = File(context.noBackupFilesDir, FILE_NAME)
            if (!f.exists()) return null
            deserialize(f.readText())
        }.getOrNull()

        fun clear(context: Context) {
            runCatching { File(context.noBackupFilesDir, FILE_NAME).delete() }
        }
    }
}
