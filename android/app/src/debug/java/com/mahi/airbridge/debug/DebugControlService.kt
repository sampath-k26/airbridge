package com.mahi.airbridge.debug

import android.app.Notification
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.lifecycle.LifecycleService
import androidx.lifecycle.lifecycleScope
import com.mahi.airbridge.R
import com.mahi.airbridge.app.graph
import com.mahi.airbridge.core.protocol.Json
import com.mahi.airbridge.core.protocol.PairingUri
import com.mahi.airbridge.storage.LocalFileSource
import com.mahi.airbridge.transfer.TransferService
import com.mahi.airbridge.transfer.TransferStatus
import kotlinx.coroutines.launch
import java.io.File

/**
 * DEBUG BUILD ONLY. Drives the real app stack from adb for automated device tests:
 *
 *   adb shell am start-foreground-service -n com.mahi.airbridge/.debug.DebugControlService \
 *       -a connect --es uri 'airbridge://pair?...'
 *   ... -a send --es dir test          (sends every file under <external files>/test)
 *   ... -a listen | status | disconnect | stop
 *
 * Results are logged as JSON lines with tag "AirBridgeTest". Exported, but guarded by
 * android.permission.DUMP which only the adb shell holds.
 */
class DebugControlService : LifecycleService() {
    private val logged = HashSet<String>()

    override fun onCreate() {
        super.onCreate()
        TransferService.createChannel(this)
        val n: Notification = NotificationCompat.Builder(this, "transfers").setSmallIcon(R.drawable.ic_stat_transfer)
            .setContentTitle("AirBridge test control").setSilent(true).build()
        ServiceCompat.startForeground(this, 77, n, if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0)
        val m = graph.sessions
        lifecycleScope.launch {
            m.transfers.collect { list ->
                for (t in list) {
                    if (t.isActive || !logged.add(t.id)) continue
                    val secs = ((t.finishedAt ?: t.startedAt) - t.startedAt) / 1000.0
                    log("event" to "result", "direction" to t.direction.name.lowercase(), "status" to t.status.name,
                        "bytes" to t.totalBytes, "files" to t.fileCount, "seconds" to secs,
                        "avgMBps" to t.averageSpeed?.let { Math.round(it / 1e5) / 10.0 }, "error" to t.error, "saved" to t.savedTo)
                }
            }
        }
        lifecycleScope.launch { m.connection.collect { log("event" to "connection", "state" to it.toString().take(300)) } }
        lifecycleScope.launch { m.listening.collect { it?.let { l -> log("event" to "listening", "uri" to l.uri, "code" to l.code.display) } } }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        val m = graph.sessions
        when (intent?.action) {
            "connect" -> PairingUri.parse(intent.getStringExtra("uri") ?: "")?.let { m.connect(it) } ?: log("event" to "error", "message" to "bad uri")
            "listen" -> m.startListening()
            "send" -> {
                // Staged with `adb push` + `run-as` into the private files dir (scoped storage hides
                // shell-pushed files in Android/data from the app).
                val dir = File(filesDir, intent.getStringExtra("dir") ?: "test")
                val files = dir.walkTopDown().filter { it.isFile }.map { LocalFileSource(it, it.relativeTo(dir).invariantSeparatorsPath) }.toList()
                val chunk = intent.getIntExtra("chunk", 0)
                if (chunk > 0) graph.settings.update { it.copy(chunkSize = chunk) }
                log("event" to "send", "files" to files.size, "id" to m.sendSources(files))
            }
            "chunk" -> graph.settings.update { it.copy(chunkSize = intent.getIntExtra("chunk", it.chunkSize)) }
            "status" -> log("event" to "status", "connection" to m.connection.value.toString().take(300),
                "transfers" to m.transfers.value.take(5).map { "${it.status}:${it.title}:${it.bytesDone}/${it.totalBytes}" })
            "disconnect" -> m.disconnect()
            "stop" -> { m.disconnect(); m.stopListening(); stopSelf() }
        }
        return START_NOT_STICKY
    }

    private fun log(vararg pairs: Pair<String, Any?>) = Log.i("AirBridgeTest", Json.obj(*pairs).toString())

}
