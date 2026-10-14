import AirBridgeCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showPairing = false
    @State private var showConnect = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                StatusHeader(showPairing: $showPairing, showConnect: $showConnect)
                DropZone()
                if !model.transfers.filter(\.isActive).isEmpty {
                    SectionLabel("Transfers")
                    Card {
                        ForEach(Array(model.transfers.filter(\.isActive).enumerated()), id: \.element.id) { i, t in
                            if i > 0 { Divider() }
                            TransferRowView(item: t)
                        }
                    }
                }
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("Paired devices")
                        PeersCard(showPairing: $showPairing)
                    }
                    .frame(maxWidth: 300)
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("Recent")
                        RecentCard()
                    }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showPairing, onDismiss: { model.endPairing() }) { PairingSheet() }
        .sheet(isPresented: $showConnect) { ConnectSheet() }
        .onChange(of: model.isConnected) { _, connected in if connected { showPairing = false; showConnect = false } }
        .alert(item: $model.pairingPrompt) { p in
            Alert(title: Text("Pair with \(p.value.peerName)?"),
                  message: Text("Check that the phone shows the same verification number:\n\n\(p.value.verificationCode)\n\nDevice key \(p.value.fingerprint)"),
                  primaryButton: .default(Text("Pair")) { p.answer(true) },
                  secondaryButton: .cancel(Text("Decline")) { p.answer(false) })
        }
        .sheet(item: $model.offerPrompt) { o in OfferSheet(prompt: o) }
        .alert(model.notice?.title ?? "", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } }),
               presenting: model.notice) { _ in Button("OK") {} } message: { n in Text(n.message) }
    }
}

// MARK: - Header

struct StatusHeader: View {
    @EnvironmentObject var model: AppModel
    @Binding var showPairing: Bool
    @Binding var showConnect: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    statusDot
                    Text(statusTitle).font(.title2.weight(.semibold))
                }
                Text(statusDetail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            if model.isConnected {
                Button("Disconnect") { model.disconnect() }
            } else {
                Button("Connect to Device…") { showConnect = true }
            }
            Button {
                model.beginPairing(); showPairing = true
            } label: { Label("Pair New Device", systemImage: "qrcode") }
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder private var statusDot: some View {
        switch model.connection {
        case .connected: Circle().fill(.green).frame(width: 10, height: 10)
        case .connecting, .reconnecting: ProgressView().controlSize(.small)
        case .failed: Circle().fill(.red).frame(width: 10, height: 10)
        case .idle: Circle().fill(.secondary.opacity(0.5)).frame(width: 10, height: 10)
        }
    }

    private var statusTitle: String {
        switch model.connection {
        case .idle: return "Ready"
        case .connecting(let t): return "Connecting to \(t)…"
        case .connected(let p, _, _): return "Connected to \(p.name)"
        case .reconnecting(let p, let a): return "Reconnecting to \(p.name) (\(a))…"
        case .failed: return "Connection problem"
        }
    }

    private var statusDetail: String {
        switch model.connection {
        case .connected(let p, let code, _):
            return "End-to-end encrypted · verification \(code) · key \(p.displayFingerprint)"
        case .failed(let m):
            return m
        case .reconnecting:
            return "Interrupted transfers resume automatically."
        default:
            if let e = model.listenError { return e }
            let ips = NetworkInfo.localIPv4().map(\.ip)
            return ips.isEmpty ? "No Wi-Fi network. Join your phone's hotspot to connect."
                : "\(model.deviceName) · waiting on \(ips.joined(separator: ", ")) port \(model.listenPort.map(String.init) ?? "—")"
        }
    }
}

// MARK: - Drop zone

struct DropZone: View {
    @EnvironmentObject var model: AppModel
    @State private var targeted = false

    var body: some View {
        let enabled = model.isConnected
        VStack(spacing: 10) {
            Image(systemName: "arrow.up.doc.on.clipboard").font(.system(size: 30, weight: .light))
                .foregroundStyle(enabled ? Color.accentColor : .secondary)
            Text(enabled ? "Drop files or folders to send to \(model.connectedPeer?.name ?? "")" : "Pair or connect a device to send files")
                .font(.headline)
            Text(enabled ? "Files stream directly over Wi-Fi with end-to-end encryption." :
                    "Received files are saved to \(model.destination.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                .font(.callout).foregroundStyle(.secondary)
            Button("Choose Files…") { choose() }.disabled(!enabled)
        }
        .frame(maxWidth: .infinity, minHeight: 170)
        .background(RoundedRectangle(cornerRadius: 14).fill(targeted ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.35)))
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            guard enabled else { return false }
            Task {
                var urls: [URL] = []
                for p in providers {
                    if let url = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                       let u = URL(dataRepresentation: url, relativeTo: nil) { urls.append(u) }
                }
                await MainActor.run { model.send(urls) }
            }
            return true
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(enabled ? "Drop files to send" : "Not connected")
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Send"
        if panel.runModal() == .OK { model.send(panel.urls) }
    }
}

