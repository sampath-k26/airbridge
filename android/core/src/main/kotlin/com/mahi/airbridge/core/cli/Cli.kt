package com.mahi.airbridge.core.cli

import com.mahi.airbridge.core.crypto.SoftwareIdentity
import com.mahi.airbridge.core.crypto.TrustStore
import com.mahi.airbridge.core.protocol.AbException
import com.mahi.airbridge.core.protocol.AbProtocol
import com.mahi.airbridge.core.protocol.Json
import com.mahi.airbridge.core.protocol.PairingCode
import com.mahi.airbridge.core.protocol.PairingUri
import com.mahi.airbridge.core.storage.FileSystemStorage
import com.mahi.airbridge.core.transfer.Direction
import com.mahi.airbridge.core.transfer.FileSource
import com.mahi.airbridge.core.transfer.Session
import com.mahi.airbridge.core.transfer.SessionEvent
import com.mahi.airbridge.core.transfer.TransferResult
import com.mahi.airbridge.core.transport.DialPairing
import com.mahi.airbridge.core.transport.Handshake
import com.mahi.airbridge.core.transport.HandshakeResult
import com.mahi.airbridge.core.transport.LocalDevice
import com.mahi.airbridge.core.transport.SocketStream
import kotlinx.coroutines.runBlocking
import java.io.File
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.util.concurrent.atomic.AtomicInteger
import kotlin.system.exitProcess

/**
 * Headless JVM peer (same options as the Swift `airbridge-cli`), used for
 * cross-implementation interop tests and benchmarks on a development machine.
 */
fun main(argv: Array<String>) {
    if (argv.isEmpty()) fail("usage: airbridge-jvm listen|dial ...")
    val mode = argv[0]
    var state = File(System.getProperty("java.io.tmpdir"), "airbridge-jvm")
    var dir = File(".")
    var port = AbProtocol.DEFAULT_PORT
    var host: String? = null
    var uri: String? = null
    var code: String? = null
    val send = ArrayList<String>()
    var expect = 0
    var chunk = AbProtocol.DEFAULT_CHUNK
    var name = "airbridge-jvm"
    var repeat = 1
    var i = 1
    fun next(): String = argv.getOrNull(++i) ?: fail("missing value for ${argv[i - 1]}")
    while (i < argv.size) {
        when (argv[i]) {
            "--state" -> state = File(next())
            "--dir" -> dir = File(next())
            "--port" -> port = next().toInt()
            "--host" -> host = next()
            "--uri" -> uri = next()
            "--code" -> code = next()
            "--expect" -> expect = next().toInt()
            "--chunk" -> chunk = next().toInt()
            "--name" -> name = next()
            "--repeat" -> repeat = next().toInt()
            "--send" -> while (i + 1 < argv.size && !argv[i + 1].startsWith("--")) send.add(next())
            else -> fail("unknown option ${argv[i]}")
        }
        i++
    }
    val identity = SoftwareIdentity.loadOrCreate(File(state, "identity.key"))
    val trust = TrustStore(File(state, "trust.json"))
    val local = LocalDevice(identity, name, "jvm", "AirBridge-jvm/1.0")
    val storage = FileSystemStorage(dir)
    val finishedIncoming = AtomicInteger()

    fun runSession(hs: HandshakeResult): Int {
        emit("event" to "connected", "peer" to hs.peer.name, "peerId" to hs.peer.deviceId, "sas" to hs.verificationCode,
            "newlyPaired" to hs.newlyPaired)
        val session = Session(hs, storage, chunk, decide = { true }) { ev ->
            if (ev is SessionEvent.Finished && ev.result.direction == Direction.RECEIVE) {
                emitResult(ev.result); finishedIncoming.incrementAndGet()
            }
        }
        session.start()
        var rc = 0
        if (send.isNotEmpty()) {
            val sources = FileSource.collect(send.map { File(it) })
            repeat(repeat) {
                if (rc == 0) {
                    val r = runBlocking { session.send(sources) }
                    emitResult(r)
                    if (!r.ok) rc = 1
                }
            }
        }
        while (finishedIncoming.get() < expect && !session.isClosed) Thread.sleep(50)
        session.close()
        return rc
    }

    try {
        when (mode) {
            "listen" -> {
                val pc = code?.let { PairingCode.normalize(it) }?.let { PairingCode(it) } ?: PairingCode()
                val server = ServerSocket()
                server.reuseAddress = true
                server.bind(InetSocketAddress(port))
                val hosts = NetworkInterface.getNetworkInterfaces().toList().filter { it.isUp && !it.isLoopback }
                    .flatMap { it.inetAddresses.toList() }.filterIsInstance<Inet4Address>().map { it.hostAddress } + "127.0.0.1"
                val u = PairingUri(hosts, server.localPort, pc.code, identity.fingerprint, name).toUri()
                emit("event" to "listening", "port" to server.localPort, "uri" to u, "code" to pc.display)
                val stream = SocketStream(server.accept())
                server.close()
                val hs = Handshake.accept(stream, local, trust, { pc }, { true })
                exitProcess(runSession(hs))
            }
            "dial" -> {
                var h = host
                var p = port
                var pairing = code?.let { PairingCode.normalize(it) }?.let { DialPairing(it, null) }
                uri?.let {
                    val parsed = PairingUri.parse(it) ?: fail("invalid pairing URI")
                    h = h ?: parsed.hosts.first(); p = parsed.port
                    pairing = DialPairing(parsed.code, parsed.fingerprint)
                }
                val target = h ?: fail("--host or --uri required")
                val stream = SocketStream.connect(target, p)
                val hs = Handshake.dial(stream, local, trust, pairing, target, p)
                exitProcess(runSession(hs))
            }
            else -> fail("unknown mode $mode")
        }
    } catch (e: AbException) {
        fail(e.toString())
    }
}

private fun emitResult(r: TransferResult) {
    val secs = r.durationMs / 1000.0
    emit("event" to "result", "direction" to r.direction.name.lowercase(), "ok" to r.ok, "bytes" to r.bytes,
        "seconds" to secs, "MBps" to Math.round(r.megabytesPerSecond * 10) / 10.0, "files" to r.files.size,
        "failed" to r.failed.size, "error" to r.error?.toString(), "saved" to r.files.mapNotNull { it.savedAs })
}

private fun emit(vararg pairs: Pair<String, Any?>) {
    println(Json.obj(*pairs).toString())
    System.out.flush()
}

private fun fail(msg: String): Nothing {
    emit("event" to "error", "message" to msg)
    exitProcess(1)
}
