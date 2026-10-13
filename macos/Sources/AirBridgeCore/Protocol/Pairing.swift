import Foundation

/// Short-lived, single-use pairing code (SPEC §3.1).
public final class PairingCode: @unchecked Sendable {
    public static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    public static let lifetime: TimeInterval = 5 * 60
    public static let maxFailures = 5

    public let code: String // normalised, 10 chars
    public let expiresAt: Date
    private let lock = ABLock()
    private var failures = 0
    private var consumed = false

    public init(code: String? = nil, now: Date = Date()) {
        if let code {
            self.code = code
        } else {
            // 50 bits from the CSPRNG: each byte's low 5 bits picks a symbol.
            let bytes = ABCrypto.randomBytes(10)
            self.code = String(bytes.map { PairingCode.alphabet[Int($0 & 0x1F)] })
        }
        self.expiresAt = now.addingTimeInterval(PairingCode.lifetime)
    }

    public var display: String {
        "\(code.prefix(5))-\(code.suffix(5))"
    }

    public var key: Data { Data(code.utf8) }

    public func isUsable(now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !consumed && failures < PairingCode.maxFailures && now < expiresAt
    }

    public func recordFailure() { lock.lock(); failures += 1; lock.unlock() }
    public func consume() { lock.lock(); consumed = true; lock.unlock() }

    public static func normalize(_ input: String) -> String? {
        var out = ""
        for ch in input.uppercased() {
            switch ch {
            case "-", " ": continue
            case "O": out.append("0")
            case "I", "L": out.append("1")
            default:
                guard alphabet.contains(ch) else { return nil }
                out.append(ch)
            }
        }
        return out.count == 10 ? out : nil
    }
}

/// QR payload (SPEC §3.2).
public struct PairingURI: Equatable, Sendable {
    public var hosts: [String]
    public var port: UInt16
    public var code: String
    public var fingerprint: Data?
    public var name: String

    public init(hosts: [String], port: UInt16, code: String, fingerprint: Data?, name: String) {
        self.hosts = hosts; self.port = port; self.code = code; self.fingerprint = fingerprint; self.name = name
    }

    public var uri: String {
        var c = URLComponents()
        c.scheme = "airbridge"; c.host = "pair"
        var items = [
            URLQueryItem(name: "v", value: "\(ABProtocol.version)"),
            URLQueryItem(name: "h", value: hosts.joined(separator: ",")),
            URLQueryItem(name: "p", value: "\(port)"),
            URLQueryItem(name: "c", value: code),
        ]
        if let fingerprint { items.append(URLQueryItem(name: "f", value: Base64URL.encode(fingerprint))) }
        items.append(URLQueryItem(name: "n", value: name))
        c.queryItems = items
        // URLComponents leaves '+' unescaped; escape it so form-decoders agree.
        return c.string!.replacingOccurrences(of: "+", with: "%2B")
    }

    public static func parse(_ s: String) -> PairingURI? {
        guard let c = URLComponents(string: s), c.scheme == "airbridge", c.host == "pair" else { return nil }
        var q: [String: String] = [:]
        for i in c.queryItems ?? [] { q[i.name] = i.value ?? "" }
        guard q["v"] == "\(ABProtocol.version)",
              let h = q["h"], !h.isEmpty,
              let p = q["p"].flatMap(UInt16.init), p > 0,
              let code = q["c"].flatMap(PairingCode.normalize)
        else { return nil }
        var fp: Data? = nil
        if let f = q["f"] {
            guard let d = Base64URL.decode(f), d.count == 32 else { return nil }
            fp = d
        }
        return PairingURI(hosts: h.split(separator: ",").map(String.init), port: p, code: code,
                          fingerprint: fp, name: q["n"] ?? "")
    }
}

public enum Base64URL {
    public static func encode(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b.append("=") }
        return Data(base64Encoded: b)
    }
}
