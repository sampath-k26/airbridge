import Foundation
import Network

/// Browses `_airbridge._tcp` (e.g. an Android phone in Receive mode). Discovery is
/// advisory: results only pre-fill an address; trust always comes from pairing.
public final class NearbyBrowser: @unchecked Sendable {
    public struct Device: Sendable, Hashable, Identifiable {
        public var id: String { name }
        public let name: String
        public let deviceId: String?
        public let endpoint: NWEndpoint
    }

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "airbridge.browser")

    public init() {}

    public func start(onChange: @escaping @Sendable ([Device]) -> Void) {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: ABProtocol.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { results, _ in
            let list: [Device] = results.compactMap { r in
                guard case .service(let name, _, _, _) = r.endpoint else { return nil }
                var id: String?
                if case .bonjour(let txt) = r.metadata { id = txt["id"] }
                return Device(name: name, deviceId: id, endpoint: r.endpoint)
            }
            onChange(list)
        }
        b.start(queue: queue)
        browser = b
    }

    public func stop() { browser?.cancel(); browser = nil }

    /// Resolves a Bonjour endpoint to "host:port" by opening (and dropping) a TCP path.
    public static func resolve(_ endpoint: NWEndpoint) async -> (String, UInt16)? {
        let conn = NWConnection(to: endpoint, using: .tcp)
        let once = OnceFlag()
        return await withCheckedContinuation { cont in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.fire() {
                        if case .hostPort(let h, let p)? = conn.currentPath?.remoteEndpoint {
                            var host = "\(h)"
                            if let i = host.firstIndex(of: "%") { host = String(host[..<i]) }
                            cont.resume(returning: (host, p.rawValue))
                        } else { cont.resume(returning: nil) }
                        conn.cancel()
                    }
                case .failed, .cancelled:
                    if once.fire() { cont.resume(returning: nil) }
                default: break
                }
            }
            conn.start(queue: DispatchQueue.global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if once.fire() { cont.resume(returning: nil); conn.cancel() }
            }
        }
    }
}
