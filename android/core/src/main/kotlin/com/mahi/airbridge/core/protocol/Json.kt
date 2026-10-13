package com.mahi.airbridge.core.protocol

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.Json as KJson

/**
 * Tolerant JSON access for untrusted control messages. Missing or mistyped required
 * fields raise [ErrorCode.MALFORMED]; unknown fields are ignored (forward compatibility).
 */
object Json {
    private val parser = KJson { ignoreUnknownKeys = true }

    fun parseObject(bytes: ByteArray): JsonObject = parseObject(bytes.toString(Charsets.UTF_8))

    fun parseObject(s: String): JsonObject = try {
        parser.parseToJsonElement(s) as JsonObject
    } catch (e: Exception) {
        throw AbException(ErrorCode.MALFORMED, "Invalid JSON")
    }

    fun parseArray(s: String): JsonArray = parser.parseToJsonElement(s) as JsonArray

    private fun prim(o: JsonObject, k: String): JsonPrimitive? = (o[k] as? JsonPrimitive)?.takeIf { it !is JsonNull }

    fun str(o: JsonObject, k: String): String =
        prim(o, k)?.takeIf { it.isString }?.content ?: throw AbException(ErrorCode.MALFORMED, "Missing '$k'")

    fun optStr(o: JsonObject, k: String): String? = prim(o, k)?.takeIf { it.isString }?.contentOrNull

    fun long(o: JsonObject, k: String): Long =
        prim(o, k)?.takeIf { !it.isString }?.longOrNull ?: throw AbException(ErrorCode.MALFORMED, "Missing '$k'")

    fun optLong(o: JsonObject, k: String): Long? = prim(o, k)?.takeIf { !it.isString }?.longOrNull

    fun int(o: JsonObject, k: String): Int {
        val v = long(o, k)
        if (v < Int.MIN_VALUE || v > Int.MAX_VALUE) throw AbException(ErrorCode.MALFORMED, "'$k' out of range")
        return v.toInt()
    }

    fun optBool(o: JsonObject, k: String): Boolean? = prim(o, k)?.booleanOrNull

    fun arr(o: JsonObject, k: String): JsonArray =
        o[k] as? JsonArray ?: throw AbException(ErrorCode.MALFORMED, "Missing '$k'")

    fun strList(o: JsonObject, k: String): List<String> =
        (o[k] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull } ?: emptyList()

    fun type(o: JsonObject): String = str(o, "type")

    fun obj(vararg pairs: Pair<String, Any?>): JsonObject = JsonObject(pairs.filter { it.second != null }.associate { (k, v) ->
        k to toElement(v)
    })

    @Suppress("UNCHECKED_CAST")
    private fun toElement(v: Any?): JsonElement = when (v) {
        null -> JsonNull
        is JsonElement -> v
        is String -> JsonPrimitive(v)
        is Number -> JsonPrimitive(v)
        is Boolean -> JsonPrimitive(v)
        is List<*> -> JsonArray(v.map { toElement(it) })
        else -> error("Unsupported JSON value ${v::class}")
    }

    fun encode(o: JsonObject): ByteArray = o.toString().toByteArray(Charsets.UTF_8)
}
