import CryptoKit
import XCTest
@testable import AirBridgeCore

/// Shared vectors in protocol/test-vectors — the Kotlin suite checks the same files.
final class VectorTests: XCTestCase {
    func vector(_ name: String) throws -> [String: Any] {
        let url = Bundle.module.url(forResource: "Vectors/\(name)", withExtension: "json")!
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    func testPathVectors() throws {
        let v = try vector("paths")
        for c in v["cases"] as! [[String: Any]] {
            let input = c["input"] as! String
            let expected = c["expected"] as? String
            XCTAssertEqual(PathSanitizer.sanitize(input), expected, "input: \(input.debugDescription)")
        }
        for g in v["generated"] as! [[String: Any]] {
            let s = String(repeating: g["component"] as! String, count: g["repeat"] as! Int)
            XCTAssertEqual(PathSanitizer.sanitize(s) != nil, g["valid"] as! Bool, "len \(s.utf8.count)")
        }
    }

    func testHandshakeVectors() throws {
        let v = try vector("handshake")
        func unhex(_ s: String) -> Data {
            Data(stride(from: 0, to: s.count, by: 2).map { i -> UInt8 in
                let a = s.index(s.startIndex, offsetBy: i)
                return UInt8(s[a..<s.index(a, offsetBy: 2)], radix: 16)!
            })
        }
        let hello = Data((v["hello"] as! String).utf8)
        let serverHello = Data((v["serverHello"] as! String).utf8)
        let th = ABCrypto.transcriptHash(hello: hello, serverHello: serverHello)
        XCTAssertEqual(ABCrypto.hex(th), v["transcriptHash"] as! String)

        let dialerEph = try P256.KeyAgreement.PrivateKey(rawRepresentation: unhex(v["dialerEphPrivate"] as! String))
        let ss = try ABCrypto.ecdh(dialerEph, peerSPKI: Data(base64Encoded: v["listenerEphSpki"] as! String)!)
        XCTAssertEqual(ABCrypto.hex(ss), v["sharedSecret"] as! String)
        let keys = ABCrypto.deriveKeys(sharedSecret: ss, transcriptHash: th)
        XCTAssertEqual(keys.dialerToListener.withUnsafeBytes { ABCrypto.hex(Data($0)) }, v["keyDialerToListener"] as! String)
        XCTAssertEqual(keys.listenerToDialer.withUnsafeBytes { ABCrypto.hex(Data($0)) }, v["keyListenerToDialer"] as! String)
        XCTAssertEqual(ABCrypto.sas(th), v["sas"] as! String)

        let lid = Data(base64Encoded: v["listenerIdentitySpki"] as! String)!
        let did = Data(base64Encoded: v["dialerIdentitySpki"] as! String)!
        XCTAssertEqual(ABCrypto.deviceId(spki: lid), v["listenerDeviceId"] as! String)
        XCTAssertEqual(ABCrypto.displayFingerprint(spki: lid), v["listenerDisplayFingerprint"] as! String)
        let code = Data((v["pairingCode"] as! String).utf8)
        XCTAssertEqual(ABCrypto.hex(ABCrypto.hmac(key: code, ABCrypto.pairListenerLabel, th, lid)), v["listenerPairProof"] as! String)
        XCTAssertEqual(ABCrypto.hex(ABCrypto.hmac(key: code, ABCrypto.pairDialerLabel, th, did)), v["dialerPairProof"] as! String)
        XCTAssertTrue(ABCrypto.verifySignature(spki: lid, signatureDER: unhex(v["serverAuthSignature"] as! String),
                                               message: ABCrypto.serverAuthLabel + th))
        XCTAssertFalse(ABCrypto.verifySignature(spki: did, signatureDER: unhex(v["serverAuthSignature"] as! String),
                                                message: ABCrypto.serverAuthLabel + th))

        var enc = RecordCipher(key: keys.dialerToListener)
        var dec = RecordCipher(key: keys.dialerToListener)
        for r in v["records"] as! [[String: Any]] {
            let pt = unhex(r["plaintext"] as! String)
            let ct = try enc.seal(pt)
            XCTAssertEqual(ABCrypto.hex(ct), r["ciphertext"] as! String)
            XCTAssertEqual(try dec.open(ct), pt)
        }
    }
}

final class PrimitiveTests: XCTestCase {
    func testRecordTamperAndReplayRejected() throws {
        let key = SymmetricKey(size: .bits256)
        var a = RecordCipher(key: key), b = RecordCipher(key: key)
        let r0 = try a.seal(Data("one".utf8))
        let r1 = try a.seal(Data("two".utf8))
        var tampered = r0; tampered[0] ^= 1
        XCTAssertThrowsError(try b.open(tampered))          // integrity
        var c = RecordCipher(key: key)
        XCTAssertThrowsError(try c.open(r1))                // out of order / skipped record
        var d = RecordCipher(key: key)
        XCTAssertEqual(try d.open(r0), Data("one".utf8))
        XCTAssertThrowsError(try d.open(r0))                // replay
        _ = b
    }

