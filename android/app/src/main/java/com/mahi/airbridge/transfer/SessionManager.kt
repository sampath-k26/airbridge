package com.mahi.airbridge.transfer

import android.content.Context
import android.net.Uri
import android.util.Log
import com.mahi.airbridge.app.Settings
import com.mahi.airbridge.core.crypto.DeviceIdentity
import com.mahi.airbridge.core.crypto.PeerRecord
import com.mahi.airbridge.core.crypto.TrustStore
import com.mahi.airbridge.core.protocol.AbException
import com.mahi.airbridge.core.protocol.AbProtocol
import com.mahi.airbridge.core.protocol.ErrorCode
import com.mahi.airbridge.core.protocol.PairingCode
import com.mahi.airbridge.core.protocol.PairingUri
import com.mahi.airbridge.core.storage.ReceiveStorage
import com.mahi.airbridge.core.transfer.Direction
import com.mahi.airbridge.core.transfer.IncomingOffer
import com.mahi.airbridge.core.transfer.SendSource
import com.mahi.airbridge.core.transfer.Session
import com.mahi.airbridge.core.transfer.SessionEvent
import com.mahi.airbridge.core.transfer.SpeedMeter
import com.mahi.airbridge.core.transport.DialPairing
import com.mahi.airbridge.core.transport.Handshake
import com.mahi.airbridge.core.transport.HandshakeResult
import com.mahi.airbridge.core.transport.LocalDevice
import com.mahi.airbridge.core.transport.PairingRequest
import com.mahi.airbridge.core.transport.SocketStream
import com.mahi.airbridge.discovery.NsdDiscovery
import com.mahi.airbridge.network.LocalNetwork
import com.mahi.airbridge.storage.ContentUriSource
import com.mahi.airbridge.storage.MediaStoreStorage
import com.mahi.airbridge.storage.TreeStorage
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.util.UUID

/**
 * Owns the network side of the app: listening, dialing, the active [Session], outgoing
 * job queue with automatic resume after interruptions, and UI-facing state.
 */
