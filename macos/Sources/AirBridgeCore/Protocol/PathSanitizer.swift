import Foundation

/// Validates untrusted relative paths received in an offer (SPEC §7).
/// Returns nil when the path must be rejected.
public enum PathSanitizer {
    static let replaced: Set<Character> = [":", "*", "?", "\"", "<", ">", "|"]

    public static func sanitize(_ raw: String) -> String? {
        let path = raw.precomposedStringWithCanonicalMapping
        if path.isEmpty || path.utf8.count > 1024 || path.hasPrefix("/") { return nil }
        for scalar in path.unicodeScalars {
            if scalar == "\\" || scalar.value < 0x20 || scalar.value == 0x7F { return nil }
        }
        // Drive letter prefix, e.g. "C:" — checked before ':' is replaced.
        let scalars = Array(path.unicodeScalars)
        if scalars.count >= 2, scalars[1] == ":",
           (scalars[0].value >= 65 && scalars[0].value <= 90) || (scalars[0].value >= 97 && scalars[0].value <= 122) {
            return nil
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count > 32 { return nil }
        var out: [String] = []
        for p in parts {
            if p.isEmpty || p == "." || p == ".." { return nil }
            var c = String(p.map { replaced.contains($0) ? "_" : $0 })
            while let last = c.last, last == " " || last == "." { c.removeLast() }
            if c.isEmpty || c.utf8.count > 255 { return nil }
            out.append(c)
        }
        return out.joined(separator: "/")
    }

    /// Returns a name that does not exist in `dir`: "name.ext", "name (1).ext", ...
    public static func uniqueName(_ name: String, exists: (String) -> Bool) -> String {
        if !exists(name) { return name }
        // Split at the last dot, but keep dot-files like ".bashrc" whole.
        var base = name, suffix = ""
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            base = String(name[..<dot]); suffix = String(name[dot...])
        }
        var i = 1
        while true {
            let candidate = "\(base) (\(i))\(suffix)"
            if !exists(candidate) { return candidate }
            i += 1
        }
    }
}
