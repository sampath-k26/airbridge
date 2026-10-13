package com.mahi.airbridge.ui

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SecondaryTabRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import com.mahi.airbridge.app.Settings
import com.mahi.airbridge.core.protocol.AbProtocol
import com.mahi.airbridge.core.protocol.PairingCode
import com.mahi.airbridge.core.protocol.PairingUri
import com.mahi.airbridge.network.HotspotController
import com.mahi.airbridge.pairing.QrScanner
import com.mahi.airbridge.transfer.SessionManager
import kotlinx.coroutines.delay

@Composable
fun ScreenHeader(title: String, onBack: () -> Unit, actions: @Composable () -> Unit = {}) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
        IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back") }
        Text(title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
        actions()
    }
}

@Composable
fun ConnectScreen(
    padding: PaddingValues,
    hotspot: HotspotController.State,
    onScanned: (PairingUri) -> Unit,
    onManual: (host: String, port: Int, code: String?) -> Unit,
    onStartHotspot: () -> Unit,
    onStopHotspot: () -> Unit,
    onBack: () -> Unit,
) {
    val context = LocalContext.current
    var tab by rememberSaveable { mutableStateOf(0) }
    var hasCamera by remember {
        mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED)
    }
    val camPerm = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { hasCamera = it }
    Column(Modifier.fillMaxSize().padding(padding).padding(horizontal = 16.dp).verticalScroll(rememberScrollState())) {
        ScreenHeader("Connect to Mac", onBack)
        SecondaryTabRow(selectedTabIndex = tab) {
            Tab(tab == 0, { tab = 0 }, text = { Text("Scan QR") })
            Tab(tab == 1, { tab = 1 }, text = { Text("Enter code") })
        }
        Spacer(Modifier.height(16.dp))
        if (tab == 0) {
            Text("On your Mac, open AirBridge and click “Pair new device”. Point the camera at the QR code.",
                style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.height(12.dp))
            Box(Modifier.fillMaxWidth().aspectRatio(1f).clip(MaterialTheme.shapes.large), contentAlignment = Alignment.Center) {
                if (hasCamera) {
                    QrScanner(Modifier.fillMaxSize(), accept = { PairingUri.parse(it) != null }) { text ->
                        PairingUri.parse(text)?.let(onScanned)
                    }
                } else {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text("Camera access is needed to scan the code.", style = MaterialTheme.typography.bodyMedium)
                        Button(onClick = { camPerm.launch(Manifest.permission.CAMERA) }, modifier = Modifier.padding(top = 8.dp)) {
                            Text("Allow camera")
                        }
                        TextButton(onClick = { tab = 1 }) { Text("Enter the code instead") }
                    }
                }
            }
        } else {
            var host by rememberSaveable { mutableStateOf("") }
            var port by rememberSaveable { mutableStateOf(AbProtocol.DEFAULT_PORT.toString()) }
            var code by rememberSaveable { mutableStateOf("") }
            Text("Type the address and code shown on the Mac. Then compare the 6-digit verification number on both screens.",
                style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.height(12.dp))
            OutlinedTextField(host, { host = it.trim() }, label = { Text("Mac address (e.g. 172.20.10.2)") }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri), modifier = Modifier.fillMaxWidth())
            OutlinedTextField(port, { port = it.filter(Char::isDigit).take(5) }, label = { Text("Port") }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), modifier = Modifier.fillMaxWidth().padding(top = 8.dp))
            OutlinedTextField(code, { code = it.take(11) }, label = { Text("Pairing code (leave empty if already paired)") }, singleLine = true,
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters),
                isError = code.isNotEmpty() && PairingCode.normalize(code) == null,
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp))
            Button(onClick = { onManual(host, port.toIntOrNull() ?: AbProtocol.DEFAULT_PORT, code.ifBlank { null }) },
                enabled = host.isNotBlank() && (code.isBlank() || PairingCode.normalize(code) != null),
                modifier = Modifier.fillMaxWidth().padding(top = 16.dp).height(50.dp)) { Text("Connect") }
        }
        SectionTitle("No shared Wi-Fi?")
        HotspotPanel(hotspot, onStartHotspot, onStopHotspot)
    }
}

