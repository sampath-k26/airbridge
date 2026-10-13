import CryptoKit
import Foundation

/// Single-value async handoff; the first `put` wins.
final class Mailbox<T: Sendable>: @unchecked Sendable {
    private let lock = ABLock()
    private var value: T?
    private var waiter: CheckedContinuation<T, Never>?

    func put(_ v: T) {
        lock.lock()
        guard value == nil else { lock.unlock(); return }
        value = v
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(returning: v)
    }

    func take(onCancel: T) async -> T {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
                lock.lock()
                if let v = value { lock.unlock(); c.resume(returning: v); return }
                waiter = c
                lock.unlock()
            }
        } onCancel: { put(onCancel) }
    }
}

/// Receiver's decision policy: return true to accept the offer.
public typealias OfferDecider = @Sendable (IncomingOffer) async -> Bool

/// An authenticated, full-duplex session with one peer (SPEC §6).
public final class Session: @unchecked Sendable {
    public let peer: PeerRecord
    public let verificationCode: String
    let channel: SecureChannel
    let storage: ReceiveStorage
    let decide: OfferDecider
    let onEvent: @Sendable (SessionEvent) -> Void
    public var chunkSize: Int

    private let lock = ABLock()
    private var outgoing: [String: OutgoingState] = [:]
    private var incoming: [String: IncomingState] = [:]
    private var streams: [UInt32: IncomingFile] = [:]
    private var nextStream: UInt32 = 1
    private var closed = false
    private var lastReceive = Date()
    private var keepalive: Task<Void, Never>?
    private let closedBox = Mailbox<ABError?>()

    public init(handshake: HandshakeResult, storage: ReceiveStorage, chunkSize: Int = ABProtocol.defaultChunkSize,
                decide: @escaping OfferDecider, onEvent: @escaping @Sendable (SessionEvent) -> Void) {
        self.peer = handshake.peer
        self.verificationCode = handshake.verificationCode
        self.channel = handshake.channel
        self.storage = storage
        self.chunkSize = min(max(chunkSize, 4096), ABProtocol.maxDataPayload)
        self.decide = decide
        self.onEvent = onEvent
    }