class SessionManager(
    private val context: Context,
    private val identity: DeviceIdentity,
    val trust: TrustStore,
    private val settings: Settings,
    val history: TransferHistory,
    val discovery: NsdDiscovery,
) {
    sealed interface Connection {
        data object Idle : Connection
        data class Connecting(val target: String) : Connection
        data class Connected(val peer: PeerRecord, val verificationCode: String, val dialer: Boolean) : Connection
        data class Reconnecting(val peer: PeerRecord, val attempt: Int) : Connection
        data class Failed(val message: String, val code: ErrorCode) : Connection
    }

    data class ListenInfo(val port: Int, val addresses: List<LocalNetwork.Address>, val code: PairingCode, val uri: String)

    data class OfferPrompt(val offer: IncomingOffer, val answer: CompletableDeferred<Boolean>)
    data class PairingPrompt(val request: PairingRequest, val answer: CompletableDeferred<Boolean>)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val _connection = MutableStateFlow<Connection>(Connection.Idle)
    val connection: StateFlow<Connection> = _connection
    private val _listening = MutableStateFlow<ListenInfo?>(null)
    val listening: StateFlow<ListenInfo?> = _listening
    private val _transfers = MutableStateFlow<List<TransferUi>>(emptyList())
    val transfers: StateFlow<List<TransferUi>> = _transfers
    private val _offerPrompt = MutableStateFlow<OfferPrompt?>(null)
    val offerPrompt: StateFlow<OfferPrompt?> = _offerPrompt
    private val _pairingPrompt = MutableStateFlow<PairingPrompt?>(null)
    val pairingPrompt: StateFlow<PairingPrompt?> = _pairingPrompt
    private val _peers = MutableStateFlow(trust.all)
    val peers: StateFlow<List<PeerRecord>> = _peers

    @Volatile private var session: Session? = null
    private var server: ServerSocket? = null
    private var acceptJob: Job? = null
    private val meters = HashMap<String, SpeedMeter>()

    /** Outgoing work survives connection loss and resumes with the same transferId. */
    private data class OutgoingJob(val transferId: String, val peerId: String, val sources: List<SendSource>, var job: Job? = null)
    private val jobs = LinkedHashMap<String, OutgoingJob>()
    private val jobSignal = Channel<Unit>(Channel.CONFLATED)

    init {
        scope.launch { runJobQueue() }
        scope.launch { (storageFor() as? MediaStoreStorage)?.cleanupStale() }
    }

    private fun local() = LocalDevice(identity, settings.values.value.deviceName)

    private fun storageFor(): ReceiveStorage =
        settings.values.value.destinationTree?.let { TreeStorage(context, it) } ?: MediaStoreStorage(context)

    val hasActiveWork: Boolean get() = session != null || _transfers.value.any { it.isActive }

    // ------------------------------------------------------------ listening

    /** Starts accepting connections and shows a fresh pairing code. */
    fun startListening() {
        scope.launch {
            if (server == null) {
                val s = ServerSocket()
                s.reuseAddress = true
                runCatching { s.bind(InetSocketAddress(AbProtocol.DEFAULT_PORT)) }.onFailure { s.bind(InetSocketAddress(0)) }
                server = s
                acceptJob = scope.launch { acceptLoop(s) }
                discovery.register(settings.values.value.deviceName, s.localPort, identity.deviceId)
            }
            refreshPairingCode()
            TransferService.ensureRunning(context)
        }
    }

    fun refreshPairingCode() {
        val s = server ?: return
        val addrs = LocalNetwork.addresses()
        val code = PairingCode()
        val uri = PairingUri(addrs.map { it.ip }, s.localPort, code.code, identity.fingerprint, settings.values.value.deviceName).toUri()
        _listening.value = ListenInfo(s.localPort, addrs, code, uri)
    }

    fun stopListening() {
        discovery.unregister()
        acceptJob?.cancel(); acceptJob = null
        runCatching { server?.close() }; server = null
        _listening.value = null
    }

    private suspend fun acceptLoop(s: ServerSocket) = withContext(Dispatchers.IO) {
        while (isActive && !s.isClosed) {
            val sock = runCatching { s.accept() }.getOrNull() ?: break
            scope.launch {
                try {
                    val hs = Handshake.accept(SocketStream(sock), local(), trust,
                        activeCode = { _listening.value?.code },
                        approve = { req -> askPairing(req) })
                    attach(hs, dialer = false)
                } catch (e: AbException) {
                    Log.i(TAG, "incoming handshake failed: ${e.code.wire}")
                    if (e.code != ErrorCode.CONNECTION_LOST) _connection.value = Connection.Failed(e.userMessage, e.code)
                } catch (e: Exception) {
                    runCatching { sock.close() }
                }
            }
        }
    }

    private fun askPairing(req: PairingRequest): Boolean = runBlocking {
        val answer = CompletableDeferred<Boolean>()
        _pairingPrompt.value = PairingPrompt(req, answer)
        val ok = withTimeoutOrNull(AbProtocol.APPROVAL_TIMEOUT_MS - 5_000) { answer.await() } ?: false
        _pairingPrompt.value = null
        ok
    }

    // -------------------------------------------------------------- dialing

    fun connect(uri: PairingUri) = scope.launch {
        dialAny(uri.hosts, uri.port, DialPairing(uri.code, uri.fingerprint), uri.name.ifBlank { uri.hosts.first() })
    }

    fun connectManual(host: String, port: Int, code: String?) = scope.launch {
        val pairing = code?.let { PairingCode.normalize(it) }?.let { DialPairing(it, null) }
        if (code != null && pairing == null) {
            _connection.value = Connection.Failed("That pairing code is not valid. It has 10 letters and digits.", ErrorCode.AUTH_FAILED)
            return@launch
        }
        dialAny(listOf(host.trim()), port, pairing, host)
    }

    /** Reconnects to a paired device using its last address or a discovered one. */
    fun reconnect(peer: PeerRecord) = scope.launch { tryReconnect(peer) }

    private suspend fun tryReconnect(peer: PeerRecord): Boolean {
        val discovered = discovery.found.value.values.filter { it.deviceId == peer.deviceId }.map { it.host to it.port }
        val port = peer.lastPort ?: AbProtocol.DEFAULT_PORT
        val candidates = (discovered + peer.lastHosts.map { it to port }).distinct()
        if (candidates.isEmpty()) return false
        for ((h, p) in candidates) if (dialAny(listOf(h), p, null, peer.name, quiet = true)) return true
        return false
    }

    private suspend fun dialAny(hosts: List<String>, port: Int, pairing: DialPairing?, label: String, quiet: Boolean = false): Boolean =
        withContext(Dispatchers.IO) {
            if (!quiet) _connection.value = Connection.Connecting(label)
            var last: AbException? = null
            for (h in hosts) {
                try {
                    val stream = SocketStream.connect(h, port, timeoutMs = 4_000)
                    val hs = Handshake.dial(stream, local(), trust, pairing, h, port)
                    attach(hs, dialer = true)
                    return@withContext true
                } catch (e: AbException) {
                    last = e
                    // Authentication errors are definitive; don't try other addresses.
                    if (e.code in setOf(ErrorCode.AUTH_FAILED, ErrorCode.PAIRING_REJECTED, ErrorCode.PAIRING_EXPIRED, ErrorCode.UNSUPPORTED_VERSION)) break
                }
            }
            if (!quiet) _connection.value = Connection.Failed(last?.userMessage ?: "Could not connect", last?.code ?: ErrorCode.CONNECTION_FAILED)
            false
        }

    fun disconnect() {
        reconnectJob?.cancel()
        session?.close()
        session = null
        _connection.value = Connection.Idle
    }

    fun forget(peer: PeerRecord) {
        if ((connection.value as? Connection.Connected)?.peer?.deviceId == peer.deviceId) disconnect()
        trust.remove(peer.deviceId)
        _peers.value = trust.all
    }

    // -------------------------------------------------------------- session

    private var reconnectJob: Job? = null

    private fun attach(hs: HandshakeResult, dialer: Boolean) {
        session?.close()
        val s = Session(hs, storageFor(), settings.values.value.chunkSize, decide = ::decide, onEvent = ::onEvent)
        session = s
        _peers.value = trust.all
        _connection.value = Connection.Connected(hs.peer, hs.verificationCode, dialer)
        s.start()
        TransferService.ensureRunning(context)
        jobSignal.trySend(Unit)
        scope.launch {
            val err = s.closedSignal.await()
            if (session !== s) return@launch
            session = null
            // Reconnect if we owe the peer data (queued sends) or it was sending to us
            // (interrupted receive): the dialer is the only side that can re-establish.
            val pending = synchronized(jobs) { jobs.values.any { it.peerId == hs.peer.deviceId } } ||
                _transfers.value.any { it.status == TransferStatus.INTERRUPTED }
            if (err != null && dialer && pending) {
                startReconnectLoop(hs.peer)
            } else {
                _connection.value = if (err == null || err.code == ErrorCode.CONNECTION_LOST) Connection.Idle
                    else Connection.Failed(err.userMessage, err.code)
            }
        }
    }

    /** After an interruption, keep trying the peer for 2 minutes so pending sends resume. */
    private fun startReconnectLoop(peer: PeerRecord) {
        reconnectJob?.cancel()
        reconnectJob = scope.launch {
            for (attempt in 1..40) {
                _connection.value = Connection.Reconnecting(peer, attempt)
                if (tryReconnect(peer)) return@launch
                delay(3_000)
            }
            _connection.value = Connection.Failed("${peer.name} is not reachable. Pending transfers were kept; reconnect to resume.",
                ErrorCode.CONNECTION_LOST)
        }
    }

    private suspend fun decide(offer: IncomingOffer): Boolean {
        if (offer.resumedBytes > 0 || !settings.values.value.askBeforeReceiving) return true
        val answer = CompletableDeferred<Boolean>()
        _offerPrompt.value = OfferPrompt(offer, answer)
        val ok = withTimeoutOrNull(120_000) { answer.await() } ?: false
        _offerPrompt.value = null
        return ok
    }

    private fun onEvent(ev: SessionEvent) {
        val peerName = session?.peer?.name ?: "device"
        val now = System.currentTimeMillis()
        when (ev) {
            is SessionEvent.Offer -> {}
            is SessionEvent.Started -> {
                synchronized(meters) { meters[ev.transferId] = SpeedMeter() }
                upsert(ev.transferId) { t ->
                    (t ?: TransferUi(ev.transferId, ev.direction, peerName, titleOf(ev.files.map { it.path }), ev.files.size, ev.totalBytes))
                        .copy(status = TransferStatus.RUNNING, error = null)
                }
            }
            is SessionEvent.Progress -> {
                val p = ev.progress
                val m = synchronized(meters) { meters.getOrPut(p.transferId) { SpeedMeter() } }
                m.add(p.bytesDone, now)
                upsert(p.transferId) { t ->
                    t?.copy(bytesDone = p.bytesDone, currentFile = p.currentFile, currentSpeed = m.current(),
                        averageSpeed = m.average(now), etaSeconds = m.etaSeconds(p.totalBytes))
                }
            }
            is SessionEvent.FileDone -> {}
            is SessionEvent.Finished -> {
                val r = ev.result
                val status = when {
                    r.ok -> TransferStatus.DONE
                    r.error?.code == ErrorCode.CANCELLED -> TransferStatus.CANCELLED
                    r.error?.code in setOf(ErrorCode.CONNECTION_LOST, ErrorCode.TIMEOUT) -> TransferStatus.INTERRUPTED
                    else -> TransferStatus.FAILED
                }
                val avg = if (r.durationMs > 0) r.bytes * 1000.0 / r.durationMs else null
                upsert(r.transferId) { t ->
                    t?.copy(status = status, error = r.error?.userMessage, savedTo = r.files.mapNotNull { it.savedAs },
                        averageSpeed = avg ?: t.averageSpeed, currentSpeed = null, etaSeconds = null,
                        bytesDone = if (r.ok) t.totalBytes else t.bytesDone, finishedAt = now)
                }
                if (status != TransferStatus.INTERRUPTED) {
                    _transfers.value.firstOrNull { it.id == r.transferId }?.let { history.add(it) }
                    if (r.direction == Direction.SEND) synchronized(jobs) { jobs.remove(r.transferId) }
                }
            }
            is SessionEvent.Closed -> {}
        }
    }

    private fun titleOf(paths: List<String>): String {
        val first = paths.firstOrNull()?.substringBefore('/') ?: "Files"
        val tops = paths.map { it.substringBefore('/') }.distinct()
        return if (tops.size <= 1) first else "$first + ${tops.size - 1} more"
    }

    private fun upsert(id: String, f: (TransferUi?) -> TransferUi?) {
        _transfers.update { list ->
            val i = list.indexOfFirst { it.id == id }
            val n = f(list.getOrNull(i)) ?: return@update list
            if (i >= 0) list.toMutableList().also { it[i] = n } else listOf(n) + list
        }
    }

    // -------------------------------------------------------------- sending

    /** Queues content URIs (files) and optional folder trees for the connected peer. */
    fun send(uris: List<Uri>, trees: List<Uri> = emptyList()) = scope.launch {
        val resolver = context.contentResolver
        val sources = uris.mapNotNull { ContentUriSource.from(resolver, it) } + trees.flatMap { ContentUriSource.fromTree(resolver, it) }
        if (sources.isEmpty()) {
            _connection.value = Connection.Failed("Could not read the selected files.", ErrorCode.READ_FAILED); return@launch
        }
        sendSources(sources)
    }

    fun sendSources(sources: List<SendSource>): String? {
        if (sources.isEmpty()) return null
        val peer = (connection.value as? Connection.Connected)?.peer
            ?: (connection.value as? Connection.Reconnecting)?.peer ?: return null
        val id = UUID.randomUUID().toString()
        synchronized(jobs) { jobs[id] = OutgoingJob(id, peer.deviceId, sources) }
        upsert(id) { TransferUi(id, Direction.SEND, peer.name, titleOf(sources.map { it.path }), sources.size, sources.sumOf { it.size }) }
        jobSignal.trySend(Unit)
        return id
    }

    /** Runs queued jobs one at a time on the current session; interrupted ones are retried. */
    private suspend fun runJobQueue() {
        for (signal in jobSignal) {
            while (true) {
                val s = session ?: break
                val next = synchronized(jobs) { jobs.values.firstOrNull { it.peerId == s.peer.deviceId && it.job == null } } ?: break
                val job = scope.launch {
                    val r = s.send(next.sources, next.transferId)
                    synchronized(jobs) {
                        if (r.error?.code in setOf(ErrorCode.CONNECTION_LOST, ErrorCode.TIMEOUT) && jobs.containsKey(next.transferId)) {
                            next.job = null // retried after reconnecting (resume)
                        } else jobs.remove(next.transferId)
                    }
                }
                next.job = job
                job.join()
                if (session !== s) break
            }
        }
    }

    fun cancel(transferId: String) {
        val job = synchronized(jobs) { jobs.remove(transferId) }
        session?.cancel(transferId)
        job?.job?.cancel()
        upsert(transferId) { t -> t?.takeIf { it.isActive }?.copy(status = TransferStatus.CANCELLED, finishedAt = System.currentTimeMillis(),
            currentSpeed = null, etaSeconds = null)?.also { history.add(it) } ?: t }
    }

    fun clearFinished() = _transfers.update { l -> l.filter { it.isActive } }

    private companion object { const val TAG = "AirBridge" }
}
