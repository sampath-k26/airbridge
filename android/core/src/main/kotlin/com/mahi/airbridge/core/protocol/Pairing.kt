package com.mahi.airbridge.core.protocol

import com.mahi.airbridge.core.crypto.AbCrypto
import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import java.util.Base64

/** Short-lived, single-use pairing code (SPEC §3.1). */
class PairingCode(val code: String = generate(), now: Long = System.currentTimeMillis()) {
    val expiresAt = now + LIFETIME_MS
    private var failures = 0
    private var consumed = false

    val display get() = code.substring(0, 5) + "-" + code.substring(5)
    val key: ByteArray get() = code.toByteArray(Charsets.US_ASCII)

    @Synchronized
    fun isUsable(now: Long = System.currentTimeMillis()) = !consumed && failures < MAX_FAILURES && now < expiresAt

    @Synchronized fun recordFailure() { failures++ }
    @Synchronized fun consume() { consumed = true }

    companion object {
        const val ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
        const val LIFETIME_MS = 5 * 60 * 1000L
        const val MAX_FAILURES = 5

        // 50 bits: the low 5 bits of each CSPRNG byte select one of 32 symbols uniformly.
        fun generate(): String = AbCrypto.randomBytes(10).joinToString("") { ALPHABET[it.toInt() and 0x1F].toString() }

        fun normalize(input: String): String? {
            val sb = StringBuilder()
            for (ch in input.uppercase()) {
                when (ch) {
                    '-', ' ' -> {}
                    'O' -> sb.append('0')
                    'I', 'L' -> sb.append('1')
                    else -> { if (ch !in ALPHABET) return null; sb.append(ch) }
                }
            }
            return sb.toString().takeIf { it.length == 10 }
        }
    }
}

/** QR payload (SPEC §3.2). */
data class PairingUri(
    val hosts: List<String>,
    val port: Int,
    val code: String,
    val fingerprint: ByteArray?,
    val name: String,
) {
    fun toUri(): String {
        fun enc(s: String) = URLEncoder.encode(s, "UTF-8").replace("+", "%20")
        val sb = StringBuilder("airbridge://pair?v=${AbProtocol.VERSION}")
        sb.append("&h=").append(enc(hosts.joinToString(",")))
        sb.append("&p=").append(port)
        sb.append("&c=").append(code)
        fingerprint?.let { sb.append("&f=").append(Base64Url.encode(it)) }
        sb.append("&n=").append(enc(name))
        return sb.toString()
    }

    override fun equals(other: Any?): Boolean = other is PairingUri && hosts == other.hosts && port == other.port &&
        code == other.code && name == other.name &&
        (fingerprint ?: ByteArray(0)).contentEquals(other.fingerprint ?: ByteArray(0))
    override fun hashCode() = code.hashCode()

    companion object {
        fun parse(s: String): PairingUri? = runCatching {
            val uri = URI(s.trim())
            if (uri.scheme != "airbridge" || uri.host != "pair") return null
            val q = (uri.rawQuery ?: return null).split("&").mapNotNull {
                val i = it.indexOf('=')
                if (i < 0) null else it.substring(0, i) to URLDecoder.decode(it.substring(i + 1), "UTF-8")
            }.toMap()
            if (q["v"] != AbProtocol.VERSION.toString()) return null
            val hosts = q["h"]?.split(",")?.filter { it.isNotBlank() }?.takeIf { it.isNotEmpty() } ?: return null
            val port = q["p"]?.toIntOrNull()?.takeIf { it in 1..65535 } ?: return null
            val code = q["c"]?.let { PairingCode.normalize(it) } ?: return null
            val fp = q["f"]?.let { Base64Url.decode(it)?.takeIf { d -> d.size == 32 } ?: return null }
            PairingUri(hosts, port, code, fp, q["n"] ?: "")
        }.getOrNull()
    }
}

object Base64Url {
    fun encode(d: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(d)
    fun decode(s: String): ByteArray? = runCatching { Base64.getUrlDecoder().decode(s) }.getOrNull()
}
