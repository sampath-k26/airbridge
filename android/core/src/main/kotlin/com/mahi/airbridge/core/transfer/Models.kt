package com.mahi.airbridge.core.transfer

import com.mahi.airbridge.core.crypto.PeerRecord
import com.mahi.airbridge.core.protocol.AbException
import java.io.File
import java.io.FileInputStream
import java.io.InputStream

enum class Direction { SEND, RECEIVE }

/** File entry of an offer (SPEC §6.2). */
data class OfferFile(val id: Int, val path: String, val size: Long, val mtime: Long, val mime: String?)

/** Something to send. Android implements this over content URIs. */
interface SendSource {
    /** Relative path announced to the receiver ("Folder/name.jpg"). */
    val path: String
    val size: Long
    val mtime: Long
    val mime: String?
    fun open(): InputStream
    /** False if the source changed since it was described (size/mtime). */
    fun unchanged(): Boolean = true
}

class FileSource(val file: File, override val path: String = file.name) : SendSource {
    override val size = file.length()
    override val mtime = file.lastModified()
    override val mime: String? = null
    override fun open(): InputStream = FileInputStream(file)
    override fun unchanged() = file.length() == size && file.lastModified() == mtime

    companion object {
        /** Expands files and folders; folders keep their name as the top-level component. */
        fun collect(files: List<File>): List<FileSource> = files.flatMap { f ->
            if (f.isDirectory) {
                f.walkTopDown().filter { it.isFile && it.name != ".DS_Store" }
                    .map { FileSource(it, f.name + "/" + it.relativeTo(f).invariantSeparatorsPath) }.toList()
            } else listOf(FileSource(f))
        }
    }
}

data class IncomingOffer(
    val transferId: String,
    val peer: PeerRecord,
    val files: List<OfferFile>,  // sanitised paths
    val totalBytes: Long,
    val resumedBytes: Long,
)

data class TransferProgress(
    val transferId: String,
    val direction: Direction,
    val totalBytes: Long,
    val bytesDone: Long,
    val fileCount: Int,
    val filesDone: Int,
    val currentFile: String?,
)

data class CompletedFile(val name: String, val savedAs: String?, val size: Long)

data class TransferResult(
    val transferId: String,
    val direction: Direction,
    val files: List<CompletedFile>,
    val failed: Map<String, AbException>,
    val bytes: Long,
    val durationMs: Long,
    val error: AbException?,
) {
    val ok get() = error == null
    val megabytesPerSecond get() = if (durationMs > 0) bytes / 1_000.0 / durationMs else 0.0
}

sealed class SessionEvent {
    data class Offer(val offer: IncomingOffer) : SessionEvent()
    data class Started(val transferId: String, val direction: Direction, val files: List<OfferFile>, val totalBytes: Long) : SessionEvent()
    data class Progress(val progress: TransferProgress) : SessionEvent()
    data class FileDone(val transferId: String, val direction: Direction, val file: CompletedFile) : SessionEvent()
    data class Finished(val result: TransferResult) : SessionEvent()
    data class Closed(val error: AbException?) : SessionEvent()
}
