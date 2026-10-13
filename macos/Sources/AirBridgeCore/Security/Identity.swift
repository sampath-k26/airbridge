import CryptoKit
import Foundation
import Security

/// Long-term device identity (SPEC §2.1).
public final class DeviceIdentity: @unchecked Sendable {
    private let key: P256.Signing.PrivateKey
    public let spki: Data
    public var deviceId: String { ABCrypto.deviceId(spki: spki) }
    public var fingerprint: Data { ABCrypto.fingerprint(spki: spki) }

    public init(key: P256.Signing.PrivateKey) {
        self.key = key
        self.spki = key.publicKey.derRepresentation
    }

    public static func generate() -> DeviceIdentity { DeviceIdentity(key: P256.Signing.PrivateKey()) }

    public func sign(_ message: Data) throws -> Data {
        try key.signature(for: message).derRepresentation
    }

    /// Loads the identity from the login Keychain, creating it on first launch.
    /// The private key never leaves the Keychain item except in process memory.
    public static func loadOrCreateFromKeychain(service: String = "com.mahi.airbridge.identity") throws -> DeviceIdentity {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "p256-identity",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data,
           let key = try? P256.Signing.PrivateKey(rawRepresentation: data) {
            return DeviceIdentity(key: key)
        }
        let key = P256.Signing.PrivateKey()
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "p256-identity",
            kSecAttrLabel as String: "AirBridge device identity",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: key.rawRepresentation,
        ]
        SecItemDelete(add.filter { $0.key != kSecValueData as String && $0.key != kSecAttrLabel as String
            && $0.key != kSecAttrAccessible as String } as CFDictionary)
        let rc = SecItemAdd(add as CFDictionary, nil)
        guard rc == errSecSuccess else { throw ABError(.internalError, "Keychain error \(rc)") }
        return DeviceIdentity(key: key)
    }

    /// File-backed identity for the CLI and tests (0600 permissions).
    public static func loadOrCreate(file: URL) throws -> DeviceIdentity {
        if let data = try? Data(contentsOf: file), let key = try? P256.Signing.PrivateKey(rawRepresentation: data) {
            return DeviceIdentity(key: key)
        }
        let key = P256.Signing.PrivateKey()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try key.rawRepresentation.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return DeviceIdentity(key: key)
    }
}

/// A paired peer. Public keys are not secret; this is stored as JSON.
public struct PeerRecord: Codable, Sendable, Identifiable, Hashable {
    public var id: String { deviceId }
    public let deviceId: String
    public let spki: Data
    public var name: String
    public var platform: String
    public var lastHosts: [String]
    public var lastPort: UInt16?
    public var pairedAt: Date
    public var lastSeen: Date

    public var displayFingerprint: String { ABCrypto.displayFingerprint(spki: spki) }
}

/// Persistent set of paired peers.
public final class TrustStore: @unchecked Sendable {
    private let file: URL?
    private let lock = ABLock()
    private var peers: [String: PeerRecord] = [:]

    public init(file: URL?) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file),
           let list = try? JSONDecoder().decode([PeerRecord].self, from: data) {
            for p in list { peers[p.deviceId] = p }
        }
    }

    public var all: [PeerRecord] {
        lock.lock(); defer { lock.unlock() }
        return peers.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    public func peer(spki: Data) -> PeerRecord? {
        lock.lock(); defer { lock.unlock() }
        guard let p = peers[ABCrypto.deviceId(spki: spki)], p.spki == spki else { return nil }
        return p
    }

    public func upsert(_ p: PeerRecord) {
        lock.lock(); peers[p.deviceId] = p; let list = Array(peers.values); lock.unlock()
        save(list)
    }

    public func remove(deviceId: String) {
        lock.lock(); peers[deviceId] = nil; let list = Array(peers.values); lock.unlock()
        save(list)
    }

    private func save(_ list: [PeerRecord]) {
        guard let file else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: file, options: .atomic) }
    }
}
