import Foundation
import UniformTypeIdentifiers

public enum TransferDirection: String, Codable, Sendable { case send, receive }

/// A file to send. `path` is the relative path announced to the receiver.
public struct OutgoingFile: Sendable, Equatable {
    public let url: URL
    public let path: String
    public let size: Int64
    public let mtime: Int64
    public let mime: String?

    public init(url: URL, path: String, size: Int64, mtime: Int64, mime: String?) {
        self.url = url; self.path = path; self.size = size; self.mtime = mtime; self.mime = mime
    }

    /// Expands files and folders into a flat list. Folders keep their name as the
    /// top-level path component. Symlinks and package internals are not followed.
    public static func collect(_ urls: [URL]) throws -> [OutgoingFile] {
        var out: [OutgoingFile] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        func make(_ u: URL, _ path: String) throws -> OutgoingFile? {
            let v = try u.resourceValues(forKeys: Set(keys))
            guard v.isRegularFile == true, v.isSymbolicLink != true else { return nil }
            let mtime = Int64((v.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000)
            let mime = UTType(filenameExtension: u.pathExtension)?.preferredMIMEType
            return OutgoingFile(url: u, path: path, size: Int64(v.fileSize ?? 0), mtime: mtime, mime: mime)
        }
        for url in urls {
            let v = try url.resourceValues(forKeys: Set(keys))
            if v.isDirectory == true {
                let base = url.lastPathComponent
                // Compare resolved paths: the enumerator reports /private/var/... for /var/...
                let root = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
                guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                             options: [.skipsPackageDescendants]) else { continue }
                for case let f as URL in e {
                    if f.lastPathComponent == ".DS_Store" { continue }
                    let comps = f.resolvingSymlinksInPath().standardizedFileURL.pathComponents
                    guard comps.count > root.count, Array(comps.prefix(root.count)) == root else { continue }
                    let rel = comps.dropFirst(root.count).joined(separator: "/")
                    if let o = try make(f, base + "/" + rel) { out.append(o) }
                }
            } else if let o = try make(url, url.lastPathComponent) {
                out.append(o)
            }
        }
        return out
    }
}

/// An offer from the peer, already validated and sanitised.
public struct IncomingOffer: Sendable {
    public let transferId: String
    public let peer: PeerRecord
    public let files: [OfferFile]   // paths are sanitised
    public let totalBytes: Int64
    public let resumedBytes: Int64  // > 0 when continuing an interrupted transfer
}

public struct TransferProgress: Sendable {
    public let transferId: String
    public let direction: TransferDirection
    public let totalBytes: Int64
    public let bytesDone: Int64
    public let fileCount: Int
    public let filesDone: Int
    public let currentFile: String?
}

public struct CompletedFile: Sendable, Codable, Hashable {
    public let name: String       // relative path as offered
    public let savedAs: String?   // final location (receiver side)
    public let size: Int64
}

public struct TransferResult: Sendable {
    public let transferId: String
    public let direction: TransferDirection
    public let files: [CompletedFile]
    public let failed: [String: ABError]
    public let bytes: Int64
    public let duration: TimeInterval
    public let error: ABError?   // nil = all files succeeded
}

public enum SessionEvent: Sendable {
    case offer(IncomingOffer)                 // informational: a decision is requested via the policy
    case started(transferId: String, direction: TransferDirection, files: [OfferFile], totalBytes: Int64)
    case progress(TransferProgress)
    case fileDone(transferId: String, direction: TransferDirection, file: CompletedFile)
    case finished(TransferResult)
    case closed(ABError?)
}
