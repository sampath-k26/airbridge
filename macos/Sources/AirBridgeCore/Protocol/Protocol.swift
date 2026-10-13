import Foundation

/// Constants from SPEC §9.
public enum ABProtocol {
    public static let version = 1
    public static let defaultPort: UInt16 = 47820
    public static let serviceType = "_airbridge._tcp"

    public static let maxHandshakeFrame = 16 * 1024
    public static let maxControlJSON = 1024 * 1024
    public static let maxDataPayload = 4 * 1024 * 1024
    public static let maxRecordCiphertext = 4 * 1024 * 1024 + 1024 + 16
    public static let maxFilesPerOffer = 5000

    public static let handshakeTimeout: TimeInterval = 15
    public static let approvalTimeout: TimeInterval = 90
    public static let pingInterval: TimeInterval = 15
    public static let idleTimeout: TimeInterval = 45

    public static let recordControl: UInt8 = 0x01
    public static let recordData: UInt8 = 0x02

    public static let defaultChunkSize = 1024 * 1024
}

/// Error codes from SPEC §6.8.
public enum ABErrorCode: String, Codable, Sendable {
    case unsupportedVersion = "unsupported_version"
    case malformed
    case authFailed = "auth_failed"
    case pairingRejected = "pairing_rejected"
    case pairingExpired = "pairing_expired"
    case declined
    case busy
    case invalidPath = "invalid_path"
    case insufficientStorage = "insufficient_storage"
    case writeFailed = "write_failed"
    case readFailed = "read_failed"
    case hashMismatch = "hash_mismatch"
    case sizeMismatch = "size_mismatch"
    case cancelled
    case resumeInvalid = "resume_invalid"
    case timeout
    case internalError = "internal"
    // Local-only (never sent on the wire).
    case connectionFailed = "connection_failed"
    case connectionLost = "connection_lost"
}

public struct ABError: Error, LocalizedError, CustomStringConvertible, Sendable {
    public let code: ABErrorCode
    public let message: String

    public init(_ code: ABErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "\(code.rawValue): \(message)" }

    /// User-facing explanation with a recovery hint. Never includes secrets.
    public var errorDescription: String? {
        switch code {
        case .unsupportedVersion: return "The other device runs an incompatible AirBridge version. Update both apps."
        case .malformed: return "The other device sent invalid data. The connection was closed for safety."
        case .authFailed: return "Authentication failed. Pair the devices again using a fresh QR code."
        case .pairingRejected: return "Pairing was declined on the other device."
        case .pairingExpired: return "The pairing code expired or was already used. Generate a new one."
        case .declined: return "The receiver declined the transfer."
        case .busy: return "The other device is busy. Try again in a moment."
        case .invalidPath: return "A file name was unsafe and the transfer was refused."
        case .insufficientStorage: return "Not enough free space on the receiving device."
        case .writeFailed: return "Could not write the file. Check the destination folder and permissions."
        case .readFailed: return "Could not read the source file. It may have been moved or deleted."
        case .hashMismatch: return "Integrity check failed — the received file did not match. It was discarded; retry the transfer."
        case .sizeMismatch: return "The received file had the wrong size. It was discarded; retry the transfer."
        case .cancelled: return "The transfer was cancelled."
        case .resumeInvalid: return "The transfer could not be resumed and must restart."
        case .timeout: return "The connection timed out. Check that both devices are on the same network."
        case .internalError: return "An internal error occurred."
        case .connectionFailed: return "Could not connect. Make sure both devices are on the same Wi-Fi or hotspot and AirBridge is open on the other device."
        case .connectionLost: return "The connection was interrupted. AirBridge will resume when the device reconnects."
        }
    }
}
