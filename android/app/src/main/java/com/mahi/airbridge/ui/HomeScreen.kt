package com.mahi.airbridge.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.CreateNewFolder
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.InsertDriveFile
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.QrCodeScanner
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.UploadFile
import androidx.compose.material.icons.outlined.Wifi
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
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
    onRemove: (String) -> Unit,
    onSettings: () -> Unit,
    onDismissError: () -> Unit,
) {
    val connected = connection is Connection.Connected
    var filter by rememberSaveable { mutableStateOf(TransferFilter.ALL) }
    val items = (active + recent).let { all -> if (filter == TransferFilter.ALL) all else all.filter { it.kind.filter == filter } }.take(40)

    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(
        start = 16.dp, end = 16.dp, top = padding.calculateTopPadding() + 12.dp, bottom = padding.calculateBottomPadding() + 24.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                AppLogo()
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text("AirBridge", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                    Text("Local File Transfer", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                IconButton(onClick = onSettings) { Icon(Icons.Outlined.Settings, "Settings") }
            }
        }
        item { StatusCard(deviceName, connection, onConnect, onReceive, onDisconnect, onDismissError) }
        item { SendCard(connected, (connection as? Connection.Connected)?.peer?.name, onSendFiles, onSendFolder) }
        item { DevicesCard(peers, connection, onConnect, onReconnect, onForget, onDisconnect) }
        item {
            Panel {
                Column {
                    Text("Recent Transfers", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.padding(start = 16.dp, top = 16.dp, end = 16.dp))
                    Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 12.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        TransferFilter.entries.forEach { f -> FilterChip(f.label, f == filter) { filter = f } }
                    }
                    if (items.isEmpty()) {
                        Text(if (filter == TransferFilter.ALL) "Files you send or receive appear here." else "No ${filter.label.lowercase()} yet.",
                            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 20.dp, top = 4.dp))
                    }
                    items.forEachIndexed { i, t ->
                        if (i > 0) HorizontalDivider(Modifier.padding(start = 16.dp), color = MaterialTheme.colorScheme.outlineVariant)
                        TransferRow(t, onCancel = { onCancel(t.id) }, onRemove = { onRemove(t.id) })
                    }
                }
            }
        }
        item { WifiCard() }
    }
}

@Composable
private fun StatusCard(deviceName: String, c: Connection, onConnect: () -> Unit, onReceive: () -> Unit,
                       onDisconnect: () -> Unit, onDismiss: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    Panel {
        Column(Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(24.dp), contentAlignment = Alignment.Center) {
                    when (c) {
                        is Connection.Connecting, is Connection.Reconnecting -> CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                        else -> {
                            val color = if (c is Connection.Failed) StatusColors.Red else StatusColors.Green
                            Box(Modifier.size(24.dp).clip(CircleShape).background(color.copy(alpha = 0.18f)), contentAlignment = Alignment.Center) {
                                StatusDot(color)
                            }
                        }
                    }
                }
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text(when (c) {
                        Connection.Idle -> "Ready"
                        is Connection.Connecting -> "Connecting to ${c.target}…"
                        is Connection.Connected -> "Connected to ${c.peer.name}"
                        is Connection.Reconnecting -> "Reconnecting to ${c.peer.name}…"
                        is Connection.Failed -> "Connection problem"
                    }, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(when (c) {
                        is Connection.Connected -> "Encrypted • verification ${c.verificationCode} • key ${c.peer.displayFingerprint}"
                        is Connection.Failed -> c.message
                        is Connection.Reconnecting -> "Attempt ${c.attempt} • interrupted transfers resume automatically"
                        else -> "$deviceName • files go directly over Wi-Fi"
                    }, style = MaterialTheme.typography.bodySmall, color = if (c is Connection.Failed) scheme.error else scheme.onSurfaceVariant)
                }
            }
            val pad = PaddingValues(horizontal = 12.dp, vertical = 10.dp)
            when (c) {
                Connection.Idle -> Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 14.dp)) {
                    // The longer label gets more room so neither wraps on a ~360 dp screen.
                    Button(onClick = onConnect, modifier = Modifier.weight(1.4f), contentPadding = pad, shape = RoundedCornerShape(10.dp)) {
                        Icon(Icons.Outlined.QrCodeScanner, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp))
                        Text("Connect to Mac", maxLines = 1, softWrap = false)
                    }
                    OutlinedButton(onClick = onReceive, modifier = Modifier.weight(1f), contentPadding = pad, shape = RoundedCornerShape(10.dp)) {
                        Icon(Icons.Outlined.Download, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp))
                        Text("Receive", maxLines = 1, softWrap = false)
                    }
                }
                is Connection.Connected -> OutlinedButton(onClick = onDisconnect, modifier = Modifier.padding(top = 12.dp),
                    shape = RoundedCornerShape(10.dp)) { Text("Disconnect") }
                is Connection.Failed -> Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 12.dp)) {
                    OutlinedButton(onClick = onConnect, shape = RoundedCornerShape(10.dp)) { Text("Try again") }
                    TextButton(onClick = onDismiss) { Text("Dismiss") }
                }
                else -> {}
            }
        }
    }
}