    public var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    public func start() {
        Task.detached(priority: .userInitiated) { [self] in await readLoop() }
        keepalive = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !self.isClosed else { return }
                if Date().timeIntervalSince(self.channel.lastSend) > ABProtocol.pingInterval {
                    try? await self.channel.sendControl(SimpleMsg(type: "ping"), urgent: true)
                }
                self.lock.lock(); let idle = Date().timeIntervalSince(self.lastReceive); self.lock.unlock()
                if idle > ABProtocol.idleTimeout {
                    self.shutdown(ABError(.timeout, "No data from peer for \(Int(idle)) s"))
                }
            }
        }
    }

    /// Waits until the session ends; returns the error (nil = closed locally).
    public func waitClosed() async -> ABError? { await closedBox.take(onCancel: nil) }

    /// Closes after queued messages (e.g. the final `transfer_done`) have been sent.
    public func close() async {
        _ = try? await withTimeout(2, onTimeout: {}) { [channel] in try await channel.flush() }
        shutdown(nil)
    }

    /// Closes immediately; queued messages may be lost.
    public func closeNow() { shutdown(nil) }

    // MARK: - Sending

    /// Sends files and waits for the receiver's verdict. Never throws; failures are in
    /// `TransferResult.error`. Cancel by cancelling the calling task or `cancel(transferId:)`.
    public func send(_ files: [OutgoingFile], transferId: String = UUID().uuidString.lowercased()) async -> TransferResult {
        let start = Date()
        let offerFiles = files.enumerated().map {
            OfferFile(id: $0.offset, path: $0.element.path, size: $0.element.size, mtime: $0.element.mtime, mime: $0.element.mime)
        }
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        let state = OutgoingState(transferId: transferId, files: offerFiles)
        lock.lock()
        if closed { lock.unlock(); return failure(transferId, .send, start, ABError(.connectionLost, "Not connected")) }
        outgoing[transferId] = state
        lock.unlock()
        defer { lock.lock(); outgoing[transferId] = nil; lock.unlock() }

        do {
            guard !files.isEmpty, files.count <= ABProtocol.maxFilesPerOffer else {
                throw ABError(.invalidPath, "1–\(ABProtocol.maxFilesPerOffer) files per transfer")
            }
            try await channel.sendControl(OfferMsg(transferId: transferId, totalBytes: total, files: offerFiles))
            let accept = try await state.response.take(onCancel: .failure(ABError(.cancelled, "Cancelled"))).get()

            var offsets: [Int: Int64] = [:]
            for f in accept.files where f.id >= 0 && f.id < files.count {
                guard f.offset >= 0, f.offset <= files[f.id].size else { throw ABError(.resumeInvalid, "Bad resume offset") }
                offsets[f.id] = f.offset
            }
            state.setExpected(Set(offsets.keys))
            let resumed = offsets.values.reduce(Int64(0), +)
            onEvent(.started(transferId: transferId, direction: .send, files: offerFiles, totalBytes: total))
            let progress = ProgressThrottle(transferId: transferId, direction: .send, total: total,
                                            fileCount: files.count, done: resumed, onEvent: onEvent)

            for (idx, file) in files.enumerated() {
                guard let offset = offsets[idx] else { continue }
                try state.checkCancelled()
                try await sendFile(file, id: idx, offset: offset, state: state, progress: progress)
            }
            progress.emit(force: true, current: nil)
            let done = await state.done.take(onCancel: .failure(ABError(.cancelled, "Cancelled")))
            if case .failure(let e) = done { throw e }
            let result = state.result(direction: .send, bytes: total - resumed, start: start)
            onEvent(.finished(result))
            return result
        } catch {
            let e = (error as? ABError) ?? ABError(.internalError, "\(error)")
            if e.code == .cancelled || e.code == .readFailed || e.code == .resumeInvalid || e.code == .invalidPath {
                if !state.peerCancelled {
                    try? await channel.sendControl(CancelMsg(transferId: transferId, reason: e.code.rawValue), urgent: true)
                }
            }
            let r = failure(transferId, .send, start, e, partial: state)
            onEvent(.finished(r))
            return r
        }
    }

    private func sendFile(_ file: OutgoingFile, id: Int, offset: Int64, state: OutgoingState, progress: ProgressThrottle) async throws {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: file.url) } catch {
            throw ABError(.readFailed, "Cannot open \(file.path)")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        var pos: Int64 = 0
        do {
            // Resume: the receiver keeps the prefix; we only need it for the full-file hash.
            while pos < offset {
                guard let d = try handle.read(upToCount: Int(min(Int64(chunkSize), offset - pos))), !d.isEmpty else {
                    throw ABError(.readFailed, "\(file.path) is shorter than expected")
                }
                hasher.update(data: d)
                pos += Int64(d.count)
            }
        } catch let e as ABError { throw e } catch { throw ABError(.readFailed, error.localizedDescription) }

        lock.lock(); let stream = nextStream; nextStream &+= 1; lock.unlock()
        try await channel.sendControl(FileBeginMsg(transferId: state.transferId, fileId: id, stream: stream, offset: offset))
        while pos < file.size {
            try state.checkCancelled()
            if Task.isCancelled { throw ABError(.cancelled, "Cancelled") }
            let d: Data
            do {
                guard let r = try handle.read(upToCount: Int(min(Int64(chunkSize), file.size - pos))), !r.isEmpty else {
                    throw ABError(.readFailed, "\(file.path) changed while sending")
                }
                d = r
            } catch let e as ABError { throw e } catch { throw ABError(.readFailed, error.localizedDescription) }
            hasher.update(data: d)
            try await channel.sendData(stream: stream, d)
            pos += Int64(d.count)
            progress.add(Int64(d.count), current: file.path)
        }
        // Detect modification during the transfer (size grew or mtime changed).
        if let v = try? file.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
           Int64(v.fileSize ?? 0) != file.size
            || Int64((v.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000) != file.mtime {
            throw ABError(.readFailed, "\(file.path) was modified during the transfer")
        }
        let digest = ABCrypto.hex(Data(hasher.finalize()))
        try await channel.sendControl(FileEndMsg(transferId: state.transferId, fileId: id, sha256: digest))
    }

    /// Cancels an outgoing or incoming transfer.
    public func cancel(transferId: String) {
        lock.lock()
        let out = outgoing[transferId]
        let inc = incoming.removeValue(forKey: transferId)
        if let inc { for s in inc.streams { streams[s]?.writer.close(keep: false); streams[s] = nil } }
        lock.unlock()
        if let out {
            out.cancelLocally()
        }
        if let inc {
            storage.discard(transferId: transferId)
            Task { try? await channel.sendControl(CancelMsg(transferId: transferId, reason: "cancelled"), urgent: true) }
            onEvent(.finished(inc.result(error: ABError(.cancelled, "Cancelled"))))
        }
    }

    // MARK: - Reading

    private func readLoop() async {
        do {
            while true {
                let rec = try await channel.receive()
                lock.lock(); lastReceive = Date(); lock.unlock()
                switch rec {
                case .data(let stream, let bytes): await handleData(stream: stream, bytes)
                case .control(let type, let json): try await handleControl(type, json)
                }
            }
        } catch {
            shutdown((error as? ABError) ?? ABError(.connectionLost, "\(error)"))
        }
    }

    private func handleControl(_ type: String, _ json: Data) async throws {
        switch type {
        case "ping":
            try await channel.sendControl(SimpleMsg(type: "pong"), urgent: true)
        case "pong":
            break
        case "offer":
            let m = try JSONCodec.decode(OfferMsg.self, json)
            Task { await self.handleOffer(m) }
        case "accept":
            let m = try JSONCodec.decode(AcceptMsg.self, json)
            outgoingState(m.transferId)?.response.put(.success(m))
        case "reject":
            let m = try JSONCodec.decode(RejectMsg.self, json)
            outgoingState(m.transferId)?.response.put(.failure(ABError(ABErrorCode(rawValue: m.code) ?? .declined, m.message)))
        case "file_begin":
            try handleFileBegin(try JSONCodec.decode(FileBeginMsg.self, json))
        case "file_end":
            try await handleFileEnd(try JSONCodec.decode(FileEndMsg.self, json))
        case "file_ok":
            let m = try JSONCodec.decode(FileOkMsg.self, json)
            if let s = outgoingState(m.transferId) {
                let f = s.fileOk(m.fileId)
                if let f { onEvent(.fileDone(transferId: m.transferId, direction: .send, file: f)) }
            }
        case "file_failed":
            let m = try JSONCodec.decode(FileFailedMsg.self, json)
            outgoingState(m.transferId)?.fileFailed(m.fileId, ABError(ABErrorCode(rawValue: m.code) ?? .internalError, m.message))
        case "transfer_done":
            let m = try JSONCodec.decode(TransferDoneMsg.self, json)
            outgoingState(m.transferId)?.done.put(.success(()))
        case "cancel":
            let m = try JSONCodec.decode(CancelMsg.self, json)
            peerCancelled(m)
        case "error":
            let m = try JSONCodec.decode(ErrorMsg.self, json)
            throw ABError(ABErrorCode(rawValue: m.code) ?? .internalError, m.message)
        default:
            break // forward compatibility: ignore unknown messages
        }
    }

    private func outgoingState(_ id: String) -> OutgoingState? {
        lock.lock(); defer { lock.unlock() }
        return outgoing[id]
    }

    private func peerCancelled(_ m: CancelMsg) {
        let err = ABError(ABErrorCode(rawValue: m.reason) ?? .cancelled, "Cancelled by \(peer.name)")
        lock.lock()
        let out = outgoing[m.transferId]
        let inc = incoming.removeValue(forKey: m.transferId)
        if let inc { for s in inc.streams { streams[s]?.writer.close(keep: false); streams[s] = nil } }
        lock.unlock()
        out?.cancelByPeer(err)
        if let inc {
            storage.discard(transferId: m.transferId)
            onEvent(.finished(inc.result(error: err)))
        }
    }

    // MARK: Receiving

    private func handleOffer(_ m: OfferMsg) async {
        func reject(_ code: ABErrorCode, _ msg: String) async {
            try? await channel.sendControl(RejectMsg(transferId: m.transferId, code: code.rawValue, message: msg), urgent: true)
        }
        guard !m.files.isEmpty, m.files.count <= ABProtocol.maxFilesPerOffer, !m.transferId.isEmpty, m.transferId.count <= 64
        else { return await reject(.malformed, "Invalid offer") }
        lock.lock(); let dup = incoming[m.transferId] != nil; lock.unlock()
        if dup { return await reject(.busy, "Transfer already in progress") }

        var sanitized: [OfferFile] = []
        var seenIds = Set<Int>(), seenPaths = Set<String>()
        for f in m.files {
            guard f.id >= 0, f.size >= 0, seenIds.insert(f.id).inserted, let p = PathSanitizer.sanitize(f.path),
                  seenPaths.insert(p.lowercased()).inserted
            else { return await reject(.invalidPath, "Unsafe or duplicate file name") }
            sanitized.append(OfferFile(id: f.id, path: p, size: f.size, mtime: f.mtime, mime: f.mime))
        }
        var offsets: [Int: Int64] = [:]
        for f in sanitized {
            offsets[f.id] = storage.resumableOffset(transferId: m.transferId, peerId: peer.deviceId, file: f, path: f.path)
        }
        let total = sanitized.reduce(Int64(0)) { $0 + $1.size }
        let resumed = offsets.values.reduce(Int64(0), +)
        if let free = storage.availableCapacity(), total - resumed > free {
            return await reject(.insufficientStorage, "Needs \(total - resumed) bytes, \(free) free")
        }
        let offer = IncomingOffer(transferId: m.transferId, peer: peer, files: sanitized, totalBytes: total, resumedBytes: resumed)
        onEvent(.offer(offer))
        guard await decide(offer) else { return await reject(.declined, "Declined by user") }
        guard !isClosed else { return }

        let state = IncomingState(transferId: m.transferId, files: sanitized, offsets: offsets, total: total,
                                  progress: ProgressThrottle(transferId: m.transferId, direction: .receive, total: total,
                                                             fileCount: sanitized.count, done: resumed, onEvent: onEvent))
        lock.lock(); incoming[m.transferId] = state; lock.unlock()
        onEvent(.started(transferId: m.transferId, direction: .receive, files: sanitized, totalBytes: total))
        try? await channel.sendControl(AcceptMsg(transferId: m.transferId,
                                                 files: sanitized.map { AcceptFile(id: $0.id, offset: offsets[$0.id] ?? 0) }),
                                       urgent: true)
    }

    private func handleFileBegin(_ m: FileBeginMsg) throws {
        lock.lock()
        guard let state = incoming[m.transferId] else { lock.unlock(); return } // cancelled: ignore
        guard let file = state.files[m.fileId], state.status[m.fileId] == nil, streams[m.stream] == nil else {
            lock.unlock(); throw ABError(.malformed, "Unexpected file_begin")
        }
        lock.unlock()
        guard m.offset == state.offsets[m.fileId] else { throw ABError(.resumeInvalid, "file_begin offset mismatch") }
        do {
            let w = try storage.openWriter(transferId: m.transferId, peerId: peer.deviceId, file: file, path: file.path, offset: m.offset)
            lock.lock()
            streams[m.stream] = IncomingFile(state: state, file: file, writer: w, position: m.offset)
            state.streams.insert(m.stream)
            lock.unlock()
        } catch {
            let e = (error as? ABError) ?? ABError(.writeFailed, "\(error)")
            failTransfer(state, e)
        }
    }

    private func handleData(stream: UInt32, _ bytes: Data) async {
        lock.lock(); let f = streams[stream]; lock.unlock()
        guard let f else { return } // stream of a cancelled/failed transfer
        guard f.position + Int64(bytes.count) <= f.file.size else {
            return failFile(f, stream: stream, ABError(.sizeMismatch, "More data than announced"))
        }
        do {
            try f.writer.write(bytes)
        } catch {
            return failTransfer(f.state, (error as? ABError) ?? ABError(.writeFailed, "\(error)"))
        }
        f.position += Int64(bytes.count)
        f.state.progress.add(Int64(bytes.count), current: f.file.path)
    }

    private func handleFileEnd(_ m: FileEndMsg) async throws {
        lock.lock()
        guard let state = incoming[m.transferId] else { lock.unlock(); return }
        let entry = streams.first { $0.value.state === state && $0.value.file.id == m.fileId }
        lock.unlock()
        guard let (stream, f) = entry else {
            // Zero-length or already-failed file.
            lock.lock(); let failed = state.status[m.fileId] != nil; lock.unlock()
            if failed { return }
            throw ABError(.malformed, "file_end without file_begin")
        }
        lock.lock(); streams[stream] = nil; state.streams.remove(stream); lock.unlock()
        if f.position != f.file.size {
            f.writer.close(keep: false)
            return await reportFile(state, m.fileId, ABError(.sizeMismatch, "Received \(f.position) of \(f.file.size) bytes"))
        }
        // Integrity: hash what is actually stored (read back from the file), so disk/write
        // faults and resume-offset bugs are caught — not just network corruption, which
        // AES-GCM already rules out.
        var hasher = SHA256()
        do { try f.writer.readPrefix { hasher.update(data: $0) } } catch {
            f.writer.close(keep: false)
            return await reportFile(state, m.fileId, ABError(.writeFailed, "Cannot read back file: \(error)"))
        }
        let digest = ABCrypto.hex(Data(hasher.finalize()))
        guard digest == m.sha256.lowercased() else {
            f.writer.close(keep: false)
            return await reportFile(state, m.fileId, ABError(.hashMismatch, "SHA-256 mismatch"))
        }
        do {
            let saved = try f.writer.finalize()
            let done = CompletedFile(name: f.file.path, savedAs: saved, size: f.file.size)
            lock.lock(); state.status[m.fileId] = .ok(done); lock.unlock()
            try? await channel.sendControl(FileOkMsg(transferId: m.transferId, fileId: m.fileId,
                                                     name: (saved as NSString).lastPathComponent), urgent: true)
            onEvent(.fileDone(transferId: m.transferId, direction: .receive, file: done))
        } catch {
            f.writer.close(keep: false)
            return await reportFile(state, m.fileId, (error as? ABError) ?? ABError(.writeFailed, "\(error)"))
        }
        await finishIfComplete(state)
    }

    private func reportFile(_ state: IncomingState, _ id: Int, _ e: ABError) async {
        lock.lock(); state.status[id] = .failed(e); lock.unlock()
        try? await channel.sendControl(FileFailedMsg(transferId: state.transferId, fileId: id, code: e.code.rawValue,
                                                     message: e.message), urgent: true)
        await finishIfComplete(state)
    }

    private func finishIfComplete(_ state: IncomingState) async {
        lock.lock()
        let complete = state.status.count == state.files.count && incoming[state.transferId] === state
        if complete { incoming[state.transferId] = nil }
        lock.unlock()
        guard complete else { return }
        let r = state.result(error: nil)
        storage.finish(transferId: state.transferId)
        try? await channel.sendControl(TransferDoneMsg(transferId: state.transferId, ok: r.error == nil), urgent: true)
        state.progress.emit(force: true, current: nil)
        onEvent(.finished(r))
    }

    private func failFile(_ f: IncomingFile, stream: UInt32, _ e: ABError) {
        lock.lock(); streams[stream] = nil; f.state.streams.remove(stream); lock.unlock()
        f.writer.close(keep: false)
        Task { await reportFile(f.state, f.file.id, e) }
    }

    /// Storage-level failure (disk full, permission): abort the whole transfer.
    private func failTransfer(_ state: IncomingState, _ e: ABError) {
        lock.lock()
        let active = incoming[state.transferId] === state
        incoming[state.transferId] = nil
        for s in state.streams { streams[s]?.writer.close(keep: false); streams[s] = nil }
        lock.unlock()
        guard active else { return }
        storage.discard(transferId: state.transferId)
        Task { try? await channel.sendControl(CancelMsg(transferId: state.transferId, reason: e.code.rawValue), urgent: true) }
        onEvent(.finished(state.result(error: e)))
    }

    // MARK: - Shutdown

    private func shutdown(_ error: ABError?) {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        let outs = Array(outgoing.values)
        let ins = Array(incoming.values)
        incoming = [:]
        // Keep partial files: an interrupted transfer can resume after reconnect.
        for (_, f) in streams { f.writer.close(keep: true) }
        streams = [:]
        lock.unlock()
        keepalive?.cancel()
        channel.close()
        let err = error ?? ABError(.connectionLost, "Disconnected")
        for o in outs { o.response.put(.failure(err)); o.done.put(.failure(err)) }
        for i in ins { onEvent(.finished(i.result(error: err))) }
        onEvent(.closed(error))
        closedBox.put(error)
    }

    private func failure(_ id: String, _ dir: TransferDirection, _ start: Date, _ e: ABError, partial: OutgoingState? = nil) -> TransferResult {
        if let partial { return partial.result(direction: dir, bytes: 0, start: start, error: e) }
        return TransferResult(transferId: id, direction: dir, files: [], failed: [:], bytes: 0,
                              duration: Date().timeIntervalSince(start), error: e)
    }
}

