import CryptoKit
import Foundation

public struct LocalDevice: Sendable {
    public let identity: DeviceIdentity
    public let name: String
    public let platform: String
    public let app: String
    public init(identity: DeviceIdentity, name: String, platform: String = "macos", app: String = "AirBridge-macOS/1.0") {
        self.identity = identity; self.name = name; self.platform = platform; self.app = app
    }
}

/// Information shown to the user when approving a new pairing.
public struct PairingRequest: Sendable {
    public let peerName: String
    public let platform: String
    public let fingerprint: String
    public let verificationCode: String
}

public struct HandshakeResult: Sendable {
    public let channel: SecureChannel
    public let peer: PeerRecord
    public let verificationCode: String
    public let newlyPaired: Bool
}

/// What a dialer knows when pairing for the first time.
public struct DialPairing: Sendable {
    public let code: String          // normalised pairing code
    public let fingerprint: Data?    // from QR; nil for manual entry
    public init(code: String, fingerprint: Data?) { self.code = code; self.fingerprint = fingerprint }
}

public enum Handshake {
    // MARK: Dialer

    public static func dial(stream: ByteStream, local: LocalDevice, trust: TrustStore,
                            pairing: DialPairing?, host: String?, port: UInt16?) async throws -> HandshakeResult {
        try await withTimeout(ABProtocol.handshakeTimeout + ABProtocol.approvalTimeout, onTimeout: { stream.close() }) {
            do {
                return try await dialInner(stream: stream, local: local, trust: trust, pairing: pairing, host: host, port: port)
            } catch { stream.close(); throw error }
        }
    }

    static func dialInner(stream: ByteStream, local: LocalDevice, trust: TrustStore,
                          pairing: DialPairing?, host: String?, port: UInt16?) async throws -> HandshakeResult {
        let eph = P256.KeyAgreement.PrivateKey()
        let hello = JSONCodec.encode(HelloMsg(
            proto: ABProtocol.version, minProto: 1, eph: eph.publicKey.derRepresentation.base64EncodedString(),
            nonce: ABCrypto.randomBytes(32).base64EncodedString(), pairing: pairing != nil, app: local.app))
        try await HandshakeFrame.write(hello, to: stream)

        let serverHello = try await HandshakeFrame.read(from: stream)
        let t = try JSONCodec.type(of: serverHello)
        if t == "error" {
            let e = try JSONCodec.decode(ErrorMsg.self, serverHello)
            throw ABError(ABErrorCode(rawValue: e.code) ?? .internalError, e.message)
        }
        guard t == "server_hello" else { throw ABError(.malformed, "Expected server_hello") }
        let sh = try JSONCodec.decode(ServerHelloMsg.self, serverHello)
        guard sh.proto == ABProtocol.version else { throw ABError(.unsupportedVersion, "Peer chose v\(sh.proto)") }
        guard let peerEph = Data(base64Encoded: sh.eph) else { throw ABError(.malformed, "Bad eph") }

        let th = ABCrypto.transcriptHash(hello: hello, serverHello: serverHello)
        let ss = try ABCrypto.ecdh(eph, peerSPKI: peerEph)
        let keys = ABCrypto.deriveKeys(sharedSecret: ss, transcriptHash: th)
        let channel = SecureChannel(stream: stream, sendKey: keys.dialerToListener, recvKey: keys.listenerToDialer)

        // server_auth
        let sa = try await expectAuth(channel, type: "server_auth")
        guard let peerSPKI = Data(base64Encoded: sa.identity), let sig = Data(base64Encoded: sa.sig),
              ABCrypto.verifySignature(spki: peerSPKI, signatureDER: sig, message: ABCrypto.serverAuthLabel + th)
        else { throw ABError(.authFailed, "Listener signature invalid") }

        var trusted = trust.peer(spki: peerSPKI) != nil
        if !trusted, let pairing {
            if let fp = pairing.fingerprint {
                trusted = ABCrypto.equal(fp, ABCrypto.fingerprint(spki: peerSPKI))
            } else if let proofB64 = sa.pairProof, let proof = Data(base64Encoded: proofB64) {
                let expected = ABCrypto.hmac(key: Data(pairing.code.utf8), ABCrypto.pairListenerLabel, th, peerSPKI)
                trusted = ABCrypto.equal(proof, expected)
            }
        }
        guard trusted else { throw ABError(.authFailed, "Listener identity could not be verified") }

        // client_auth
        let mySig = try local.identity.sign(ABCrypto.clientAuthLabel + th)
        let myProof = pairing.map {
            ABCrypto.hmac(key: Data($0.code.utf8), ABCrypto.pairDialerLabel, th, local.identity.spki).base64EncodedString()
        }
        try await channel.sendControl(AuthMsg(type: "client_auth", identity: local.identity.spki.base64EncodedString(),
                                              sig: mySig.base64EncodedString(), name: local.name,
                                              platform: local.platform, pairProof: myProof))

        let rec = try await channel.receive()
        guard case .control(let type, let json) = rec else { throw ABError(.malformed, "Expected control") }
        if type == "error" {
            let e = try JSONCodec.decode(ErrorMsg.self, json)
            throw ABError(ABErrorCode(rawValue: e.code) ?? .authFailed, e.message)
        }
        guard type == "auth_ok" else { throw ABError(.malformed, "Expected auth_ok") }

        let existing = trust.peer(spki: peerSPKI)
        let now = Date()
        var record = existing ?? PeerRecord(deviceId: ABCrypto.deviceId(spki: peerSPKI), spki: peerSPKI, name: sa.name,
                                            platform: sa.platform, lastHosts: [], lastPort: nil, pairedAt: now, lastSeen: now)
        record.name = sa.name
        record.lastSeen = now
        if let host { record.lastHosts = [host] + record.lastHosts.filter { $0 != host }.prefix(3) }
        if let port { record.lastPort = port }
        trust.upsert(record)
        return HandshakeResult(channel: channel, peer: record, verificationCode: ABCrypto.sas(th), newlyPaired: existing == nil)
    }

