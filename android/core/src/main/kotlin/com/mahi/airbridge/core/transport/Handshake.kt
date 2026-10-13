package com.mahi.airbridge.core.transport

import com.mahi.airbridge.core.crypto.AbCrypto
import com.mahi.airbridge.core.crypto.DeviceIdentity
import com.mahi.airbridge.core.crypto.PeerRecord
import com.mahi.airbridge.core.crypto.TrustStore
import com.mahi.airbridge.core.protocol.AbException
import com.mahi.airbridge.core.protocol.AbProtocol
import com.mahi.airbridge.core.protocol.ErrorCode
import com.mahi.airbridge.core.protocol.Json
import com.mahi.airbridge.core.protocol.PairingCode
import kotlinx.serialization.json.JsonObject
import java.util.Base64

data class LocalDevice(
    val identity: DeviceIdentity,
    val name: String,
    val platform: String = "android",
    val app: String = "AirBridge-Android/1.0",
)

/** Shown to the user before a new device is trusted. */
data class PairingRequest(val peerName: String, val platform: String, val fingerprint: String, val verificationCode: String)

class HandshakeResult(
    val channel: SecureChannel,
    val peer: PeerRecord,
    val verificationCode: String,
    val newlyPaired: Boolean,
)

/** What the dialer knows when pairing for the first time. */
data class DialPairing(val code: String, val fingerprint: ByteArray?)

/** Authenticated key exchange (SPEC §5). Blocking; call from a background thread. */
object Handshake {
    private val b64 = Base64.getEncoder()
    private val unb64 = Base64.getDecoder()

    private fun b64d(s: String?): ByteArray? = s?.let { runCatching { unb64.decode(it) }.getOrNull() }

    fun dial(
        stream: SocketStream, local: LocalDevice, trust: TrustStore, pairing: DialPairing?, host: String?, port: Int?,
    ): HandshakeResult {
        stream.setReadTimeout(AbProtocol.HANDSHAKE_TIMEOUT_MS)
        val eph = AbCrypto.generateEphemeral()
        val hello = Json.encode(Json.obj(
            "type" to "hello", "proto" to AbProtocol.VERSION, "minProto" to 1,
            "eph" to b64.encodeToString(AbCrypto.spki(eph.public)),
            "nonce" to b64.encodeToString(AbCrypto.randomBytes(32)),
            "pairing" to (pairing != null), "app" to local.app,
        ))
        HandshakeFrame.write(stream, hello)

        val serverHello = HandshakeFrame.read(stream)
        val sh = Json.parseObject(serverHello)
        when (Json.type(sh)) {
            "error" -> throw AbException(ErrorCode.fromWire(Json.optStr(sh, "code")), Json.optStr(sh, "message") ?: "")
            "server_hello" -> {}
            else -> throw AbException(ErrorCode.MALFORMED, "Expected server_hello")
        }
        if (Json.int(sh, "proto") != AbProtocol.VERSION) throw AbException(ErrorCode.UNSUPPORTED_VERSION, "Peer chose v${sh["proto"]}")
        val peerEph = b64d(Json.str(sh, "eph")) ?: throw AbException(ErrorCode.MALFORMED, "Bad eph")

        val th = AbCrypto.transcriptHash(hello, serverHello)
        val keys = AbCrypto.deriveKeys(AbCrypto.ecdh(eph.private, peerEph), th)
        val channel = SecureChannel(stream, keys.dialerToListener, keys.listenerToDialer)
        try {
            val sa = expect(channel, "server_auth")
            val peerSpki = b64d(Json.str(sa, "identity")) ?: throw AbException(ErrorCode.MALFORMED, "Bad identity")
            val sig = b64d(Json.str(sa, "sig")) ?: throw AbException(ErrorCode.MALFORMED, "Bad sig")
            if (!AbCrypto.verify(peerSpki, sig, AbCrypto.SERVER_AUTH_LABEL + th)) {
                throw AbException(ErrorCode.AUTH_FAILED, "Listener signature invalid")
            }
            var trusted = trust.peer(peerSpki) != null
            if (!trusted && pairing != null) {
                trusted = if (pairing.fingerprint != null) {
                    AbCrypto.constantTimeEquals(pairing.fingerprint, AbCrypto.fingerprint(peerSpki))
                } else {
                    val proof = b64d(Json.optStr(sa, "pairProof"))
                    proof != null && AbCrypto.constantTimeEquals(proof,
                        AbCrypto.hmac(pairing.code.toByteArray(), AbCrypto.PAIR_LISTENER_LABEL, th, peerSpki))
                }
            }
            if (!trusted) throw AbException(ErrorCode.AUTH_FAILED, "Listener identity could not be verified")

            val mySig = local.identity.sign(AbCrypto.CLIENT_AUTH_LABEL + th)
            val myProof = pairing?.let {
                b64.encodeToString(AbCrypto.hmac(it.code.toByteArray(), AbCrypto.PAIR_DIALER_LABEL, th, local.identity.spki))
            }
            channel.sendControl(Json.obj(
                "type" to "client_auth", "identity" to b64.encodeToString(local.identity.spki),
                "sig" to b64.encodeToString(mySig), "name" to local.name, "platform" to local.platform, "pairProof" to myProof,
            ))
            // The listener's user may need up to 90 s to approve a new pairing.
            stream.setReadTimeout(AbProtocol.HANDSHAKE_TIMEOUT_MS + AbProtocol.APPROVAL_TIMEOUT_MS)
            val ok = expect(channel, "auth_ok")
            stream.setReadTimeout(AbProtocol.IDLE_TIMEOUT_MS)

            val existing = trust.peer(peerSpki)
            val now = System.currentTimeMillis()
            val record = (existing ?: PeerRecord(AbCrypto.deviceId(peerSpki), peerSpki, Json.str(sa, "name"),
                Json.optStr(sa, "platform") ?: "", emptyList(), null, now, now)).let { r ->
                r.copy(
                    name = Json.optStr(ok, "name") ?: Json.str(sa, "name"), lastSeen = now,
                    lastHosts = if (host != null) (listOf(host) + r.lastHosts.filter { it != host }).take(4) else r.lastHosts,
                    lastPort = port ?: r.lastPort,
                )
            }
            trust.upsert(record)
            return HandshakeResult(channel, record, AbCrypto.sas(th), existing == null)
        } catch (e: Exception) {
            channel.close()
            throw e
        }
    }

