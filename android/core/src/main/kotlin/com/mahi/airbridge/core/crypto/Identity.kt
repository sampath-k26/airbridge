package com.mahi.airbridge.core.crypto

import com.mahi.airbridge.core.protocol.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.File
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.X509EncodedKeySpec
import java.util.Base64

/** Long-term device identity (SPEC §2.1). Android uses a Keystore-backed implementation. */
interface DeviceIdentity {
    val spki: ByteArray
    fun sign(message: ByteArray): ByteArray

    val deviceId: String get() = AbCrypto.deviceId(spki)
    val fingerprint: ByteArray get() = AbCrypto.fingerprint(spki)
}

/** Software key pair; used by the JVM CLI and tests. */
class SoftwareIdentity(private val privateKey: PrivateKey, override val spki: ByteArray) : DeviceIdentity {
    override fun sign(message: ByteArray): ByteArray =
        Signature.getInstance("SHA256withECDSA").run { initSign(privateKey); update(message); sign() }

    companion object {
        fun generate(): SoftwareIdentity {
            val kp: KeyPair = KeyPairGenerator.getInstance("EC")
                .apply { initialize(ECGenParameterSpec("secp256r1"), AbCrypto.random) }.generateKeyPair()
            return SoftwareIdentity(kp.private, kp.public.encoded)
        }

        fun fromScalar(raw: ByteArray, spki: ByteArray) = SoftwareIdentity(AbCrypto.privateKeyFromScalar(raw), spki)

        /** File holds `PKCS8 || SPKI` base64 lines; permissions restricted to the owner. */
        fun loadOrCreate(file: File): SoftwareIdentity {
            if (file.exists()) {
                runCatching {
                    val (p, s) = file.readLines().map { Base64.getDecoder().decode(it) }
                    val kf = KeyFactory.getInstance("EC")
                    kf.generatePublic(X509EncodedKeySpec(s))
                    return SoftwareIdentity(kf.generatePrivate(PKCS8EncodedKeySpec(p)), s)
                }
            }
            val kp = KeyPairGenerator.getInstance("EC")
                .apply { initialize(ECGenParameterSpec("secp256r1"), AbCrypto.random) }.generateKeyPair()
            file.parentFile?.mkdirs()
            file.writeText(Base64.getEncoder().encodeToString(kp.private.encoded) + "\n" +
                Base64.getEncoder().encodeToString(kp.public.encoded) + "\n")
            file.setReadable(false, false); file.setReadable(true, true)
            file.setWritable(false, false); file.setWritable(true, true)
            return SoftwareIdentity(kp.private, kp.public.encoded)
        }
    }
}

/** A paired peer. Public keys are not secret. */
data class PeerRecord(
    val deviceId: String,
    val spki: ByteArray,
    val name: String,
    val platform: String,
    val lastHosts: List<String>,
    val lastPort: Int?,
    val pairedAt: Long,
    val lastSeen: Long,
) {
    val displayFingerprint get() = AbCrypto.displayFingerprint(spki)

    fun toJson(): JsonObject = buildJsonObject {
        put("deviceId", deviceId)
        put("spki", Base64.getEncoder().encodeToString(spki))
        put("name", name)
        put("platform", platform)
        put("lastHosts", JsonArray(lastHosts.map { kotlinx.serialization.json.JsonPrimitive(it) }))
        lastPort?.let { put("lastPort", it) }
        put("pairedAt", pairedAt)
        put("lastSeen", lastSeen)
    }

    override fun equals(other: Any?) = other is PeerRecord && other.deviceId == deviceId && other.spki.contentEquals(spki) &&
        other.name == name && other.lastHosts == lastHosts && other.lastPort == lastPort && other.lastSeen == lastSeen
    override fun hashCode() = deviceId.hashCode()

    companion object {
        fun fromJson(o: JsonObject) = PeerRecord(
            deviceId = Json.str(o, "deviceId"),
            spki = Base64.getDecoder().decode(Json.str(o, "spki")),
            name = Json.str(o, "name"),
            platform = Json.optStr(o, "platform") ?: "",
            lastHosts = Json.strList(o, "lastHosts"),
            lastPort = Json.optLong(o, "lastPort")?.toInt(),
            pairedAt = Json.optLong(o, "pairedAt") ?: 0,
            lastSeen = Json.optLong(o, "lastSeen") ?: 0,
        )
    }
}

/** Persistent paired-device list (JSON file). Thread-safe. */
class TrustStore(private val file: File?) {
    private val peers = LinkedHashMap<String, PeerRecord>()

    init {
        file?.takeIf { it.exists() }?.let { f ->
            runCatching {
                Json.parseArray(f.readText()).forEach { e ->
                    val p = PeerRecord.fromJson(e as JsonObject); peers[p.deviceId] = p
                }
            }
        }
    }

    @get:Synchronized
    val all: List<PeerRecord> get() = peers.values.sortedByDescending { it.lastSeen }

    @Synchronized
    fun peer(spki: ByteArray): PeerRecord? =
        peers[AbCrypto.deviceId(spki)]?.takeIf { it.spki.contentEquals(spki) }

    @Synchronized
    fun upsert(p: PeerRecord) { peers[p.deviceId] = p; save() }

    @Synchronized
    fun remove(deviceId: String) { peers.remove(deviceId); save() }

    private fun save() {
        val f = file ?: return
        f.parentFile?.mkdirs()
        val tmp = File(f.parentFile, f.name + ".tmp")
        tmp.writeText(JsonArray(peers.values.map { it.toJson() }).toString())
        tmp.renameTo(f)
    }
}
