package com.mahi.airbridge.core.protocol

import java.text.Normalizer

/** Validates untrusted relative paths received in an offer (SPEC §7). Null = reject. */
object PathSanitizer {
    private val replaced = setOf(':', '*', '?', '"', '<', '>', '|')

    fun sanitize(raw: String): String? {
        val path = Normalizer.normalize(raw, Normalizer.Form.NFC)
        if (path.isEmpty() || path.toByteArray(Charsets.UTF_8).size > 1024 || path.startsWith("/")) return null
        if (path.codePoints().anyMatch { it == '\\'.code || it < 0x20 || it == 0x7F }) return null
        if (path.length >= 2 && path[1] == ':' && path[0].let { it in 'A'..'Z' || it in 'a'..'z' }) return null
        val parts = path.split("/")
        if (parts.size > 32) return null
        val out = ArrayList<String>(parts.size)
        for (p in parts) {
            if (p.isEmpty() || p == "." || p == "..") return null
            var c = buildString(p.length) { for (ch in p) append(if (ch in replaced) '_' else ch) }
            c = c.trimEnd(' ', '.')
            if (c.isEmpty() || c.toByteArray(Charsets.UTF_8).size > 255) return null
            out.add(c)
        }
        return out.joinToString("/")
    }

    /** "name.ext" → "name (1).ext", … until [exists] is false. Dot-files stay whole. */
    fun uniqueName(name: String, exists: (String) -> Boolean): String {
        if (!exists(name)) return name
        val dot = name.lastIndexOf('.')
        val (base, suffix) = if (dot > 0) name.substring(0, dot) to name.substring(dot) else name to ""
        var i = 1
        while (true) {
            val candidate = "$base ($i)$suffix"
            if (!exists(candidate)) return candidate
            i++
        }
    }
}
