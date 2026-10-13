import CryptoKit
import Foundation

public enum Record {
    case control(type: String, json: Data)
    case data(stream: UInt32, bytes: Data)
}

/// Encrypted record layer (SPEC §4.2) on top of a `ByteStream`.
///
/// Sends are pipelined: up to `maxInFlight` bytes may be queued in the network stack
/// before `send` suspends, so disk reads overlap with transmission (backpressure).
public final class SecureChannel: @unchecked Sendable {
    public let stream: ByteStream
    private let lock = ABLock()
    private var sendCipher: RecordCipher
    private var recvCipher: RecordCipher // only used by the single reader task
    private var inFlight = 0
    private var sendError: Error?
    private var drainWaiters: [CheckedContinuation<Void, Error>] = []
    public let maxInFlight: Int
    public private(set) var lastSend = Date()

    public init(stream: ByteStream, sendKey: SymmetricKey, recvKey: SymmetricKey, maxInFlight: Int = 8 * 1024 * 1024) {
        self.stream = stream
        self.sendCipher = RecordCipher(key: sendKey)
        self.recvCipher = RecordCipher(key: recvKey)
        self.maxInFlight = maxInFlight
    }

    /// `urgent` control messages skip the in-flight limit. The reader task must use it:
    /// if both peers stream simultaneously and the readers blocked on capacity while
    /// replying, each would wait for the other to read — a deadlock.
    public func sendControl<T: Encodable>(_ message: T, urgent: Bool = false) async throws {
        var pt = Data([ABProtocol.recordControl])
        pt.append(JSONCodec.encode(message))
        try await send(plaintext: pt, urgent: urgent)
    }

    public func sendData(stream id: UInt32, _ bytes: Data) async throws {
        precondition(!bytes.isEmpty && bytes.count <= ABProtocol.maxDataPayload)
        var pt = Data(capacity: bytes.count + 5)
        pt.append(ABProtocol.recordData)
        var be = id.bigEndian
        pt.append(Data(bytes: &be, count: 4))
        pt.append(bytes)
        try await send(plaintext: pt)
    }

    private func send(plaintext: Data, urgent: Bool = false) async throws {
        if !urgent { try await waitForCapacity() }
        lock.lock()
        if let e = sendError { lock.unlock(); throw e }
        let sealed: Data
        do { sealed = try sendCipher.seal(plaintext) } catch { lock.unlock(); throw error }
        var frame = ABCrypto.u32(sealed.count)
        frame.append(sealed)
        let size = frame.count
        inFlight += size
        lastSend = Date()
        // Enqueue while holding the lock so wire order == nonce order.
        stream.send(frame) { [weak self] err in self?.completed(size: size, error: err) }
        lock.unlock()
    }

    private func completed(size: Int, error: Error?) {
        lock.lock()
        inFlight -= size
        if let error, sendError == nil { sendError = error }
        let waiters = drainWaiters
        drainWaiters = []
        let err = sendError
        lock.unlock()
        for w in waiters {
            if let err { w.resume(throwing: err) } else { w.resume() }
        }
    }

    private func waitForCapacity() async throws {
        while true {
            lock.lock()
            if let e = sendError { lock.unlock(); throw e }
            if inFlight < maxInFlight { lock.unlock(); return }
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                drainWaiters.append(c)
                lock.unlock()
            }
        }
    }

    /// Waits until everything queued so far has been handed to the network stack.
    public func flush() async throws {
        while true {
            lock.lock()
            if let e = sendError { lock.unlock(); throw e }
            if inFlight == 0 { lock.unlock(); return }
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                drainWaiters.append(c)
                lock.unlock()
            }
        }
    }

    /// Reads and authenticates the next record. Must be called from one task only.
    public func receive() async throws -> Record {
        let header = try await stream.readExactly(4)
        let len = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
        guard len >= 17, len <= ABProtocol.maxRecordCiphertext else {
            throw ABError(.malformed, "Bad record length \(len)")
        }
        let body = try await stream.readExactly(len)
        let pt = try recvCipher.open(body)
        guard let kind = pt.first else { throw ABError(.malformed, "Empty record") }
        switch kind {
        case ABProtocol.recordControl:
            let json = pt.dropFirst()
            guard json.count <= ABProtocol.maxControlJSON else { throw ABError(.malformed, "Control too large") }
            let j = Data(json)
            return .control(type: try JSONCodec.type(of: j), json: j)
        case ABProtocol.recordData:
            guard pt.count > 5 else { throw ABError(.malformed, "Empty data record") }
            let idBytes = pt.subdata(in: pt.startIndex + 1 ..< pt.startIndex + 5)
            let id = idBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
            return .data(stream: id, bytes: pt.subdata(in: pt.startIndex + 5 ..< pt.endIndex))
        default:
            throw ABError(.malformed, "Unknown record type \(kind)")
        }
    }

    public func close() { stream.close() }
}

/// Plaintext handshake frames (SPEC §4.1).
enum HandshakeFrame {
    static func write(_ json: Data, to s: ByteStream) async throws {
        var f = ABCrypto.u32(json.count)
        f.append(json)
        try await s.write(f)
    }

    static func read(from s: ByteStream) async throws -> Data {
        let h = try await s.readExactly(4)
        let len = Int(h.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
        guard len >= 1, len <= ABProtocol.maxHandshakeFrame else {
            throw ABError(.malformed, "Bad handshake frame length")
        }
        return try await s.readExactly(len)
    }
}