@Composable
private fun HotspotPanel(state: HotspotController.State, onStart: () -> Unit, onStop: () -> Unit) {
    val context = LocalContext.current
    val perm = if (Build.VERSION.SDK_INT >= 33) Manifest.permission.NEARBY_WIFI_DEVICES else Manifest.permission.ACCESS_FINE_LOCATION
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { if (it) onStart() }
    Panel {
        Column(Modifier.padding(16.dp)) {
            Text("Recommended: turn on this phone's Wi-Fi hotspot (Settings → Hotspot) and join it from the Mac. " +
                "No internet or mobile data is used for transfers.", style = MaterialTheme.typography.bodyMedium)
            Spacer(Modifier.height(8.dp))
            Text("Or create a temporary local-only hotspot from AirBridge:", style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            when (state) {
                is HotspotController.State.On -> {
                    Text("Network: ${state.ssid}", fontFamily = FontFamily.Monospace, modifier = Modifier.padding(top = 8.dp))
                    Text("Password: ${state.passphrase ?: "—"}", fontFamily = FontFamily.Monospace)
                    Text("Join this network on the Mac, then pair. It stops when you tap Stop or leave AirBridge.",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    OutlinedButton(onClick = onStop, modifier = Modifier.padding(top = 8.dp)) { Text("Stop hotspot") }
                }
                HotspotController.State.Starting -> Text("Starting…", modifier = Modifier.padding(top = 8.dp))
                is HotspotController.State.Failed -> {
                    Text(state.reason, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 8.dp))
                    OutlinedButton(onClick = onStart, modifier = Modifier.padding(top = 8.dp)) { Text("Try again") }
                }
                HotspotController.State.Off -> OutlinedButton(modifier = Modifier.padding(top = 8.dp), onClick = {
                    if (ContextCompat.checkSelfPermission(context, perm) == PackageManager.PERMISSION_GRANTED) onStart() else launcher.launch(perm)
                }) { Text("Start local-only hotspot") }
            }
        }
    }
}

@Composable
fun ReceiveScreen(padding: PaddingValues, info: SessionManager.ListenInfo?, connection: SessionManager.Connection,
                  onRefresh: () -> Unit, onBack: () -> Unit) {
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) { while (true) { delay(1000); now = System.currentTimeMillis() } }
    Column(Modifier.fillMaxSize().padding(padding).padding(horizontal = 16.dp).verticalScroll(rememberScrollState()),
        horizontalAlignment = Alignment.CenterHorizontally) {
        ScreenHeader("Receive", onBack) { IconButton(onClick = onRefresh) { Icon(Icons.Outlined.Refresh, "New code") } }
        if (connection is SessionManager.Connection.Connected) {
            Text("Connected to ${connection.peer.name}. Files sent from the Mac appear in your transfers.",
                style = MaterialTheme.typography.bodyLarge, modifier = Modifier.padding(16.dp))
            return@Column
        }
        if (info == null) { Text("Starting…", modifier = Modifier.padding(24.dp)); return@Column }
        val left = ((info.code.expiresAt - now) / 1000).coerceAtLeast(0)
        Text("In AirBridge on the Mac choose “Connect to device” and enter:", style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(vertical = 8.dp))
        Panel {
            Column(Modifier.padding(20.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text("Pairing code", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(info.code.display, fontSize = 32.sp, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.SemiBold)
                Text(if (left > 0) "Expires in ${left / 60}:${"%02d".format(left % 60)}" else "Expired — tap refresh",
                    style = MaterialTheme.typography.labelMedium,
                    color = if (left > 0) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.error)
                Spacer(Modifier.height(12.dp))
                Text("Address", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (info.addresses.isEmpty()) Text("No Wi-Fi or hotspot network", color = MaterialTheme.colorScheme.error)
                info.addresses.forEach { a ->
                    Text("${a.ip}  port ${info.port}", fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.titleMedium)
                }
            }
        }
        Spacer(Modifier.height(16.dp))
        QrImage(info.uri, Modifier.size(220.dp))
        Text("The code works once and expires after 5 minutes.", style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(16.dp))
    }
}

@Composable
fun SettingsScreen(
    padding: PaddingValues,
    values: Settings.Values,
    fingerprint: String,
    onUpdate: ((Settings.Values) -> Settings.Values) -> Unit,
    onPickDestination: () -> Unit,
    onClearHistory: () -> Unit,
    onBack: () -> Unit,
) {
    var name by remember(values.deviceName) { mutableStateOf(values.deviceName) }
    Column(Modifier.fillMaxSize().padding(padding).padding(horizontal = 16.dp).verticalScroll(rememberScrollState())) {
        ScreenHeader("Settings", onBack)
        SectionTitle("This device")
        Panel {
            Column(Modifier.padding(16.dp)) {
                OutlinedTextField(name, { name = it.take(40) }, label = { Text("Device name") }, singleLine = true,
                    modifier = Modifier.fillMaxWidth())
                TextButton(onClick = { onUpdate { it.copy(deviceName = name.ifBlank { it.deviceName }) } }) { Text("Save name") }
                Text("Identity key: $fingerprint", style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        SectionTitle("Receiving")
        Panel {
            Column(Modifier.padding(16.dp)) {
                Text("Save files to", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(values.destinationTree?.lastPathSegment?.substringAfter(':')?.let { "Folder: $it" } ?: "Downloads/AirBridge",
                    style = MaterialTheme.typography.bodyLarge)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(onClick = onPickDestination) { Text("Choose folder") }
                    if (values.destinationTree != null) TextButton(onClick = { onUpdate { it.copy(destinationTree = null) } }) { Text("Use Downloads") }
                }
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 8.dp)) {
                    Column(Modifier.weight(1f)) {
                        Text("Ask before receiving", style = MaterialTheme.typography.bodyLarge)
                        Text("Paired devices can send without asking when off.", style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Switch(values.askBeforeReceiving, { v -> onUpdate { it.copy(askBeforeReceiving = v) } })
                }
            }
        }
        SectionTitle("Performance")
        Panel {
            Column(Modifier.padding(16.dp)) {
                Text("Chunk size", style = MaterialTheme.typography.bodyLarge)
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    listOf(64 * 1024 to "64K", 256 * 1024 to "256K", 1024 * 1024 to "1M", 4 * 1024 * 1024 to "4M").forEach { (v, l) ->
                        if (values.chunkSize == v) Button(onClick = {}) { Text(l) } else OutlinedButton(onClick = { onUpdate { it.copy(chunkSize = v) } }) { Text(l) }
                    }
                }
                Text("1M is the default; see docs/performance.md for measurements.", style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        SectionTitle("History")
        Panel { TextButton(onClick = onClearHistory, modifier = Modifier.padding(8.dp)) { Text("Clear transfer history") } }
        Spacer(Modifier.height(32.dp))
    }
}
