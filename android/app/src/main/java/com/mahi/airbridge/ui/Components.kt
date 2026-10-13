package com.mahi.airbridge.ui

import android.graphics.Bitmap
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AudioFile
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.FolderZip
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.InsertDriveFile
import androidx.compose.material.icons.outlined.PictureAsPdf
import androidx.compose.material.icons.outlined.VideoFile
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import com.mahi.airbridge.core.transfer.Direction
import com.mahi.airbridge.transfer.TransferStatus
import com.mahi.airbridge.transfer.TransferUi
import com.mahi.airbridge.util.Format

@Composable
fun SectionTitle(text: String, modifier: Modifier = Modifier) {
    Text(text.uppercase(), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = modifier.padding(start = 4.dp, top = 20.dp, bottom = 8.dp))
}

@Composable
fun Panel(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Surface(modifier.fillMaxWidth(), shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surface,
        tonalElevation = 0.dp, shadowElevation = 0.dp,
        border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)) { content() }
}

@Composable
fun StatusDot(color: Color, size: Dp = 10.dp) {
    Box(Modifier.size(size).clip(CircleShape).background(color))
}

fun iconFor(name: String, isFolder: Boolean = false): ImageVector {
    if (isFolder) return Icons.Outlined.Folder
    return when (name.substringAfterLast('.', "").lowercase()) {
        "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "bmp", "dng", "raw" -> Icons.Outlined.Image
        "mp4", "mov", "mkv", "avi", "webm", "3gp", "m4v" -> Icons.Outlined.VideoFile
        "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus" -> Icons.Outlined.AudioFile
        "pdf" -> Icons.Outlined.PictureAsPdf
        "zip", "rar", "7z", "tar", "gz", "xz" -> Icons.Outlined.FolderZip
        "doc", "docx", "txt", "md", "rtf", "pages", "xls", "xlsx", "csv", "ppt", "pptx", "key" -> Icons.Outlined.Description
        else -> Icons.Outlined.InsertDriveFile
    }
}

@Composable
fun TransferRow(t: TransferUi, onCancel: (() -> Unit)?) {
    val scheme = MaterialTheme.colorScheme
    Column(Modifier.fillMaxWidth().animateContentSize().padding(16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(40.dp).clip(RoundedCornerShape(10.dp)).background(scheme.primaryContainer), contentAlignment = Alignment.Center) {
                Icon(iconFor(t.title, t.fileCount > 1 && !t.title.contains('.')), null, tint = scheme.onPrimaryContainer)
            }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(t.title, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.MiddleEllipsis)
                val dir = if (t.direction == Direction.SEND) "To ${t.peerName}" else "From ${t.peerName}"
                val files = if (t.fileCount == 1) "1 file" else "${t.fileCount} files"
                Text("$dir · $files · ${Format.bytes(t.totalBytes)}", style = MaterialTheme.typography.bodySmall,
                    color = scheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            if (onCancel != null && t.isActive) {
                IconButton(onClick = onCancel, modifier = Modifier.semantics { contentDescription = "Cancel transfer" }) {
                    Icon(Icons.Outlined.Close, null)
                }
            }
        }
        when (t.status) {
            TransferStatus.RUNNING, TransferStatus.WAITING, TransferStatus.INTERRUPTED -> {
                Spacer(Modifier.height(12.dp))
                LinearProgressIndicator(progress = { t.fraction }, modifier = Modifier.fillMaxWidth().height(6.dp).clip(CircleShape),
                    trackColor = scheme.surfaceVariant, drawStopIndicator = {})
                Spacer(Modifier.height(8.dp))
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    val left = when (t.status) {
                        TransferStatus.WAITING -> "Waiting for the other device…"
                        TransferStatus.INTERRUPTED -> "Interrupted — resumes on reconnect"
                        else -> "${(t.fraction * 100).toInt()}% · ${Format.bytes(t.bytesDone)}"
                    }
                    Text(left, style = MaterialTheme.typography.labelMedium, color = scheme.onSurfaceVariant)
                    if (t.status == TransferStatus.RUNNING) {
                        Text("${Format.speed(t.currentSpeed)} · ${Format.eta(t.etaSeconds)}", style = MaterialTheme.typography.labelMedium,
                            fontWeight = FontWeight.Medium)
                    }
                }
                if (t.status == TransferStatus.RUNNING) {
                    Text("Average ${Format.speed(t.averageSpeed)}" + (t.currentFile?.let { " · ${it.substringAfterLast('/')}" } ?: ""),
                        style = MaterialTheme.typography.labelSmall, color = scheme.onSurfaceVariant, maxLines = 1,
                        overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 2.dp))
                }
            }
            TransferStatus.DONE -> Text("Completed · verified (SHA-256) · avg ${Format.speed(t.averageSpeed)}",
                style = MaterialTheme.typography.labelMedium, color = scheme.tertiary, modifier = Modifier.padding(top = 8.dp))
            TransferStatus.FAILED -> Text(t.error ?: "Failed", style = MaterialTheme.typography.labelMedium, color = scheme.error,
                modifier = Modifier.padding(top = 8.dp))
            TransferStatus.CANCELLED -> Text("Cancelled", style = MaterialTheme.typography.labelMedium, color = scheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 8.dp))
        }
    }
}

@Composable
fun QrImage(content: String, modifier: Modifier = Modifier) {
    val bmp = remember(content) {
        val m = QRCodeWriter().encode(content, BarcodeFormat.QR_CODE, 0, 0,
            mapOf(EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M, EncodeHintType.MARGIN to 1))
        val b = Bitmap.createBitmap(m.width, m.height, Bitmap.Config.ARGB_8888)
        for (x in 0 until m.width) for (y in 0 until m.height) b.setPixel(x, y, if (m[x, y]) 0xFF000000.toInt() else 0xFFFFFFFF.toInt())
        b.asImageBitmap()
    }
    Image(bmp, contentDescription = "Pairing QR code", modifier = modifier.clip(RoundedCornerShape(12.dp)),
        filterQuality = FilterQuality.None)
}
