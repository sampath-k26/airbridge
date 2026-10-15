import AirBridgeCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum Page: String, CaseIterable, Identifiable {
    case transfer = "Transfer", devices = "Devices", history = "History", settings = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .transfer: "arrow.left.arrow.right"
        case .devices: "iphone"
        case .history: "clock"
        case .settings: "gearshape"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var page: Page = .transfer
    @State private var showPairing = false
    @State private var showConnect = false

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(page: $page)
                .frame(width: 236)
            Divider()
            VStack(spacing: 0) {
                StatusHeader(showPairing: $showPairing, showConnect: $showConnect)
                    .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 18)
                Group {
                    switch page {
                    case .transfer: TransferPage(showPairing: $showPairing)
                    case .devices: DevicesPage(showPairing: $showPairing, showConnect: $showConnect)
                    case .history: HistoryPage()
                    case .settings: ScrollView { SettingsForm().frame(maxWidth: 640).padding(.bottom, 24) }
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .background(Theme.canvas)
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 1000, minHeight: 660)
        .tint(Theme.accent)
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

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @Binding var page: Page

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 1) {
                    Text("AirBridge").font(.title2.weight(.semibold))
                    Text("Local File Transfer").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18).padding(.top, 44).padding(.bottom, 26)

            VStack(spacing: 4) {
                ForEach(Page.allCases) { p in
                    Button { page = p } label: {
                        HStack(spacing: 14) {
                            Image(systemName: p.symbol).font(.system(size: 17)).frame(width: 24)
                            Text(p.rawValue).font(.body.weight(page == p ? .medium : .regular))
                            Spacer()
                        }
                        .foregroundStyle(page == p ? Theme.accent : Color.primary)
                        .padding(.horizontal, 14).frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: 9).fill(page == p ? Theme.selection : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(page == p ? .isSelected : [])
                }
            }
            .padding(.horizontal, 12)

            Spacer()
            NetworkCard().padding(12)
        }
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
    }
}

/// Bottom-left card: how this Mac is connected.
struct NetworkCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let online = !NetworkInfo.localIPv4().isEmpty
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: online ? "wifi" : "wifi.slash")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(online ? Theme.accent : .secondary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(online ? Theme.selection : Theme.subtle))
            VStack(alignment: .leading, spacing: 3) {
                Text(online ? "Direct Wi-Fi" : "No network").font(.callout.weight(.semibold))
                Text(online ? "No internet required" : "Join your phone's hotspot").font(.caption).foregroundStyle(.secondary)
                Text("Fast • Private • Secure").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card.opacity(0.7)))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Header

struct StatusHeader: View {
    @EnvironmentObject var model: AppModel
    @Binding var showPairing: Bool
    @Binding var showConnect: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            statusDot
            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle).font(.title2.weight(.semibold))
                Text(statusDetail).font(.callout).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            }
            Spacer(minLength: 16)
            if model.isConnected {
                Button { model.disconnect() } label: { Label("Disconnect", systemImage: "xmark.circle") }
                    .buttonStyle(SecondaryButtonStyle())
            } else {
                Button { showConnect = true } label: { Label("Connect to Device…", systemImage: "link") }
                    .buttonStyle(SecondaryButtonStyle())
            }
            Button { model.beginPairing(); showPairing = true } label: { Label("Pair New Device", systemImage: "qrcode") }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    @ViewBuilder private var statusDot: some View {
        switch model.connection {
        case .connecting, .reconnecting:
            ProgressView().controlSize(.small).frame(width: 22, height: 22)
        default:
            let c: Color = model.listenError != nil || { if case .failed = model.connection { return true }; return false }()
                ? Theme.red : Theme.green
            Circle().fill(c.opacity(0.18)).frame(width: 22, height: 22).overlay(StatusDot(color: c, size: 10))
        }
    }

    private var statusTitle: String {
        switch model.connection {
        case .idle: return model.listenError == nil ? "Ready" : "Not listening"
        case .connecting(let t): return "Connecting to \(t)…"
        case .connected(let p, _, _): return "Connected to \(p.name)"
        case .reconnecting(let p, let a): return "Reconnecting to \(p.name) (\(a))…"
        case .failed: return "Connection problem"
        }
    }

    private var statusDetail: String {
        switch model.connection {
        case .connected(let p, let code, _):
            return "End-to-end encrypted  •  verification \(code)  •  key \(p.displayFingerprint)"
        case .failed(let m):
            return m
        case .reconnecting:
            return "Interrupted transfers resume automatically."
        default:
            if let e = model.listenError { return e }
            let ips = NetworkInfo.localIPv4().map(\.ip)
            let port = model.listenPort.map(String.init) ?? "—"
            return ips.isEmpty ? "\(model.deviceName)  •  No Wi-Fi network. Join your phone's hotspot to connect."
                : "\(model.deviceName)  •  Waiting for connection on \(ips.map { "\($0):\(port)" }.joined(separator: ", "))"
        }
    }
}

