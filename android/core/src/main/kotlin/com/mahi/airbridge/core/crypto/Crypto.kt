package com.mahi.airbridge.core.crypto

import com.mahi.airbridge.core.protocol.AbException
import com.mahi.airbridge.core.protocol.ErrorCode
import java.math.BigInteger
import java.nio.ByteBuffer
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.PublicKey
import java.security.SecureRandom
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPrivateKeySpec
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Cryptographic building blocks (SPEC §2, §5.3). Uses only JCA primitives. */
object AbCrypto {
    val TRANSCRIPT_LABEL = "AirBridge/1".toByteArray()
    val SESSION_KEYS_INFO = "airbridge/1 session keys".toByteArray()
    val SERVER_AUTH_LABEL = "airbridge/1 server-auth".toByteArray()
    val CLIENT_AUTH_LABEL = "airbridge/1 client-auth".toByteArray()
    val PAIR_LISTENER_LABEL = "airbridge/1 pair-listener".toByteArray()
    val PAIR_DIALER_LABEL = "airbridge/1 pair-dialer".toByteArray()

    val random = SecureRandom()

    fun randomBytes(n: Int) = ByteArray(n).also { random.nextBytes(it) }

    fun sha256(vararg parts: ByteArray): ByteArray {
        val md = MessageDigest.getInstance("SHA-256")
        parts.forEach { md.update(it) }
        return md.digest()
    }

    fun hex(b: ByteArray): String = buildString(b.size * 2) {
        for (x in b) { append("0123456789abcdef"[(x.toInt() shr 4) and 0xF]); append("0123456789abcdef"[x.toInt() and 0xF]) }
    }

    fun unhex(s: String): ByteArray = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    fun u32(v: Int): ByteArray = ByteBuffer.allocate(4).putInt(v).array()

    /** th = SHA-256("AirBridge/1" || u32 len || hello || u32 len || server_hello) */
    fun transcriptHash(hello: ByteArray, serverHello: ByteArray): ByteArray =
        sha256(TRANSCRIPT_LABEL, u32(hello.size), hello, u32(serverHello.size), serverHello)

    fun hmac(key: ByteArray, vararg parts: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        parts.forEach { mac.update(it) }
        return mac.doFinal()
    }

    /** RFC 5869 HKDF-SHA256. */
    fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val prk = hmac(if (salt.isEmpty()) ByteArray(32) else salt, ikm)
        val out = ByteArray(length)
        var t = ByteArray(0)
        var pos = 0
        var i = 1
        while (pos < length) {
            t = hmac(prk, t, info, byteArrayOf(i.toByte()))
            val n = minOf(t.size, length - pos)
            System.arraycopy(t, 0, out, pos, n)
            pos += n; i++
        }
        return out
    }

    class SessionKeys(val dialerToListener: ByteArray, val listenerToDialer: ByteArray)

    fun deriveKeys(sharedSecret: ByteArray, th: ByteArray): SessionKeys {
        val okm = hkdf(sharedSecret, th, SESSION_KEYS_INFO, 64)
        return SessionKeys(okm.copyOfRange(0, 32), okm.copyOfRange(32, 64))
    }

    /** 6-digit short authentication string. */
    fun sas(th: ByteArray): String {
        val v = ByteBuffer.wrap(th, 0, 4).int.toLong() and 0xFFFFFFFFL
        return "%06d".format(v % 1_000_000)
    }

    fun constantTimeEquals(a: ByteArray, b: ByteArray) = MessageDigest.isEqual(a, b)

    // --- EC P-256 ---

    val p256: ECParameterSpec by lazy {
        val ap = AlgorithmParameters.getInstance("EC")
        ap.init(ECGenParameterSpec("secp256r1"))
        ap.getParameterSpec(ECParameterSpec::class.java)
    }

    fun generateEphemeral(): KeyPair =
        KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1"), random) }.generateKeyPair()

    /** DER SubjectPublicKeyInfo — identical bytes to CryptoKit's `derRepresentation`. */
    fun spki(key: PublicKey): ByteArray = key.encoded

    fun publicKeyFromSpki(spki: ByteArray): PublicKey = try {
        KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(spki))
    } catch (e: Exception) {
        throw AbException(ErrorCode.MALFORMED, "Invalid public key", e)
    }

    fun privateKeyFromScalar(raw: ByteArray): PrivateKey =
        KeyFactory.getInstance("EC").generatePrivate(ECPrivateKeySpec(BigInteger(1, raw), p256))

    fun ecdh(priv: PrivateKey, peerSpki: ByteArray): ByteArray {
        val ka = KeyAgreement.getInstance("ECDH")
        ka.init(priv)
        ka.doPhase(publicKeyFromSpki(peerSpki), true)
        return ka.generateSecret() // 32-byte X coordinate
    }

    fun verify(spki: ByteArray, signatureDer: ByteArray, message: ByteArray): Boolean = try {
        val s = Signature.getInstance("SHA256withECDSA")
        s.initVerify(publicKeyFromSpki(spki))
        s.update(message)
        s.verify(signatureDer)
    } catch (e: Exception) {
        false
    }

    fun fingerprint(spki: ByteArray) = sha256(spki)
    fun deviceId(spki: ByteArray) = hex(fingerprint(spki).copyOf(16))
    fun displayFingerprint(spki: ByteArray) = hex(fingerprint(spki).copyOf(8)).chunked(4).joinToString(" ")
}

/**
 * AES-256-GCM with an implicit per-direction counter nonce (SPEC §4.2).
 * Not thread-safe: each direction is owned by one thread.
 */
class RecordCipher(key: ByteArray) {
    private val keySpec = SecretKeySpec(key, "AES")
    private val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    private val nonce = ByteArray(12)
    var counter = 0L
        private set

    private fun nextNonce(): GCMParameterSpec {
        ByteBuffer.wrap(nonce, 4, 8).putLong(counter)
        return GCMParameterSpec(128, nonce)
    }

    /** Encrypts [len] bytes of [input]; returns ciphertext || tag. */
    fun seal(input: ByteArray, off: Int = 0, len: Int = input.size): ByteArray {
        check(counter != -1L) { "nonce space exhausted" }
        cipher.init(Cipher.ENCRYPT_MODE, keySpec, nextNonce())
        val out = cipher.doFinal(input, off, len)
        counter++
        return out
    }

    fun open(record: ByteArray): ByteArray {
        if (record.size < 16) throw AbException(ErrorCode.MALFORMED, "Record too short")
        cipher.init(Cipher.DECRYPT_MODE, keySpec, nextNonce())
        val pt = try {
            cipher.doFinal(record)
        } catch (e: Exception) {
            throw AbException(ErrorCode.MALFORMED, "Record authentication failed")
        }
        counter++
        return pt
    }
}
