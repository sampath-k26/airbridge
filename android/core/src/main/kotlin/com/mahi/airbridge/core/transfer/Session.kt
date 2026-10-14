package com.mahi.airbridge.core.transfer

import com.mahi.airbridge.core.crypto.AbCrypto
import com.mahi.airbridge.core.crypto.PeerRecord
import com.mahi.airbridge.core.protocol.AbException
import com.mahi.airbridge.core.protocol.AbProtocol
import com.mahi.airbridge.core.protocol.ErrorCode
import com.mahi.airbridge.core.protocol.Json
import com.mahi.airbridge.core.protocol.PathSanitizer
import com.mahi.airbridge.core.storage.IncomingFileWriter
import com.mahi.airbridge.core.storage.ReceiveStorage
import com.mahi.airbridge.core.transport.HandshakeResult
import com.mahi.airbridge.core.transport.Record
import com.mahi.airbridge.core.transport.SecureChannel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CancellationException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * An authenticated, full-duplex session with one peer (SPEC §6). Either side may send
 * at any time. Incoming records are handled on a dedicated reader thread; outgoing
 * transfers run in the caller's coroutine on [Dispatchers.IO].
 */
class Session(
    handshake: HandshakeResult,
    private val storage: ReceiveStorage,
    chunkSize: Int = AbProtocol.DEFAULT_CHUNK,
    private val decide: suspend (IncomingOffer) -> Boolean,
    private val onEvent: (SessionEvent) -> Unit,
) {
    val peer: PeerRecord = handshake.peer
    val verificationCode = handshake.verificationCode
    private val channel: SecureChannel = handshake.channel
    val chunkSize = chunkSize.coerceIn(4096, AbProtocol.MAX_DATA_PAYLOAD)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val outgoing = ConcurrentHashMap<String, OutgoingState>()
    private val incoming = ConcurrentHashMap<String, IncomingState>()
    private val streams = ConcurrentHashMap<Int, IncomingFile>()
    private val nextStream = AtomicInteger(1)
    private val closed = AtomicBoolean(false)
    val closedSignal = CompletableDeferred<AbException?>()

    val isClosed get() = closed.get()

    fun start() {
        Thread({ readLoop() }, "airbridge-reader").apply { isDaemon = true; start() }
        scope.launch {
            while (isActive && !isClosed) {
                delay(5_000)
                if (System.currentTimeMillis() - channel.lastSendMs > AbProtocol.PING_INTERVAL_MS) {
                    runCatching { channel.sendControl(Json.obj("type" to "ping"), urgent = true) }
                }
            }
        }
    }

    /** Closes after queued messages were written (bounded wait). */
    fun close() {
        runCatching {
            val t = Thread { runCatching { channel.flush() } }
            t.start(); t.join(2_000)
        }
        shutdown(null)
    }

    // ---------------------------------------------------------------- sending

    /**
     * Sends [sources] and waits for the receiver's verdict. Never throws for transfer
     * failures (see [TransferResult.error]); cancel by cancelling the coroutine.
     */
    suspend fun send(sources: List<SendSource>, transferId: String = UUID.randomUUID().toString()): TransferResult =
        withContext(Dispatchers.IO) {
            val start = System.currentTimeMillis()
            val files = sources.mapIndexed { i, s -> OfferFile(i, s.path, s.size, s.mtime, s.mime) }
            val total = files.sumOf { it.size }
            val state = OutgoingState(transferId, files)
            if (isClosed) return@withContext failure(transferId, start, AbException(ErrorCode.CONNECTION_LOST, "Not connected"))
            outgoing[transferId] = state
            try {
                if (sources.isEmpty() || sources.size > AbProtocol.MAX_FILES_PER_OFFER) {
                    throw AbException(ErrorCode.INVALID_PATH, "1–${AbProtocol.MAX_FILES_PER_OFFER} files per transfer")
                }
                channel.sendControl(Json.obj("type" to "offer", "transferId" to transferId, "totalBytes" to total,
                    "files" to files.map { Json.obj("id" to it.id, "path" to it.path, "size" to it.size, "mtime" to it.mtime, "mime" to it.mime) }))
                val accept = state.response.await().getOrThrow()
                val offsets = HashMap<Int, Long>()
                for (e in Json.arr(accept, "files")) {
                    val o = e as? JsonObject ?: continue
                    val id = Json.int(o, "id")
                    val off = Json.long(o, "offset")
                    if (id !in files.indices) continue
                    if (off < 0 || off > files[id].size) throw AbException(ErrorCode.RESUME_INVALID, "Bad resume offset")
                    offsets[id] = off
                }
                state.expect(offsets.keys)
                val resumed = offsets.values.sum()
                onEvent(SessionEvent.Started(transferId, Direction.SEND, files, total))
                val progress = ProgressThrottle(transferId, Direction.SEND, total, files.size, resumed, onEvent)
                for ((idx, src) in sources.withIndex()) {
                    val off = offsets[idx] ?: continue
                    state.checkCancelled()
                    sendFile(src, idx, off, state, progress)
                }
                progress.emit(force = true, current = null)
                state.done.await().getOrThrow()
                state.result(total - resumed, start, null).also { onEvent(SessionEvent.Finished(it)) }
            } catch (t: Throwable) {
                val e = when (t) {
                    is AbException -> t
                    is CancellationException -> AbException(ErrorCode.CANCELLED, "Cancelled")
                    else -> AbException(ErrorCode.INTERNAL, t.toString(), t)
                }
                if (e.code in setOf(ErrorCode.CANCELLED, ErrorCode.READ_FAILED, ErrorCode.RESUME_INVALID, ErrorCode.INVALID_PATH) &&
                    !state.peerCancelled) {
                    runCatching { channel.sendControl(Json.obj("type" to "cancel", "transferId" to transferId, "reason" to e.code.wire), urgent = true) }
                }
                state.result(0, start, e).also { onEvent(SessionEvent.Finished(it)) }
            } finally {
                outgoing.remove(transferId)
            }
        }

    private suspend fun sendFile(src: SendSource, id: Int, offset: Long, state: OutgoingState, progress: ProgressThrottle) {
        val input: InputStream = try { src.open() } catch (e: Exception) {
            throw AbException(ErrorCode.READ_FAILED, "Cannot open ${src.path}", e)
        }
        input.use { inp ->
            val md = MessageDigest.getInstance("SHA-256")
            val buf = ByteArray(chunkSize)
            var pos = 0L
            fun readSome(max: Long): Int {
                val n = try { inp.read(buf, 0, minOf(buf.size.toLong(), max).toInt()) } catch (e: IOException) {
                    throw AbException(ErrorCode.READ_FAILED, e.message ?: "read failed", e)
                }
                if (n <= 0) throw AbException(ErrorCode.READ_FAILED, "${src.path} is shorter than announced")
                return n
            }
            // Resume: the receiver keeps the prefix; read it only for the full-file hash.
            while (pos < offset) { val n = readSome(offset - pos); md.update(buf, 0, n); pos += n }
            val stream = nextStream.getAndIncrement()
            channel.sendControl(Json.obj("type" to "file_begin", "transferId" to state.transferId, "fileId" to id,
                "stream" to stream, "offset" to offset))
            while (pos < src.size) {
                currentCoroutineContext().ensureActive()
                state.checkCancelled()
                val n = readSome(src.size - pos)
                md.update(buf, 0, n)
                channel.sendData(stream, buf, 0, n)
                pos += n
                progress.add(n.toLong(), src.path)
            }
            if (!src.unchanged()) throw AbException(ErrorCode.READ_FAILED, "${src.path} was modified during the transfer")
            channel.sendControl(Json.obj("type" to "file_end", "transferId" to state.transferId, "fileId" to id,
                "sha256" to AbCrypto.hex(md.digest())))
        }
    }

    /** Cancels an outgoing or incoming transfer. */
    fun cancel(transferId: String) {
        outgoing[transferId]?.cancel(AbException(ErrorCode.CANCELLED, "Cancelled"), byPeer = false)
        incoming.remove(transferId)?.let { inc ->
            dropStreams(inc, keep = false)
            storage.discard(transferId)
            runCatching { channel.sendControl(Json.obj("type" to "cancel", "transferId" to transferId, "reason" to "cancelled"), urgent = true) }
            onEvent(SessionEvent.Finished(inc.result(AbException(ErrorCode.CANCELLED, "Cancelled"))))
        }
    }

    // ---------------------------------------------------------------- reading

    private fun readLoop() {
        try {
            while (true) {
                when (val rec = channel.receive()) {
                    is Record.Data -> handleData(rec)
                    is Record.Control -> handleControl(rec.type, rec.json)
                }
            }
        } catch (e: Exception) {
            shutdown(e as? AbException ?: AbException(ErrorCode.CONNECTION_LOST, e.message ?: "lost", e))
        }
    }

    private fun handleControl(type: String, m: JsonObject) {
        when (type) {
            "ping" -> channel.sendControl(Json.obj("type" to "pong"), urgent = true)
            "pong" -> {}
            "offer" -> scope.launch { handleOffer(m) }
            "accept" -> outgoing[Json.str(m, "transferId")]?.response?.complete(Result.success(m))
            "reject" -> outgoing[Json.str(m, "transferId")]?.response?.complete(Result.failure(
                AbException(ErrorCode.fromWire(Json.optStr(m, "code"), ErrorCode.DECLINED), Json.optStr(m, "message") ?: "")))
            "file_begin" -> handleFileBegin(m)
            "file_end" -> handleFileEnd(m)
            "file_ok" -> outgoing[Json.str(m, "transferId")]?.let { s ->
                s.fileOk(Json.int(m, "fileId"))?.let { onEvent(SessionEvent.FileDone(s.transferId, Direction.SEND, it)) }
            }
            "file_failed" -> outgoing[Json.str(m, "transferId")]?.fileFailed(Json.int(m, "fileId"),
                AbException(ErrorCode.fromWire(Json.optStr(m, "code")), Json.optStr(m, "message") ?: ""))
            "transfer_done" -> outgoing[Json.str(m, "transferId")]?.done?.complete(Result.success(Unit))
            "cancel" -> peerCancelled(Json.str(m, "transferId"), Json.optStr(m, "reason"))
            "error" -> throw AbException(ErrorCode.fromWire(Json.optStr(m, "code")), Json.optStr(m, "message") ?: "")
            else -> {} // forward compatibility
        }
    }

    private fun peerCancelled(id: String, reason: String?) {
        val err = AbException(ErrorCode.fromWire(reason, ErrorCode.CANCELLED), "Cancelled by ${peer.name}")
        outgoing[id]?.cancel(err, byPeer = true)
        incoming.remove(id)?.let { inc ->
            dropStreams(inc, keep = false)
            storage.discard(id)
            onEvent(SessionEvent.Finished(inc.result(err)))
        }
    }

    private suspend fun handleOffer(m: JsonObject) {
        val transferId = runCatching { Json.str(m, "transferId") }.getOrNull() ?: return
        fun reject(code: ErrorCode, msg: String) = runCatching {
            channel.sendControl(Json.obj("type" to "reject", "transferId" to transferId, "code" to code.wire, "message" to msg), urgent = true)
        }
        val raw = runCatching { Json.arr(m, "files") }.getOrNull()
        if (raw == null || raw.isEmpty() || raw.size > AbProtocol.MAX_FILES_PER_OFFER || transferId.isEmpty() || transferId.length > 64) {
            reject(ErrorCode.MALFORMED, "Invalid offer"); return
        }
        if (incoming.containsKey(transferId)) { reject(ErrorCode.BUSY, "Transfer already in progress"); return }
        val files = ArrayList<OfferFile>()
        val ids = HashSet<Int>(); val paths = HashSet<String>()
        for (e in raw) {
            val f = runCatching {
                val o = e as JsonObject
                OfferFile(Json.int(o, "id"), Json.str(o, "path"), Json.long(o, "size"), Json.optLong(o, "mtime") ?: 0, Json.optStr(o, "mime"))
            }.getOrNull()
            val p = f?.let { PathSanitizer.sanitize(it.path) }
            if (f == null || p == null || f.id < 0 || f.size < 0 || !ids.add(f.id) || !paths.add(p.lowercase())) {
                reject(ErrorCode.INVALID_PATH, "Unsafe or duplicate file name"); return
            }
            files.add(f.copy(path = p))
        }
        val offsets = files.associate { it.id to storage.resumableOffset(transferId, peer.deviceId, it) }
        val total = files.sumOf { it.size }
        val resumed = offsets.values.sum()
        val free = storage.availableBytes()
        if (free != null && total - resumed > free) { reject(ErrorCode.INSUFFICIENT_STORAGE, "Needs ${total - resumed} bytes, $free free"); return }
        val offer = IncomingOffer(transferId, peer, files, total, resumed)
        onEvent(SessionEvent.Offer(offer))
        if (!decide(offer)) { reject(ErrorCode.DECLINED, "Declined by user"); return }
        if (isClosed) return
        val state = IncomingState(transferId, files, offsets, total,
            ProgressThrottle(transferId, Direction.RECEIVE, total, files.size, resumed, onEvent))
        incoming[transferId] = state
        onEvent(SessionEvent.Started(transferId, Direction.RECEIVE, files, total))
        runCatching {
            channel.sendControl(Json.obj("type" to "accept", "transferId" to transferId,
                "files" to files.map { Json.obj("id" to it.id, "offset" to (offsets[it.id] ?: 0L)) }), urgent = true)
        }
    }

    private fun handleFileBegin(m: JsonObject) {
        val state = incoming[Json.str(m, "transferId")] ?: return // cancelled: ignore
        val fileId = Json.int(m, "fileId")
        val stream = Json.int(m, "stream")
        val offset = Json.long(m, "offset")
        val file = state.files[fileId]
        if (file == null || state.status.containsKey(fileId) || streams.containsKey(stream)) {
            throw AbException(ErrorCode.MALFORMED, "Unexpected file_begin")
        }
        if (offset != state.offsets[fileId]) throw AbException(ErrorCode.RESUME_INVALID, "file_begin offset mismatch")
        try {
            val w = storage.openWriter(state.transferId, peer.deviceId, file, offset)
            streams[stream] = IncomingFile(state, file, w, offset)
            state.streams.add(stream)
        } catch (e: Exception) {
            failTransfer(state, e as? AbException ?: AbException(ErrorCode.WRITE_FAILED, e.toString(), e))
        }
    }

    private fun handleData(rec: Record.Data) {
        val f = streams[rec.stream] ?: return // stream of a cancelled/failed transfer
        if (f.position + rec.len > f.file.size) {
            streams.remove(rec.stream); f.state.streams.remove(rec.stream)
            f.writer.close(keep = false)
            reportFile(f.state, f.file.id, AbException(ErrorCode.SIZE_MISMATCH, "More data than announced"))
            return
        }
        try {
            f.writer.write(rec.buf, rec.off, rec.len)
        } catch (e: Exception) {
            failTransfer(f.state, e as? AbException ?: AbException(ErrorCode.WRITE_FAILED, e.toString(), e))
            return
        }
        f.position += rec.len
        f.state.progress.add(rec.len.toLong(), f.file.path)
    }

    private fun handleFileEnd(m: JsonObject) {
        val state = incoming[Json.str(m, "transferId")] ?: return
        val fileId = Json.int(m, "fileId")
        val entry = streams.entries.firstOrNull { it.value.state === state && it.value.file.id == fileId }
        if (entry == null) {
            if (state.status.containsKey(fileId)) return // already failed
            throw AbException(ErrorCode.MALFORMED, "file_end without file_begin")
        }
        streams.remove(entry.key); state.streams.remove(entry.key)
        val f = entry.value
        // Integrity: hash what is actually stored (read back), so storage faults and
        // resume-offset bugs are caught — network corruption is already ruled out by AES-GCM.
        val digest = if (f.position != f.file.size) "" else try {
            val md = MessageDigest.getInstance("SHA-256")
            f.writer.readPrefix { b, o, l -> md.update(b, o, l) }
            AbCrypto.hex(md.digest())
        } catch (e: Exception) {
            f.writer.close(keep = false)
            reportFile(state, fileId, AbException(ErrorCode.WRITE_FAILED, "Cannot read back file: $e", e))
            return
        }
        when {
            f.position != f.file.size -> {
                f.writer.close(keep = false)
                reportFile(state, fileId, AbException(ErrorCode.SIZE_MISMATCH, "Received ${f.position} of ${f.file.size} bytes"))
            }
            digest != Json.str(m, "sha256").lowercase() -> {
                f.writer.close(keep = false)
                reportFile(state, fileId, AbException(ErrorCode.HASH_MISMATCH, "SHA-256 mismatch"))
            }
            else -> try {
                val saved = f.writer.finish()
                val done = CompletedFile(f.file.path, saved, f.file.size)
                state.status[fileId] = Result.success(done)
                runCatching {
                    channel.sendControl(Json.obj("type" to "file_ok", "transferId" to state.transferId, "fileId" to fileId,
                        "name" to saved.substringAfterLast('/')), urgent = true)
                }
                onEvent(SessionEvent.FileDone(state.transferId, Direction.RECEIVE, done))
                finishIfComplete(state)
            } catch (e: Exception) {
                f.writer.close(keep = false)
                reportFile(state, fileId, e as? AbException ?: AbException(ErrorCode.WRITE_FAILED, e.toString(), e))
            }
        }
    }

    private fun reportFile(state: IncomingState, id: Int, e: AbException) {
        state.status[id] = Result.failure(e)
        runCatching {
            channel.sendControl(Json.obj("type" to "file_failed", "transferId" to state.transferId, "fileId" to id,
                "code" to e.code.wire, "message" to (e.message ?: "")), urgent = true)
        }
        finishIfComplete(state)
    }

    private fun finishIfComplete(state: IncomingState) {
        if (state.status.size != state.files.size) return
        if (!incoming.remove(state.transferId, state)) return
        val r = state.result(null)
        storage.finish(state.transferId)
        runCatching {
            channel.sendControl(Json.obj("type" to "transfer_done", "transferId" to state.transferId, "ok" to r.ok), urgent = true)
        }
        state.progress.emit(force = true, current = null)
        onEvent(SessionEvent.Finished(r))
    }

    /** Storage-level failure (disk full, permission): abort the whole transfer. */
    private fun failTransfer(state: IncomingState, e: AbException) {
        // A write that fails because shutdown() just closed the file is a lost connection,
        // not a storage error: keep the partial so the transfer can resume.
        if (isClosed) return
        if (!incoming.remove(state.transferId, state)) return
        dropStreams(state, keep = false)
        storage.discard(state.transferId)
        runCatching { channel.sendControl(Json.obj("type" to "cancel", "transferId" to state.transferId, "reason" to e.code.wire), urgent = true) }
        onEvent(SessionEvent.Finished(state.result(e)))
    }

    private fun dropStreams(state: IncomingState, keep: Boolean) {
        for (s in state.streams.toList()) streams.remove(s)?.writer?.close(keep)
        state.streams.clear()
    }

    private fun shutdown(error: AbException?) {
        if (!closed.compareAndSet(false, true)) return
        channel.close()
        val err = error ?: AbException(ErrorCode.CONNECTION_LOST, "Disconnected")
        // Keep partial files: an interrupted transfer can resume after reconnecting.
        for ((_, f) in streams) f.writer.close(keep = true)
        streams.clear()
        for (o in outgoing.values) o.fail(err)
        val ins = incoming.values.toList()
        incoming.clear()
        for (i in ins) onEvent(SessionEvent.Finished(i.result(err)))
        onEvent(SessionEvent.Closed(error))
        closedSignal.complete(error)
        scope.cancel()
    }

    private fun failure(id: String, start: Long, e: AbException) =
        TransferResult(id, Direction.SEND, emptyList(), emptyMap(), 0, System.currentTimeMillis() - start, e)
}

