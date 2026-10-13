import AirBridgeCore
import CryptoKit
import Foundation

/// Deterministic cross-implementation vectors (protocol/test-vectors/handshake.json).
/// ECDSA signatures are randomised, so the vector carries one signature to *verify*.
func emitVectors() {
    func key(_ byte: UInt8) -> Data { Data(repeating: byte, count: 31) + Data([0x01]) }
    let dialerEph = try! P256.KeyAgreement.PrivateKey(rawRepresentation: key(0x11))
    let listenerEph = try! P256.KeyAgreement.PrivateKey(rawRepresentation: key(0x22))
    let listenerId = try! P256.Signing.PrivateKey(rawRepresentation: key(0x33))
    let dialerId = try! P256.Signing.PrivateKey(rawRepresentation: key(0x44))

    let hello = Data(#"{"type":"hello","proto":1,"minProto":1,"eph":"\#(dialerEph.publicKey.derRepresentation.base64EncodedString())","nonce":"AAAA","pairing":true}"#.utf8)
    let serverHello = Data(#"{"type":"server_hello","proto":1,"eph":"\#(listenerEph.publicKey.derRepresentation.base64EncodedString())","nonce":"BBBB"}"#.utf8)
    let th = ABCrypto.transcriptHash(hello: hello, serverHello: serverHello)
    let ss = try! ABCrypto.ecdh(dialerEph, peerSPKI: listenerEph.publicKey.derRepresentation)
    let keys = ABCrypto.deriveKeys(sharedSecret: ss, transcriptHash: th)
    let code = "ABCDEFGHJK"
    let listenerProof = ABCrypto.hmac(key: Data(code.utf8), ABCrypto.pairListenerLabel, th, listenerId.publicKey.derRepresentation)
    let dialerProof = ABCrypto.hmac(key: Data(code.utf8), ABCrypto.pairDialerLabel, th, dialerId.publicKey.derRepresentation)
    let sig = try! listenerId.signature(for: ABCrypto.serverAuthLabel + th).derRepresentation

    var cipher = RecordCipher(key: keys.dialerToListener)
    let pt0 = Data([0x01]) + Data(#"{"type":"ping"}"#.utf8)
    let pt1 = Data([0x02, 0, 0, 0, 7]) + Data("hello file bytes".utf8)
    let ct0 = try! cipher.seal(pt0)
    let ct1 = try! cipher.seal(pt1)

    func hex(_ d: Data) -> String { ABCrypto.hex(d) }
    let out: [String: Any] = [
        "description": "SPEC §5.3 key schedule and §4.2 records. Private keys are raw P-256 scalars (hex).",
        "dialerEphPrivate": hex(key(0x11)), "listenerEphPrivate": hex(key(0x22)),
        "listenerIdentityPrivate": hex(key(0x33)), "dialerIdentityPrivate": hex(key(0x44)),
        "dialerEphSpki": dialerEph.publicKey.derRepresentation.base64EncodedString(),
        "listenerEphSpki": listenerEph.publicKey.derRepresentation.base64EncodedString(),
        "listenerIdentitySpki": listenerId.publicKey.derRepresentation.base64EncodedString(),
        "dialerIdentitySpki": dialerId.publicKey.derRepresentation.base64EncodedString(),
        "listenerFingerprint": hex(ABCrypto.fingerprint(spki: listenerId.publicKey.derRepresentation)),
        "listenerDeviceId": ABCrypto.deviceId(spki: listenerId.publicKey.derRepresentation),
        "listenerDisplayFingerprint": ABCrypto.displayFingerprint(spki: listenerId.publicKey.derRepresentation),
        "hello": String(data: hello, encoding: .utf8)!, "serverHello": String(data: serverHello, encoding: .utf8)!,
        "transcriptHash": hex(th), "sharedSecret": hex(ss),
        "keyDialerToListener": keys.dialerToListener.withUnsafeBytes { hex(Data($0)) },
        "keyListenerToDialer": keys.listenerToDialer.withUnsafeBytes { hex(Data($0)) },
        "sas": ABCrypto.sas(th), "pairingCode": code,
        "listenerPairProof": hex(listenerProof), "dialerPairProof": hex(dialerProof),
        "serverAuthSignature": hex(sig),
        "records": [["counter": 0, "plaintext": hex(pt0), "ciphertext": hex(ct0)],
                    ["counter": 1, "plaintext": hex(pt1), "ciphertext": hex(ct1)]],
    ]
    let data = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    print(String(data: data, encoding: .utf8)!)
}