    // MARK: Listener

    public static func accept(stream: ByteStream, local: LocalDevice, trust: TrustStore,
                              activeCode: @escaping @Sendable () -> PairingCode?,
                              approve: @escaping @Sendable (PairingRequest) async -> Bool) async throws -> HandshakeResult {
        try await withTimeout(ABProtocol.handshakeTimeout + ABProtocol.approvalTimeout, onTimeout: { stream.close() }) {
            do {
                return try await acceptInner(stream: stream, local: local, trust: trust, activeCode: activeCode, approve: approve)
            } catch { stream.close(); throw error }
        }
    }

    static func acceptInner(stream: ByteStream, local: LocalDevice, trust: TrustStore,
                            activeCode: @escaping @Sendable () -> PairingCode?,
                            approve: @escaping @Sendable (PairingRequest) async -> Bool) async throws -> HandshakeResult {
        let hello = try await HandshakeFrame.read(from: stream)
        guard try JSONCodec.type(of: hello) == "hello" else { throw ABError(.malformed, "Expected hello") }
        let h = try JSONCodec.decode(HelloMsg.self, hello)
        guard h.minProto <= ABProtocol.version, h.proto >= ABProtocol.version else {
            try? await HandshakeFrame.write(JSONCodec.encode(ErrorMsg(
                code: ABErrorCode.unsupportedVersion.rawValue, message: "Listener supports protocol v1")), to: stream)
            throw ABError(.unsupportedVersion, "Dialer protocol \(h.minProto)...\(h.proto)")
        }
        guard let peerEph = Data(base64Encoded: h.eph) else { throw ABError(.malformed, "Bad eph") }

        let eph = P256.KeyAgreement.PrivateKey()
        let serverHello = JSONCodec.encode(ServerHelloMsg(
            proto: ABProtocol.version, eph: eph.publicKey.derRepresentation.base64EncodedString(),
            nonce: ABCrypto.randomBytes(32).base64EncodedString()))
        try await HandshakeFrame.write(serverHello, to: stream)

        let th = ABCrypto.transcriptHash(hello: hello, serverHello: serverHello)
        let ss = try ABCrypto.ecdh(eph, peerSPKI: peerEph)
        let keys = ABCrypto.deriveKeys(sharedSecret: ss, transcriptHash: th)
        let channel = SecureChannel(stream: stream, sendKey: keys.listenerToDialer, recvKey: keys.dialerToListener)

        let code = (h.pairing == true) ? activeCode().flatMap { $0.isUsable() ? $0 : nil } : nil
        let mySig = try local.identity.sign(ABCrypto.serverAuthLabel + th)
        let myProof = code.map {
            ABCrypto.hmac(key: $0.key, ABCrypto.pairListenerLabel, th, local.identity.spki).base64EncodedString()
        }
        try await channel.sendControl(AuthMsg(type: "server_auth", identity: local.identity.spki.base64EncodedString(),
                                              sig: mySig.base64EncodedString(), name: local.name,
                                              platform: local.platform, pairProof: myProof))

        let ca = try await expectAuth(channel, type: "client_auth")
        guard let peerSPKI = Data(base64Encoded: ca.identity), let sig = Data(base64Encoded: ca.sig),
              ABCrypto.verifySignature(spki: peerSPKI, signatureDER: sig, message: ABCrypto.clientAuthLabel + th)
        else {
            await sendError(channel, ErrorMsg(code: ABErrorCode.authFailed.rawValue, message: "Bad signature"))
            throw ABError(.authFailed, "Dialer signature invalid")
        }

        let sas = ABCrypto.sas(th)
        var newlyPaired = false
        if trust.peer(spki: peerSPKI) == nil {
            guard h.pairing == true, ca.pairProof != nil else {
                await sendError(channel, ErrorMsg(code: ABErrorCode.authFailed.rawValue, message: "Not paired"))
                throw ABError(.authFailed, "Unknown device without pairing proof")
            }
            guard let code else {
                await sendError(channel, ErrorMsg(code: ABErrorCode.pairingExpired.rawValue,
                                                        message: "Pairing code expired or already used"))
                throw ABError(.pairingExpired, "No active pairing code")
            }
            let expected = ABCrypto.hmac(key: code.key, ABCrypto.pairDialerLabel, th, peerSPKI)
            guard let proof = ca.pairProof.flatMap({ Data(base64Encoded: $0) }), ABCrypto.equal(proof, expected) else {
                code.recordFailure()
                await sendError(channel, ErrorMsg(code: ABErrorCode.authFailed.rawValue, message: "Wrong pairing code"))
                throw ABError(.authFailed, "Wrong pairing code")
            }
            code.consume()
            let ok = await approve(PairingRequest(peerName: ca.name, platform: ca.platform,
                                                  fingerprint: ABCrypto.displayFingerprint(spki: peerSPKI),
                                                  verificationCode: sas))
            guard ok else {
                await sendError(channel, ErrorMsg(code: ABErrorCode.pairingRejected.rawValue, message: "Declined"))
                throw ABError(.pairingRejected, "User declined pairing")
            }
            newlyPaired = true
        }

        let now = Date()
        var record = trust.peer(spki: peerSPKI) ?? PeerRecord(
            deviceId: ABCrypto.deviceId(spki: peerSPKI), spki: peerSPKI, name: ca.name, platform: ca.platform,
            lastHosts: [], lastPort: nil, pairedAt: now, lastSeen: now)
        record.name = ca.name
        record.lastSeen = now
        if let host = stream.remoteHost { record.lastHosts = [host] + record.lastHosts.filter { $0 != host }.prefix(3) }
        trust.upsert(record)
        try await channel.sendControl(AuthOkMsg(name: local.name, paired: true))
        return HandshakeResult(channel: channel, peer: record, verificationCode: sas, newlyPaired: newlyPaired)
    }

