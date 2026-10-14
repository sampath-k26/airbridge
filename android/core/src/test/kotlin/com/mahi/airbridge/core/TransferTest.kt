package com.mahi.airbridge.core

import com.mahi.airbridge.core.crypto.AbCrypto
import com.mahi.airbridge.core.crypto.SoftwareIdentity
import com.mahi.airbridge.core.crypto.TrustStore
import com.mahi.airbridge.core.protocol.AbException
import com.mahi.airbridge.core.protocol.ErrorCode
import com.mahi.airbridge.core.protocol.Json
import com.mahi.airbridge.core.protocol.PairingCode
import com.mahi.airbridge.core.storage.FileSystemStorage
import com.mahi.airbridge.core.storage.IncomingFileWriter
import com.mahi.airbridge.core.storage.ReceiveStorage
import com.mahi.airbridge.core.transfer.FileSource
import com.mahi.airbridge.core.transfer.OfferFile
import com.mahi.airbridge.core.transfer.SendSource
import com.mahi.airbridge.core.transfer.Session
import com.mahi.airbridge.core.transfer.SessionEvent
import com.mahi.airbridge.core.transfer.TransferResult
import com.mahi.airbridge.core.transport.DialPairing
import com.mahi.airbridge.core.transport.Handshake
import com.mahi.airbridge.core.transport.HandshakeResult
import com.mahi.airbridge.core.transport.LocalDevice
import com.mahi.airbridge.core.transport.Record
import com.mahi.airbridge.core.transport.SocketStream
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.nio.file.Files
import java.security.MessageDigest
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** End-to-end tests over loopback TCP using the JVM build of the Android core. */
class TransferTest {
    private val tmp: File = Files.createTempDirectory("ab-test").toFile()
    private val pool = Executors.newCachedThreadPool()

    @AfterTest fun cleanup() { tmp.deleteRecursively(); pool.shutdownNow() }

    class Peer(val local: LocalDevice, val trust: TrustStore = TrustStore(null))

    private fun peer(name: String) = Peer(LocalDevice(SoftwareIdentity.generate(), name))

    private fun connect(l: Peer, d: Peer, code: PairingCode?, pairing: DialPairing?, approve: Boolean = true): Pair<HandshakeResult, HandshakeResult> {
        val server = ServerSocket().apply { bind(InetSocketAddress("127.0.0.1", 0)) }
        val acc: Future<HandshakeResult> = pool.submit<HandshakeResult> {
            val s = SocketStream(server.accept())
            Handshake.accept(s, l.local, l.trust, { code }, { approve })
        }
        try {
            val dialed = Handshake.dial(SocketStream.connect("127.0.0.1", server.localPort), d.local, d.trust, pairing, "127.0.0.1", server.localPort)
            return acc.get() to dialed
        } catch (e: Exception) {
            runCatching { acc.get() }
            throw e
        } finally {
            server.close()
        }
    }

    private fun pair(a: Peer, b: Peer): Pair<HandshakeResult, HandshakeResult> {
        val code = PairingCode()
        return connect(a, b, code, DialPairing(code.code, a.local.identity.fingerprint))
    }

    private fun session(hs: HandshakeResult, dir: File, storage: ReceiveStorage = FileSystemStorage(dir), chunk: Int = 256 * 1024,
                        events: MutableList<SessionEvent>? = null): Session =
        Session(hs, storage, chunk, decide = { true }) { e -> events?.add(e) }.also { it.start() }

    private fun file(name: String, bytes: Int): File = File(tmp, "src/$name").apply {
        parentFile.mkdirs(); writeBytes(AbCrypto.randomBytes(bytes))
    }

    private fun sha(f: File) = AbCrypto.hex(MessageDigest.getInstance("SHA-256").digest(f.readBytes()))

