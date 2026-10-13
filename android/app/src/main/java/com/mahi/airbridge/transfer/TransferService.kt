package com.mahi.airbridge.transfer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleService
import androidx.lifecycle.lifecycleScope
import com.mahi.airbridge.R
import com.mahi.airbridge.app.AirBridgeApp
import com.mahi.airbridge.ui.MainActivity
import com.mahi.airbridge.util.Format
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

/**
 * Keeps the connection and transfers alive while the screen is off (foreground service,
 * type dataSync). Holds a Wi-Fi lock and a partial wake lock only while transferring,
 * and stops itself when nothing is connected or listening.
 */
class TransferService : LifecycleService() {
    private var wifiLock: WifiManager.WifiLock? = null
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        createChannel(this)
        ServiceCompat.startForeground(this, NOTIFICATION_ID, build("AirBridge", "Ready", null),
            if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0)
        val m = (application as AirBridgeApp).graph.sessions
        lifecycleScope.launch {
            combine(m.connection, m.transfers, m.listening) { c, t, l -> Triple(c, t, l) }.collect { (c, t, l) ->
                val active = t.firstOrNull { it.status == TransferStatus.RUNNING }
                setLocks(active != null)
                val (title, text) = when {
                    active != null -> (if (active.direction.name == "SEND") "Sending " else "Receiving ") + active.title to
                        "${(active.fraction * 100).toInt()}% · ${Format.speed(active.currentSpeed)}"
                    c is SessionManager.Connection.Connected -> "Connected to ${c.peer.name}" to "Ready to send and receive"
                    c is SessionManager.Connection.Reconnecting -> "Reconnecting to ${c.peer.name}…" to "Transfers will resume automatically"
                    l != null -> "Waiting for a connection" to "Port ${l.port}"
                    else -> "AirBridge" to "Idle"
                }
                getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID,
                    build(title, text, active?.let { (it.fraction * 1000).toInt() }))
            }
        }
        lifecycleScope.launch {
            // Stop when idle for 30 s (no session, no listener, no active transfer).
            var idleFor = 0
            while (true) {
                delay(5_000)
                idleFor = if (!m.hasActiveWork && m.listening.value == null) idleFor + 5 else 0
                if (idleFor >= 30) { stopSelf(); break }
            }
        }
    }

    private fun setLocks(on: Boolean) {
        if (on) {
            if (wifiLock == null) {
                val wm = applicationContext.getSystemService(WifiManager::class.java)
                @Suppress("DEPRECATION")
                wifiLock = wm.createWifiLock(
                    if (Build.VERSION.SDK_INT >= 29) WifiManager.WIFI_MODE_FULL_LOW_LATENCY else WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                    "airbridge:transfer").apply { setReferenceCounted(false); acquire() }
            }
            if (wakeLock == null) {
                wakeLock = getSystemService(PowerManager::class.java)
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "airbridge:transfer").apply { setReferenceCounted(false); acquire(6 * 3600_000L) }
            }
        } else {
            wifiLock?.release(); wifiLock = null
            wakeLock?.release(); wakeLock = null
        }
    }

    override fun onDestroy() {
        setLocks(false)
        super.onDestroy()
    }

    private fun build(title: String, text: String, progressPermille: Int?): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_transfer)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setContentIntent(open)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .apply { if (progressPermille != null) setProgress(1000, progressPermille, false) }
            .build()
    }

    companion object {
        private const val CHANNEL = "transfers"
        private const val NOTIFICATION_ID = 1

        fun createChannel(context: Context) {
            context.getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL, "Transfers", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Progress of AirBridge transfers"
                })
        }

        /** Starts the service; failures (background-start restrictions) are non-fatal. */
        fun ensureRunning(context: Context) {
            runCatching { ContextCompat.startForegroundService(context, Intent(context, TransferService::class.java)) }
        }
    }
}
