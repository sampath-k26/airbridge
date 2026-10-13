package com.mahi.airbridge.core.storage

import com.mahi.airbridge.core.protocol.AbException
import com.mahi.airbridge.core.protocol.ErrorCode
import com.mahi.airbridge.core.protocol.Json
import com.mahi.airbridge.core.protocol.PathSanitizer
import com.mahi.airbridge.core.transfer.OfferFile
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.file.FileAlreadyExistsException
import java.nio.file.Files

/** Where incoming files go. Implementations must never overwrite existing files. */
interface ReceiveStorage {
    fun availableBytes(): Long?
    /** Bytes kept from an interrupted attempt of the same transfer (SPEC §8), else 0. */
    fun resumableOffset(transferId: String, peerId: String, file: OfferFile): Long
    fun openWriter(transferId: String, peerId: String, file: OfferFile, offset: Long): IncomingFileWriter
    /** Removes all partial data of a transfer (explicit cancel / failure). */
    fun discard(transferId: String)
    /** Removes bookkeeping once a transfer completed. */
    fun finish(transferId: String)
}

interface IncomingFileWriter {
    /** Streams the bytes written so far from offset 0 (verifies what is on disk). */
    fun readPrefix(consumer: (ByteArray, Int, Int) -> Unit)
    fun write(buf: ByteArray, off: Int, len: Int)
    /** Syncs and publishes the file under a unique final name; returns its display location. */
    fun finish(): String
    /** Closes; `keep` leaves the partial for a later resume. */
    fun close(keep: Boolean)
}

/** Maps a write IOException to a typed error (ENOSPC → insufficient storage). */
fun ioError(e: IOException): AbException =
    if (e.message?.contains("ENOSPC") == true || e.message?.contains("No space left", ignoreCase = true) == true) {
        AbException(ErrorCode.INSUFFICIENT_STORAGE, "Disk full", e)
    } else AbException(ErrorCode.WRITE_FAILED, e.message ?: "write failed", e)

/** Transfer IDs are untrusted: keep only safe characters for use in file names. */
fun safeId(id: String) = id.filter { it.isLetterOrDigit() && it.code < 128 || it == '-' }.take(64).ifEmpty { "invalid" }

/**
 * Plain filesystem storage (JVM CLI/tests). Layout mirrors the macOS app:
 * `<dest>/.airbridge-partial/<transferId>/<fileId>.part` + `.json`.
 */
class FileSystemStorage(val destination: File) : ReceiveStorage {
    private val partialRoot = File(destination, ".airbridge-partial")

    private fun dir(id: String) = File(partialRoot, safeId(id))

    override fun availableBytes(): Long? = destination.apply { mkdirs() }.usableSpace

    override fun resumableOffset(transferId: String, peerId: String, file: OfferFile): Long {
        val meta = File(dir(transferId), "${file.id}.json")
        val part = File(dir(transferId), "${file.id}.part")
        if (!meta.exists() || !part.exists()) return 0
        val m = runCatching { Json.parseObject(meta.readText()) }.getOrNull() ?: return 0
        val ok = Json.optStr(m, "peerId") == peerId && Json.optStr(m, "path") == file.path &&
            Json.optLong(m, "size") == file.size && Json.optLong(m, "mtime") == file.mtime
        return if (ok) minOf(part.length(), file.size) else 0
    }

    override fun openWriter(transferId: String, peerId: String, file: OfferFile, offset: Long): IncomingFileWriter {
        try {
            val d = dir(transferId).apply { mkdirs() }
            File(d, "${file.id}.json").writeText(Json.obj("peerId" to peerId, "path" to file.path,
                "size" to file.size, "mtime" to file.mtime).toString())
            val part = File(d, "${file.id}.part")
            val raf = RandomAccessFile(part, "rw")
            raf.setLength(offset)
            raf.seek(offset)
            return FsWriter(raf, part, File(d, "${file.id}.json"), finalTarget(transferId, file.path))
        } catch (e: IOException) {
            throw ioError(e)
        }
    }

    /** Remaps a conflicting top-level folder once per transfer ("Photos" → "Photos (1)"). */
    @Synchronized
    private fun finalTarget(transferId: String, path: String): File {
        val comps = path.split("/").toMutableList()
        if (comps.size == 1) return File(destination, path)
        val metaFile = File(dir(transferId), "transfer.json")
        val map = runCatching { Json.parseObject(metaFile.readText()) }.getOrNull()?.toMutableMap() ?: mutableMapOf()
        val mapped = (map[comps[0]] as? JsonPrimitive)?.content
            ?: PathSanitizer.uniqueName(comps[0]) { File(destination, it).exists() }.also {
                map[comps[0]] = JsonPrimitive(it)
                metaFile.writeText(JsonObject(map).toString())
            }
        comps[0] = mapped
        return File(destination, comps.joinToString("/"))
    }

    override fun discard(transferId: String) { dir(transferId).deleteRecursively() }

    override fun finish(transferId: String) {
        dir(transferId).deleteRecursively()
        if (partialRoot.list()?.isEmpty() == true) partialRoot.delete()
    }

    private class FsWriter(val raf: RandomAccessFile, val part: File, val meta: File, val target: File) : IncomingFileWriter {
        private var closed = false

        override fun readPrefix(consumer: (ByteArray, Int, Int) -> Unit) {
            var remaining = raf.filePointer
            FileInputStream(part).use { input ->
                val buf = ByteArray(1 shl 20)
                while (remaining > 0) {
                    val n = input.read(buf, 0, minOf(buf.size.toLong(), remaining).toInt())
                    if (n <= 0) throw AbException(ErrorCode.RESUME_INVALID, "Partial file shrank")
                    consumer(buf, 0, n); remaining -= n
                }
            }
        }

        override fun write(buf: ByteArray, off: Int, len: Int) {
            try { raf.write(buf, off, len) } catch (e: IOException) { throw ioError(e) }
        }

        override fun finish(): String {
            try {
                raf.fd.sync()
                raf.close(); closed = true
                target.parentFile.mkdirs()
                var name = target.name
                while (true) {
                    val dst = File(target.parentFile, name)
                    try {
                        // Files.move without REPLACE_EXISTING never overwrites.
                        Files.move(part.toPath(), dst.toPath())
                        meta.delete()
                        return dst.path
                    } catch (e: FileAlreadyExistsException) {
                        name = PathSanitizer.uniqueName(target.name) { File(target.parentFile, it).exists() }
                    }
                }
            } catch (e: IOException) {
                throw ioError(e)
            }
        }

        override fun close(keep: Boolean) {
            if (!closed) { runCatching { raf.close() }; closed = true }
            if (!keep) { part.delete(); meta.delete() }
        }
    }
}