    private fun awaitResult(events: List<SessionEvent>, timeoutMs: Long = 20_000): TransferResult? {
        val end = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < end) {
            events.filterIsInstance<SessionEvent.Finished>().firstOrNull()?.let { return it.result }
            Thread.sleep(20)
        }
        return null
    }

    private fun codeOf(block: () -> Unit): ErrorCode = assertFailsWith<AbException> { block() }.code

    // ---------------------------------------------------------------- pairing

    @Test fun qrPairingThenReconnectWithoutCode() {
        val mac = peer("mac"); val phone = peer("phone")
        val (l, d) = pair(mac, phone)
        assertTrue(l.newlyPaired && d.newlyPaired)
        assertEquals(l.verificationCode, d.verificationCode)
        l.channel.close(); d.channel.close()
        val (l2, d2) = connect(mac, phone, null, null)
        assertFalse(l2.newlyPaired || d2.newlyPaired)
        l2.channel.close(); d2.channel.close()
    }

    @Test fun manualCodeAuthenticatesListenerAndIsSingleUse() {
        val mac = peer("mac"); val phone = peer("phone")
        val code = PairingCode()
        val (l, d) = connect(mac, phone, code, DialPairing(code.code, null))
        assertEquals(l.verificationCode, d.verificationCode)
        assertFalse(code.isUsable())
        l.channel.close(); d.channel.close()
    }

    @Test fun unknownDeviceWithoutCodeRejected() {
        val mac = peer("mac")
        assertEquals(ErrorCode.AUTH_FAILED, codeOf { connect(mac, peer("stranger"), PairingCode(), null) })
        assertTrue(mac.trust.all.isEmpty())
    }

    @Test fun wrongCodeRejectedBothWays() {
        val mac = peer("mac")
        val code = PairingCode()
        assertEquals(ErrorCode.AUTH_FAILED, codeOf { connect(mac, peer("p"), code, DialPairing("ZZZZZZZZZZ", mac.local.identity.fingerprint)) })
        assertTrue(code.isUsable())
        // Manual mode: the listener cannot prove a code the dialer doesn't share.
        assertEquals(ErrorCode.AUTH_FAILED, codeOf { connect(mac, peer("p2"), code, DialPairing("ZZZZZZZZZZ", null)) })
    }

    @Test fun fingerprintMismatchExpiredAndDeclined() {
        val mac = peer("mac")
        val code = PairingCode()
        assertEquals(ErrorCode.AUTH_FAILED, codeOf { connect(mac, peer("p"), code, DialPairing(code.code, ByteArray(32) { 7 })) })
        val old = PairingCode(now = System.currentTimeMillis() - 400_000)
        assertEquals(ErrorCode.PAIRING_EXPIRED, codeOf { connect(mac, peer("p"), old, DialPairing(old.code, mac.local.identity.fingerprint)) })
        val c3 = PairingCode()
        assertEquals(ErrorCode.PAIRING_REJECTED, codeOf { connect(mac, peer("p"), c3, DialPairing(c3.code, mac.local.identity.fingerprint), approve = false) })
        assertTrue(mac.trust.all.isEmpty())
    }

    // -------------------------------------------------------------- transfers

    @Test fun transferVariety() {
        val (l, d) = pair(peer("mac"), peer("phone"))
        val recv = File(tmp, "recv")
        val ev = CopyOnWriteArrayList<SessionEvent>()
        val rs = session(l, recv, events = ev); val ss = session(d, tmp)
        val files = listOf(file("1KB.bin", 1024), file("1MB.bin", 1 shl 20), file("empty.txt", 0), file("日本語 résumé 🎉.pdf", 3333))
        file("Album/a.jpg", 5000); file("Album/Sub/b.mov", 70_000)
        val r = runBlocking { ss.send(FileSource.collect(files + File(tmp, "src/Album"))) }
        assertNull(r.error, r.error.toString())
        assertEquals(6, r.files.size)
        assertNull(awaitResult(ev)!!.error)
        for (f in files) assertEquals(sha(f), sha(File(recv, f.name)))
        assertEquals(sha(File(tmp, "src/Album/Sub/b.mov")), sha(File(recv, "Album/Sub/b.mov")))
        assertFalse(File(recv, ".airbridge-partial").exists())
        rs.close(); ss.close()
    }

    @Test fun nameConflictsNeverOverwrite() {
        val (l, d) = pair(peer("mac"), peer("phone"))
        val recv = File(tmp, "recv").apply { File(this, "Album").mkdirs(); File(this, "photo.jpg").writeText("keep me") }
        val ev = CopyOnWriteArrayList<SessionEvent>()
        val rs = session(l, recv, events = ev); val ss = session(d, tmp)
        val f = file("photo.jpg", 100); file("Album/x.jpg", 10)
        assertNull(runBlocking { ss.send(FileSource.collect(listOf(f, File(tmp, "src/Album")))) }.error)
        awaitResult(ev)
        assertEquals("keep me", File(recv, "photo.jpg").readText())
        assertEquals(sha(f), sha(File(recv, "photo (1).jpg")))
        assertTrue(File(recv, "Album (1)/x.jpg").exists())
        rs.close(); ss.close()
    }

    @Test fun unsafePathsRejected() {
        val (l, d) = pair(peer("mac"), peer("phone"))
        val rs = session(l, File(tmp, "recv")); val ss = session(d, tmp)
        val f = file("x.bin", 10)
        for (bad in listOf("../escape.bin", "/etc/x", "a/../../b", "C:/x", "a\\b")) {
            val src = object : SendSource by FileSource(f) { override val path = bad }
            assertEquals(ErrorCode.INVALID_PATH, runBlocking { ss.send(listOf(src)) }.error?.code, bad)
        }
        assertFalse(File(tmp, "escape.bin").exists())
        rs.close(); ss.close()
    }

    @Test fun bidirectionalSimultaneous() {
        val (l, d) = pair(peer("mac"), peer("phone"))
        val a = session(l, File(tmp, "recvMac")); val b = session(d, File(tmp, "recvPhone"))
        val f1 = file("toPhone.bin", 20 shl 20); val f2 = file("toMac.bin", 20 shl 20)
        val (x, y) = runBlocking {
            val r1 = async { a.send(listOf(FileSource(f1))) }
            val r2 = async { b.send(listOf(FileSource(f2))) }
            r1.await() to r2.await()
        }
        assertNull(x.error); assertNull(y.error)
        assertEquals(sha(f1), sha(File(tmp, "recvPhone/toPhone.bin")))
        assertEquals(sha(f2), sha(File(tmp, "recvMac/toMac.bin")))
        a.close(); b.close()
    }

    @Test fun cancelRemovesPartial() {
        val (l, d) = pair(peer("mac"), peer("phone"))
        val recv = File(tmp, "recv")
        val ev = CopyOnWriteArrayList<SessionEvent>()
        val rs = session(l, recv, SlowStorage(FileSystemStorage(recv)), events = ev)
        val ss = session(d, tmp, chunk = 64 * 1024)
        // Larger than everything that can be in flight (8 MB queue + socket buffers), so the
        // cancel reaches the receiver before the file can complete.
        val f = file("big.bin", 80 shl 20)
        val job = pool.submit<TransferResult> { runBlocking { ss.send(listOf(FileSource(f)), "cancel-me") } }
        Thread.sleep(300)
        ss.cancel("cancel-me")
        assertEquals(ErrorCode.CANCELLED, job.get().error?.code)
        assertEquals(ErrorCode.CANCELLED, awaitResult(ev)?.error?.code)
        assertFalse(File(recv, "big.bin").exists())
        assertFalse(File(recv, ".airbridge-partial/cancel-me").exists())
        rs.close(); ss.close()
    }

    @Test fun resumeAfterConnectionLoss() {
        val mac = peer("mac"); val phone = peer("phone")
        val recv = File(tmp, "recv")
        val f = file("video.mp4", 24 shl 20)
        val (l, d) = pair(mac, phone)
        val ev = CopyOnWriteArrayList<SessionEvent>()
        val rs = session(l, recv, SlowStorage(FileSystemStorage(recv)), events = ev)
        val ss = session(d, tmp)
        val job = pool.submit<TransferResult> { runBlocking { ss.send(listOf(FileSource(f)), "resume-1") } }
        while (ev.none { it is SessionEvent.Progress && it.progress.bytesDone > (8 shl 20) }) Thread.sleep(10)
        rs.close() // drop the connection mid-file
        assertEquals(ErrorCode.CONNECTION_LOST, job.get().error?.code)
        val kept = File(recv, ".airbridge-partial/resume-1/0.part").length()
        assertTrue(kept > 0)
        ss.close()

        val (l2, d2) = connect(mac, phone, null, null) // full re-authentication
        val ev2 = CopyOnWriteArrayList<SessionEvent>()
        val rs2 = session(l2, recv, events = ev2); val ss2 = session(d2, tmp)
        val r = runBlocking { ss2.send(listOf(FileSource(f)), "resume-1") }
        assertNull(r.error)
        assertTrue(r.bytes < (24 shl 20), "only the remainder is sent (sent ${r.bytes})")
        awaitResult(ev2)
        assertEquals(sha(f), sha(File(recv, "video.mp4")))
        rs2.close(); ss2.close()
    }

    /** Regression: a write racing with close() must not delete the partial (found by CI). */
    @Test fun writeFailingDuringCloseKeepsPartial() {
        val (l, d) = pair(peer("mac"), peer("phone"))
        val recv = File(tmp, "recv")
        val ev = CopyOnWriteArrayList<SessionEvent>()
        val storage = CloseRaceStorage(FileSystemStorage(recv))
        val rs = session(l, recv, storage, events = ev)
        val ss = session(d, tmp)
        val job = pool.submit<TransferResult> { runBlocking { ss.send(listOf(FileSource(file("big.bin", 16 shl 20))), "race-1") } }
        assertTrue(storage.armed.await(10, TimeUnit.SECONDS))
        rs.close()
        assertEquals(ErrorCode.CONNECTION_LOST, job.get(10, TimeUnit.SECONDS).error?.code)
        assertTrue(File(recv, ".airbridge-partial/race-1/0.part").length() > 0, "partial kept for resume")
        ss.close()
    }

    @Test fun corruptionOnDiskDetected() {
        val (l, d) = pair(peer("mac"), peer("phone"))
        val recv = File(tmp, "recv")
        val rs = session(l, recv, CorruptingStorage(FileSystemStorage(recv))); val ss = session(d, tmp)
        assertEquals(ErrorCode.HASH_MISMATCH, runBlocking { ss.send(listOf(FileSource(file("doc.pdf", 100_000)))) }.error?.code)
        assertFalse(File(recv, "doc.pdf").exists())
        rs.close(); ss.close()
    }

    @Test fun diskFullAndCapacity() {
        val (l, d) = pair(peer("mac"), peer("phone"))
        val recv = File(tmp, "recv")
        val rs = session(l, recv, FullDiskStorage(FileSystemStorage(recv))); val ss = session(d, tmp)
        assertEquals(ErrorCode.INSUFFICIENT_STORAGE, runBlocking { ss.send(listOf(FileSource(file("a.bin", 3 shl 20)))) }.error?.code)
        rs.close(); ss.close()
        val (l2, d2) = pair(peer("mac2"), peer("phone2"))
        val rs2 = session(l2, recv, object : ReceiveStorage by FileSystemStorage(recv) { override fun availableBytes() = 10L })
        val ss2 = session(d2, tmp)
        assertEquals(ErrorCode.INSUFFICIENT_STORAGE, runBlocking { ss2.send(listOf(FileSource(file("b.bin", 1000)))) }.error?.code)
        rs2.close(); ss2.close()
    }

    @Test fun invalidResumeOffsetFromPeerRejected() {
        val (l, d) = pair(peer("mac"), peer("phone"))
        val ss = session(d, tmp)
        pool.submit {
            while (true) {
                val rec = l.channel.receive() as? Record.Control ?: continue
                if (rec.type == "offer") {
                    l.channel.sendControl(Json.obj("type" to "accept", "transferId" to Json.str(rec.json, "transferId"),
                        "files" to listOf(Json.obj("id" to 0, "offset" to 999_999))))
                }
            }
        }
        assertEquals(ErrorCode.RESUME_INVALID, runBlocking { ss.send(listOf(FileSource(file("a.bin", 1000)))) }.error?.code)
        l.channel.close(); ss.close()
    }

    @Test fun malformedRecordClosesSession() {
        val (l, d) = pair(peer("mac"), peer("phone"))
        val rs = session(l, tmp)
        d.channel.stream.write(AbCrypto.u32(64) + AbCrypto.randomBytes(64))
        assertEquals(ErrorCode.MALFORMED, runBlocking { rs.closedSignal.await() }?.code)
        d.channel.close()
    }

    @Test fun unsupportedVersionAndOversizedFrame() {
        val mac = peer("mac")
        val server = ServerSocket().apply { bind(InetSocketAddress("127.0.0.1", 0)) }
        val acc = pool.submit<ErrorCode> {
            codeOf { Handshake.accept(SocketStream(server.accept()), mac.local, mac.trust, { null }, { true }) }
        }
        val s = SocketStream.connect("127.0.0.1", server.localPort)
        com.mahi.airbridge.core.transport.HandshakeFrame.write(s,
            """{"type":"hello","proto":2,"minProto":2,"eph":"AA==","nonce":"AA=="}""".toByteArray())
        val reply = Json.parseObject(com.mahi.airbridge.core.transport.HandshakeFrame.read(s))
        assertEquals("unsupported_version", Json.str(reply, "code"))
        assertEquals(ErrorCode.UNSUPPORTED_VERSION, acc.get())
        val acc2 = pool.submit<ErrorCode> {
            codeOf { Handshake.accept(SocketStream(server.accept()), mac.local, mac.trust, { null }, { true }) }
        }
        SocketStream.connect("127.0.0.1", server.localPort).write(AbCrypto.u32(10_000_000))
        assertEquals(ErrorCode.MALFORMED, acc2.get())
        server.close()
    }
}

