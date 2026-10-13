package com.mahi.airbridge.core.protocol

/** Constants from protocol/SPEC.md §9. */
object AbProtocol {
    const val VERSION = 1
    const val DEFAULT_PORT = 47820
    const val SERVICE_TYPE = "_airbridge._tcp"

    const val MAX_HANDSHAKE_FRAME = 16 * 1024
    const val MAX_CONTROL_JSON = 1024 * 1024
    const val MAX_DATA_PAYLOAD = 4 * 1024 * 1024
    const val MAX_RECORD_CIPHERTEXT = 4 * 1024 * 1024 + 1024 + 16
    const val MAX_FILES_PER_OFFER = 5000

    const val HANDSHAKE_TIMEOUT_MS = 15_000L
    const val APPROVAL_TIMEOUT_MS = 90_000L
    const val PING_INTERVAL_MS = 15_000L
    const val IDLE_TIMEOUT_MS = 45_000L

    const val RECORD_CONTROL: Byte = 0x01
    const val RECORD_DATA: Byte = 0x02

    const val DEFAULT_CHUNK = 1024 * 1024
}

/** Error codes from SPEC §6.8 (plus local-only codes that never go on the wire). */
enum class ErrorCode(val wire: String) {
    UNSUPPORTED_VERSION("unsupported_version"),
    MALFORMED("malformed"),
    AUTH_FAILED("auth_failed"),
    PAIRING_REJECTED("pairing_rejected"),
    PAIRING_EXPIRED("pairing_expired"),
    DECLINED("declined"),
    BUSY("busy"),
    INVALID_PATH("invalid_path"),
    INSUFFICIENT_STORAGE("insufficient_storage"),
    WRITE_FAILED("write_failed"),
    READ_FAILED("read_failed"),
    HASH_MISMATCH("hash_mismatch"),
    SIZE_MISMATCH("size_mismatch"),
    CANCELLED("cancelled"),
    RESUME_INVALID("resume_invalid"),
    TIMEOUT("timeout"),
    INTERNAL("internal"),
    CONNECTION_FAILED("connection_failed"),
    CONNECTION_LOST("connection_lost");

    companion object {
        fun fromWire(s: String?, default: ErrorCode = INTERNAL): ErrorCode =
            entries.firstOrNull { it.wire == s } ?: default
    }
}

/** Typed protocol error. [message] is diagnostic; [userMessage] is safe to show in the UI. */
class AbException(val code: ErrorCode, message: String, cause: Throwable? = null) : Exception(message, cause) {
    val userMessage: String
        get() = when (code) {
            ErrorCode.UNSUPPORTED_VERSION -> "The other device runs an incompatible AirBridge version. Update both apps."
            ErrorCode.MALFORMED -> "The other device sent invalid data. The connection was closed for safety."
            ErrorCode.AUTH_FAILED -> "Authentication failed. Pair the devices again using a fresh QR code."
            ErrorCode.PAIRING_REJECTED -> "Pairing was declined on the other device."
            ErrorCode.PAIRING_EXPIRED -> "The pairing code expired or was already used. Generate a new one."
            ErrorCode.DECLINED -> "The receiver declined the transfer."
            ErrorCode.BUSY -> "The other device is busy. Try again in a moment."
            ErrorCode.INVALID_PATH -> "A file name was unsafe and the transfer was refused."
            ErrorCode.INSUFFICIENT_STORAGE -> "Not enough free space on the receiving device."
            ErrorCode.WRITE_FAILED -> "Could not write the file. Check the destination folder and permissions."
            ErrorCode.READ_FAILED -> "Could not read the source file. It may have been moved or deleted."
            ErrorCode.HASH_MISMATCH -> "Integrity check failed — the received file did not match. It was discarded; retry the transfer."
            ErrorCode.SIZE_MISMATCH -> "The received file had the wrong size. It was discarded; retry the transfer."
            ErrorCode.CANCELLED -> "The transfer was cancelled."
            ErrorCode.RESUME_INVALID -> "The transfer could not be resumed and must restart."
            ErrorCode.TIMEOUT -> "The connection timed out. Check that both devices are on the same network."
            ErrorCode.INTERNAL -> "An internal error occurred."
            ErrorCode.CONNECTION_FAILED -> "Could not connect. Make sure both devices are on the same Wi-Fi or hotspot and AirBridge is open on the other device."
            ErrorCode.CONNECTION_LOST -> "The connection was interrupted. AirBridge will resume when the device reconnects."
        }

    override fun toString(): String = "${code.wire}: $message"
}
