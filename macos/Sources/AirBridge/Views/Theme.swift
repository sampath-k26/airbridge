import AppKit
import QuickLookThumbnailing
import SwiftUI

// MARK: - Colors

/// App palette. Every color has a light and a dark variant.
enum Theme {
    static let accent = Color(nsColor: NSColor(name: nil) { a in
        a.isDark ? NSColor(red: 0.30, green: 0.56, blue: 1.00, alpha: 1) : NSColor(red: 0.16, green: 0.45, blue: 0.96, alpha: 1)
    })
    static let sidebar = dynamic(light: (0.945, 0.953, 0.973), dark: (0.110, 0.114, 0.125))
    static let canvas = dynamic(light: (0.961, 0.965, 0.976), dark: (0.133, 0.137, 0.149))
    static let card = dynamic(light: (1, 1, 1), dark: (0.173, 0.176, 0.192))
    static let border = dynamic(light: (0.882, 0.894, 0.918), dark: (0.255, 0.263, 0.286))
    static let selection = dynamic(light: (0.867, 0.910, 0.988), dark: (0.169, 0.243, 0.376))
    static let subtle = dynamic(light: (0.945, 0.953, 0.969), dark: (0.208, 0.212, 0.231))
    static let green = Color(red: 0.13, green: 0.66, blue: 0.33)
    static let red = Color(red: 0.90, green: 0.22, blue: 0.21)
    static let orange = Color(red: 0.95, green: 0.55, blue: 0.10)

    private static func dynamic(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            let c = a.isDark ? dark : light
            return NSColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

private extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

// MARK: - Building blocks

struct Card<Content: View>: View {
    var padding: CGFloat = 0
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
    }
}

/// Rounded status badge ("Completed", "Error", …).
struct Pill: View {
    let text: String
    let color: Color
    var symbol: String?
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(color.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(color.opacity(0.35)))
        .fixedSize()
    }
}

struct StatusDot: View {
    let color: Color
    var size: CGFloat = 8
    var body: some View { Circle().fill(color).frame(width: size, height: size) }
}

/// Primary blue button used for the main actions.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.accent.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)))
            .contentShape(Rectangle())
    }
}

/// White button with a thin border.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9).fill(configuration.isPressed ? Theme.subtle : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
            .contentShape(Rectangle())
    }
}

/// "⋯" menu used on rows.
struct MoreMenu<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        Menu { content } label: {
            Image(systemName: "ellipsis").rotationEffect(.degrees(90)).frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .foregroundStyle(.secondary)
        .accessibilityLabel("More")
    }
}

// MARK: - File kinds

enum FileKind: String, CaseIterable {
    case image, video, audio, pdf, document, archive, folder, other

    init(name: String, fileCount: Int) {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "dng", "tiff", "bmp": self = .image
        case "mp4", "mov", "mkv", "avi", "m4v", "3gp", "webm": self = .video
        case "mp3", "m4a", "wav", "flac", "aac", "ogg", "opus": self = .audio
        case "pdf": self = .pdf
        case "doc", "docx", "pages", "txt", "rtf", "md", "xls", "xlsx", "numbers", "csv", "ppt", "pptx", "key", "odt", "epub":
            self = .document
        case "zip", "rar", "7z", "gz", "tar", "apk", "dmg": self = .archive
        case "": self = fileCount > 1 ? .folder : .other
        default: self = .other
        }
    }

    var label: String {
        switch self {
        case .image: "Image"
        case .video: "Video"
        case .audio: "Audio"
        case .pdf, .document: "Document"
        case .archive: "Archive"
        case .folder: "Folder"
        case .other: "File"
        }
    }

    var symbol: String {
        switch self {
        case .image: "photo.fill"
        case .video: "play.rectangle.fill"
        case .audio: "music.note"
        case .pdf: "doc.richtext.fill"
        case .document: "doc.text.fill"
        case .archive: "doc.zipper"
        case .folder: "folder.fill"
        case .other: "doc.fill"
        }
    }

    var tint: Color {
        switch self {
        case .image: Color(red: 0.16, green: 0.45, blue: 0.96)
        case .video: Color(red: 0.55, green: 0.27, blue: 0.93)
        case .audio: Color(red: 0.91, green: 0.27, blue: 0.55)
        case .pdf: Color(red: 0.90, green: 0.22, blue: 0.21)
        case .document: Color(red: 0.20, green: 0.50, blue: 0.85)
        case .archive: Color(red: 0.93, green: 0.55, blue: 0.13)
        case .folder: Color(red: 0.13, green: 0.62, blue: 0.80)
        case .other: Color(red: 0.45, green: 0.50, blue: 0.58)
        }
    }

    /// Filter chip the kind belongs to.
    var filter: TransferFilter {
        switch self {
        case .image: .images
        case .video: .videos
        case .pdf, .document: .documents
        default: .other
        }
    }
}