// ------------------------------------------------------------------ test storages

private open class WrappedStorage(val inner: ReceiveStorage) : ReceiveStorage by inner {
    open fun wrap(w: IncomingFileWriter): IncomingFileWriter = w
    override fun openWriter(transferId: String, peerId: String, file: OfferFile, offset: Long) =
        wrap(inner.openWriter(transferId, peerId, file, offset))
}

/**
 * Holds one write until the session closes the file, then lets it fail while shutdown()
 * is still running: the exact interleaving that deleted partials.
 */
private class CloseRaceStorage(inner: ReceiveStorage) : WrappedStorage(inner) {
    val armed = CountDownLatch(1)
    private val fileClosed = CountDownLatch(1)
    private val writeFailed = CountDownLatch(1)
    override fun wrap(w: IncomingFileWriter) = object : IncomingFileWriter by w {
        var bytes = 0L
        override fun write(buf: ByteArray, off: Int, len: Int) {
            bytes += len
            if (bytes < (4 shl 20) || armed.count == 0L) return w.write(buf, off, len)
            armed.countDown()
            fileClosed.await(10, TimeUnit.SECONDS)
            try { w.write(buf, off, len) } finally { writeFailed.countDown() }
        }
        override fun close(keep: Boolean) {
            w.close(keep)
            fileClosed.countDown()
            // Keep shutdown() from finishing until the failed write has been handled.
            if (writeFailed.await(10, TimeUnit.SECONDS)) Thread.sleep(300)
        }
    }
}

private class SlowStorage(inner: ReceiveStorage) : WrappedStorage(inner) {
    override fun wrap(w: IncomingFileWriter) = object : IncomingFileWriter by w {
        override fun write(buf: ByteArray, off: Int, len: Int) { Thread.sleep(3); w.write(buf, off, len) }
    }
}

private class CorruptingStorage(inner: ReceiveStorage) : WrappedStorage(inner) {
    override fun wrap(w: IncomingFileWriter) = object : IncomingFileWriter by w {
        var done = false
        override fun write(buf: ByteArray, off: Int, len: Int) {
            if (!done && len > 0) { val c = buf.copyOfRange(off, off + len); c[0] = (c[0].toInt() xor 1).toByte(); done = true; w.write(c, 0, len) }
            else w.write(buf, off, len)
        }
    }
}

private class FullDiskStorage(inner: ReceiveStorage) : WrappedStorage(inner) {
    override fun wrap(w: IncomingFileWriter) = object : IncomingFileWriter by w {
        var n = 0L
        override fun write(buf: ByteArray, off: Int, len: Int) {
            n += len
            if (n > (1 shl 20)) throw AbException(ErrorCode.INSUFFICIENT_STORAGE, "Disk full")
            w.write(buf, off, len)
        }
    }
}
