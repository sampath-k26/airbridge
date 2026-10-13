import AirBridgeCore
import Foundation

// Headless AirBridge peer for interop tests and benchmarks.
//
//   airbridge-cli listen --state DIR --dir OUT [--port P] [--code CODE] [--send F...] [--expect N] [--chunk BYTES]
//   airbridge-cli dial   --state DIR --dir OUT (--uri URI | --host H --port P [--code CODE]) [--send F...] [--expect N]
//
// Prints one JSON object per line. Incoming offers are auto-accepted (test tool only).

setvbuf(stdout, nil, _IOLBF, 0)

struct Options {
    var mode = ""
    var state = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("airbridge-cli")
    var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    var port: UInt16 = ABProtocol.defaultPort
    var host: String?
    var uri: String?
    var code: String?
    var send: [String] = []
    var expect = 0
    var chunk = ABProtocol.defaultChunkSize
    var name = "airbridge-cli"
    var repeatCount = 1
    var transferId: String?
    var bonjour = false
}

func emit(_ dict: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys, .withoutEscapingSlashes])
    print(String(data: data, encoding: .utf8)!)
}

func fail(_ msg: String) -> Never {
    emit(["event": "error", "message": msg])
    exit(1)
}

var o = Options()
var args = Array(CommandLine.arguments.dropFirst())
guard let mode = args.first else { fail("usage: airbridge-cli listen|dial ...") }
o.mode = mode
args.removeFirst()
var i = 0
func next() -> String { i += 1; guard i < args.count else { fail("missing value for \(args[i - 1])") }; return args[i] }
while i < args.count {
    switch args[i] {
    case "--state": o.state = URL(fileURLWithPath: next())
    case "--dir": o.dir = URL(fileURLWithPath: next())
    case "--port": o.port = UInt16(next()) ?? 0
    case "--host": o.host = next()
    case "--uri": o.uri = next()
    case "--code": o.code = next()
    case "--expect": o.expect = Int(next()) ?? 0
    case "--chunk": o.chunk = Int(next()) ?? o.chunk
    case "--name": o.name = next()
    case "--repeat": o.repeatCount = Int(next()) ?? 1
    case "--transfer-id": o.transferId = next()
    case "--bonjour": o.bonjour = true
    case "--send":
        while i + 1 < args.count, !args[i + 1].hasPrefix("--") { o.send.append(next()) }
    default: fail("unknown option \(args[i])")
    }
    i += 1
}

let identity = try DeviceIdentity.loadOrCreate(file: o.state.appendingPathComponent("identity.key"))
let trust = TrustStore(file: o.state.appendingPathComponent("trust.json"))
let local = LocalDevice(identity: identity, name: o.name, platform: "macos", app: "AirBridge-cli/1.0")
let storage = FileSystemStorage(destination: o.dir)

final class Counter: @unchecked Sendable {
    let lock = ABLock()
    var finishedIncoming = 0
}
let counter = Counter()

func describe(_ r: TransferResult) -> [String: Any] {
    let mbps = r.duration > 0 ? Double(r.bytes) / r.duration / 1_000_000 : 0
    return ["event": "result", "direction": r.direction.rawValue, "ok": r.error == nil, "bytes": r.bytes,
            "seconds": (r.duration * 1000).rounded() / 1000, "MBps": (mbps * 10).rounded() / 10,
            "files": r.files.count, "failed": r.failed.count, "error": r.error?.description ?? NSNull(),
            "saved": r.files.compactMap { $0.savedAs }]
}

func runSession(_ hs: HandshakeResult) async -> Int32 {
    emit(["event": "connected", "peer": hs.peer.name, "peerId": hs.peer.deviceId, "sas": hs.verificationCode,
          "newlyPaired": hs.newlyPaired])
    let session = Session(handshake: hs, storage: storage, chunkSize: o.chunk, decide: { _ in true }, onEvent: { ev in
        if case .finished(let r) = ev, r.direction == .receive {
            emit(describe(r))
            counter.lock.lock(); counter.finishedIncoming += 1; counter.lock.unlock()
        }
    })
    session.start()
    var rc: Int32 = 0
    if !o.send.isEmpty {
        do {
            let files = try OutgoingFile.collect(o.send.map { URL(fileURLWithPath: $0) })
            for _ in 0..<o.repeatCount {
                let r = await session.send(files, transferId: o.transferId ?? UUID().uuidString.lowercased())
                emit(describe(r))
                if r.error != nil { rc = 1; break }
            }
        } catch {
            emit(["event": "error", "message": "\(error)"]); rc = 1
        }
    }
    // Wait for the expected number of incoming transfers (or the session to end).
    while true {
        counter.lock.lock(); let n = counter.finishedIncoming; counter.lock.unlock()
        if n >= o.expect || session.isClosed { break }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    await session.close()
    return rc
}

switch o.mode {
case "listen":
    let code = o.code.flatMap(PairingCode.normalize).map { PairingCode(code: $0) } ?? PairingCode()
    let listener = Listener()
    let done = DispatchSemaphore(value: 0)
    final class RC: @unchecked Sendable { var value: Int32 = 0 }
    let rc = RC()
    let port = try await listener.start(port: o.port, bonjourName: o.bonjour ? o.name : nil, deviceId: identity.deviceId) { stream in
        Task {
            do {
                try await stream.waitReady(timeout: 10)
                let hs = try await Handshake.accept(stream: stream, local: local, trust: trust,
                                                    activeCode: { code }, approve: { _ in true })
                rc.value = await runSession(hs)
            } catch {
                emit(["event": "error", "message": "\(error)"]); rc.value = 1
            }
            done.signal()
        }
    }
    let uri = PairingURI(hosts: NetworkInfo.localIPv4().map(\.ip) + ["127.0.0.1"], port: port, code: code.code,
                         fingerprint: identity.fingerprint, name: o.name)
    emit(["event": "listening", "port": Int(port), "uri": uri.uri, "code": code.display])
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async { done.wait(); c.resume() }
    }
    listener.stop()
    exit(rc.value)

case "dial":
    var host = o.host, port = o.port
    var pairing: DialPairing? = o.code.flatMap(PairingCode.normalize).map { DialPairing(code: $0, fingerprint: nil) }
    if let uri = o.uri {
        guard let p = PairingURI.parse(uri) else { fail("invalid pairing URI") }
        host = host ?? p.hosts.first; port = p.port
        pairing = DialPairing(code: p.code, fingerprint: p.fingerprint)
    }
    guard let host else { fail("--host or --uri required") }
    do {
        let stream = try await ByteStream.connect(host: host, port: port)
        let hs = try await Handshake.dial(stream: stream, local: local, trust: trust, pairing: pairing, host: host, port: port)
        exit(await runSession(hs))
    } catch {
        fail("\(error)")
    }

case "vectors":
    emitVectors()

default:
    fail("unknown mode \(o.mode)")
}
