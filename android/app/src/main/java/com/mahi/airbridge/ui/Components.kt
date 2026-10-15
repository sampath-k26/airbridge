package com.mahi.airbridge.ui

import android.graphics.Bitmap
import android.text.format.DateUtils
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.AudioFile
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.FolderZip
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.InsertDriveFile
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.PictureAsPdf
import androidx.compose.material.icons.outlined.SmartDisplay
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
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

/** Status colors shared by both themes (same as the Mac app). */
object StatusColors {
    val Green = Color(0xFF21A853)
    val Red = Color(0xFFE53935)
    val Orange = Color(0xFFF28C1A)
}

@Composable
fun SectionTitle(text: String, modifier: Modifier = Modifier) {
    Text(text.uppercase(), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = modifier.padding(start = 4.dp, top = 20.dp, bottom = 8.dp))
}

@Composable
fun Panel(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Surface(modifier.fillMaxWidth(), shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surface,
        tonalElevation = 0.dp, shadowElevation = 0.dp,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)) { content() }
}

/** Card with a dashed outline, like the Mac app's drop zone. */
@Composable
fun DashedPanel(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    val color = MaterialTheme.colorScheme.outline
    Box(modifier.fillMaxWidth()
        .clip(MaterialTheme.shapes.large)
        .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.6f))
        .drawBehind {
            val r = 20.dp.toPx()
            drawRoundRect(color, cornerRadius = CornerRadius(r, r),
                style = Stroke(width = 1.5.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(14f, 12f))))
        }) { content() }
}

@Composable
fun StatusDot(color: Color, size: Dp = 10.dp) {
    Box(Modifier.size(size).clip(CircleShape).background(color))
}

/** Rounded status badge ("Completed", "Error", …). */
@Composable
fun Pill(text: String, color: Color) {
    Text(text, style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.Medium, color = color, maxLines = 1,
        modifier = Modifier.clip(RoundedCornerShape(7.dp)).background(color.copy(alpha = 0.10f))
            .border(1.dp, color.copy(alpha = 0.35f), RoundedCornerShape(7.dp))
            .padding(horizontal = 9.dp, vertical = 3.dp))
}

/** App logo: the launcher artwork on its blue gradient. */
@Composable
fun AppLogo(size: Dp = 44.dp) {
    Box(Modifier.size(size).clip(RoundedCornerShape(size * 0.26f))
        .background(Brush.linearGradient(listOf(Color(0xFF3385FA), Color(0xFF1254D1)))), contentAlignment = Alignment.Center) {
        Icon(androidx.compose.ui.res.painterResource(com.mahi.airbridge.R.drawable.ic_launcher_foreground), null,
            tint = Color.Unspecified, modifier = Modifier.size(size * 1.5f))
    }
}

private val Wallpapers = listOf(
    listOf(Color(0xFF5C45D9), Color(0xFF338CFA), Color(0xFFFA8C59)),
    listOf(Color(0xFF0D4DD9), Color(0xFF26B3FA)),
    listOf(Color(0xFFD9408C), Color(0xFF7340E6)),
    listOf(Color(0xFF0D8C8C), Color(0xFF3373F2)),
)

/** Small drawn picture of the device (a laptop for a Mac, a phone otherwise); the wallpaper comes from [seed]. */
@Composable
fun DeviceTile(platform: String, size: Dp = 40.dp, seed: String = "") {
    val wallpaper = Brush.verticalGradient(Wallpapers[(seed.hashCode() and 0x7FFFFFFF) % Wallpapers.size])
    Box(Modifier.size(width = size, height = size * 1.15f), contentAlignment = Alignment.Center) {
        if (platform == "android") {
            Box(Modifier.size(width = size * 0.58f, height = size * 1.12f).clip(RoundedCornerShape(size * 0.12f))
                .background(Color(0xFF1C1C1E)).padding(2.dp).clip(RoundedCornerShape(size * 0.09f)).background(wallpaper))
        } else {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Box(Modifier.size(width = size * 0.8f, height = size * 0.52f).clip(RoundedCornerShape(3.dp))
                    .background(Color(0xFF26262A)).padding(2.dp).clip(RoundedCornerShape(2.dp)).background(wallpaper))
                Box(Modifier.size(width = size, height = size * 0.07f).clip(RoundedCornerShape(2.dp)).background(Color(0xFFB4B4B8)))
            }
        }
    }
}

// MARK: file kinds

enum class FileKind(val label: String, val icon: ImageVector, val tint: Color) {
    IMAGE("Image", Icons.Outlined.Image, Color(0xFF2973F5)),
    VIDEO("Video", Icons.Outlined.SmartDisplay, Color(0xFF8C45ED)),
    AUDIO("Audio", Icons.Outlined.AudioFile, Color(0xFFE8458C)),
    PDF("Document", Icons.Outlined.PictureAsPdf, Color(0xFFE53935)),
    DOCUMENT("Document", Icons.Outlined.Description, Color(0xFF3380D9)),
    ARCHIVE("Archive", Icons.Outlined.FolderZip, Color(0xFFED8C21)),
    FOLDER("Folder", Icons.Outlined.Folder, Color(0xFF219ECC)),
    OTHER("File", Icons.Outlined.InsertDriveFile, Color(0xFF737F94));

    val filter: TransferFilter get() = when (this) {
        IMAGE -> TransferFilter.IMAGES
        VIDEO -> TransferFilter.VIDEOS
        PDF, DOCUMENT -> TransferFilter.DOCUMENTS
        else -> TransferFilter.OTHER
    }