    func testPairingCodeRules() {
        XCTAssertEqual(PairingCode.normalize("ab12c-de34f"), "AB12CDE34F")
        XCTAssertEqual(PairingCode.normalize("oIL00 11111"), "0110011111")
        XCTAssertNil(PairingCode.normalize("ABCDE-FGHJ"))   // too short
        XCTAssertNil(PairingCode.normalize("ABCDE-FGHJU"))  // U not in alphabet
        let now = Date()
        let c = PairingCode(now: now)
        XCTAssertEqual(c.code.count, 10)
        XCTAssertTrue(c.isUsable(now: now))
        XCTAssertFalse(c.isUsable(now: now.addingTimeInterval(301)))
        for _ in 0..<5 { c.recordFailure() }
        XCTAssertFalse(c.isUsable(now: now))
        let d = PairingCode(now: now); d.consume()
        XCTAssertFalse(d.isUsable(now: now))
        // Codes are random.
        XCTAssertNotEqual(PairingCode().code, PairingCode().code)
    }

    func testPairingURIRoundTrip() {
        let fp = ABCrypto.randomBytes(32)
        let u = PairingURI(hosts: ["172.20.10.2", "192.168.1.5"], port: 47820, code: "AB12CDE34F", fingerprint: fp,
                           name: "Mahesh’s MacBook Air + test")
        XCTAssertEqual(PairingURI.parse(u.uri), u)
        XCTAssertFalse(u.uri.contains("secret"))
        XCTAssertNil(PairingURI.parse("airbridge://pair?v=2&h=1.2.3.4&p=1&c=AB12CDE34F"))
        XCTAssertNil(PairingURI.parse("airbridge://pair?v=1&h=1.2.3.4&p=0&c=AB12CDE34F"))
        XCTAssertNil(PairingURI.parse("airbridge://pair?v=1&h=1.2.3.4&p=1&c=AB12CDE34F&f=short"))
        XCTAssertNil(PairingURI.parse("https://evil.example/pair?v=1"))
    }

    func testUniqueName() {
        let existing: Set<String> = ["a.txt", "a (1).txt", ".bashrc", "noext"]
        XCTAssertEqual(PathSanitizer.uniqueName("a.txt") { existing.contains($0) }, "a (2).txt")
        XCTAssertEqual(PathSanitizer.uniqueName(".bashrc") { existing.contains($0) }, ".bashrc (1)")
        XCTAssertEqual(PathSanitizer.uniqueName("noext") { existing.contains($0) }, "noext (1)")
        XCTAssertEqual(PathSanitizer.uniqueName("new.bin") { existing.contains($0) }, "new.bin")
    }

    func testSpeedMeter() {
        var m = SpeedMeter(window: 2)
        XCTAssertNil(m.current)
        m.add(bytesDone: 0, at: 0)
        m.add(bytesDone: 10_000_000, at: 1)
        XCTAssertEqual(m.current!, 10_000_000, accuracy: 1)
        m.add(bytesDone: 30_000_000, at: 2)
        m.add(bytesDone: 40_000_000, at: 4) // window keeps only (2 s, 30 MB) and (4 s, 40 MB)
        XCTAssertEqual(m.current!, 5_000_000, accuracy: 1)
        XCTAssertEqual(m.average(at: 4)!, 10_000_000, accuracy: 1)
        XCTAssertEqual(m.eta(totalBytes: 50_000_000)!, 2, accuracy: 0.01)
    }
}
