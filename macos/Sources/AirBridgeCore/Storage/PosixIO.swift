import Foundation

/// Plain POSIX file I/O into buffers we own. `FileHandle.read(upToCount:)` returns
/// autoreleased buffers; inside long-running async tasks (no autorelease pool drains)
/// those accumulate, and a 1 GB transfer peaked at ~1 GB RSS. These helpers keep
/// memory bounded by the chunk size.
enum PosixIO {
    /// Reads up to `max` bytes; returns empty Data at end of file.
    static func read(_ fd: Int32, max: Int) throws -> Data {
        var d = Data(count: max)
        let n = d.withUnsafeMutableBytes { buf -> Int in
            while true {
                let r = Darwin.read(fd, buf.baseAddress!, max)
                if r < 0 && errno == EINTR { continue }
                return r
            }
        }
        if n < 0 { throw ABError(.readFailed, String(cString: strerror(errno))) }
        if n < max { d.removeSubrange(n..<max) }
        return d
    }

    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let r = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                if r < 0 {
                    if errno == EINTR { continue }
                    if errno == ENOSPC || errno == EDQUOT { throw ABError(.insufficientStorage, "Disk full") }
                    throw ABError(.writeFailed, String(cString: strerror(errno)))
                }
                off += r
            }
        }
    }
}