enum TransferFilter: String, CaseIterable, Identifiable {
    case all = "All", images = "Images", videos = "Videos", documents = "Documents", other = "Other"
    var id: String { rawValue }
    var symbol: String? {
        switch self {
        case .all: nil
        case .images: "photo"
        case .videos: "video"
        case .documents: "doc"
        case .other: "doc.on.doc"
        }
    }
}

/// Colored square with the file-type symbol, or a real thumbnail for local images.
struct FileTile: View {
    let kind: FileKind
    var previewPath: String?
    var size: CGFloat = 52
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFill()
            } else if kind == .pdf {
                RoundedRectangle(cornerRadius: 10).fill(kind.tint)
                Image(systemName: kind.symbol).font(.system(size: size * 0.42)).foregroundStyle(.white)
            } else {
                RoundedRectangle(cornerRadius: 10).fill(kind.tint.opacity(0.14))
                Image(systemName: kind.symbol).font(.system(size: size * 0.42)).foregroundStyle(kind.tint)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: previewPath) { thumbnail = await Thumbnails.image(previewPath, kind: kind, size: size) }
        .accessibilityHidden(true)
    }
}

/// Small in-memory cache of Quick Look thumbnails for image files that still exist.
@MainActor
enum Thumbnails {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(_ path: String?, kind: FileKind, size: CGFloat) async -> NSImage? {
        guard kind == .image, let path, FileManager.default.fileExists(atPath: path) else { return nil }
        if let hit = cache.object(forKey: path as NSString) { return hit }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let req = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: size, height: size),
                                               scale: scale, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) else { return nil }
        cache.setObject(rep.nsImage, forKey: path as NSString)
        return rep.nsImage
    }
}

// MARK: - Formatting

enum Fmt {
    /// Decimal units (MB = 10^6 bytes), matching Finder.
    static func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
    static func speed(_ bps: Double?) -> String { bps.map { String(format: "%.1f MB/s", $0 / 1e6) } ?? "—" }
    static func eta(_ s: TimeInterval?) -> String {
        guard let s else { return "—" }
        let i = Int(s)
        return i < 60 ? "\(i)s left" : i < 3600 ? "\(i / 60)m \(i % 60)s left" : "\(i / 3600)h \((i % 3600) / 60)m left"
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    static func ago(_ date: Date, now: Date = Date()) -> String {
        now.timeIntervalSince(date) < 60 ? "Just now" : relative.localizedString(for: date, relativeTo: now)
    }
}

extension TransferItem {
    /// First top-level name, without the " + N more" suffix.
    var primaryName: String {
        if let r = title.range(of: " + ", options: .backwards), title.hasSuffix(" more") { return String(title[..<r.lowerBound]) }
        return title
    }

    var kind: FileKind { FileKind(name: primaryName, fileCount: fileCount) }

    var previewPath: String? { direction == .send ? sourcePaths?.first : savedTo.first }
}