// MARK: - Per-transfer state

final class OutgoingState: @unchecked Sendable {
    let transferId: String
    let files: [OfferFile]
    let response = Mailbox<Result<AcceptMsg, ABError>>()
    let done = Mailbox<Result<Void, ABError>>()
    private let lock = ABLock()
    private var expected: Set<Int> = []
    private var ok: [Int: CompletedFile] = [:]
    private var failed: [Int: ABError] = [:]
    private var cancelError: ABError?
    private(set) var peerCancelled = false

    init(transferId: String, files: [OfferFile]) { self.transferId = transferId; self.files = files }

    func setExpected(_ ids: Set<Int>) {
        lock.lock(); expected = ids; let empty = ids.isEmpty; lock.unlock()
        if empty { done.put(.success(())) }
    }

    func fileOk(_ id: Int) -> CompletedFile? {
        guard id >= 0 && id < files.count else { return nil }
        let f = CompletedFile(name: files[id].path, savedAs: nil, size: files[id].size)
        lock.lock(); ok[id] = f; lock.unlock()
        return f
    }

    func fileFailed(_ id: Int, _ e: ABError) { lock.lock(); failed[id] = e; lock.unlock() }

    func cancelLocally() {
        lock.lock(); if cancelError == nil { cancelError = ABError(.cancelled, "Cancelled") }; lock.unlock()
        response.put(.failure(ABError(.cancelled, "Cancelled")))
        done.put(.failure(ABError(.cancelled, "Cancelled")))
    }

