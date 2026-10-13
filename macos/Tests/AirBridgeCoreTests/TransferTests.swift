import CryptoKit
import XCTest
@testable import AirBridgeCore

/// End-to-end tests over real loopback TCP (Network.framework).
final class TransferTests: XCTestCase {
    var tmp: URL!

    override func setUp() {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ab-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    // MARK: Helpers

    struct Peer {
        let local: LocalDevice
        let trust: TrustStore
    }

    func makePeer(_ name: String) -> Peer {
        Peer(local: LocalDevice(identity: .generate(), name: name), trust: TrustStore(file: nil))
    }

    final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

    /// Connects `dialer` to `listener` over loopback; returns both handshake results.
    func connect(_ listenerPeer: Peer, _ dialerPeer: Peer, code: PairingCode?, pairing: DialPairing?,
                 approve: Bool = true) async throws -> (HandshakeResult, HandshakeResult) {
        let listener = Listener()
        let accepted = Box<Result<HandshakeResult, Error>?>(nil)
        let sem = AsyncSemaphore()
        let port = try await listener.start(port: 0, bonjourName: nil, deviceId: "t") { stream in
            Task {
                do {
                    try await stream.waitReady(timeout: 5)
                    let r = try await Handshake.accept(stream: stream, local: listenerPeer.local, trust: listenerPeer.trust,
                                                       activeCode: { code }, approve: { _ in approve })
                    accepted.value = .success(r)
                } catch { accepted.value = .failure(error) }
                sem.signal()
            }
        }
        defer { listener.stop() }
        let stream = try await ByteStream.connect(host: "127.0.0.1", port: port)
        let dialed: HandshakeResult
        do {
            dialed = try await Handshake.dial(stream: stream, local: dialerPeer.local, trust: dialerPeer.trust,
                                              pairing: pairing, host: "127.0.0.1", port: port)
        } catch {
            await sem.wait()
            throw error
        }
        await sem.wait()
        return (try accepted.value!.get(), dialed)
    }

    func pair(_ a: Peer, _ b: Peer) async throws -> (HandshakeResult, HandshakeResult) {
        let code = PairingCode()
        return try await connect(a, b, code: code, pairing: DialPairing(code: code.code, fingerprint: a.local.identity.fingerprint))
    }

    func session(_ hs: HandshakeResult, _ dir: URL, storage: ReceiveStorage? = nil, chunk: Int = 256 * 1024,
                 events: Box<[SessionEvent]>? = nil) -> Session {
        let s = Session(handshake: hs, storage: storage ?? FileSystemStorage(destination: dir), chunkSize: chunk,
                        decide: { _ in true }, onEvent: { e in if let events { objc_sync_enter(events); events.value.append(e); objc_sync_exit(events) } })
        s.start()
        return s
    }

    func waitForResult(_ events: Box<[SessionEvent]>, timeout: TimeInterval = 20) async -> TransferResult? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            objc_sync_enter(events)
            let r = events.value.compactMap { e -> TransferResult? in if case .finished(let r) = e { return r }; return nil }.first
            objc_sync_exit(events)
            if let r { return r }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    func write(_ name: String, bytes: Int) -> URL {
        let url = tmp.appendingPathComponent("src").appendingPathComponent(name)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! ABCrypto.randomBytes(bytes).write(to: url)
        return url
    }

    func sha(_ url: URL) -> String { ABCrypto.hex(Data(SHA256.hash(data: try! Data(contentsOf: url)))) }

    // MARK: Pairing / authentication

    func testQRPairingThenReconnectWithoutCode() async throws {
        let mac = makePeer("mac"), phone = makePeer("phone")
        let (l, d) = try await pair(mac, phone)
        XCTAssertTrue(l.newlyPaired); XCTAssertTrue(d.newlyPaired)
        XCTAssertEqual(l.verificationCode, d.verificationCode)
        l.channel.close(); d.channel.close()
        // Paired devices reconnect with no code at all.
        let (l2, d2) = try await connect(mac, phone, code: nil, pairing: nil)
        XCTAssertFalse(l2.newlyPaired); XCTAssertFalse(d2.newlyPaired)
        l2.channel.close(); d2.channel.close()
    }

    func testManualCodePairingAuthenticatesListenerByProof() async throws {
        let mac = makePeer("mac"), phone = makePeer("phone")
        let code = PairingCode()
        let (l, d) = try await connect(mac, phone, code: code, pairing: DialPairing(code: code.code, fingerprint: nil))
        XCTAssertEqual(l.verificationCode, d.verificationCode)
        XCTAssertFalse(code.isUsable(), "code must be single-use")
        l.channel.close(); d.channel.close()
    }

    func testUnknownDeviceWithoutCodeIsRejected() async throws {
        let mac = makePeer("mac"), stranger = makePeer("stranger")
        do {
            _ = try await connect(mac, stranger, code: PairingCode(), pairing: nil)
            XCTFail("should fail")
        } catch let e as ABError {
            XCTAssertEqual(e.code, .authFailed)
        }
        XCTAssertTrue(mac.trust.all.isEmpty)
    }

    func testWrongCodeIsRejectedAndCounted() async throws {
        let mac = makePeer("mac"), phone = makePeer("phone")
        let code = PairingCode()
        do {
            _ = try await connect(mac, phone, code: code, pairing: DialPairing(code: "ZZZZZZZZZZ", fingerprint: mac.local.identity.fingerprint))
            XCTFail("should fail")
        } catch let e as ABError {
            XCTAssertEqual(e.code, .authFailed)
        }
        XCTAssertTrue(code.isUsable(), "one failure does not burn the code")
        for _ in 0..<4 { code.recordFailure() }
        XCTAssertFalse(code.isUsable(), "5 failures invalidate the code")
    }

    func testManualPairingWithWrongCodeCannotAuthenticateListener() async throws {
        // Without a fingerprint the dialer relies on the listener's code proof.
        let mac = makePeer("mac"), phone = makePeer("phone")
        do {
            _ = try await connect(mac, phone, code: PairingCode(), pairing: DialPairing(code: "ZZZZZZZZZZ", fingerprint: nil))
            XCTFail("should fail")
        } catch let e as ABError {
            XCTAssertEqual(e.code, .authFailed)
        }
    }

    func testFingerprintMismatchIsRejected() async throws {
        let mac = makePeer("mac"), phone = makePeer("phone")
        let code = PairingCode()
        do {
            _ = try await connect(mac, phone, code: code, pairing: DialPairing(code: code.code, fingerprint: Data(repeating: 7, count: 32)))
            XCTFail("should fail")
        } catch let e as ABError {
            XCTAssertEqual(e.code, .authFailed)
        }
    }

    func testExpiredCodeIsRejected() async throws {
        let mac = makePeer("mac"), phone = makePeer("phone")
        let code = PairingCode(now: Date().addingTimeInterval(-400))
        do {
            _ = try await connect(mac, phone, code: code, pairing: DialPairing(code: code.code, fingerprint: mac.local.identity.fingerprint))
            XCTFail("should fail")
        } catch let e as ABError {
            XCTAssertEqual(e.code, .pairingExpired)
        }
    }

    func testDeclinedPairing() async throws {
        let mac = makePeer("mac"), phone = makePeer("phone")
        let code = PairingCode()
        do {
            _ = try await connect(mac, phone, code: code, pairing: DialPairing(code: code.code, fingerprint: mac.local.identity.fingerprint),
                                  approve: false)
            XCTFail("should fail")
        } catch let e as ABError {
            XCTAssertEqual(e.code, .pairingRejected)
        }
        XCTAssertTrue(mac.trust.all.isEmpty && phone.trust.all.isEmpty)
    }

    func testUnsupportedVersionAndOversizedFrame() async throws {
        let mac = makePeer("mac")
        let listener = Listener()
        let result = Box<Error?>(nil)
        let sem = AsyncSemaphore()
        let port = try await listener.start(port: 0, bonjourName: nil, deviceId: "t") { stream in
            Task {
                do {
                    try await stream.waitReady(timeout: 5)
                    _ = try await Handshake.accept(stream: stream, local: mac.local, trust: mac.trust, activeCode: { nil }, approve: { _ in true })
                } catch { result.value = error }
                sem.signal()
            }
        }
        defer { listener.stop() }
        // Version 2-only dialer.
        let s = try await ByteStream.connect(host: "127.0.0.1", port: port)
        try await HandshakeFrame.write(Data(#"{"type":"hello","proto":2,"minProto":2,"eph":"AA==","nonce":"AA=="}"#.utf8), to: s)
        let reply = try await HandshakeFrame.read(from: s)
        XCTAssertEqual(try JSONCodec.decode(ErrorMsg.self, reply).code, "unsupported_version")
        await sem.wait()
        XCTAssertEqual((result.value as? ABError)?.code, .unsupportedVersion)
        s.close()
        // Oversized frame header.
        let s2 = try await ByteStream.connect(host: "127.0.0.1", port: port)
        try await s2.write(ABCrypto.u32(10_000_000))
        await sem.wait()
        XCTAssertEqual((result.value as? ABError)?.code, .malformed)
        s2.close()
    }

    // MARK: Transfers

    func testTransferVariety() async throws {
        let mac = makePeer("mac"), phone = makePeer("phone")
        let (l, d) = try await pair(mac, phone)
        let recv = tmp.appendingPathComponent("recv")
        let ev = Box<[SessionEvent]>([])
        let rs = session(l, recv, events: ev)
        let ss = session(d, tmp)
        let files = [write("1KB.bin", bytes: 1024), write("1MB.bin", bytes: 1 << 20), write("empty.txt", bytes: 0),
                     write("日本語 résumé 🎉.pdf", bytes: 3333)]
        let folder = tmp.appendingPathComponent("src/Album")
        _ = write("Album/a.jpg", bytes: 5000); _ = write("Album/Sub/b.mov", bytes: 70_000)
        let r = await ss.send(try OutgoingFile.collect(files + [folder]))
        XCTAssertNil(r.error, "\(String(describing: r.error))")
        XCTAssertEqual(r.files.count, 6)
        let rr = await waitForResult(ev)
        XCTAssertNil(rr?.error)
        for f in files { XCTAssertEqual(sha(f), sha(recv.appendingPathComponent(f.lastPathComponent.precomposedStringWithCanonicalMapping))) }
        XCTAssertEqual(sha(tmp.appendingPathComponent("src/Album/Sub/b.mov")), sha(recv.appendingPathComponent("Album/Sub/b.mov")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recv.appendingPathComponent(".airbridge-partial").path))
        await rs.close(); await ss.close()
    }

    func testNameConflictsNeverOverwrite() async throws {
        let mac = makePeer("mac"), phone = makePeer("phone")
        let (l, d) = try await pair(mac, phone)
        let recv = tmp.appendingPathComponent("recv")
        try FileManager.default.createDirectory(at: recv.appendingPathComponent("Album"), withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: recv.appendingPathComponent("photo.jpg"))
        let ev = Box<[SessionEvent]>([])
        let rs = session(l, recv, events: ev), ss = session(d, tmp)
        let f = write("photo.jpg", bytes: 100)
        _ = write("Album/x.jpg", bytes: 10)
        let r = await ss.send(try OutgoingFile.collect([f, tmp.appendingPathComponent("src/Album")]))
        XCTAssertNil(r.error)
        _ = await waitForResult(ev)
        XCTAssertEqual(try String(contentsOf: recv.appendingPathComponent("photo.jpg"), encoding: .utf8), "keep me")
        XCTAssertEqual(sha(f), sha(recv.appendingPathComponent("photo (1).jpg")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recv.appendingPathComponent("Album (1)/x.jpg").path))
        await rs.close(); await ss.close()
    }

    func testUnsafePathsAreRejected() async throws {
        let mac = makePeer("mac"), phone = makePeer("phone")
        let (l, d) = try await pair(mac, phone)
        let recv = tmp.appendingPathComponent("recv")
        let rs = session(l, recv), ss = session(d, tmp)
        let f = write("x.bin", bytes: 10)
        for bad in ["../escape.bin", "/etc/x", "a/../../b", "C:/x"] {
            let r = await ss.send([OutgoingFile(url: f, path: bad, size: 10, mtime: 0, mime: nil)])
            XCTAssertEqual(r.error?.code, .invalidPath, bad)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("escape.bin").path))
        await rs.close(); await ss.close()
    }

    func testBidirectionalSimultaneousTransfers() async throws {
        let mac = makePeer("mac"), phone = makePeer("phone")
        let (l, d) = try await pair(mac, phone)
        let a = session(l, tmp.appendingPathComponent("recvMac"))
        let b = session(d, tmp.appendingPathComponent("recvPhone"))
        let f1 = write("toPhone.bin", bytes: 30 << 20), f2 = write("toMac.bin", bytes: 30 << 20)
        let o1 = try OutgoingFile.collect([f1]), o2 = try OutgoingFile.collect([f2])
        async let r1 = a.send(o1)
        async let r2 = b.send(o2)
        let (x, y) = await (r1, r2)
        XCTAssertNil(x.error); XCTAssertNil(y.error)
        XCTAssertEqual(sha(f1), sha(tmp.appendingPathComponent("recvPhone/toPhone.bin")))
        XCTAssertEqual(sha(f2), sha(tmp.appendingPathComponent("recvMac/toMac.bin")))
        await a.close(); await b.close()
    }

    func testCancelBySenderRemovesPartial() async throws {
        let mac = makePeer("mac"), phone = makePeer("phone")
        let (l, d) = try await pair(mac, phone)
        let recv = tmp.appendingPathComponent("recv")
        let ev = Box<[SessionEvent]>([])
        let rs = session(l, recv, storage: SlowStorage(FileSystemStorage(destination: recv)), events: ev)
        let ss = session(d, tmp, chunk: 64 * 1024)
        let f = write("big.bin", bytes: 80 << 20) // larger than everything in flight
        let t = Task { await ss.send(try! OutgoingFile.collect([f]), transferId: "cancel-me") }
        try await Task.sleep(nanoseconds: 300_000_000)
        ss.cancel(transferId: "cancel-me")
        let r = await t.value
        XCTAssertEqual(r.error?.code, .cancelled)
        let rr = await waitForResult(ev)
        XCTAssertEqual(rr?.error?.code, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recv.appendingPathComponent("big.bin").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recv.appendingPathComponent(".airbridge-partial/cancel-me").path))
        await rs.close(); await ss.close()
    }

    func testResumeAfterConnectionLoss() async throws {
        let mac = makePeer("mac"), phone = makePeer("phone")
        let recv = tmp.appendingPathComponent("recv")
        let f = write("video.mp4", bytes: 24 << 20)
        let files = try OutgoingFile.collect([f])

        // Attempt 1: drop the connection once the receiver has ~8 MB.
        let (l, d) = try await pair(mac, phone)
        let ev = Box<[SessionEvent]>([])
        let rs = session(l, recv, storage: SlowStorage(FileSystemStorage(destination: recv)), chunk: 256 * 1024, events: ev)
        let ss = session(d, tmp, chunk: 256 * 1024)
        let t = Task { await ss.send(files, transferId: "resume-1") }
        while true {
            let progressed = { () -> Bool in
                objc_sync_enter(ev); defer { objc_sync_exit(ev) }
                return ev.value.contains { if case .progress(let p) = $0 { return p.bytesDone > 8 << 20 }; return false }
            }()
            if progressed { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        rs.closeNow()
        let r1 = await t.value
        XCTAssertEqual(r1.error?.code, .connectionLost)
        let partial = recv.appendingPathComponent(".airbridge-partial/resume-1/0.part")
        let kept = (try FileManager.default.attributesOfItem(atPath: partial.path)[.size] as! NSNumber).int64Value
        XCTAssertGreaterThan(kept, 0)
        await ss.close()

        // Attempt 2: reconnect (full re-authentication) and re-offer the same transferId.
        let (l2, d2) = try await connect(mac, phone, code: nil, pairing: nil)
        let ev2 = Box<[SessionEvent]>([])
        let rs2 = session(l2, recv, events: ev2)
        let ss2 = session(d2, tmp)
        let r2 = await ss2.send(files, transferId: "resume-1")
        XCTAssertNil(r2.error)
        XCTAssertLessThan(r2.bytes, Int64(24 << 20), "only the remainder is sent")
        _ = await waitForResult(ev2)
        XCTAssertEqual(sha(f), sha(recv.appendingPathComponent("video.mp4")))
        await rs2.close(); await ss2.close()
    }

    func testCorruptionIsDetectedByHash() async throws {
        let mac = makePeer("mac"), phone = makePeer("phone")
        let (l, d) = try await pair(mac, phone)
        let recv = tmp.appendingPathComponent("recv")
        let rs = session(l, recv, storage: CorruptingStorage(FileSystemStorage(destination: recv)))
        let ss = session(d, tmp)
        let r = await ss.send(try OutgoingFile.collect([write("doc.pdf", bytes: 100_000)]))
        XCTAssertEqual(r.error?.code, .hashMismatch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recv.appendingPathComponent("doc.pdf").path), "corrupt file must not be published")
        await rs.close(); await ss.close()
    }

    func testDiskFullAbortsTransfer() async throws {
        let mac = makePeer("mac"), phone = makePeer("phone")
        let (l, d) = try await pair(mac, phone)
        let recv = tmp.appendingPathComponent("recv")
        let rs = session(l, recv, storage: FullDiskStorage(FileSystemStorage(destination: recv)))
        let ss = session(d, tmp)
        let r = await ss.send(try OutgoingFile.collect([write("a.bin", bytes: 3 << 20)]))
        XCTAssertEqual(r.error?.code, .insufficientStorage)
        await rs.close(); await ss.close()
    }

    func testInsufficientCapacityRejectsOffer() async throws {
        let mac = makePeer("mac"), phone = makePeer("phone")
        let (l, d) = try await pair(mac, phone)
        let recv = tmp.appendingPathComponent("recv")
        let rs = session(l, recv, storage: TinyStorage(FileSystemStorage(destination: recv)))
        let ss = session(d, tmp)
        let r = await ss.send(try OutgoingFile.collect([write("a.bin", bytes: 1000)]))
        XCTAssertEqual(r.error?.code, .insufficientStorage)
        await rs.close(); await ss.close()
    }

    func testInvalidResumeOffsetFromPeerIsRejected() async throws {
        let mac = makePeer("mac"), phone = makePeer("phone")
        let (l, d) = try await pair(mac, phone)
        let ss = session(d, tmp)
        // A misbehaving receiver answers with an offset beyond the file size.
        Task {
            while true {
                guard case .control(let type, let json) = try await l.channel.receive() else { continue }
                if type == "offer" {
                    let o = try JSONCodec.decode(OfferMsg.self, json)
                    try await l.channel.sendControl(AcceptMsg(transferId: o.transferId, files: [AcceptFile(id: 0, offset: 999_999)]))
                }
            }
        }
        let r = await ss.send(try OutgoingFile.collect([write("a.bin", bytes: 1000)]))
        XCTAssertEqual(r.error?.code, .resumeInvalid)
        l.channel.close(); await ss.close()
    }

    func testMalformedRecordClosesSession() async throws {
        let mac = makePeer("mac"), phone = makePeer("phone")
        let (l, d) = try await pair(mac, phone)
        let rs = session(l, tmp)
        try await d.channel.stream.write(ABCrypto.u32(64) + ABCrypto.randomBytes(64)) // garbage ciphertext
        let err = await rs.waitClosed()
        XCTAssertEqual(err?.code, .malformed)
        d.channel.close()
    }
}

// MARK: - Test storages

final class AsyncSemaphore: @unchecked Sendable {
    private let lock = ABLock()
    private var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() {
        lock.lock()
        if waiters.isEmpty { count += 1; lock.unlock() } else { let w = waiters.removeFirst(); lock.unlock(); w.resume() }
    }
    func wait() async {
        await withCheckedContinuation { c in
            lock.lock()
            if count > 0 { count -= 1; lock.unlock(); c.resume() } else { waiters.append(c); lock.unlock() }
        }
    }
}

class WrappedStorage: ReceiveStorage, @unchecked Sendable {
    let inner: ReceiveStorage
    init(_ inner: ReceiveStorage) { self.inner = inner }
    func availableCapacity() -> Int64? { inner.availableCapacity() }
    func resumableOffset(transferId: String, peerId: String, file: OfferFile, path: String) -> Int64 {
        inner.resumableOffset(transferId: transferId, peerId: peerId, file: file, path: path)
    }
    func openWriter(transferId: String, peerId: String, file: OfferFile, path: String, offset: Int64) throws -> IncomingFileWriter {
        wrap(try inner.openWriter(transferId: transferId, peerId: peerId, file: file, path: path, offset: offset))
    }
    func wrap(_ w: IncomingFileWriter) -> IncomingFileWriter { w }
    func discard(transferId: String) { inner.discard(transferId: transferId) }
    func finish(transferId: String) { inner.finish(transferId: transferId) }
}

class WriterProxy: IncomingFileWriter {
    let w: IncomingFileWriter
    init(_ w: IncomingFileWriter) { self.w = w }
    func readPrefix(_ body: (Data) throws -> Void) throws { try w.readPrefix(body) }
    func write(_ data: Data) throws { try w.write(data) }
    func finalize() throws -> String { try w.finalize() }
    func close(keep: Bool) { w.close(keep: keep) }
}

/// Slows writes so a test can interrupt mid-transfer.
final class SlowStorage: WrappedStorage, @unchecked Sendable {
    override func wrap(_ w: IncomingFileWriter) -> IncomingFileWriter {
        final class P: WriterProxy { override func write(_ d: Data) throws { usleep(3000); try super.write(d) } }
        return P(w)
    }
}

/// Flips one bit in the first chunk written (simulates storage corruption).
final class CorruptingStorage: WrappedStorage, @unchecked Sendable {
    override func wrap(_ w: IncomingFileWriter) -> IncomingFileWriter {
        final class P: WriterProxy {
            var done = false
            override func write(_ d: Data) throws {
                var d = d
                if !done, !d.isEmpty { d[d.startIndex] ^= 1; done = true }
                try super.write(d)
            }
        }
        return P(w)
    }
}

/// Fails with ENOSPC after 1 MB.
final class FullDiskStorage: WrappedStorage, @unchecked Sendable {
    override func wrap(_ w: IncomingFileWriter) -> IncomingFileWriter {
        final class P: WriterProxy {
            var n = 0
            override func write(_ d: Data) throws {
                n += d.count
                if n > 1 << 20 { throw ABError(.insufficientStorage, "Disk full") }
                try super.write(d)
            }
        }
        return P(w)
    }
}

final class TinyStorage: WrappedStorage, @unchecked Sendable {
    override func availableCapacity() -> Int64? { 10 }
}