    /// Sends a fatal error and waits until it is handed to the network stack, so the
    /// subsequent close does not discard it.
    private static func sendError(_ channel: SecureChannel, _ e: ErrorMsg) async {
        try? await channel.sendControl(e, urgent: true)
        try? await channel.flush()
    }

    private static func expectAuth(_ channel: SecureChannel, type: String) async throws -> AuthMsg {
        let rec = try await channel.receive()
        guard case .control(let t, let json) = rec else { throw ABError(.malformed, "Expected control") }
        if t == "error" {
            let e = try JSONCodec.decode(ErrorMsg.self, json)
            throw ABError(ABErrorCode(rawValue: e.code) ?? .authFailed, e.message)
        }
        guard t == type else { throw ABError(.malformed, "Expected \(type)") }
        return try JSONCodec.decode(AuthMsg.self, json)
    }
}

/// Runs `op`; if it does not finish within `seconds`, calls `onTimeout` (which must make
/// `op` fail, e.g. by closing its socket) and throws `.timeout`.
public func withTimeout<T: Sendable>(_ seconds: TimeInterval, onTimeout: @escaping @Sendable () -> Void,
                                     _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    let fired = OnceFlag()
    let timer = Task {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        if fired.fire() { onTimeout() }
    }
    defer { timer.cancel() }
    do {
        let v = try await op()
        _ = fired.fire()
        return v
    } catch {
        if !fired.fire() { throw ABError(.timeout, "Timed out") }
        throw error
    }
}