    companion object {
        fun of(name: String, fileCount: Int): FileKind = when (name.substringAfterLast('.', "").lowercase()) {
            "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "bmp", "dng", "tiff" -> IMAGE
            "mp4", "mov", "mkv", "avi", "webm", "3gp", "m4v" -> VIDEO
            "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus" -> AUDIO
            "pdf" -> PDF
            "doc", "docx", "txt", "md", "rtf", "pages", "xls", "xlsx", "csv", "ppt", "pptx", "key", "odt", "epub", "numbers" -> DOCUMENT
            "zip", "rar", "7z", "tar", "gz", "xz", "apk", "dmg" -> ARCHIVE
            "" -> if (fileCount > 1) FOLDER else OTHER
            else -> OTHER
        }
    }
}

enum class TransferFilter(val label: String) { ALL("All"), IMAGES("Images"), VIDEOS("Videos"), DOCUMENTS("Documents"), OTHER("Other") }

/** First top-level name, without the " + N more" suffix. */
val TransferUi.primaryName: String
    get() = if (title.endsWith(" more") && title.contains(" + ")) title.substringBeforeLast(" + ") else title

val TransferUi.kind: FileKind get() = FileKind.of(primaryName, fileCount)

@Composable
fun FileTile(kind: FileKind, size: Dp = 46.dp) {
    val solid = kind == FileKind.PDF
    Box(Modifier.size(size).clip(RoundedCornerShape(11.dp)).background(if (solid) kind.tint else kind.tint.copy(alpha = 0.14f)),
        contentAlignment = Alignment.Center) {
        Icon(kind.icon, null, tint = if (solid) Color.White else kind.tint, modifier = Modifier.size(size * 0.5f))
    }
}

fun relativeTime(millis: Long, now: Long = System.currentTimeMillis()): String =
    if (now - millis < 60_000) "Just now"
    else DateUtils.getRelativeTimeSpanString(millis, now, DateUtils.MINUTE_IN_MILLIS, DateUtils.FORMAT_ABBREV_RELATIVE).toString()

@Composable
fun TransferRow(t: TransferUi, onCancel: () -> Unit, onRemove: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    var menu by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().animateContentSize().padding(start = 16.dp, end = 4.dp, top = 12.dp, bottom = 12.dp)) {
        FileTile(t.kind)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(t.title, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.MiddleEllipsis)
            val dir = if (t.direction == Direction.SEND) "To ${t.peerName}" else "From ${t.peerName}"
            val what = if (t.fileCount == 1) t.kind.label else "${t.fileCount} files"
            Text("$dir • $what • ${Format.bytes(t.totalBytes)}", style = MaterialTheme.typography.bodySmall,
                color = scheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Spacer(Modifier.height(4.dp))
            when (t.status) {
                TransferStatus.RUNNING, TransferStatus.WAITING, TransferStatus.INTERRUPTED -> {
                    LinearProgressIndicator(progress = { t.fraction }, modifier = Modifier.fillMaxWidth().padding(top = 4.dp).height(6.dp).clip(CircleShape),
                        trackColor = scheme.surfaceVariant, drawStopIndicator = {})
                    Text(when (t.status) {
                        TransferStatus.WAITING -> "Waiting for the other device…"
                        TransferStatus.INTERRUPTED -> "Interrupted — resumes on reconnect"
                        else -> "${(t.fraction * 100).toInt()}% • ${Format.speed(t.currentSpeed)} • ${Format.eta(t.etaSeconds)}"
                    }, style = MaterialTheme.typography.labelMedium,
                        color = if (t.status == TransferStatus.INTERRUPTED) StatusColors.Orange else scheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = 6.dp))
                }
                TransferStatus.DONE -> StatusLine(Icons.Filled.CheckCircle, "Completed • ${Format.speed(t.averageSpeed)}", StatusColors.Green)
                TransferStatus.FAILED -> StatusLine(Icons.Filled.Warning, t.error ?: "Failed", StatusColors.Red)
                TransferStatus.CANCELLED -> Text("Cancelled", style = MaterialTheme.typography.labelMedium, color = scheme.onSurfaceVariant)
            }
        }
        Spacer(Modifier.width(8.dp))
        Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(6.dp)) {
            when (t.status) {
                TransferStatus.DONE -> Pill("Completed", StatusColors.Green)
                TransferStatus.FAILED -> Pill("Error", StatusColors.Red)
                TransferStatus.CANCELLED -> Pill("Cancelled", scheme.onSurfaceVariant)
                TransferStatus.INTERRUPTED -> Pill("Paused", StatusColors.Orange)
                TransferStatus.WAITING -> Pill("Waiting", scheme.onSurfaceVariant)
                TransferStatus.RUNNING -> Pill(if (t.direction == Direction.SEND) "Sending" else "Receiving", scheme.primary)
            }
            if (!t.isActive) {
                Text(relativeTime(t.finishedAt ?: t.startedAt), style = MaterialTheme.typography.labelSmall, color = scheme.onSurfaceVariant)
            }
        }
        Box {
            if (t.isActive) {
                IconButton(onClick = onCancel, modifier = Modifier.size(36.dp).semantics { contentDescription = "Cancel transfer" }) {
                    Icon(Icons.Outlined.Close, null, modifier = Modifier.size(20.dp))
                }
            } else {
                IconButton(onClick = { menu = true }, modifier = Modifier.size(36.dp)) {
                    Icon(Icons.Outlined.MoreVert, "Options for ${t.title}", modifier = Modifier.size(20.dp))
                }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text("Remove from history") }, onClick = { menu = false; onRemove() })
                }
            }
        }
    }
}

@Composable
private fun StatusLine(icon: ImageVector, text: String, color: Color) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = color, modifier = Modifier.size(15.dp))
        Spacer(Modifier.width(5.dp))
        Text(text, style = MaterialTheme.typography.labelMedium, color = color, maxLines = 2, overflow = TextOverflow.Ellipsis)
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
