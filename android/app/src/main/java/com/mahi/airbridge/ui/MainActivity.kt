package com.mahi.airbridge.ui

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.mahi.airbridge.app.graph
import com.mahi.airbridge.transfer.SessionManager.Connection
import com.mahi.airbridge.util.Format

class MainActivity : ComponentActivity() {
    /** Files shared from other apps, sent once a Mac is connected. */
    private val pendingShares = mutableStateListOf<Uri>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        handleShare(intent)
        setContent { AirBridgeTheme { App() } }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleShare(intent)
    }

    private fun handleShare(intent: Intent?) {
        intent ?: return
        val uris = when (intent.action) {
            Intent.ACTION_SEND -> listOfNotNull(if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                else @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_STREAM))
            Intent.ACTION_SEND_MULTIPLE -> (if (Build.VERSION.SDK_INT >= 33) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                else @Suppress("DEPRECATION") intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)) ?: emptyList()
            else -> emptyList()
        }
        pendingShares.addAll(uris)
    }

    @Composable
    private fun App() {
        val g = graph
        val m = g.sessions
        val connection by m.connection.collectAsStateWithLifecycle()
        val transfers by m.transfers.collectAsStateWithLifecycle()
        val peers by m.peers.collectAsStateWithLifecycle()
        val listening by m.listening.collectAsStateWithLifecycle()
        val settings by g.settings.values.collectAsStateWithLifecycle()
        val hotspot by g.hotspot.state.collectAsStateWithLifecycle()
        val offer by m.offerPrompt.collectAsStateWithLifecycle()
        val pairing by m.pairingPrompt.collectAsStateWithLifecycle()
        var screen by rememberSaveable { mutableStateOf("home") }
        var historyVersion by rememberSaveable { mutableStateOf(0) }

        val notifPerm = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {}
        LaunchedEffect(Unit) {
            if (Build.VERSION.SDK_INT >= 33) notifPerm.launch(Manifest.permission.POST_NOTIFICATIONS)
            g.discovery.startDiscovery()
        }
        // Share sheet: send as soon as we are connected.
        LaunchedEffect(connection, pendingShares.size) {
            if (connection is Connection.Connected && pendingShares.isNotEmpty()) {
                m.send(pendingShares.toList()); pendingShares.clear()
            }
        }
        LaunchedEffect(connection) { if (connection is Connection.Connected && (screen == "connect" || screen == "receive")) screen = "home" }

        val pickFiles = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
            if (uris.isNotEmpty()) m.send(uris)
        }
        val pickFolder = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
            if (uri != null) m.send(emptyList(), listOf(uri))
        }
        val pickDestination = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
            if (uri != null) {
                contentResolver.takePersistableUriPermission(uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                g.settings.update { it.copy(destinationTree = uri) }
            }
        }

        BackHandler(enabled = screen != "home") { screen = "home" }
        Scaffold(Modifier.fillMaxSize(), containerColor = MaterialTheme.colorScheme.background) { padding ->
            when (screen) {
                "connect" -> ConnectScreen(padding, hotspot, onScanned = { m.connect(it); screen = "home" },
                    onManual = { h, p, c -> m.connectManual(h, p, c); screen = "home" },
                    onStartHotspot = g.hotspot::start, onStopHotspot = g.hotspot::stop, onBack = { screen = "home" })
                "receive" -> ReceiveScreen(padding, listening, connection, onRefresh = m::refreshPairingCode, onBack = { screen = "home" })
                "settings" -> SettingsScreen(padding, settings, g.identity.let { com.mahi.airbridge.core.crypto.AbCrypto.displayFingerprint(it.spki) },
                    onUpdate = g.settings::update, onPickDestination = { pickDestination.launch(null) },
                    onClearHistory = { g.history.clear(); historyVersion++ }, onBack = { screen = "home" })
                else -> {
                    val recent = remember(transfers, historyVersion) {
                        val activeIds = transfers.filter { it.isActive }.map { it.id }.toSet()
                        g.history.items.filter { it.id !in activeIds }
                    }
                    HomeScreen(settings.deviceName, connection, peers, transfers.filter { it.isActive }, recent, padding,
                        onSendFiles = { pickFiles.launch(arrayOf("*/*")) }, onSendFolder = { pickFolder.launch(null) },
                        onReceive = { m.startListening(); screen = "receive" }, onConnect = { screen = "connect" },
                        onReconnect = m::reconnect, onForget = m::forget, onDisconnect = m::disconnect, onCancel = m::cancel,
                        onRemove = { g.history.remove(it); historyVersion++ },
                        onSettings = { screen = "settings" }, onDismissError = m::disconnect)
                }
            }
        }

        pairing?.let { p ->
            AlertDialog(onDismissRequest = {},
                title = { Text("Pair with ${p.request.peerName}?") },
                text = {
                    Column {
                        Text("Check that the Mac shows the same verification number:")
                        Text(p.request.verificationCode, style = MaterialTheme.typography.headlineMedium, fontFamily = FontFamily.Monospace,
                            fontWeight = FontWeight.SemiBold)
                        Text("Device key ${p.request.fingerprint}", style = MaterialTheme.typography.bodySmall)
                    }
                },
                confirmButton = { TextButton(onClick = { p.answer.complete(true) }) { Text("Pair") } },
                dismissButton = { TextButton(onClick = { p.answer.complete(false) }) { Text("Decline") } })
        }
        offer?.let { o ->
            AlertDialog(onDismissRequest = {},
                title = { Text("Receive from ${o.offer.peer.name}?") },
                text = { Text("${o.offer.files.size} file(s), ${Format.bytes(o.offer.totalBytes)}\n" +
                    o.offer.files.take(5).joinToString("\n") { "• " + it.path } + if (o.offer.files.size > 5) "\n…" else "") },
                confirmButton = { TextButton(onClick = { o.answer.complete(true) }) { Text("Accept") } },
                dismissButton = { TextButton(onClick = { o.answer.complete(false) }) { Text("Decline") } })
        }
    }
}
