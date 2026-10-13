package com.mahi.airbridge.storage

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.os.StatFs
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import androidx.documentfile.provider.DocumentFile
import com.mahi.airbridge.core.protocol.AbException
import com.mahi.airbridge.core.protocol.ErrorCode
import com.mahi.airbridge.core.protocol.Json
import com.mahi.airbridge.core.protocol.PathSanitizer
import com.mahi.airbridge.core.storage.IncomingFileWriter
import com.mahi.airbridge.core.storage.ReceiveStorage
import com.mahi.airbridge.core.storage.ioError
import com.mahi.airbridge.core.storage.safeId
import com.mahi.airbridge.core.transfer.OfferFile
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException

/**
 * Resume bookkeeping shared by both Android storages: one JSON file per partial file in
 * the app's private directory, recording which content URI holds the bytes.
 */
private class PartialIndex(context: Context) {
    val root = File(context.filesDir, "partial")

    fun metaFile(transferId: String, fileId: Int) = File(File(root, safeId(transferId)), "$fileId.json")

    fun write(transferId: String, file: OfferFile, peerId: String, uri: Uri) {
        val f = metaFile(transferId, file.id)
        f.parentFile?.mkdirs()
        f.writeText(Json.obj("peerId" to peerId, "path" to file.path, "size" to file.size, "mtime" to file.mtime,
            "uri" to uri.toString(), "created" to System.currentTimeMillis()).toString())
    }

    /** Returns the stored URI if it belongs to the same file of the same peer. */
    fun match(transferId: String, file: OfferFile, peerId: String): Uri? {
        val f = metaFile(transferId, file.id)
        if (!f.exists()) return null
        val m = runCatching { Json.parseObject(f.readText()) }.getOrNull() ?: return null
        val ok = Json.optStr(m, "peerId") == peerId && Json.optStr(m, "path") == file.path &&
            Json.optLong(m, "size") == file.size && Json.optLong(m, "mtime") == file.mtime
        return if (ok) Json.optStr(m, "uri")?.let(Uri::parse) else null
    }

    fun uris(transferId: String): List<Uri> = File(root, safeId(transferId)).listFiles()?.mapNotNull {
        runCatching { Json.optStr(Json.parseObject(it.readText()), "uri")?.let(Uri::parse) }.getOrNull()
    } ?: emptyList()

    fun remove(transferId: String, fileId: Int) { metaFile(transferId, fileId).delete() }
    fun removeTransfer(transferId: String) { File(root, safeId(transferId)).deleteRecursively() }

    /** Entries older than 24 h (documented cleanup policy). */
    fun stale(now: Long = System.currentTimeMillis()): List<Pair<File, Uri?>> = root.listFiles()?.flatMap { dir ->
        dir.listFiles()?.mapNotNull { f ->
            val m = runCatching { Json.parseObject(f.readText()) }.getOrNull()
            val created = m?.let { Json.optLong(it, "created") } ?: 0
            if (now - created > 24 * 3600_000L) f to m?.let { Json.optStr(it, "uri") }?.let(Uri::parse) else null
        } ?: emptyList()
    } ?: emptyList()
}

private fun mimeFor(file: OfferFile): String {
    val ext = file.path.substringAfterLast('/').substringAfterLast('.', "").lowercase()
    return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
}

/** Writes through a ParcelFileDescriptor opened on a content URI. */
private abstract class PfdWriter(private val pfd: ParcelFileDescriptor, offset: Long) : IncomingFileWriter {
    private val out = FileOutputStream(pfd.fileDescriptor)
    private val channel = out.channel
    protected var closed = false

    init {
        channel.truncate(offset)
        channel.position(offset)
    }

    override fun readPrefix(consumer: (ByteArray, Int, Int) -> Unit) {
        val end = channel.position()
        // A dup shares the file offset with the writer, so restore it afterwards.
        val dup = ParcelFileDescriptor.dup(pfd.fileDescriptor)
        ParcelFileDescriptor.AutoCloseInputStream(dup).use { input ->
            input.channel.position(0)
            val buf = ByteArray(1 shl 20)
            var remaining = end
            while (remaining > 0) {
                val n = input.read(buf, 0, minOf(buf.size.toLong(), remaining).toInt())
                if (n <= 0) throw AbException(ErrorCode.RESUME_INVALID, "Partial file shrank")
                consumer(buf, 0, n); remaining -= n
            }
        }
        channel.position(end)
    }

    override fun write(buf: ByteArray, off: Int, len: Int) {
        try { out.write(buf, off, len) } catch (e: IOException) { throw ioError(e) }
    }

    protected fun syncAndClose() {
        try {
            out.flush(); pfd.fileDescriptor.sync()
        } catch (e: IOException) { throw ioError(e) } finally {
            runCatching { out.close() }; runCatching { pfd.close() }; closed = true
        }
    }

    protected fun closeQuietly() { if (!closed) { runCatching { out.close() }; runCatching { pfd.close() }; closed = true } }
}

/**
 * Default destination: `Download/AirBridge/…` through MediaStore. No storage permission
 * is needed (Android 10+). Items stay IS_PENDING (invisible to other apps) until the
 * SHA-256 check passed. MediaStore itself makes names unique, so nothing is overwritten.
 */