// MARK: - Transfer rows

struct TransferRowView: View {
    @EnvironmentObject var model: AppModel
    let item: TransferItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: Self.symbol(for: item.title, multiple: item.fileCount > 1))
                    .font(.title3).frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.headline).lineLimit(1).truncationMode(.middle)
                    Text("\(item.direction == .send ? "To" : "From") \(item.peerName) · \(item.fileCount == 1 ? "1 file" : "\(item.fileCount) files") · \(Fmt.bytes(item.totalBytes))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if item.isActive {
                    Button { model.cancel(item.id) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Cancel transfer")
                } else if item.direction == .receive, item.status == .done {
                    Button("Show in Finder") { model.reveal(item) }.buttonStyle(.link)
                }
            }
            switch item.status {
            case .running, .waiting, .interrupted:
                ProgressView(value: item.fraction).progressViewStyle(.linear)
                HStack {
                    Text(item.status == .waiting ? "Waiting for the other device…" :
                            item.status == .interrupted ? "Interrupted — resumes on reconnect" :
                            "\(Int(item.fraction * 100))% · \(Fmt.bytes(item.bytesDone))")
                    Spacer()
                    if item.status == .running {
                        Text("\(Fmt.speed(item.currentSpeed)) · avg \(Fmt.speed(item.averageSpeed)) · \(Fmt.eta(item.eta))").monospacedDigit()
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            case .done:
                Label("Completed · SHA-256 verified · avg \(Fmt.speed(item.averageSpeed))", systemImage: "checkmark.seal.fill")
                    .font(.caption).foregroundStyle(.green)
            case .failed:
                Label(item.error ?? "Failed", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
            case .cancelled:
                Text("Cancelled").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }

    static func symbol(for name: String, multiple: Bool) -> String {
        if multiple && !name.contains(".") { return "folder" }
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "gif", "webp", "dng": return "photo"
        case "mp4", "mov", "mkv", "avi", "m4v", "3gp": return "film"
        case "mp3", "m4a", "wav", "flac", "aac", "ogg", "opus": return "music.note"
        case "pdf": return "doc.richtext"
        case "zip", "rar", "7z", "gz", "tar": return "doc.zipper"
        default: return "doc"
        }
    }
}

struct PeersCard: View {
    @EnvironmentObject var model: AppModel
    @Binding var showPairing: Bool

    var body: some View {
        Card {
            if model.peers.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No paired devices yet.").font(.callout)
                    Button("Pair New Device") { model.beginPairing(); showPairing = true }.buttonStyle(.link)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(model.peers.enumerated()), id: \.element.id) { i, p in
                if i > 0 { Divider() }
                let connected = model.connectedPeer?.deviceId == p.deviceId
                HStack {
                    Image(systemName: p.platform == "android" ? "iphone.gen3" : "desktopcomputer").foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).font(.callout.weight(.medium))
                        Text(connected ? "Connected" : "Key \(p.displayFingerprint)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        if !connected { Button("Connect") { model.reconnect(p) } }
                        Button("Forget Device", role: .destructive) { model.forget(p) }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
    }
}

struct RecentCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card {
            if model.history.isEmpty {
                Text("Transfers you send or receive appear here.").font(.callout).foregroundStyle(.secondary)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(model.history.prefix(15).enumerated()), id: \.element.id) { i, t in
                if i > 0 { Divider() }
                TransferRowView(item: t)
            }
        }
    }
}

// MARK: - Building blocks

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.18)))
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 2)
    }
}

enum Fmt {
    /// Decimal units (MB = 10^6 bytes), matching Finder.
    static func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
    static func speed(_ bps: Double?) -> String { bps.map { String(format: "%.1f MB/s", $0 / 1e6) } ?? "—" }
    static func eta(_ s: TimeInterval?) -> String {
        guard let s else { return "—" }
        let i = Int(s)
        return i < 60 ? "\(i)s left" : i < 3600 ? "\(i / 60)m \(i % 60)s left" : "\(i / 3600)h \((i % 3600) / 60)m left"
    }
}
