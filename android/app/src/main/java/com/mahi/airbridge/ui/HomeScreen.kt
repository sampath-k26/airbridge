package com.mahi.airbridge.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CreateNewFolder
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.LaptopMac
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.QrCodeScanner
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.UploadFile
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.mahi.airbridge.core.crypto.PeerRecord
import com.mahi.airbridge.transfer.SessionManager.Connection
import com.mahi.airbridge.transfer.TransferUi
import com.mahi.airbridge.util.Format

@Composable
fun HomeScreen(
    deviceName: String,
    connection: Connection,
    peers: List<PeerRecord>,
    active: List<TransferUi>,
    recent: List<TransferUi>,
    padding: PaddingValues,
    onSendFiles: () -> Unit,
    onSendFolder: () -> Unit,
    onReceive: () -> Unit,
    onConnect: () -> Unit,
    onReconnect: (PeerRecord) -> Unit,
    onForget: (PeerRecord) -> Unit,
    onDisconnect: () -> Unit,
    onCancel: (String) -> Unit,
    onSettings: () -> Unit,
    onDismissError: () -> Unit,
) {
    val connected = connection is Connection.Connected
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(
        start = 20.dp, end = 20.dp, top = padding.calculateTopPadding() + 12.dp, bottom = padding.calculateBottomPadding() + 24.dp)) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("AirBridge", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.SemiBold)
                    Text(deviceName, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                IconButton(onClick = onSettings) { Icon(Icons.Outlined.Settings, "Settings") }
            }
            Spacer(Modifier.height(16.dp))
            ConnectionPanel(connection, onConnect, onReceive, onDisconnect, onDismissError)
            Spacer(Modifier.height(12.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Button(onClick = onSendFiles, enabled = connected, modifier = Modifier.weight(1f).height(52.dp)) {
                    Icon(Icons.Outlined.UploadFile, null); Spacer(Modifier.width(8.dp)); Text("Send files")
                }
                FilledTonalButton(onClick = onSendFolder, enabled = connected, modifier = Modifier.height(52.dp)) {
                    Icon(Icons.Outlined.CreateNewFolder, "Send folder")
                }
            }
            if (!connected) {
                Text("Connect to your Mac first — files go directly over Wi-Fi, never through the internet.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 8.dp, start = 4.dp))
            }
        }
        if (active.isNotEmpty()) {
            item { SectionTitle("Transfers") }
            item {
                Panel {
                    Column { active.forEachIndexed { i, t ->
                        if (i > 0) HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                        TransferRow(t) { onCancel(t.id) }
                    } }
                }
            }
        }
        item { SectionTitle("Paired devices") }
        item {
            Panel {
                if (peers.isEmpty()) {
                    Text("No paired devices yet. Open AirBridge on your Mac and scan its QR code.",
                        style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(16.dp))
                } else Column {
                    peers.forEachIndexed { i, p ->
                        if (i > 0) HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                        PeerRow(p, isConnected = (connection as? Connection.Connected)?.peer?.deviceId == p.deviceId,
                            onClick = { onReconnect(p) }, onForget = { onForget(p) })
                    }
                }
            }
        }
        item { SectionTitle("Recent") }
        if (recent.isEmpty()) {
            item {
                Panel { Text("Transfers you send or receive appear here.", style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(16.dp)) }
            }
        } else item {
            Panel {
                Column { recent.take(20).forEachIndexed { i, t ->
                    if (i > 0) HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                    TransferRow(t, null)
                } }
            }
        }
    }
}

@Composable
private fun ConnectionPanel(c: Connection, onConnect: () -> Unit, onReceive: () -> Unit, onDisconnect: () -> Unit, onDismiss: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    Panel {
        Column(Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                when (c) {
                    is Connection.Connecting, is Connection.Reconnecting -> CircularProgressIndicator(Modifier.size(12.dp), strokeWidth = 2.dp)
                    is Connection.Connected -> StatusDot(scheme.tertiary)
                    is Connection.Failed -> StatusDot(scheme.error)
                    Connection.Idle -> StatusDot(scheme.outline)
                }
                Spacer(Modifier.width(10.dp))
                Text(when (c) {
                    Connection.Idle -> "Not connected"
                    is Connection.Connecting -> "Connecting to ${c.target}…"
                    is Connection.Connected -> "Connected to ${c.peer.name}"
                    is Connection.Reconnecting -> "Reconnecting to ${c.peer.name} (attempt ${c.attempt})…"
                    is Connection.Failed -> "Connection problem"
                }, style = MaterialTheme.typography.titleMedium)
            }
            when (c) {
                is Connection.Connected -> {
                    Text("Encrypted · verification ${c.verificationCode} · key ${c.peer.displayFingerprint}",
                        style = MaterialTheme.typography.bodySmall, color = scheme.onSurfaceVariant, modifier = Modifier.padding(top = 6.dp))
                    TextButton(onClick = onDisconnect, contentPadding = PaddingValues(0.dp)) { Text("Disconnect") }
                }
                is Connection.Failed -> {
                    Text(c.message, style = MaterialTheme.typography.bodySmall, color = scheme.error, modifier = Modifier.padding(top = 6.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 8.dp)) {
                        OutlinedButton(onClick = onConnect) { Text("Try again") }
                        TextButton(onClick = onDismiss) { Text("Dismiss") }
                    }
                }
                Connection.Idle -> Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 12.dp)) {
                    // The longer label gets more room so neither wraps on a ~360 dp screen.
                    val pad = PaddingValues(horizontal = 12.dp, vertical = 10.dp)
                    OutlinedButton(onClick = onConnect, modifier = Modifier.weight(1.4f), contentPadding = pad) {
                        Icon(Icons.Outlined.QrCodeScanner, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp))
                        Text("Connect to Mac", maxLines = 1, softWrap = false)
                    }
                    OutlinedButton(onClick = onReceive, modifier = Modifier.weight(1f), contentPadding = pad) {
                        Icon(Icons.Outlined.Download, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp))
                        Text("Receive", maxLines = 1, softWrap = false)
                    }
                }
                else -> {}
            }
        }
    }
}

@Composable
private fun PeerRow(p: PeerRecord, isConnected: Boolean, onClick: () -> Unit, onForget: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().clickable(enabled = !isConnected, onClick = onClick).padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Outlined.LaptopMac, null, tint = MaterialTheme.colorScheme.primary)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(p.name, style = MaterialTheme.typography.bodyLarge)
            Text(if (isConnected) "Connected" else "Tap to connect · ${p.lastHosts.firstOrNull() ?: "address unknown"}",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            // Two devices can share a name (e.g. a reinstalled Mac app); the key tells them apart.
            Text("Key ${p.displayFingerprint.substringBefore(' ')} · paired ${Format.date(p.pairedAt)}",
                style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        IconButton(onClick = { menu = true }) { Icon(Icons.Outlined.MoreVert, "Options for ${p.name}") }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(text = { Text("Forget device") }, onClick = { menu = false; onForget() })
        }
    }
}