    func cancelByPeer(_ e: ABError) {
        lock.lock(); peerCancelled = true; if cancelError == nil { cancelError = e }; lock.unlock()
        response.put(.failure(e))
        done.put(.failure(e))
    }

    func checkCancelled() throws {
        lock.lock(); defer { lock.unlock() }
        if let e = cancelError { throw e }
    }

    func result(direction: TransferDirection, bytes: Int64, start: Date, error: ABError? = nil) -> TransferResult {
        lock.lock(); defer { lock.unlock() }
        var failedByName: [String: ABError] = [:]
        for (id, e) in failed where id < files.count { failedByName[files[id].path] = e }
        var err = error
        if err == nil, let first = failed.values.first { err = first }
        if err == nil, ok.count < expected.count { err = ABError(.internalError, "Missing file confirmations") }
        return TransferResult(transferId: transferId, direction: direction,
                              files: ok.keys.sorted().compactMap { ok[$0] }, failed: failedByName,
                              bytes: bytes, duration: Date().timeIntervalSince(start), error: err)
    }
}

final class IncomingState: @unchecked Sendable {
    enum Status { case ok(CompletedFile), failed(ABError) }
    let transferId: String
    let files: [Int: OfferFile]
    let offsets: [Int: Int64]
    let total: Int64
    let progress: ProgressThrottle
    let start = Date()
    var status: [Int: Status] = [:]   // guarded by Session.lock
    var streams: Set<UInt32> = []     // guarded by Session.lock

