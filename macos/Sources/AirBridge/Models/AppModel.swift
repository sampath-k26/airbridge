import AirBridgeCore
import AppKit
import Foundation

enum TransferStatus: String, Codable { case waiting, running, done, failed, cancelled, interrupted }

/// Everything the UI shows about one transfer. Values come from measured progress only.
struct TransferItem: Identifiable, Codable, Equatable {
    let id: String
    let direction: TransferDirection
    var peerName: String
    var title: String
    var fileCount: Int
    var totalBytes: Int64
    var bytesDone: Int64 = 0
    var status: TransferStatus = .waiting
    var currentFile: String?
    var currentSpeed: Double?
    var averageSpeed: Double?
    var eta: TimeInterval?
    var error: String?
    var savedTo: [String] = []
    /// Local paths of what was sent (top-level items), used for previews and Show in Finder.
    var sourcePaths: [String]?
    var startedAt = Date()
    var finishedAt: Date?

    var fraction: Double { totalBytes > 0 ? min(1, Double(bytesDone) / Double(totalBytes)) : (status == .done ? 1 : 0) }
    var isActive: Bool { status == .waiting || status == .running || status == .interrupted }
}

struct Notice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct PendingDecision<T>: Identifiable {
    let id = UUID()
    let value: T
    let answer: (Bool) -> Void
}

/// Owns listening/dialing, the active session, outgoing jobs with resume, and UI state.
@MainActor
final class AppModel: ObservableObject {
    enum Connection: Equatable {
        case idle
        case connecting(String)
        case connected(PeerRecord, code: String, dialer: Bool)
        case reconnecting(PeerRecord, attempt: Int)
        case failed(String)
    }

    @Published var connection: Connection = .idle
    @Published var transfers: [TransferItem] = []
    @Published var history: [TransferItem] = []
    @Published var peers: [PeerRecord] = []
    @Published var nearby: [NearbyBrowser.Device] = []
    @Published var listenPort: UInt16?
    @Published var listenError: String?
    @Published var pairingCode: PairingCode?
    @Published var pairingPrompt: PendingDecision<PairingRequest>?
    @Published var offerPrompt: PendingDecision<IncomingOffer>?
    /// A one-off message for the user (shown as an alert).
    @Published var notice: Notice?

    // Settings (UserDefaults).
    @Published var deviceName: String { didSet { defaults.set(deviceName, forKey: "deviceName") } }
    @Published var destination: URL { didSet { defaults.set(destination.path, forKey: "destination") } }
    @Published var askBeforeReceiving: Bool { didSet { defaults.set(askBeforeReceiving, forKey: "askBeforeReceiving") } }
    @Published var chunkSize: Int { didSet { defaults.set(chunkSize, forKey: "chunkSize") } }

    let identity: DeviceIdentity
    let trust: TrustStore
    private let defaults = UserDefaults.standard
    private let supportDir: URL
    private let listener = Listener()
    private let browser = NearbyBrowser()
    private var session: Session?
    private var meters: [String: SpeedMeter] = [:]
    private var jobs: [String: (peerId: String, files: [OutgoingFile], task: Task<Void, Never>?)] = [:]
    private var jobOrder: [String] = []
    private var reconnectTask: Task<Void, Never>?
    private var started = false

    var isConnected: Bool { if case .connected = connection { return true }; return false }
    var connectedPeer: PeerRecord? { if case .connected(let p, _, _) = connection { return p }; return nil }

    init() {
        let fm = FileManager.default
        supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AirBridge")
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        do {
            identity = try DeviceIdentity.loadOrCreateFromKeychain()
        } catch {
            // Keychain unavailable (e.g. locked): fall back to a 0600 file in Application Support.
            identity = (try? DeviceIdentity.loadOrCreate(file: supportDir.appendingPathComponent("identity.key"))) ?? .generate()
        }
        trust = TrustStore(file: supportDir.appendingPathComponent("trust.json"))
        deviceName = defaults.string(forKey: "deviceName") ?? Host.current().localizedName ?? "Mac"
        destination = URL(fileURLWithPath: defaults.string(forKey: "destination")
            ?? fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("AirBridge").path)
        askBeforeReceiving = defaults.object(forKey: "askBeforeReceiving") as? Bool ?? false
        chunkSize = defaults.object(forKey: "chunkSize") as? Int ?? ABProtocol.defaultChunkSize
        peers = trust.all
        history = (try? JSONDecoder().decode([TransferItem].self, from: Data(contentsOf: historyURL))) ?? []
    }

