package com.mahi.airbridge.core.transport

import com.mahi.airbridge.core.crypto.AbCrypto
import com.mahi.airbridge.core.crypto.RecordCipher
import com.mahi.airbridge.core.protocol.AbException
import com.mahi.airbridge.core.protocol.AbProtocol
import com.mahi.airbridge.core.protocol.ErrorCode
import com.mahi.airbridge.core.protocol.Json
import kotlinx.serialization.json.JsonObject
import java.io.BufferedInputStream
import java.io.Closeable
import java.io.EOFException
import java.io.IOException
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.nio.ByteBuffer
import java.util.concurrent.LinkedBlockingDeque
import java.util.concurrent.atomic.AtomicBoolean

/** Blocking TCP stream. */
class SocketStream(val socket: Socket) : Closeable {
    private val input = BufferedInputStream(socket.getInputStream(), 256 * 1024)
    val output: OutputStream = socket.getOutputStream()
    private val closed = AtomicBoolean(false)

    init {
        socket.tcpNoDelay = true
        socket.keepAlive = true
        // Larger socket buffers keep a fast Wi-Fi link busy; the OS may clamp them.
        runCatching { socket.sendBufferSize = 4 * 1024 * 1024 }
        runCatching { socket.receiveBufferSize = 4 * 1024 * 1024 }
    }

    val remoteHost: String? get() = (socket.remoteSocketAddress as? InetSocketAddress)?.address?.hostAddress?.substringBefore('%')

    fun setReadTimeout(ms: Long) { runCatching { socket.soTimeout = ms.toInt() } }

    fun readFully(buf: ByteArray, off: Int = 0, len: Int = buf.size) {
        var pos = off
        val end = off + len
        try {
            while (pos < end) {
                val n = input.read(buf, pos, end - pos)
                if (n < 0) throw EOFException("Connection closed by peer")
                pos += n
            }
        } catch (e: SocketTimeoutException) {
            throw AbException(ErrorCode.TIMEOUT, "No data from peer", e)
        } catch (e: IOException) {
            throw AbException(ErrorCode.CONNECTION_LOST, e.message ?: "Connection lost", e)
        }
    }

    fun readU32(): Int { val b = ByteArray(4); readFully(b); return ByteBuffer.wrap(b).int }

    fun write(b: ByteArray) {
        try { output.write(b); output.flush() } catch (e: IOException) {
            throw AbException(ErrorCode.CONNECTION_LOST, e.message ?: "Connection lost", e)
        }
    }

    val isClosed get() = closed.get()

    override fun close() { if (closed.compareAndSet(false, true)) runCatching { socket.close() } }

    companion object {
        fun connect(host: String, port: Int, timeoutMs: Int = 10_000, socketFactory: () -> Socket = { Socket() }): SocketStream {
            val s = socketFactory()
            try {
                s.connect(InetSocketAddress(host, port), timeoutMs)
            } catch (e: SocketTimeoutException) {
                runCatching { s.close() }
                throw AbException(ErrorCode.TIMEOUT, "Connection to $host:$port timed out", e)
            } catch (e: IOException) {
                runCatching { s.close() }
                throw AbException(ErrorCode.CONNECTION_FAILED, "Cannot connect to $host:$port: ${e.message}", e)
            }
            return SocketStream(s)
        }
    }
}

sealed class Record {
    class Control(val type: String, val json: JsonObject) : Record()
    /** File bytes are `buf[off until off+len]` (no copy). */
    class Data(val stream: Int, val buf: ByteArray, val off: Int, val len: Int) : Record()
}

/**
 * Encrypted record layer (SPEC §4.2).
 *
 * All writes go through one writer thread so the wire order equals the nonce order.
 * Data sends block while more than [maxInFlight] bytes are queued (backpressure);
 * control sends never block, so the reader thread can always answer — otherwise two
 * peers streaming at each other could deadlock with both readers stuck writing.
 */
