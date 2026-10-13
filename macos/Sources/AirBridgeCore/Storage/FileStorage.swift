import Foundation

/// Where incoming files are written. Implementations must never overwrite existing files.
public protocol ReceiveStorage: Sendable {
    /// Free bytes at the destination, or nil if unknown.
    func availableCapacity() -> Int64?
    /// Bytes already received for this file in an earlier, interrupted attempt (SPEC §8).
    func resumableOffset(transferId: String, peerId: String, file: OfferFile, path: String) -> Int64
    func openWriter(transferId: String, peerId: String, file: OfferFile, path: String, offset: Int64) throws -> IncomingFileWriter
    /// Deletes all partial data of a transfer (explicit cancel / failure).
    func discard(transferId: String)
    /// Removes bookkeeping once a transfer is complete.
    func finish(transferId: String)
}

public protocol IncomingFileWriter: AnyObject {
    /// Streams the bytes written so far (from offset 0), used to verify what is on disk.
    func readPrefix(_ body: (Data) throws -> Void) throws
    func write(_ data: Data) throws
    /// Flushes to stable storage and moves the file to its final, unique name.
    func finalize() throws -> String
    /// Closes the file. `keep` = leave the partial for a later resume.
    func close(keep: Bool)
}

/// Filesystem storage used by the macOS app and CLI.
///
/// Layout: `<dest>/.airbridge-partial/<transferId>/<fileId>.part` (+ `.json` metadata).
/// The partial directory lives inside the destination so the final `rename` is atomic
/// and never crosses volumes.
public final class FileSystemStorage: ReceiveStorage, @unchecked Sendable {
    public let destination: URL
    let partialRoot: URL
    private let fm = FileManager.default
    private let lock = ABLock()

    public static let partialMaxAge: TimeInterval = 24 * 3600

    public init(destination: URL) {
        self.destination = destination
        self.partialRoot = destination.appendingPathComponent(".airbridge-partial", isDirectory: true)
    }

    struct PartialMeta: Codable {
        let peerId: String
        let path: String
        let size: Int64
        let mtime: Int64
        let created: Date
    }

    struct TransferMeta: Codable {
        var topLevelMap: [String: String] // incoming top-level name → chosen local name
    }

    func transferDir(_ id: String) -> URL {
        // transferId is untrusted: keep only safe characters.
        let safe = String(id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" }.prefix(64))
        return partialRoot.appendingPathComponent(safe.isEmpty ? "invalid" : safe, isDirectory: true)
    }

    public func availableCapacity() -> Int64? {
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let v = try? destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage
    }

    public func resumableOffset(transferId: String, peerId: String, file: OfferFile, path: String) -> Int64 {
        let dir = transferDir(transferId)
        let part = dir.appendingPathComponent("\(file.id).part")
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("\(file.id).json")),
              let meta = try? JSONDecoder().decode(PartialMeta.self, from: data),
              meta.peerId == peerId, meta.path == path, meta.size == file.size, meta.mtime == file.mtime,
              let attrs = try? fm.attributesOfItem(atPath: part.path),
              let len = (attrs[.size] as? NSNumber)?.int64Value
        else { return 0 }
        return min(len, file.size)
    }

    public func openWriter(transferId: String, peerId: String, file: OfferFile, path: String, offset: Int64) throws -> IncomingFileWriter {
        let dir = transferDir(transferId)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let part = dir.appendingPathComponent("\(file.id).part")
            let meta = PartialMeta(peerId: peerId, path: path, size: file.size, mtime: file.mtime, created: Date())
            try JSONEncoder().encode(meta).write(to: dir.appendingPathComponent("\(file.id).json"), options: .atomic)
            if !fm.fileExists(atPath: part.path) || offset == 0 {
                guard fm.createFile(atPath: part.path, contents: nil) else { throw ABError(.writeFailed, "Cannot create file") }
            }
            let h = try FileHandle(forUpdating: part)
            try h.truncate(atOffset: UInt64(offset))
            try h.seek(toOffset: UInt64(offset))
            let target = try finalTarget(transferId: transferId, path: path)
            return try FSWriter(handle: h, partURL: part, metaURL: dir.appendingPathComponent("\(file.id).json"),
                            target: target, fm: fm)
        } catch let e as ABError {
            throw e
        } catch {
            throw ABError(.writeFailed, error.localizedDescription)
        }
    }

    /// Resolves the destination for `path`, remapping a conflicting top-level component
    /// to "name (1)" once per transfer so that all files of one folder stay together.
    func finalTarget(transferId: String, path: String) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        var comps = path.split(separator: "/").map(String.init)
        guard comps.count > 1 else { return destination.appendingPathComponent(path) }
        let metaURL = transferDir(transferId).appendingPathComponent("transfer.json")
        var meta = (try? Data(contentsOf: metaURL)).flatMap { try? JSONDecoder().decode(TransferMeta.self, from: $0) }
            ?? TransferMeta(topLevelMap: [:])
        let top = comps[0]
        if let mapped = meta.topLevelMap[top] {
            comps[0] = mapped
        } else {
            let chosen = PathSanitizer.uniqueName(top) { fm.fileExists(atPath: destination.appendingPathComponent($0).path) }
            meta.topLevelMap[top] = chosen
            comps[0] = chosen
            try JSONEncoder().encode(meta).write(to: metaURL, options: .atomic)
        }
        return destination.appendingPathComponent(comps.joined(separator: "/"))
    }

    public func discard(transferId: String) { try? fm.removeItem(at: transferDir(transferId)) }

    public func finish(transferId: String) {
        try? fm.removeItem(at: transferDir(transferId))
        if let left = try? fm.contentsOfDirectory(atPath: partialRoot.path), left.isEmpty {
            try? fm.removeItem(at: partialRoot)
        }
    }

    /// Deletes partial transfers older than 24 h (documented cleanup policy).
    public func cleanupStalePartials(now: Date = Date()) {
        guard let items = try? fm.contentsOfDirectory(at: partialRoot, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for item in items {
            let mod = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(mod) > FileSystemStorage.partialMaxAge { try? fm.removeItem(at: item) }
        }
    }
}

