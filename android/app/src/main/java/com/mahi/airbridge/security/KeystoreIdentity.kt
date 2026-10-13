package com.mahi.airbridge.security

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import com.mahi.airbridge.core.crypto.DeviceIdentity
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.spec.ECGenParameterSpec

/**
 * Device identity whose private key is generated inside Android Keystore and never
 * leaves it (hardware-backed where the device supports it). Only signing is allowed.
 */
class KeystoreIdentity private constructor(private val privateKey: PrivateKey, override val spki: ByteArray) : DeviceIdentity {

    override fun sign(message: ByteArray): ByteArray =
        Signature.getInstance("SHA256withECDSA").run { initSign(privateKey); update(message); sign() }

    companion object {
        private const val ALIAS = "airbridge_identity_p256"

        fun loadOrCreate(): KeystoreIdentity {
            val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            val existing = ks.getEntry(ALIAS, null) as? KeyStore.PrivateKeyEntry
            if (existing != null) return KeystoreIdentity(existing.privateKey, existing.certificate.publicKey.encoded)
            val gen = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
            gen.initialize(
                KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN)
                    .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                    .setDigests(KeyProperties.DIGEST_SHA256)
                    .build()
            )
            val kp = gen.generateKeyPair()
            return KeystoreIdentity(kp.private, kp.public.encoded)
        }

        /** "Forget this device's identity": all peers must pair again. */
        fun reset() {
            KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(ALIAS)
        }
    }
}