private class OutgoingState(val transferId: String, val files: List<OfferFile>) {
    val response = CompletableDeferred<Result<JsonObject>>()
    val done = CompletableDeferred<Result<Unit>>()
    private val ok = ConcurrentHashMap<Int, CompletedFile>()
    private val failed = ConcurrentHashMap<Int, AbException>()
    @Volatile private var expected: Set<Int> = emptySet()
    @Volatile private var cancelError: AbException? = null
    @Volatile var peerCancelled = false

    fun expect(ids: Set<Int>) { expected = ids; if (ids.isEmpty()) done.complete(Result.success(Unit)) }

    fun fileOk(id: Int): CompletedFile? {
        val f = files.getOrNull(id) ?: return null
        return CompletedFile(f.path, null, f.size).also { ok[id] = it }
    }

    fun fileFailed(id: Int, e: AbException) { failed[id] = e }

    fun cancel(e: AbException, byPeer: Boolean) {
        if (byPeer) peerCancelled = true
        if (cancelError == null) cancelError = e
        fail(e)
    }

    fun fail(e: AbException) {
        response.complete(Result.failure(e))
        done.complete(Result.failure(e))
    }

    fun checkCancelled() { cancelError?.let { throw it } }

    fun result(bytes: Long, start: Long, error: AbException?): TransferResult {
        val failedByName = failed.mapKeys { files.getOrNull(it.key)?.path ?: "${it.key}" }
        val err = error ?: failed.values.firstOrNull()
            ?: if (ok.size < expected.size) AbException(ErrorCode.INTERNAL, "Missing file confirmations") else null
        return TransferResult(transferId, Direction.SEND, ok.toSortedMap().values.toList(), failedByName, bytes,
            System.currentTimeMillis() - start, err)
    }
}