    fun accept(
        stream: SocketStream, local: LocalDevice, trust: TrustStore,
        activeCode: () -> PairingCode?, approve: (PairingRequest) -> Boolean,
    ): HandshakeResult {
        stream.setReadTimeout(AbProtocol.HANDSHAKE_TIMEOUT_MS)
        val hello = HandshakeFrame.read(stream)
        val h = Json.parseObject(hello)
        if (Json.type(h) != "hello") throw AbException(ErrorCode.MALFORMED, "Expected hello")
        val proto = Json.int(h, "proto")
        val minProto = Json.optLong(h, "minProto")?.toInt() ?: proto
        if (minProto > AbProtocol.VERSION || proto < AbProtocol.VERSION) {
            runCatching {
                HandshakeFrame.write(stream, Json.encode(Json.obj("type" to "error",
                    "code" to ErrorCode.UNSUPPORTED_VERSION.wire, "message" to "Listener supports protocol v1")))
            }
            throw AbException(ErrorCode.UNSUPPORTED_VERSION, "Dialer protocol $minProto..$proto")
        }
        val peerEph = b64d(Json.str(h, "eph")) ?: throw AbException(ErrorCode.MALFORMED, "Bad eph")
        val wantsPairing = Json.optBool(h, "pairing") == true

        val eph = AbCrypto.generateEphemeral()
        val serverHello = Json.encode(Json.obj(
            "type" to "server_hello", "proto" to AbProtocol.VERSION,
            "eph" to b64.encodeToString(AbCrypto.spki(eph.public)), "nonce" to b64.encodeToString(AbCrypto.randomBytes(32)),
        ))
        HandshakeFrame.write(stream, serverHello)

        val th = AbCrypto.transcriptHash(hello, serverHello)
        val keys = AbCrypto.deriveKeys(AbCrypto.ecdh(eph.private, peerEph), th)
        val channel = SecureChannel(stream, keys.listenerToDialer, keys.dialerToListener)
        fun fail(code: ErrorCode, wire: String): Nothing {
            runCatching { channel.sendControl(Json.obj("type" to "error", "code" to code.wire, "message" to wire), urgent = true); channel.flush() }
            channel.close()
            throw AbException(code, wire)
        }
        try {
            val code = if (wantsPairing) activeCode()?.takeIf { it.isUsable() } else null
            channel.sendControl(Json.obj(
                "type" to "server_auth", "identity" to b64.encodeToString(local.identity.spki),
                "sig" to b64.encodeToString(local.identity.sign(AbCrypto.SERVER_AUTH_LABEL + th)),
                "name" to local.name, "platform" to local.platform,
                "pairProof" to code?.let { b64.encodeToString(AbCrypto.hmac(it.key, AbCrypto.PAIR_LISTENER_LABEL, th, local.identity.spki)) },
            ))
            val ca = expect(channel, "client_auth")
            val peerSpki = b64d(Json.str(ca, "identity")) ?: fail(ErrorCode.MALFORMED, "Bad identity")
            val sig = b64d(Json.str(ca, "sig")) ?: fail(ErrorCode.MALFORMED, "Bad sig")
            if (!AbCrypto.verify(peerSpki, sig, AbCrypto.CLIENT_AUTH_LABEL + th)) fail(ErrorCode.AUTH_FAILED, "Bad signature")

            val sas = AbCrypto.sas(th)
            val peerName = Json.str(ca, "name").take(64)
            val platform = (Json.optStr(ca, "platform") ?: "").take(16)
            var newlyPaired = false
            if (trust.peer(peerSpki) == null) {
                val proof = b64d(Json.optStr(ca, "pairProof"))
                if (!wantsPairing || proof == null) fail(ErrorCode.AUTH_FAILED, "Not paired")
                if (code == null) fail(ErrorCode.PAIRING_EXPIRED, "Pairing code expired or already used")
                val expected = AbCrypto.hmac(code.key, AbCrypto.PAIR_DIALER_LABEL, th, peerSpki)
                if (!AbCrypto.constantTimeEquals(proof, expected)) {
                    code.recordFailure()
                    fail(ErrorCode.AUTH_FAILED, "Wrong pairing code")
                }
                code.consume()
                if (!approve(PairingRequest(peerName, platform, AbCrypto.displayFingerprint(peerSpki), sas))) {
                    fail(ErrorCode.PAIRING_REJECTED, "Declined")
                }
                newlyPaired = true
            }
            val now = System.currentTimeMillis()
            val host = stream.remoteHost
            val record = (trust.peer(peerSpki) ?: PeerRecord(AbCrypto.deviceId(peerSpki), peerSpki, peerName, platform,
                emptyList(), null, now, now)).let { r ->
                r.copy(name = peerName, lastSeen = now,
                    lastHosts = if (host != null) (listOf(host) + r.lastHosts.filter { it != host }).take(4) else r.lastHosts)
            }
            trust.upsert(record)
            channel.sendControl(Json.obj("type" to "auth_ok", "name" to local.name, "paired" to true))
            stream.setReadTimeout(AbProtocol.IDLE_TIMEOUT_MS)
            return HandshakeResult(channel, record, sas, newlyPaired)
        } catch (e: Exception) {
            channel.close()
            throw e
        }
    }

    private fun expect(channel: SecureChannel, type: String): JsonObject {
        val rec = channel.receive() as? Record.Control ?: throw AbException(ErrorCode.MALFORMED, "Expected control")
        if (rec.type == "error") {
            throw AbException(ErrorCode.fromWire(Json.optStr(rec.json, "code"), ErrorCode.AUTH_FAILED), Json.optStr(rec.json, "message") ?: "")
        }
        if (rec.type != type) throw AbException(ErrorCode.MALFORMED, "Expected $type, got ${rec.type}")
        return rec.json
    }
}