class MediaStoreStorage(private val context: Context, private val subdir: String = "AirBridge") : ReceiveStorage {
    private val resolver = context.contentResolver
    private val index = PartialIndex(context)
    private val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)

    override fun availableBytes(): Long? = runCatching { StatFs(Environment.getExternalStorageDirectory().path).availableBytes }.getOrNull()

    override fun resumableOffset(transferId: String, peerId: String, file: OfferFile): Long {
        val uri = index.match(transferId, file, peerId) ?: return 0
        val len = runCatching { resolver.openFileDescriptor(uri, "r")?.use { it.statSize } }.getOrNull() ?: return 0
        return len.coerceIn(0, file.size)
    }

    override fun openWriter(transferId: String, peerId: String, file: OfferFile, offset: Long): IncomingFileWriter {
        try {
            val uri = if (offset > 0) index.match(transferId, file, peerId)
                ?: throw AbException(ErrorCode.RESUME_INVALID, "Partial file missing") else {
                val name = file.path.substringAfterLast('/')
                val dir = file.path.substringBeforeLast('/', "")
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                    put(MediaStore.MediaColumns.MIME_TYPE, mimeFor(file))
                    put(MediaStore.MediaColumns.RELATIVE_PATH,
                        Environment.DIRECTORY_DOWNLOADS + "/" + subdir + (if (dir.isEmpty()) "" else "/$dir"))
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                resolver.insert(collection, values) ?: throw AbException(ErrorCode.WRITE_FAILED, "MediaStore insert failed")
            }
            index.write(transferId, file, peerId, uri)
            val pfd = resolver.openFileDescriptor(uri, "rw") ?: throw AbException(ErrorCode.WRITE_FAILED, "Cannot open output")
            return object : PfdWriter(pfd, offset) {
                override fun finish(): String {
                    syncAndClose()
                    resolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
                    index.remove(transferId, file.id)
                    return resolver.query(uri, arrayOf(MediaStore.MediaColumns.RELATIVE_PATH, MediaStore.MediaColumns.DISPLAY_NAME),
                        null, null, null)?.use { c -> if (c.moveToFirst()) c.getString(0) + c.getString(1) else null }
                        ?: file.path
                }

                override fun close(keep: Boolean) {
                    closeQuietly()
                    if (!keep) { runCatching { resolver.delete(uri, null, null) }; index.remove(transferId, file.id) }
                }
            }
        } catch (e: IOException) {
            throw ioError(e)
        } catch (e: SecurityException) {
            throw AbException(ErrorCode.WRITE_FAILED, "Permission denied", e)
        }
    }

    override fun discard(transferId: String) {
        index.uris(transferId).forEach { runCatching { resolver.delete(it, null, null) } }
        index.removeTransfer(transferId)
    }

    override fun finish(transferId: String) = index.removeTransfer(transferId)

    fun cleanupStale() = index.stale().forEach { (f, uri) ->
        uri?.let { runCatching { resolver.delete(it, null, null) } }; f.delete()
    }
}

/**
 * A user-chosen folder (ACTION_OPEN_DOCUMENT_TREE). Files are written as
 * "name.airbridge-part" and renamed to a unique final name after verification.
 */
class TreeStorage(private val context: Context, private val tree: Uri) : ReceiveStorage {
    private val resolver = context.contentResolver
    private val index = PartialIndex(context)
    private val root get() = DocumentFile.fromTreeUri(context, tree) ?: throw AbException(ErrorCode.WRITE_FAILED, "Destination unavailable")

    override fun availableBytes(): Long? = null // not exposed by SAF; failures surface as write errors

    override fun resumableOffset(transferId: String, peerId: String, file: OfferFile): Long {
        val uri = index.match(transferId, file, peerId) ?: return 0
        return runCatching { resolver.openFileDescriptor(uri, "r")?.use { it.statSize } }.getOrNull()?.coerceIn(0, file.size) ?: 0
    }

    private fun dirFor(path: String): DocumentFile {
        var d = root
        for (c in path.split('/').dropLast(1)) {
            d = d.findFile(c)?.takeIf { it.isDirectory } ?: d.createDirectory(c)
                ?: throw AbException(ErrorCode.WRITE_FAILED, "Cannot create folder $c")
        }
        return d
    }

    override fun openWriter(transferId: String, peerId: String, file: OfferFile, offset: Long): IncomingFileWriter {
        try {
            val dir = dirFor(file.path)
            val name = file.path.substringAfterLast('/')
            val uri = if (offset > 0) index.match(transferId, file, peerId)
                ?: throw AbException(ErrorCode.RESUME_INVALID, "Partial file missing")
            else dir.createFile("application/octet-stream", "$name.airbridge-part")?.uri
                ?: throw AbException(ErrorCode.WRITE_FAILED, "Cannot create file")
            index.write(transferId, file, peerId, uri)
            val pfd = resolver.openFileDescriptor(uri, "rw") ?: throw AbException(ErrorCode.WRITE_FAILED, "Cannot open output")
            return object : PfdWriter(pfd, offset) {
                override fun finish(): String {
                    syncAndClose()
                    val finalName = PathSanitizer.uniqueName(name) { dir.findFile(it) != null }
                    val renamed = DocumentsContract.renameDocument(resolver, uri, finalName)
                        ?: throw AbException(ErrorCode.WRITE_FAILED, "Rename failed")
                    index.remove(transferId, file.id)
                    return (DocumentFile.fromSingleUri(context, renamed)?.name ?: finalName)
                }

                override fun close(keep: Boolean) {
                    closeQuietly()
                    if (!keep) { runCatching { DocumentsContract.deleteDocument(resolver, uri) }; index.remove(transferId, file.id) }
                }
            }
        } catch (e: IOException) {
            throw ioError(e)
        } catch (e: SecurityException) {
            throw AbException(ErrorCode.WRITE_FAILED, "Permission to the destination folder was revoked", e)
        }
    }

    override fun discard(transferId: String) {
        index.uris(transferId).forEach { runCatching { DocumentsContract.deleteDocument(resolver, it) } }
        index.removeTransfer(transferId)
    }

    override fun finish(transferId: String) = index.removeTransfer(transferId)
}
