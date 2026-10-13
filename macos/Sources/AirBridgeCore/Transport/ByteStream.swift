import Foundation
import Network

/// A TCP byte stream over `NWConnection` with async read/write.
public final class ByteStream: @unchecked Sendable {
    public let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = ABLock()
    private var closed = false

    /// Wraps a connection; starts it if needed.
    public init(connection: NWConnection, queue: DispatchQueue = DispatchQueue(label: "airbridge.stream")) {
        self.connection = connection
        self.queue = queue
    }

    public static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true // control messages must not wait behind Nagle
        tcp.connectionTimeout = 10
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 20
        let params = NWParameters(tls: nil, tcp: tcp)
        params.serviceClass = .responsiveData
        return params
    }

    /// Opens a TCP connection, failing with `.connectionFailed` after `timeout`.
    public static func connect(host: String, port: UInt16, timeout: TimeInterval = 10) async throws -> ByteStream {
        guard let p = NWEndpoint.Port(rawValue: port) else { throw ABError(.connectionFailed, "Bad port") }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: tcpParameters())
        let stream = ByteStream(connection: conn)
        try await stream.waitReady(timeout: timeout)
        return stream
    }

    /// Starts an accepted or new connection and waits until it is ready.
    public func waitReady(timeout: TimeInterval) async throws {
        let once = OnceFlag()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.fire() { cont.resume() }
                case .failed(let e):
                    if once.fire() { cont.resume(throwing: ABError(.connectionFailed, "\(e)")) }
                case .waiting(let e):
                    // .waiting means the path is unusable (e.g. host unreachable); fail fast.
                    if once.fire() { cont.resume(throwing: ABError(.connectionFailed, "\(e)")) }
                    self?.close()
                case .cancelled:
                    if once.fire() { cont.resume(throwing: ABError(.connectionFailed, "cancelled")) }
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                if once.fire() {
                    cont.resume(throwing: ABError(.timeout, "Connection timed out"))
                    self?.close()
                }
            }
            connection.start(queue: queue)
        }
    }

    public var remoteHost: String? {
        if case .hostPort(let host, _) = connection.endpoint {
            var s = "\(host)"
            if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) } // strip interface scope
            return s
        }
        return nil
    }

    public func readExactly(_ n: Int) async throws -> Data {
        if n == 0 { return Data() }
        return try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, isComplete, error in
                if let data, data.count == n {
                    cont.resume(returning: data)
                } else if let error {
                    cont.resume(throwing: ABError(.connectionLost, "\(error)"))
                } else {
                    _ = isComplete
                    cont.resume(throwing: ABError(.connectionLost, "Connection closed by peer"))
                }
            }
        }
    }

    /// Enqueues data; `completion` fires once the stack has taken it.
    public func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        connection.send(content: data, completion: .contentProcessed { err in
            completion(err.map { ABError(.connectionLost, "\($0)") })
        })
    }

    public func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            send(data) { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            }
        }
    }

    public func close() {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        if !wasClosed { connection.cancel() }
    }

    public var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
}

/// Thread-safe "first caller wins" flag for resuming continuations exactly once.
final class OnceFlag: @unchecked Sendable {
    private let lock = ABLock()
    private var done = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
