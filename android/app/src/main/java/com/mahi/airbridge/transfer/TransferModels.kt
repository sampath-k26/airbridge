package com.mahi.airbridge.transfer

import com.mahi.airbridge.core.protocol.Json
import com.mahi.airbridge.core.transfer.Direction
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import java.io.File

enum class TransferStatus { WAITING, RUNNING, DONE, FAILED, CANCELLED, INTERRUPTED }

/** Everything the UI shows about one transfer. Values come from measured progress only. */
data class TransferUi(
    val id: String,
    val direction: Direction,
    val peerName: String,
    val title: String,
    val fileCount: Int,
    val totalBytes: Long,
    val bytesDone: Long = 0,
    val status: TransferStatus = TransferStatus.WAITING,
    val currentFile: String? = null,
    val currentSpeed: Double? = null,   // bytes/s, sliding window
    val averageSpeed: Double? = null,   // bytes/s, whole transfer
    val etaSeconds: Long? = null,
    val error: String? = null,
    val savedTo: List<String> = emptyList(),
    val startedAt: Long = System.currentTimeMillis(),
    val finishedAt: Long? = null,
) {
    val fraction: Float get() = if (totalBytes > 0) (bytesDone.toFloat() / totalBytes).coerceIn(0f, 1f) else if (status == TransferStatus.DONE) 1f else 0f
    val isActive get() = status == TransferStatus.WAITING || status == TransferStatus.RUNNING || status == TransferStatus.INTERRUPTED
}

/** Persistent list of finished transfers (most recent first, max 100). */
class TransferHistory(private val file: File) {
    @get:Synchronized
    var items: List<TransferUi> = load(); private set

    private fun load(): List<TransferUi> = runCatching {
        Json.parseArray(file.readText()).mapNotNull { e ->
            val o = e as JsonObject
            TransferUi(
                id = Json.str(o, "id"), direction = Direction.valueOf(Json.str(o, "direction")),
                peerName = Json.str(o, "peer"), title = Json.str(o, "title"), fileCount = Json.int(o, "files"),
                totalBytes = Json.long(o, "total"), bytesDone = Json.long(o, "done"),
                status = TransferStatus.valueOf(Json.str(o, "status")), averageSpeed = Json.optStr(o, "avg")?.toDoubleOrNull(),
                error = Json.optStr(o, "error"), savedTo = Json.strList(o, "saved"),
                startedAt = Json.long(o, "started"), finishedAt = Json.optLong(o, "finished"),
            )
        }
    }.getOrDefault(emptyList())

    @Synchronized
    fun add(t: TransferUi) {
        items = (listOf(t) + items.filter { it.id != t.id }).take(100)
        save()
    }

    private fun save() {
        runCatching {
            file.writeText(JsonArray(items.map {
                Json.obj("id" to it.id, "direction" to it.direction.name, "peer" to it.peerName, "title" to it.title,
                    "files" to it.fileCount, "total" to it.totalBytes, "done" to it.bytesDone, "status" to it.status.name,
                    "avg" to it.averageSpeed?.toString(), "error" to it.error, "saved" to it.savedTo.take(20),
                    "started" to it.startedAt, "finished" to it.finishedAt)
            }).toString())
        }
    }

    @Synchronized
    fun remove(id: String) {
        items = items.filter { it.id != id }
        save()
    }

    @Synchronized
    fun clear() { items = emptyList(); file.delete() }
}