@Composable
private fun SendCard(connected: Boolean, peerName: String?, onSendFiles: () -> Unit, onSendFolder: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    DashedPanel {
        Column(Modifier.fillMaxWidth().padding(vertical = 22.dp, horizontal = 16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(Icons.Outlined.UploadFile, null, tint = if (connected) scheme.primary else scheme.onSurfaceVariant, modifier = Modifier.size(40.dp))
            Spacer(Modifier.height(8.dp))
            Text(if (connected) "Send files" else "Connect to send files", style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold)
            Text(if (connected) "Choose files to send to ${peerName ?: "your Mac"}"
                else "Files go directly over Wi-Fi, never through the internet.",
                style = MaterialTheme.typography.bodyMedium, color = scheme.onSurfaceVariant, textAlign = TextAlign.Center)
            Spacer(Modifier.height(14.dp))
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = onSendFiles, enabled = connected, shape = RoundedCornerShape(10.dp),
                    contentPadding = PaddingValues(horizontal = 20.dp, vertical = 10.dp)) {
                    Icon(Icons.Outlined.InsertDriveFile, null, Modifier.size(18.dp)); Spacer(Modifier.width(8.dp)); Text("Choose Files")
                }
                FilledTonalIconButton(onClick = onSendFolder, enabled = connected, shape = RoundedCornerShape(10.dp),
                    modifier = Modifier.size(44.dp)) { Icon(Icons.Outlined.CreateNewFolder, "Send folder") }
            }
        }
    }
}

@Composable
private fun DevicesCard(peers: List<PeerRecord>, c: Connection, onAdd: () -> Unit, onReconnect: (PeerRecord) -> Unit,
                        onForget: (PeerRecord) -> Unit, onDisconnect: () -> Unit) {
    Panel {
        Column(Modifier.padding(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Paired Devices", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                Box(Modifier.size(32.dp).clip(CircleShape).border(1.dp, MaterialTheme.colorScheme.outline, CircleShape)
                    .clickable(onClick = onAdd, role = Role.Button), contentAlignment = Alignment.Center) {
                    Icon(Icons.Outlined.Add, "Pair new device", Modifier.size(18.dp))
                }
            }
            Spacer(Modifier.height(10.dp))
            if (peers.isEmpty()) {
                Text("No paired devices yet. Open AirBridge on your Mac, click Pair New Device and scan its QR code.",
                    style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                peers.forEach { p ->
                    val state = when {
                        c is Connection.Connected && c.peer.deviceId == p.deviceId -> PeerState.CONNECTED
                        c is Connection.Reconnecting && c.peer.deviceId == p.deviceId -> PeerState.CONNECTING
                        c is Connection.Connecting && c.target == p.name -> PeerState.CONNECTING
                        else -> PeerState.OFFLINE
                    }
                    PeerRow(p, state, onClick = { onReconnect(p) }, onForget = { onForget(p) }, onDisconnect = onDisconnect)
                }
            }
        }
    }
}

private enum class PeerState(val text: String) { CONNECTED("Connected"), CONNECTING("Connecting…"), OFFLINE("Not connected") }

@Composable
private fun PeerRow(p: PeerRecord, state: PeerState, onClick: () -> Unit, onForget: () -> Unit, onDisconnect: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    var menu by remember { mutableStateOf(false) }
    val connected = state == PeerState.CONNECTED
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
        .background(if (connected) scheme.primaryContainer.copy(alpha = 0.7f) else scheme.surfaceVariant.copy(alpha = 0.6f))
        .clickable(enabled = state == PeerState.OFFLINE, onClick = onClick)
        .semantics { selected = connected }
        .padding(start = 12.dp, top = 10.dp, bottom = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        DeviceTile(p.platform, 36.dp, seed = p.deviceId)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(p.name, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Row(verticalAlignment = Alignment.CenterVertically) {
                StatusDot(when (state) { PeerState.CONNECTED -> StatusColors.Green; PeerState.CONNECTING -> StatusColors.Orange; else -> scheme.outline }, 8.dp)
                Spacer(Modifier.width(5.dp))
                Text(if (state == PeerState.OFFLINE) "Not connected • tap to connect" else state.text, style = MaterialTheme.typography.bodySmall,
                    color = if (connected) StatusColors.Green else scheme.onSurfaceVariant)
            }
            // Two devices can share a name (e.g. a reinstalled Mac app); the key tells them apart.
            Text("Key ${p.displayFingerprint.substringBefore(' ')} • paired ${Format.date(p.pairedAt)}",
                style = MaterialTheme.typography.labelSmall, color = scheme.onSurfaceVariant)
        }
        Box {
            IconButton(onClick = { menu = true }) { Icon(Icons.Outlined.MoreVert, "Options for ${p.name}") }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                if (connected) DropdownMenuItem(text = { Text("Disconnect") }, onClick = { menu = false; onDisconnect() })
                else DropdownMenuItem(text = { Text("Connect") }, onClick = { menu = false; onClick() })
                DropdownMenuItem(text = { Text("Forget device") }, onClick = { menu = false; onForget() })
            }
        }
    }
}

@Composable
private fun FilterChip(label: String, selected: Boolean, onClick: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    Text(label, style = MaterialTheme.typography.labelLarge, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
        color = if (selected) scheme.primary else scheme.onSurface,
        modifier = Modifier.clip(RoundedCornerShape(8.dp))
            .background(if (selected) scheme.primaryContainer else scheme.surfaceVariant)
            .clickable(onClick = onClick, role = Role.Tab)
            .semantics { this.selected = selected }
            .padding(horizontal = 14.dp, vertical = 7.dp))
}

@Composable
private fun WifiCard() {
    val scheme = MaterialTheme.colorScheme
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(scheme.surfaceVariant.copy(alpha = 0.6f)).padding(14.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(40.dp).clip(CircleShape).background(scheme.primaryContainer), contentAlignment = Alignment.Center) {
            Icon(Icons.Outlined.Wifi, null, tint = scheme.primary)
        }
        Spacer(Modifier.width(12.dp))
        Column {
            Text("Direct Wi-Fi", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
            Text("No internet required • Fast • Private • Secure", style = MaterialTheme.typography.bodySmall, color = scheme.onSurfaceVariant)
        }
    }
}