    init(transferId: String, files: [OfferFile], offsets: [Int: Int64], total: Int64, progress: ProgressThrottle) {
        self.transferId = transferId
        self.files = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        self.offsets = offsets
        self.total = total
        self.progress = progress
    }

    func result(error: ABError?) -> TransferResult {
        var ok: [CompletedFile] = []
        var failed: [String: ABError] = [:]
        for (id, s) in status.sorted(by: { $0.key < $1.key }) {
            switch s {
            case .ok(let f): ok.append(f)
            case .failed(let e): failed[files[id]?.path ?? "\(id)"] = e
            }
        }
        let resumed = offsets.values.reduce(Int64(0), +)
        return TransferResult(transferId: transferId, direction: .receive, files: ok, failed: failed,
                              bytes: progress.doneBytes - resumed, duration: Date().timeIntervalSince(start),
                              error: error ?? failed.values.first)
    }
}

final class IncomingFile {
    let state: IncomingState
    let file: OfferFile
    let writer: IncomingFileWriter
    var position: Int64

    init(state: IncomingState, file: OfferFile, writer: IncomingFileWriter, position: Int64) {
        self.state = state; self.file = file; self.writer = writer; self.position = position
    }
}

/// Emits progress at most every 100 ms so the UI is not flooded.
final class ProgressThrottle: @unchecked Sendable {
    let transferId: String
    let direction: TransferDirection
    let total: Int64
    let fileCount: Int
    let onEvent: @Sendable (SessionEvent) -> Void
    private let lock = ABLock()
    private var done: Int64
    private var filesDone = 0
    private var lastEmit = Date.distantPast
    private var lastFile: String?

    init(transferId: String, direction: TransferDirection, total: Int64, fileCount: Int, done: Int64,
         onEvent: @escaping @Sendable (SessionEvent) -> Void) {
        self.transferId = transferId; self.direction = direction; self.total = total
        self.fileCount = fileCount; self.done = done; self.onEvent = onEvent
    }

    var doneBytes: Int64 { lock.lock(); defer { lock.unlock() }; return done }

    func add(_ n: Int64, current: String) {
        lock.lock()
        done += n
        if lastFile != current { if lastFile != nil { filesDone += 1 }; lastFile = current }
        lock.unlock()
        emit(force: false, current: current)
    }

    func emit(force: Bool, current: String?) {
        lock.lock()
        let now = Date()
        guard force || now.timeIntervalSince(lastEmit) >= 0.1 else { lock.unlock(); return }
        lastEmit = now
        if force && current == nil { filesDone = fileCount }
        let p = TransferProgress(transferId: transferId, direction: direction, totalBytes: total, bytesDone: done,
                                 fileCount: fileCount, filesDone: filesDone, currentFile: current ?? lastFile)
        lock.unlock()
        onEvent(.progress(p))
    }
}
