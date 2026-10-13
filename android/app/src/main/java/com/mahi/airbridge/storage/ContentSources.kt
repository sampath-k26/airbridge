package com.mahi.airbridge.storage

import android.content.ContentResolver
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import com.mahi.airbridge.core.protocol.AbException
import com.mahi.airbridge.core.protocol.ErrorCode
import com.mahi.airbridge.core.transfer.SendSource
import java.io.File
import java.io.FileInputStream
import java.io.InputStream

/**
 * A user-selected document. Content URIs may have no filesystem path, so size and
 * name come from the provider and data is read through [ContentResolver] streams.
 */
class ContentUriSource(
    private val resolver: ContentResolver,
    val uri: Uri,
    override val path: String,
    override val size: Long,
    override val mtime: Long,
    override val mime: String?,
) : SendSource {
    override fun open(): InputStream =
        resolver.openInputStream(uri) ?: throw AbException(ErrorCode.READ_FAILED, "Cannot open $path")

    override fun unchanged(): Boolean {
        val (s, m) = stat(resolver, uri)
        return (s < 0 || s == size) && (m <= 0 || mtime <= 0 || m == mtime)
    }

    companion object {
        /** Builds a source from a picker/share URI. Returns null when the size is unknown. */
        fun from(resolver: ContentResolver, uri: Uri, relativeDir: String? = null): ContentUriSource? {
            var name: String? = null
            var size = -1L
            runCatching {
                resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
                    if (c.moveToFirst()) {
                        name = c.getString(0)
                        if (!c.isNull(1)) size = c.getLong(1)
                    }
                }
            }
            if (size < 0) size = runCatching { resolver.openFileDescriptor(uri, "r")?.use { it.statSize } }.getOrNull() ?: -1
            if (size < 0) return null
            val display = (name ?: uri.lastPathSegment ?: "file").replace('/', '_')
            val (_, mtime) = stat(resolver, uri)
            val path = if (relativeDir != null) "$relativeDir/$display" else display
            return ContentUriSource(resolver, uri, path, size, mtime, resolver.getType(uri))
        }

        private fun stat(resolver: ContentResolver, uri: Uri): Pair<Long, Long> = runCatching {
            resolver.query(uri, arrayOf(OpenableColumns.SIZE, DocumentsContract.Document.COLUMN_LAST_MODIFIED), null, null, null)?.use { c ->
                if (!c.moveToFirst()) return@use -1L to 0L
                val s = if (c.isNull(0)) -1L else c.getLong(0)
                val m = c.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED).takeIf { it >= 0 && !c.isNull(it) }?.let { c.getLong(it) } ?: 0L
                s to m
            }
        }.getOrNull() ?: (-1L to 0L)

        /** Recursively lists a document tree chosen with ACTION_OPEN_DOCUMENT_TREE. */
        fun fromTree(resolver: ContentResolver, treeUri: Uri): List<ContentUriSource> {
            val out = ArrayList<ContentUriSource>()
            val rootId = DocumentsContract.getTreeDocumentId(treeUri)
            val rootName = resolver.query(DocumentsContract.buildDocumentUriUsingTree(treeUri, rootId),
                arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) c.getString(0) else null
            } ?: "Folder"
            fun walk(docId: String, rel: String, depth: Int) {
                if (depth > 32) return
                val children = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, docId)
                resolver.query(children, arrayOf(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_SIZE,
                    DocumentsContract.Document.COLUMN_LAST_MODIFIED), null, null, null)?.use { c ->
                    while (c.moveToNext()) {
                        val id = c.getString(0)
                        val name = c.getString(1).replace('/', '_')
                        val mime = c.getString(2)
                        if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                            walk(id, "$rel/$name", depth + 1)
                        } else {
                            out.add(ContentUriSource(resolver, DocumentsContract.buildDocumentUriUsingTree(treeUri, id),
                                "$rel/$name", if (c.isNull(3)) 0 else c.getLong(3), if (c.isNull(4)) 0 else c.getLong(4), mime))
                        }
                    }
                }
            }
            walk(rootId, rootName.replace('/', '_'), 0)
            return out
        }
    }
}

/** A plain file (used by the debug test hook for files in the app's own directory). */
class LocalFileSource(val file: File, override val path: String) : SendSource {
    override val size = file.length()
    override val mtime = file.lastModified()
    override val mime: String? = null
    override fun open(): InputStream = FileInputStream(file)
    override fun unchanged() = file.length() == size && file.lastModified() == mtime
}