private class IncomingState(
    val transferId: String,
    files: List<OfferFile>,
    val offsets: Map<Int, Long>,
    val total: Long,
    val progress: ProgressThrottle,
) {
    val files = files.associateBy { it.id }
    val start = System.currentTimeMillis()
    val status = ConcurrentHashMap<Int, Result<CompletedFile>>()
    val streams: MutableSet<Int> = ConcurrentHashMap.newKeySet()

    fun result(error: AbException?): TransferResult {
        val ok = status.toSortedMap().values.mapNotNull { it.getOrNull() }
        val failed = status.filterValues { it.isFailure }
            .map { (id, r) -> (files[id]?.path ?: "$id") to (r.exceptionOrNull() as AbException) }.toMap()
        return TransferResult(transferId, Direction.RECEIVE, ok, failed, progress.doneBytes - offsets.values.sum(),
            System.currentTimeMillis() - start, error ?: failed.values.firstOrNull())
    }
}

private class IncomingFile(
    val state: IncomingState,
    val file: OfferFile,
    val writer: IncomingFileWriter,
    var position: Long,
)

/** Emits progress at most every 100 ms. */
private class ProgressThrottle(
    val transferId: String,
    val direction: Direction,
    val total: Long,
    val fileCount: Int,
    done: Long,
    val onEvent: (SessionEvent) -> Unit,
) {
    private var done = done
    private var filesDone = 0
    private var lastEmit = 0L
    private var lastFile: String? = null

    val doneBytes: Long @Synchronized get() = done

    fun add(n: Long, current: String) {
        synchronized(this) {
            done += n
            if (lastFile != current) { if (lastFile != null) filesDone++; lastFile = current }
        }
        emit(false, current)
    }

    fun emit(force: Boolean, current: String?) {
        val p = synchronized(this) {
            val now = System.currentTimeMillis()
            if (!force && now - lastEmit < 100) return
            lastEmit = now
            if (force && current == null) filesDone = fileCount
            TransferProgress(transferId, direction, total, done, fileCount, filesDone, current ?: lastFile)
        }
        onEvent(SessionEvent.Progress(p))
    }
}