// MARK: - Transfer page

struct TransferPage: View {
    @EnvironmentObject var model: AppModel
    @Binding var showPairing: Bool

    var body: some View {
        VStack(spacing: 18) {
            DropZone()
            HStack(alignment: .top, spacing: 18) {
                PairedDevicesPanel(showPairing: $showPairing).frame(width: 232)
                TransfersPanel(title: "Recent Transfers", limit: 30)
            }
            .frame(maxHeight: .infinity)
        }
    }
}

struct DropZone: View {
    @EnvironmentObject var model: AppModel
    @State private var targeted = false

    var body: some View {
        let enabled = model.isConnected
        VStack(spacing: 6) {
            Image(systemName: "doc.badge.arrow.up")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(enabled ? Theme.accent : .secondary)
                .padding(.bottom, 6)
            Text(enabled ? "Drag and drop files here" : "Connect a device to send files").font(.title3.weight(.semibold))
            Text(enabled ? "or choose files to send to \(model.connectedPeer?.name ?? "your device")"
                    : "Received files are saved to \(model.destination.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                .font(.body).foregroundStyle(.secondary)
            Button { choose() } label: { Label("Choose Files", systemImage: "doc") }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!enabled)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .background(RoundedRectangle(cornerRadius: 16).fill(targeted ? Theme.selection : Theme.card.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
            .foregroundStyle(targeted ? Theme.accent : Color.secondary.opacity(0.35)))
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
        .accessibilityElement(children: .contain)
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

// MARK: - Devices

struct PairedDevicesPanel: View {
    @EnvironmentObject var model: AppModel
    @Binding var showPairing: Bool

    var body: some View {
        Card(padding: 14) {
            HStack {
                Text("Paired Devices").font(.headline)
                Spacer()
                Button { model.beginPairing(); showPairing = true } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(Theme.border))
                }
                .buttonStyle(.plain).help("Pair New Device").accessibilityLabel("Pair New Device")
            }
            .padding(.bottom, 12)
            if model.peers.isEmpty {
                Text("No paired devices yet. Tap + and scan the code with your phone.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.peers) { p in PeerRow(peer: p, compact: true) }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }
}

/// How a paired device relates to the current connection.
enum PeerState {
    case connected, connecting, available, offline

    var text: String {
        switch self {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .available: "Nearby"
        case .offline: "Not connected"
        }
    }

    var color: Color {
        switch self {
        case .connected: Theme.green
        case .connecting: Theme.orange
        case .available: Theme.accent
        case .offline: .secondary
        }
    }
}

extension AppModel {
    func state(of p: PeerRecord) -> PeerState {
        switch connection {
        case .connected(let c, _, _) where c.deviceId == p.deviceId: return .connected
        case .reconnecting(let c, _) where c.deviceId == p.deviceId: return .connecting
        case .connecting(let label) where label == p.name: return .connecting
        default: return nearby.contains { $0.deviceId == p.deviceId } ? .available : .offline
        }
    }
}

/// Small drawn picture of the device: a phone with a colored wallpaper (or a laptop for Macs).
/// The wallpaper is picked from the device id so two phones with the same name look different.
struct DeviceTile: View {
    let platform: String
    var seed: String = ""
    var size: CGFloat = 40

    private static let wallpapers: [[Color]] = [
        [Color(red: 0.36, green: 0.27, blue: 0.85), Color(red: 0.20, green: 0.55, blue: 0.98), Color(red: 0.98, green: 0.55, blue: 0.35)],
        [Color(red: 0.05, green: 0.30, blue: 0.85), Color(red: 0.15, green: 0.70, blue: 0.98)],
        [Color(red: 0.85, green: 0.25, blue: 0.55), Color(red: 0.45, green: 0.25, blue: 0.90)],
        [Color(red: 0.05, green: 0.55, blue: 0.55), Color(red: 0.20, green: 0.45, blue: 0.95)],
    ]

    private var wallpaper: LinearGradient {
        let hash = seed.unicodeScalars.reduce(5381) { (($0 &<< 5) &+ $0) ^ Int($1.value) }
        let i = (hash & 0x7FFFFFFF) % Self.wallpapers.count
        return LinearGradient(colors: Self.wallpapers[i], startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        Group {
            if platform == "android" { phone } else { laptop }
        }
        .frame(width: size, height: size * 1.3)
        .accessibilityHidden(true)
    }

    private var phone: some View {
        let w = size * 0.62, h = size * 1.28
        return ZStack {
            RoundedRectangle(cornerRadius: w * 0.2, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.30), Color(white: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: w * 0.15, style: .continuous)
                .fill(wallpaper)
                .overlay(
                    // Soft "wave" so the wallpaper reads as a picture, not a flat color.
                    Ellipse().fill(.white.opacity(0.22)).frame(width: w * 1.2, height: h * 0.35)
                        .offset(x: w * 0.25, y: h * 0.18).blur(radius: 2)
                )
                .clipShape(RoundedRectangle(cornerRadius: w * 0.15, style: .continuous))
                .padding(max(1.5, w * 0.06))
            Circle().fill(Color(white: 0.05)).frame(width: w * 0.12, height: w * 0.12)
                .offset(y: -h / 2 + w * 0.16)
        }
        .frame(width: w, height: h)
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }

    private var laptop: some View {
        let w = size * 0.95
        return VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color(white: 0.15))
                .overlay(RoundedRectangle(cornerRadius: 2).fill(wallpaper).padding(2))
                .frame(width: w * 0.8, height: w * 0.52)
            RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.7)).frame(width: w, height: w * 0.07)
        }
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}

struct PeerRow: View {
    @EnvironmentObject var model: AppModel
    let peer: PeerRecord
    var compact = false

    var body: some View {
        let state = model.state(of: peer)
        HStack(spacing: 12) {
            DeviceTile(platform: peer.platform, seed: peer.deviceId, size: compact ? 36 : 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(peer.name).font(.callout.weight(.semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    StatusDot(color: state.color)
                    Text(state.text).font(.caption).foregroundStyle(state == .connected ? Theme.green : .secondary)
                }
                if !compact {
                    Text("Key \(peer.displayFingerprint)  •  paired \(peer.pairedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if !compact {
                if state == .connected {
                    Button("Disconnect") { model.disconnect() }.buttonStyle(SecondaryButtonStyle())
                } else {
                    Button("Connect") { model.reconnect(peer) }.buttonStyle(SecondaryButtonStyle()).disabled(state == .connecting)
                }
            }
            MoreMenu {
                if state == .connected { Button("Disconnect") { model.disconnect() } }
                else { Button("Connect") { model.reconnect(peer) } }
                Divider()
                Button("Forget Device", role: .destructive) { model.forget(peer) }
            }
        }
        .padding(compact ? 10 : 14)
        .background(RoundedRectangle(cornerRadius: 11).fill(state == .connected ? Theme.selection.opacity(0.7) : Theme.subtle.opacity(0.6)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(peer.name), \(state.text)")
    }
}

struct DevicesPage: View {
    @EnvironmentObject var model: AppModel
    @Binding var showPairing: Bool
    @Binding var showConnect: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Card(padding: 18) {
                    HStack {
                        Text("Paired Devices").font(.headline)
                        Spacer()
                        Button { model.beginPairing(); showPairing = true } label: { Label("Pair New Device", systemImage: "qrcode") }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                    .padding(.bottom, 14)
                    if model.peers.isEmpty {
                        Text("No paired devices yet. Open AirBridge on your phone, tap **Connect to Mac** and scan the code.")
                            .foregroundStyle(.secondary)
                    }
                    VStack(spacing: 10) { ForEach(model.peers) { PeerRow(peer: $0) } }
                }
                let unpaired = model.nearby.filter { d in !model.peers.contains { $0.deviceId == d.deviceId } }
                Card(padding: 18) {
                    HStack {
                        Text("Nearby").font(.headline)
                        Spacer()
                        Button { showConnect = true } label: { Label("Connect by Address…", systemImage: "link") }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    .padding(.bottom, 10)
                    if unpaired.isEmpty {
                        Text("No other AirBridge devices found on this network. On the phone tap **Receive**, or connect by address.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(unpaired) { d in
                        HStack(spacing: 12) {
                            DeviceTile(platform: "android", seed: d.deviceId ?? d.name, size: 34)
                            Text(d.name).font(.callout.weight(.semibold))
                            Spacer()
                            Button("Connect…") { showConnect = true }.buttonStyle(SecondaryButtonStyle())
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }
}

// MARK: - Transfers list

struct HistoryPage: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        TransfersPanel(title: "Transfer History", limit: nil) {
            if !model.history.isEmpty {
                Button("Clear History") { model.clearHistory() }.buttonStyle(SecondaryButtonStyle())
            }
        }
    }
}

struct TransfersPanel<Extra: View>: View {
    @EnvironmentObject var model: AppModel
    let title: String
    let limit: Int?
    @ViewBuilder var extra: Extra
    @State private var filter: TransferFilter = .all

    init(title: String, limit: Int?, @ViewBuilder extra: () -> Extra = { EmptyView() }) {
        self.title = title; self.limit = limit; self.extra = extra()
    }

    private var items: [TransferItem] {
        let active = model.transfers.filter(\.isActive)
        let all = active + model.history.filter { h in !active.contains { $0.id == h.id } }
        let filtered = filter == .all ? all : all.filter { $0.kind.filter == filter }
        return limit.map { Array(filtered.prefix($0)) } ?? filtered
    }

    var body: some View {
        Card(padding: 0) {
            HStack(spacing: 8) {
                Text(title).font(.title3.weight(.semibold))
                Spacer(minLength: 12)
                extra
                ForEach(TransferFilter.allCases) { f in
                    Button { filter = f } label: {
                        HStack(spacing: 5) {
                            if let s = f.symbol { Image(systemName: s) }
                            Text(f.rawValue)
                        }
                        .font(.callout.weight(filter == f ? .medium : .regular))
                        .foregroundStyle(filter == f ? Theme.accent : .primary)
                        .padding(.horizontal, 11).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8).fill(filter == f ? Theme.selection : Theme.subtle))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(filter == f ? .isSelected : [])
                }
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 8)

            if items.isEmpty {
                Text(filter == .all ? "Files you send or receive appear here." : "No \(filter.rawValue.lowercased()) yet.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(30)
            } else {
                ScrollView {
                    TimelineView(.periodic(from: .now, by: 30)) { ctx in
                        LazyVStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                                if i > 0 { Divider().padding(.leading, 18) }
                                TransferRow(item: t, now: ctx.date)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

struct TransferRow: View {
    @EnvironmentObject var model: AppModel
    let item: TransferItem
    let now: Date

    var body: some View {
        HStack(spacing: 16) {
            FileTile(kind: item.kind, previewPath: item.previewPath)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text("\(item.direction == .send ? "To" : "From") \(item.peerName)  •  "
                     + (item.fileCount == 1 ? item.kind.label : "\(item.fileCount) files")
                     + "  •  \(Fmt.bytes(item.totalBytes))")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                statusLine
            }
            Spacer(minLength: 12)
            if !item.isActive {
                Text(Fmt.ago(item.finishedAt ?? item.startedAt, now: now)).font(.callout).foregroundStyle(.secondary)
                    .frame(minWidth: 90, alignment: .trailing)
            }
            badge.frame(minWidth: 96)
            MoreMenu {
                if item.isActive {
                    Button("Cancel Transfer", role: .destructive) { model.cancel(item.id) }
                } else {
                    if item.status == .done { Button("Show in Finder") { model.reveal(item) } }
                    Button("Remove from History") { model.removeFromHistory(item.id) }
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var statusLine: some View {
        switch item.status {
        case .running, .waiting, .interrupted:
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: item.fraction).progressViewStyle(.linear).frame(maxWidth: 420)
                Text(item.status == .waiting ? "Waiting for the other device…" :
                        item.status == .interrupted ? "Interrupted — resumes on reconnect" :
                        "\(Int(item.fraction * 100))%  •  \(Fmt.bytes(item.bytesDone)) of \(Fmt.bytes(item.totalBytes))  •  "
                        + "\(Fmt.speed(item.currentSpeed))  •  \(Fmt.eta(item.eta))")
                    .font(.caption).foregroundStyle(item.status == .interrupted ? Theme.orange : .secondary).monospacedDigit()
            }
        case .done:
            Label { Text("Completed  •  \(Fmt.speed(item.averageSpeed))  •  SHA-256 verified") } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .font(.callout).foregroundStyle(Theme.green)
        case .failed:
            Label(item.error ?? "Failed", systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(Theme.red).lineLimit(2)
        case .cancelled:
            Label("Cancelled", systemImage: "xmark.circle").font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var badge: some View {
        switch item.status {
        case .done: Pill(text: "Completed", color: Theme.green)
        case .failed: Pill(text: "Error", color: Theme.red, symbol: "exclamationmark.circle")
        case .cancelled: Pill(text: "Cancelled", color: .secondary)
        case .interrupted: Pill(text: "Paused", color: Theme.orange)
        case .waiting: Pill(text: "Waiting", color: .secondary)
        case .running: Pill(text: item.direction == .send ? "Sending" : "Receiving", color: Theme.accent)
        }
    }
}