/// Writes through a raw file descriptor. All fd use is serialised by `lock`: the session
/// may close a writer (connection lost) while the reader task is still writing, and a
/// closed `FileHandle` raises an Objective-C exception instead of a Swift error.
final class FSWriter: IncomingFileWriter {
    private let lock = ABLock()
    private var fd: Int32
    private var position: Int64
    let partURL: URL
    let metaURL: URL
    let target: URL
    let fm: FileManager

    init(handle: FileHandle, partURL: URL, metaURL: URL, target: URL, fm: FileManager) throws {
        // Take ownership of a duplicate descriptor so the FileHandle can be released.
        let dupFd = dup(handle.fileDescriptor)
        let pos = Int64(try handle.offset())
        try? handle.close()
        guard dupFd >= 0 else { throw ABError(.writeFailed, String(cString: strerror(errno))) }
        fd = dupFd
        position = pos
        self.partURL = partURL; self.metaURL = metaURL; self.target = target; self.fm = fm
    }

    deinit { if fd >= 0 { Darwin.close(fd) } }

    private func withFd<T>(_ body: (Int32) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard fd >= 0 else { throw ABError(.connectionLost, "Writer closed") }
        return try body(fd)
    }

    func readPrefix(_ body: (Data) throws -> Void) throws {
        let end = try withFd { _ in position }
        let rfd = open(partURL.path, O_RDONLY)
        guard rfd >= 0 else { throw ABError(.writeFailed, String(cString: strerror(errno))) }
        defer { Darwin.close(rfd) }
        var remaining = end
        while remaining > 0 {
            let d = try PosixIO.read(rfd, max: Int(min(remaining, 1 << 20)))
            guard !d.isEmpty else { throw ABError(.resumeInvalid, "Partial file shrank") }
            try body(d)
            remaining -= Int64(d.count)
        }
    }

    func write(_ data: Data) throws {
        try withFd { fd in
            try PosixIO.writeAll(fd, data)
            position += Int64(data.count)
        }
    }

    func finalize() throws -> String {
        do {
            try withFd { fd in
                if fsync(fd) != 0 { throw ABError(.writeFailed, String(cString: strerror(errno))) }
                Darwin.close(fd)
                self.fd = -1
            }
            let dir = target.deletingLastPathComponent()
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // Exclusive rename: never replaces an existing file. On conflict pick "name (n)".
            var name = target.lastPathComponent
            while true {
                let dst = dir.appendingPathComponent(name)
                let rc = partURL.withUnsafeFileSystemRepresentation { src in
                    dst.withUnsafeFileSystemRepresentation { d in renamex_np(src!, d!, UInt32(RENAME_EXCL)) }
                }
                if rc == 0 { break }
                if errno != EEXIST { throw ABError(.writeFailed, String(cString: strerror(errno))) }
                name = PathSanitizer.uniqueName(target.lastPathComponent) { self.fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
            }
            try? fm.removeItem(at: metaURL)
            return dir.appendingPathComponent(name).path
        } catch let e as ABError {
            throw e
        } catch {
            throw ABError(.writeFailed, error.localizedDescription)
        }
    }

    func close(keep: Bool) {
        lock.lock()
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        lock.unlock()
        if !keep {
            try? fm.removeItem(at: partURL)
            try? fm.removeItem(at: metaURL)
        }
    }
}