class SecureChannel(
    val stream: SocketStream,
    sendKey: ByteArray,
    recvKey: ByteArray,
    private val maxInFlight: Long = 8L * 1024 * 1024,
) : Closeable {
    private val sendCipher = RecordCipher(sendKey)
    private val recvCipher = RecordCipher(recvKey)
    private val queue = LinkedBlockingDeque<ByteArray>()
    private val lock = Object()
    private var inFlight = 0L
    @Volatile private var sendError: AbException? = null
    @Volatile var lastSendMs = System.currentTimeMillis(); private set
    private val stop = ByteArray(0)

    private val writer = Thread({ writeLoop() }, "airbridge-writer").apply { isDaemon = true; start() }

    private fun writeLoop() {
        try {
            while (true) {
                val pt = queue.take()
                if (pt === stop) return
                val frame = ByteArray(4 + pt.size + 16)
                ByteBuffer.wrap(frame).putInt(pt.size + 16)
                val ct = sendCipher.seal(pt)
                System.arraycopy(ct, 0, frame, 4, ct.size)
                stream.output.write(frame)
                // Flush only when the queue is empty: batching keeps syscalls low at high rates.
                if (queue.isEmpty()) stream.output.flush()
                lastSendMs = System.currentTimeMillis()
                synchronized(lock) { inFlight -= pt.size; lock.notifyAll() }
            }
        } catch (e: Exception) {
            sendError = e as? AbException ?: AbException(ErrorCode.CONNECTION_LOST, e.message ?: "write failed", e)
            synchronized(lock) { lock.notifyAll() }
            stream.close()
        }
    }

    private fun enqueue(pt: ByteArray, urgent: Boolean) {
        synchronized(lock) {
            while (!urgent && inFlight >= maxInFlight && sendError == null && !stream.isClosed) lock.wait(1000)
            sendError?.let { throw it }
            if (stream.isClosed) throw AbException(ErrorCode.CONNECTION_LOST, "Channel closed")
            inFlight += pt.size
        }
        queue.put(pt)
    }

    fun sendControl(msg: JsonObject, urgent: Boolean = false) {
        val json = Json.encode(msg)
        val pt = ByteArray(1 + json.size)
        pt[0] = AbProtocol.RECORD_CONTROL
        System.arraycopy(json, 0, pt, 1, json.size)
        enqueue(pt, urgent)
    }

    fun sendData(streamId: Int, buf: ByteArray, off: Int, len: Int) {
        require(len in 1..AbProtocol.MAX_DATA_PAYLOAD)
        val pt = ByteArray(5 + len)
        pt[0] = AbProtocol.RECORD_DATA
        ByteBuffer.wrap(pt, 1, 4).putInt(streamId)
        System.arraycopy(buf, off, pt, 5, len)
        enqueue(pt, false)
    }

    /** Blocks until all queued records were written to the socket. */
    fun flush() {
        synchronized(lock) {
            while (inFlight > 0 && sendError == null && !stream.isClosed) lock.wait(1000)
            sendError?.let { throw it }
        }
    }

    /** Reads and authenticates the next record. Single reader thread only. */
    fun receive(): Record {
        val len = stream.readU32()
        if (len < 17 || len > AbProtocol.MAX_RECORD_CIPHERTEXT) throw AbException(ErrorCode.MALFORMED, "Bad record length $len")
        val body = ByteArray(len)
        stream.readFully(body)
        val pt = recvCipher.open(body)
        if (pt.isEmpty()) throw AbException(ErrorCode.MALFORMED, "Empty record")
        return when (pt[0]) {
            AbProtocol.RECORD_CONTROL -> {
                if (pt.size - 1 > AbProtocol.MAX_CONTROL_JSON) throw AbException(ErrorCode.MALFORMED, "Control too large")
                val obj = Json.parseObject(String(pt, 1, pt.size - 1, Charsets.UTF_8))
                Record.Control(Json.type(obj), obj)
            }
            AbProtocol.RECORD_DATA -> {
                if (pt.size <= 5) throw AbException(ErrorCode.MALFORMED, "Empty data record")
                Record.Data(ByteBuffer.wrap(pt, 1, 4).int, pt, 5, pt.size - 5)
            }
            else -> throw AbException(ErrorCode.MALFORMED, "Unknown record type ${pt[0]}")
        }
    }

    override fun close() {
        queue.offerFirst(stop)
        stream.close()
        synchronized(lock) { lock.notifyAll() }
    }
}

/** Plaintext handshake frames (SPEC §4.1). */
object HandshakeFrame {
    fun write(stream: SocketStream, json: ByteArray) = stream.write(AbCrypto.u32(json.size) + json)

    fun read(stream: SocketStream): ByteArray {
        val len = stream.readU32()
        if (len < 1 || len > AbProtocol.MAX_HANDSHAKE_FRAME) throw AbException(ErrorCode.MALFORMED, "Bad handshake frame length")
        return ByteArray(len).also { stream.readFully(it) }
    }
}
