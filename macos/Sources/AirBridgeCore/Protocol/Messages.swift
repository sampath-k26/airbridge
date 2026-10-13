import Foundation

/// JSON control messages (SPEC §5, §6). Unknown fields are ignored by Codable.
public struct Envelope: Decodable { public let type: String }

public struct HelloMsg: Codable {
    public var type = "hello"
    public let proto: Int
    public let minProto: Int
    public let eph: String
    public let nonce: String
    public let pairing: Bool?
    public let app: String?
}

public struct ServerHelloMsg: Codable {
    public var type = "server_hello"
    public let proto: Int
    public let eph: String
    public let nonce: String
}

public struct AuthMsg: Codable {
    public let type: String // server_auth | client_auth
    public let identity: String
    public let sig: String
    public let name: String
    public let platform: String
    public let pairProof: String?
}

public struct AuthOkMsg: Codable {
    public var type = "auth_ok"
    public let name: String
    public let paired: Bool
}

public struct ErrorMsg: Codable {
    public var type = "error"
    public let code: String
    public let message: String
}

public struct SimpleMsg: Codable {
    public let type: String // ping | pong
}

public struct OfferFile: Codable, Sendable, Equatable {
    public let id: Int
    public let path: String
    public let size: Int64
    public let mtime: Int64
    public let mime: String?
    public init(id: Int, path: String, size: Int64, mtime: Int64, mime: String? = nil) {
        self.id = id; self.path = path; self.size = size; self.mtime = mtime; self.mime = mime
    }
}

public struct OfferMsg: Codable {
    public var type = "offer"
    public let transferId: String
    public let totalBytes: Int64
    public let files: [OfferFile]
}

public struct AcceptFile: Codable, Sendable { public let id: Int; public let offset: Int64 }

public struct AcceptMsg: Codable {
    public var type = "accept"
    public let transferId: String
    public let files: [AcceptFile]
}

public struct RejectMsg: Codable {
    public var type = "reject"
    public let transferId: String
    public let code: String
    public let message: String
}

public struct FileBeginMsg: Codable {
    public var type = "file_begin"
    public let transferId: String
    public let fileId: Int
    public let stream: UInt32
    public let offset: Int64
}

public struct FileEndMsg: Codable {
    public var type = "file_end"
    public let transferId: String
    public let fileId: Int
    public let sha256: String
}

public struct FileOkMsg: Codable {
    public var type = "file_ok"
    public let transferId: String
    public let fileId: Int
    public let name: String
}

public struct FileFailedMsg: Codable {
    public var type = "file_failed"
    public let transferId: String
    public let fileId: Int
    public let code: String
    public let message: String
}

public struct TransferDoneMsg: Codable {
    public var type = "transfer_done"
    public let transferId: String
    public let ok: Bool
}

public struct CancelMsg: Codable {
    public var type = "cancel"
    public let transferId: String
    public let reason: String
}

public enum JSONCodec {
    public static func encode<T: Encodable>(_ v: T) -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return try! e.encode(v)
    }

    public static func decode<T: Decodable>(_ t: T.Type, _ d: Data) throws -> T {
        do { return try JSONDecoder().decode(t, from: d) } catch {
            throw ABError(.malformed, "Invalid \(T.self)")
        }
    }

    public static func type(of d: Data) throws -> String {
        try decode(Envelope.self, d).type
    }
}