    private var historyURL: URL { supportDir.appendingPathComponent("history.json") }
    private var local: LocalDevice { LocalDevice(identity: identity, name: deviceName) }
    private var storage: FileSystemStorage { FileSystemStorage(destination: destination) }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        storage.cleanupStalePartials()
        Task { await startListening() }
        browser.start { [weak self] devices in
            Task { @MainActor in self?.nearby = devices.filter { $0.deviceId != self?.identity.deviceId } }
        }
    }

    private func startListening() async {
        do {
            let port = try await listener.start(bonjourName: deviceName, deviceId: identity.deviceId) { [weak self] stream in
                Task { await self?.accept(stream) }
            }
            listenPort = port
            listenError = nil
        } catch {
            listenError = "Cannot accept connections: \((error as? ABError)?.message ?? "\(error)")"
        }
    }

    // MARK: - Pairing

    func beginPairing() { pairingCode = PairingCode() }
    func endPairing() { pairingCode = nil }

    var pairingURI: String? {
        guard let code = pairingCode, let port = listenPort else { return nil }
        let hosts = NetworkInfo.localIPv4().map(\.ip)
        guard !hosts.isEmpty else { return nil }
        return PairingURI(hosts: hosts, port: port, code: code.code, fingerprint: identity.fingerprint, name: deviceName).uri
    }

    private func accept(_ stream: ByteStream) async {
        do {
            try await stream.waitReady(timeout: 10)
            let code = pairingCode
            let hs = try await Handshake.accept(stream: stream, local: local, trust: trust,
                                                activeCode: { code }, approve: { [weak self] req in
                                                    await self?.askPairing(req) ?? false
                                                })
            attach(hs, dialer: false)
            if hs.newlyPaired { pairingCode = nil }
        } catch let e as ABError {
            if e.code != .connectionLost && e.code != .connectionFailed { connection = .failed(e.errorDescription ?? e.message) }
        } catch {}
    }

    private func askPairing(_ req: PairingRequest) async -> Bool {
        NSApp.requestUserAttention(.criticalRequest)
        return await withCheckedContinuation { cont in
            let once = OnceBox()
            pairingPrompt = PendingDecision(value: req) { ok in if once.fire() { cont.resume(returning: ok) } }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64((ABProtocol.approvalTimeout - 5) * 1e9))
                if once.fire() { self.pairingPrompt = nil; cont.resume(returning: false) }
            }
        }
    }

    // MARK: - Dialing (Mac → phone in Receive mode)

    func connect(host: String, port: UInt16, code: String?) {
        let pairing: DialPairing? = code.flatMap(PairingCode.normalize).map { DialPairing(code: $0, fingerprint: nil) }
        if let code, !code.isEmpty, pairing == nil {
            connection = .failed("That pairing code is not valid. It has 10 letters and digits."); return
        }
        Task { await dial(hosts: [host], port: port, pairing: pairing, label: host) }
    }

    func reconnect(_ peer: PeerRecord) {
        Task { _ = await tryReconnect(peer, quiet: false) }
    }

    private func tryReconnect(_ peer: PeerRecord, quiet: Bool) async -> Bool {
        var candidates: [(String, UInt16)] = []
        for d in nearby where d.deviceId == peer.deviceId {
            if let r = await NearbyBrowser.resolve(d.endpoint) { candidates.append(r) }
        }
        candidates += peer.lastHosts.map { ($0, peer.lastPort ?? ABProtocol.defaultPort) }
        for (h, p) in candidates where await dial(hosts: [h], port: p, pairing: nil, label: peer.name, quiet: true) { return true }
        if !quiet { connection = .failed("\(peer.name) is not reachable. Open AirBridge on it and make sure both devices share a network.") }
        return false
    }

    @discardableResult
    private func dial(hosts: [String], port: UInt16, pairing: DialPairing?, label: String, quiet: Bool = false) async -> Bool {
        if !quiet { connection = .connecting(label) }
        var last: ABError?
        for h in hosts {
            do {
                let stream = try await ByteStream.connect(host: h, port: port, timeout: 5)
                let hs = try await Handshake.dial(stream: stream, local: local, trust: trust, pairing: pairing, host: h, port: port)
                attach(hs, dialer: true)
                return true
            } catch let e as ABError {
                last = e
                if [.authFailed, .pairingRejected, .pairingExpired, .unsupportedVersion].contains(e.code) { break }
            } catch {}
        }
        if !quiet { connection = .failed(last?.errorDescription ?? "Could not connect") }
        return false
    }

    func disconnect() {
        reconnectTask?.cancel()
        let s = session
        session = nil
        connection = .idle
        Task { await s?.close() }
    }

    func forget(_ peer: PeerRecord) {
        if connectedPeer?.deviceId == peer.deviceId { disconnect() }
        trust.remove(deviceId: peer.deviceId)
        peers = trust.all
    }

    // MARK: - Session

    private func attach(_ hs: HandshakeResult, dialer: Bool) {
        session?.closeNow()
        reconnectTask?.cancel()
        let s = Session(handshake: hs, storage: storage, chunkSize: chunkSize,
                        decide: { [weak self] offer in await self?.decide(offer) ?? false },
                        onEvent: { [weak self] ev in Task { @MainActor in self?.handle(ev) } })
        session = s
        peers = trust.all
        connection = .connected(hs.peer, code: hs.verificationCode, dialer: dialer)
        s.start()
        runJobs()
        Task { [weak self] in
            let err = await s.waitClosed()
            await MainActor.run {
                guard let self, self.session === s else { return }
                self.session = nil
                let owesData = self.jobs.values.contains { $0.peerId == hs.peer.deviceId }
                    || self.transfers.contains { $0.status == .interrupted }
                if err != nil, dialer, owesData {
                    self.startReconnectLoop(hs.peer)
                } else {
                    self.connection = (err == nil || err?.code == .connectionLost) ? .idle : .failed(err?.errorDescription ?? "")
                }
            }
        }
    }

    /// After an interruption keep trying for 2 minutes so transfers resume.
    private func startReconnectLoop(_ peer: PeerRecord) {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            for attempt in 1...40 {
                guard let self, !Task.isCancelled else { return }
                self.connection = .reconnecting(peer, attempt: attempt)
                if await self.tryReconnect(peer, quiet: true) { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            self?.connection = .failed("\(peer.name) is not reachable. Pending transfers were kept; reconnect to resume.")
        }
    }

    private func decide(_ offer: IncomingOffer) async -> Bool {
        if offer.resumedBytes > 0 || !askBeforeReceiving { return true }
        NSApp.requestUserAttention(.informationalRequest)
        return await withCheckedContinuation { cont in
            let once = OnceBox()
            offerPrompt = PendingDecision(value: offer) { ok in if once.fire() { cont.resume(returning: ok) } }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                if once.fire() { self.offerPrompt = nil; cont.resume(returning: false) }
            }
        }
    }

    private func handle(_ ev: SessionEvent) {
        let now = Date().timeIntervalSinceReferenceDate
        let peerName = connectedPeer?.name ?? "device"
        switch ev {
        case .offer, .fileDone, .closed:
            break
        case .started(let id, let dir, let files, let total):
            meters[id] = SpeedMeter()
            upsert(id) { t in
                var t = t ?? TransferItem(id: id, direction: dir, peerName: peerName, title: Self.title(files.map(\.path)),
                                          fileCount: files.count, totalBytes: total)
                t.status = .running; t.error = nil
                return t
            }
        case .progress(let p):
            var m = meters[p.transferId] ?? SpeedMeter()
            m.add(bytesDone: p.bytesDone, at: now)
            meters[p.transferId] = m
            upsert(p.transferId) { t in
                guard var t else { return nil }
                t.bytesDone = p.bytesDone; t.currentFile = p.currentFile
                t.currentSpeed = m.current; t.averageSpeed = m.average(at: now); t.eta = m.eta(totalBytes: p.totalBytes)
                return t
            }
        case .finished(let r):
            let status: TransferStatus
            switch r.error?.code {
            case nil: status = .done
            case .cancelled?: status = .cancelled
            case .connectionLost?, .timeout?: status = .interrupted
            default: status = .failed
            }
            upsert(r.transferId) { t in
                guard var t else { return nil }
                t.status = status
                t.error = r.error?.errorDescription
                t.savedTo = r.files.compactMap(\.savedAs)
                if r.duration > 0, r.bytes > 0 { t.averageSpeed = Double(r.bytes) / r.duration }
                t.currentSpeed = nil; t.eta = nil
                if status == .done { t.bytesDone = t.totalBytes }
                t.finishedAt = Date()
                return t
            }
            if status != .interrupted {
                if let t = transfers.first(where: { $0.id == r.transferId }) { addHistory(t) }
                if r.direction == .send { jobs[r.transferId] = nil; jobOrder.removeAll { $0 == r.transferId } }
                if status == .done, r.direction == .receive, r.files.count > 0 {
                    NSApp.requestUserAttention(.informationalRequest)
                }
            }
        }
    }

    private static func title(_ paths: [String]) -> String {
        let tops = Array(NSOrderedSet(array: paths.map { String($0.split(separator: "/").first ?? "") })) as? [String] ?? []
        guard let first = tops.first else { return "Files" }
        return tops.count <= 1 ? first : "\(first) + \(tops.count - 1) more"
    }

    private func upsert(_ id: String, _ f: (TransferItem?) -> TransferItem?) {
        if let i = transfers.firstIndex(where: { $0.id == id }) {
            if let n = f(transfers[i]) { transfers[i] = n }
        } else if let n = f(nil) {
            transfers.insert(n, at: 0)
        }
    }

    private func addHistory(_ t: TransferItem) {
        history.removeAll { $0.id == t.id }
        history.insert(t, at: 0)
        if history.count > 100 { history.removeLast(history.count - 100) }
        transfers.removeAll { $0.id == t.id && !$0.isActive }
        try? JSONEncoder().encode(history).write(to: historyURL, options: .atomic)
    }

    func removeFromHistory(_ id: String) {
        history.removeAll { $0.id == id }
        try? JSONEncoder().encode(history).write(to: historyURL, options: .atomic)
    }

    func clearHistory() {
        history = []
        try? FileManager.default.removeItem(at: historyURL)
    }

    // MARK: - Sending

    func send(_ urls: [URL]) {
        guard let peer = connectedPeer else { return }
        let files: [OutgoingFile]
        do { files = try OutgoingFile.collect(urls) } catch let e as CloudFilesNotDownloaded {
            // Ask macOS to fetch them now; reading them during the transfer would hang
            // without internet (e.g. on a phone hotspot without mobile data).
            for u in e.files { try? FileManager.default.startDownloadingUbiquitousItem(at: u) }
            let names = e.files.prefix(3).map { "“\($0.lastPathComponent)”" }.joined(separator: ", ")
                + (e.files.count > 3 ? " and \(e.files.count - 3) more" : "")
            notice = Notice(title: "Not downloaded from iCloud yet",
                            message: "\(names) \(e.files.count == 1 ? "is" : "are") stored in iCloud and not on this Mac. "
                                + "AirBridge asked macOS to download \(e.files.count == 1 ? "it" : "them"). This needs internet, so if the Mac "
                                + "is on a hotspot without mobile data, download in Finder (Download Now) on your normal Wi-Fi first. "
                                + "Then send again.")
            return
        } catch {
            notice = Notice(title: "Could not read the selected files", message: error.localizedDescription); return
        }
        guard !files.isEmpty else { return }
        let id = UUID().uuidString.lowercased()
        jobs[id] = (peer.deviceId, files, nil)
        jobOrder.append(id)
        upsert(id) { _ in
            var t = TransferItem(id: id, direction: .send, peerName: peer.name, title: Self.title(files.map(\.path)),
                                 fileCount: files.count, totalBytes: files.reduce(0) { $0 + $1.size })
            t.sourcePaths = urls.map(\.path)
            return t
        }
        runJobs()
    }

    /// Runs queued sends one after another; interrupted ones are retried on reconnect
    /// with the same transferId, which makes the receiver resume.
    private func runJobs() {
        guard let s = session, !jobs.values.contains(where: { $0.task != nil }) else { return }
        guard let id = jobOrder.first(where: { jobs[$0]?.peerId == s.peer.deviceId }), let job = jobs[id] else { return }
        let task = Task { [weak self] in
            let r = await s.send(job.files, transferId: id)
            await MainActor.run {
                guard let self else { return }
                if [.connectionLost, .timeout].contains(r.error?.code), self.jobs[id] != nil {
                    self.jobs[id]?.task = nil
                } else {
                    self.jobs[id] = nil; self.jobOrder.removeAll { $0 == id }
                }
                if self.session === s { self.runJobs() }
            }
        }
        jobs[id]?.task = task
    }

    func cancel(_ id: String) {
        let job = jobs.removeValue(forKey: id)
        jobOrder.removeAll { $0 == id }
        session?.cancel(transferId: id)
        job?.task?.cancel()
        upsert(id) { t in
            guard var t, t.isActive else { return t }
            t.status = .cancelled; t.finishedAt = Date(); t.currentSpeed = nil; t.eta = nil
            return t
        }
        if let t = transfers.first(where: { $0.id == id }), t.status == .cancelled { addHistory(t) }
    }

    func reveal(_ t: TransferItem) {
        let urls = (t.direction == .send ? t.sourcePaths ?? [] : t.savedTo).map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if urls.isEmpty { NSWorkspace.shared.open(destination) } else { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
}

/// First-caller-wins flag for main-actor callbacks.
final class OnceBox: @unchecked Sendable {
    private let lock = ABLock()
    private var done = false
    func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
