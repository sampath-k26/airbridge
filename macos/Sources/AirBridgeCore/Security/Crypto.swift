import CryptoKit
import Foundation

/// Cryptographic building blocks defined in SPEC §2 and §5.3.
public enum ABCrypto {
    public static let transcriptLabel = Data("AirBridge/1".utf8)
    public static let sessionKeysInfo = Data("airbridge/1 session keys".utf8)
    public static let serverAuthLabel = Data("airbridge/1 server-auth".utf8)
    public static let clientAuthLabel = Data("airbridge/1 client-auth".utf8)
    public static let pairListenerLabel = Data("airbridge/1 pair-listener".utf8)
    public static let pairDialerLabel = Data("airbridge/1 pair-dialer".utf8)

    public static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    public static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    public static func u32(_ v: Int) -> Data {
        var be = UInt32(v).bigEndian
        return Data(bytes: &be, count: 4)
    }

    /// th = SHA-256("AirBridge/1" || u32 len || hello || u32 len || server_hello)
    public static func transcriptHash(hello: Data, serverHello: Data) -> Data {
        var d = transcriptLabel
        d.append(u32(hello.count)); d.append(hello)
        d.append(u32(serverHello.count)); d.append(serverHello)
        return sha256(d)
    }

    public struct SessionKeys: Equatable {
        public let dialerToListener: SymmetricKey
        public let listenerToDialer: SymmetricKey
        public static func == (a: SessionKeys, b: SessionKeys) -> Bool {
            a.dialerToListener.withUnsafeBytes { Data($0) } == b.dialerToListener.withUnsafeBytes { Data($0) }
                && a.listenerToDialer.withUnsafeBytes { Data($0) } == b.listenerToDialer.withUnsafeBytes { Data($0) }
        }
    }

    public static func deriveKeys(sharedSecret: Data, transcriptHash th: Data) -> SessionKeys {
        let okm = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedSecret),
            salt: th, info: sessionKeysInfo, outputByteCount: 64)
        let bytes = okm.withUnsafeBytes { Data($0) }
        return SessionKeys(
            dialerToListener: SymmetricKey(data: bytes.prefix(32)),
            listenerToDialer: SymmetricKey(data: bytes.suffix(32)))
    }

    public static func ecdh(_ priv: P256.KeyAgreement.PrivateKey, peerSPKI: Data) throws -> Data {
        let pub = try P256.KeyAgreement.PublicKey(derRepresentation: peerSPKI)
        let secret = try priv.sharedSecretFromKeyAgreement(with: pub)
        return secret.withUnsafeBytes { Data($0) }
    }

    /// 6-digit short authentication string shown on both screens.
    public static func sas(_ th: Data) -> String {
        let v = th.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return String(format: "%06u", v % 1_000_000)
    }

    public static func hmac(key: Data, _ parts: Data...) -> Data {
        var h = HMAC<SHA256>(key: SymmetricKey(data: key))
        for p in parts { h.update(data: p) }
        return Data(h.finalize())
    }

    /// Constant-time comparison.
    public static func equal(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[a.startIndex + i] ^ b[b.startIndex + i] }
        return diff == 0
    }

    public static func verifySignature(spki: Data, signatureDER: Data, message: Data) -> Bool {
        guard let key = try? P256.Signing.PublicKey(derRepresentation: spki),
              let sig = try? P256.Signing.ECDSASignature(derRepresentation: signatureDER)
        else { return false }
        return key.isValidSignature(sig, for: message)
    }

    public static func fingerprint(spki: Data) -> Data { sha256(spki) }

    public static func deviceId(spki: Data) -> String { hex(fingerprint(spki: spki).prefix(16)) }

    /// "ab12 cd34 ef56 7890"
    public static func displayFingerprint(spki: Data) -> String {
        let h = hex(fingerprint(spki: spki).prefix(8))
        return stride(from: 0, to: h.count, by: 4).map { i -> String in
            let s = h.index(h.startIndex, offsetBy: i)
            return String(h[s..<h.index(s, offsetBy: 4)])
        }.joined(separator: " ")
    }

    public static func randomBytes(_ n: Int) -> Data {
        var d = Data(count: n)
        let rc = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        precondition(rc == errSecSuccess, "CSPRNG failure")
        return d
    }
}

/// AES-256-GCM with a per-direction implicit counter nonce (SPEC §4.2).
public struct RecordCipher {
    private let key: SymmetricKey
    public private(set) var counter: UInt64 = 0

    public init(key: SymmetricKey) { self.key = key }

    private func nonce() -> AES.GCM.Nonce {
        var n = Data(count: 4)
        var c = counter.bigEndian
        n.append(Data(bytes: &c, count: 8))
        return try! AES.GCM.Nonce(data: n)
    }

    /// Returns ciphertext || tag.
    public mutating func seal(_ plaintext: Data) throws -> Data {
        precondition(counter < UInt64.max)
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce())
        counter += 1
        // `box.ciphertext` is a slice (non-zero startIndex); copy into a fresh Data.
        var out = Data(capacity: plaintext.count + 16)
        out.append(box.ciphertext)
        out.append(box.tag)
        return out
    }

    public mutating func open(_ record: Data) throws -> Data {
        guard record.count >= 16 else { throw ABError(.malformed, "Record too short") }
        let ct = record.prefix(record.count - 16)
        let tag = record.suffix(16)
        let box = try AES.GCM.SealedBox(nonce: nonce(), ciphertext: ct, tag: tag)
        do {
            let pt = try AES.GCM.open(box, using: key)
            counter += 1
            return pt
        } catch {
            throw ABError(.malformed, "Record authentication failed")
        }
    }
}
