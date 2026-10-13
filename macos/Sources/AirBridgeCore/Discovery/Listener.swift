import Foundation
import Network

/// Accepts AirBridge TCP connections and (optionally) advertises `_airbridge._tcp`.
public final class Listener: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "airbridge.listener")

    public init() {}

    /// Starts listening on `port` (falls back to an ephemeral port if it is taken).
    /// Returns the bound port.
    public func start(port: UInt16 = ABProtocol.defaultPort, bonjourName: String?, deviceId: String,
                      onConnection: @escaping @Sendable (ByteStream) -> Void) async throws -> UInt16 {
        do {
            return try await start(exactPort: port, bonjourName: bonjourName, deviceId: deviceId, onConnection: onConnection)
        } catch {
            return try await start(exactPort: 0, bonjourName: bonjourName, deviceId: deviceId, onConnection: onConnection)
        }
    }

    private func start(exactPort: UInt16, bonjourName: String?, deviceId: String,
                       onConnection: @escaping @Sendable (ByteStream) -> Void) async throws -> UInt16 {
        let params = ByteStream.tcpParameters()
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: exactPort == 0 ? .any : NWEndpoint.Port(rawValue: exactPort)!)
        if let bonjourName {
            let txt = NWTXTRecord(["v": "\(ABProtocol.version)", "id": deviceId, "n": bonjourName])
            l.service = NWListener.Service(name: bonjourName, type: ABProtocol.serviceType, txtRecord: txt)
        }
        l.newConnectionHandler = { conn in
            onConnection(ByteStream(connection: conn))
        }
        let once = OnceFlag()
        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            l.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.fire() { cont.resume(returning: l.port?.rawValue ?? exactPort) }
                case .failed(let e):
                    if once.fire() { cont.resume(throwing: ABError(.connectionFailed, "Listener failed: \(e)")) }
                    l.cancel()
                case .cancelled:
                    if once.fire() { cont.resume(throwing: ABError(.connectionFailed, "Listener cancelled")) }
                default: break
                }
            }
            l.start(queue: queue)
        }
        listener = l
        return port
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }
}

public enum NetworkInfo {
    public struct Address: Sendable, Hashable {
        public let interface: String
        public let ip: String
    }

    /// Non-loopback IPv4 addresses on Wi-Fi/Ethernet-like interfaces. Phone-hotspot
    /// subnets come first because that is the primary AirBridge topology.
    public static func localIPv4() -> [Address] {
        var out: [Address] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0, (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue } // skip utun/awdl/llw
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            if ip.hasPrefix("169.254.") { continue }
            out.append(Address(interface: name, ip: ip))
        }
        func rank(_ a: Address) -> Int {
            if a.ip.hasPrefix("172.") || a.ip.hasPrefix("192.168.43.") || a.ip.hasPrefix("192.168.49.") { return 0 }
            return a.interface == "en0" ? 1 : 2
        }
        return out.sorted { rank($0) < rank($1) }
    }
}
