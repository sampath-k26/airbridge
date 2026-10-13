package com.mahi.airbridge

import android.provider.MediaStore
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.mahi.airbridge.core.crypto.AbCrypto
import com.mahi.airbridge.core.crypto.RecordCipher
import com.mahi.airbridge.core.crypto.SoftwareIdentity
import com.mahi.airbridge.core.crypto.TrustStore
import com.mahi.airbridge.core.protocol.PairingCode
import com.mahi.airbridge.core.transfer.OfferFile
import com.mahi.airbridge.core.transfer.Session
import com.mahi.airbridge.core.transfer.SessionEvent
import com.mahi.airbridge.core.transport.DialPairing
import com.mahi.airbridge.core.transport.Handshake
import com.mahi.airbridge.core.transport.LocalDevice
import com.mahi.airbridge.core.transport.SocketStream
import com.mahi.airbridge.security.KeystoreIdentity
import com.mahi.airbridge.storage.LocalFileSource
import com.mahi.airbridge.storage.MediaStoreStorage
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.security.MessageDigest
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors

/** Runs on the real phone: Android Keystore, MediaStore and Conscrypt crypto. */
@RunWith(AndroidJUnit4::class)
class DeviceTest {
    private val ctx = InstrumentationRegistry.getInstrumentation().targetContext

    @Test fun keystoreIdentitySignsVerifiably() {
        val id = KeystoreIdentity.loadOrCreate()
        val msg = AbCrypto.randomBytes(100)
        assertTrue(AbCrypto.verify(id.spki, id.sign(msg), msg))
        // Stable across loads (same key alias).
        assertTrue(KeystoreIdentity.loadOrCreate().spki.contentEquals(id.spki))
    }

    @Test fun mediaStoreWriteResumeVerifyFinalize() {
        val storage = MediaStoreStorage(ctx, "AirBridgeTest")
        val data = AbCrypto.randomBytes(3 * 1024 * 1024 + 17)
        val file = OfferFile(0, "Sub dir/résumé test.bin", data.size.toLong(), 1234, null)
        val tid = "test-" + System.nanoTime()
        val w1 = storage.openWriter(tid, "peer", file, 0)
        w1.write(data, 0, 1_000_000)
        w1.close(keep = true) // simulated connection loss
        val off = storage.resumableOffset(tid, "peer", file)
        assertEquals(1_000_000L, off)
        assertEquals(0L, storage.resumableOffset(tid, "other-peer", file)) // never resume another peer's file
        val w2 = storage.openWriter(tid, "peer", file, off)
        w2.write(data, off.toInt(), data.size - off.toInt())
        val md = MessageDigest.getInstance("SHA-256")
        w2.readPrefix { b, o, l -> md.update(b, o, l) }
        assertTrue(md.digest().contentEquals(MessageDigest.getInstance("SHA-256").digest(data)))
        val saved = w2.finish()
        assertTrue(saved, saved.startsWith("Download/AirBridgeTest/Sub dir/"))
        storage.finish(tid)
        // Clean up the test file.
        val n = ctx.contentResolver.delete(MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?", arrayOf("Download/AirBridgeTest/%"))
        assertTrue(n >= 1)
    }

    @Test fun cryptoThroughputOnDevice() {
        // AES-256-GCM (Conscrypt/BoringSSL) and SHA-256 per record size used by AirBridge.
        val c = RecordCipher(AbCrypto.randomBytes(32))
        val total = 256 * 1024 * 1024
        for (size in listOf(64 * 1024, 256 * 1024, 1024 * 1024, 4 * 1024 * 1024)) {
            val buf = AbCrypto.randomBytes(size)
            repeat(8) { c.seal(buf) } // warm-up
            val n = total / size
            val t0 = System.nanoTime()
            repeat(n) { c.seal(buf) }
            val aes = total / ((System.nanoTime() - t0) / 1e9) / 1e6
            val md = MessageDigest.getInstance("SHA-256")
            val t1 = System.nanoTime()
            repeat(n) { md.update(buf) }
            md.digest()
            val sha = total / ((System.nanoTime() - t1) / 1e9) / 1e6
            Log.i("AirBridgeBench", "{\"chunk\":$size,\"aesGcmMBps\":%.0f,\"sha256MBps\":%.0f}".format(aes, sha))
            assertTrue("AES-GCM too slow: $aes MB/s", aes > 50)
        }
    }

    @Test fun loopbackSessionIntoMediaStore() {
        val pool = Executors.newCachedThreadPool()
        val a = LocalDevice(SoftwareIdentity.generate(), "a"); val b = LocalDevice(SoftwareIdentity.generate(), "b")
        val ta = TrustStore(null); val tb = TrustStore(null)
        val code = PairingCode()
        val server = ServerSocket().apply { bind(InetSocketAddress("127.0.0.1", 0)) }
        val acc = pool.submit<com.mahi.airbridge.core.transport.HandshakeResult> {
            Handshake.accept(SocketStream(server.accept()), a, ta, { code }, { true })
        }
        val hd = Handshake.dial(SocketStream.connect("127.0.0.1", server.localPort), b, tb, DialPairing(code.code, a.identity.fingerprint), null, null)
        val ha = acc.get()
        val events = CopyOnWriteArrayList<SessionEvent>()
        val recv = Session(ha, MediaStoreStorage(ctx, "AirBridgeTest"), decide = { true }) { events.add(it) }.also { it.start() }
        val send = Session(hd, MediaStoreStorage(ctx, "AirBridgeTest"), decide = { true }) {}.also { it.start() }
        val src = File(ctx.cacheDir, "loop.bin").apply { writeBytes(AbCrypto.randomBytes(64 * 1024 * 1024)) }
        val r = runBlocking { send.send(listOf(LocalFileSource(src, "loop.bin"))) }
        assertNull(r.error?.toString(), r.error)
        Log.i("AirBridgeBench", "{\"loopbackMediaStoreMBps\":%.1f,\"ms\":%d}".format(r.megabytesPerSecond, r.durationMs))
        recv.close(); send.close(); src.delete(); server.close()
        ctx.contentResolver.delete(MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?", arrayOf("Download/AirBridgeTest/%"))
    }
}
