import AirBridgeCore
import Combine
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Shows the QR code the phone scans: endpoint + one-time code + this Mac's key fingerprint.
struct PairingSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair a New Device").font(.title2.weight(.semibold))
            if let uri = model.pairingURI, let code = model.pairingCode {
                Text("In AirBridge on your phone tap **Connect to Mac** and scan this code.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                QRCodeView(text: uri).frame(width: 240, height: 240)
                    .accessibilityLabel("Pairing QR code")
                let left = max(0, Int(code.expiresAt.timeIntervalSince(now)))
                VStack(spacing: 4) {
                    Text("Or enter manually").font(.caption).foregroundStyle(.secondary)
                    Text(code.display).font(.system(.title, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                    Text(NetworkInfo.localIPv4().map { "\($0.ip)" }.joined(separator: " · ") + "  port \(model.listenPort ?? 0)")
                        .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    Text(left > 0 ? "Single use · expires in \(left / 60):\(String(format: "%02d", left % 60))" : "Expired")
                        .font(.caption).foregroundStyle(left > 0 ? Color.secondary : Color.red)
                }
                if left == 0 { Button("New Code") { model.beginPairing() } }
            } else if NetworkInfo.localIPv4().isEmpty {
                Label("This Mac is not on a network.", systemImage: "wifi.slash").font(.headline)
                Text("Turn on your phone's Wi-Fi hotspot and join it from the Wi-Fi menu. No internet is needed.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
            } else {
                ProgressView()
                if let e = model.listenError { Text(e).foregroundStyle(.red) }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onReceive(timer) { now = $0 }
    }
}

struct QRCodeView: View {
    let text: String
    var body: some View {
        if let img = Self.render(text) {
            Image(nsImage: img).interpolation(.none).resizable().scaledToFit()
                .padding(10).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    static func render(_ s: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

/// Mac dials the phone (phone in Receive mode) — manual address + code, or a nearby device.
struct ConnectSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var port = String(ABProtocol.defaultPort)
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect to a Device").font(.title2.weight(.semibold))
            Text("On the phone tap **Receive**, then enter the address and pairing code it shows. Leave the code empty for an already paired device.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.nearby.isEmpty {
                Text("Nearby").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(model.nearby) { d in
                    Button {
                        Task {
                            if let (h, p) = await NearbyBrowser.resolve(d.endpoint) { host = h; port = String(p) }
                        }
                    } label: { Label(d.name, systemImage: "iphone.gen3") }.buttonStyle(.link)
                }
            }
            Form {
                TextField("Address", text: $host, prompt: Text("e.g. 172.31.154.181"))
                TextField("Port", text: $port)
                TextField("Pairing code", text: $code, prompt: Text("XXXXX-XXXXX"))
            }
            let codeValid = code.isEmpty || PairingCode.normalize(code) != nil
            if !codeValid { Text("The code has 10 letters and digits.").font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Connect") {
                    model.connect(host: host.trimmingCharacters(in: .whitespaces), port: UInt16(port) ?? ABProtocol.defaultPort,
                                  code: code.isEmpty ? nil : code)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(host.isEmpty || !codeValid)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

struct OfferSheet: View {
    @EnvironmentObject var model: AppModel
    let prompt: PendingDecision<IncomingOffer>

    var body: some View {
        let o = prompt.value
        VStack(alignment: .leading, spacing: 12) {
            Text("Receive from \(o.peer.name)?").font(.title3.weight(.semibold))
            Text("\(o.files.count) file\(o.files.count == 1 ? "" : "s") · \(Fmt.bytes(o.totalBytes))").foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(o.files.prefix(200), id: \.id) { f in
                        HStack { Text(f.path).lineLimit(1).truncationMode(.middle); Spacer(); Text(Fmt.bytes(f.size)).foregroundStyle(.secondary) }
                            .font(.callout)
                    }
                }
            }.frame(maxHeight: 200)
            HStack {
                Spacer()
                Button("Decline") { prompt.answer(false); model.offerPrompt = nil }.keyboardShortcut(.cancelAction)
                Button("Accept") { prompt.answer(true); model.offerPrompt = nil }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 440)
    }
}

/// Settings window (⌘,).
struct SettingsView: View {
    var body: some View { SettingsForm().frame(width: 520, height: 420) }
}

/// Shared by the Settings window and the Settings page in the main window.
struct SettingsForm: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("This Mac") {
                TextField("Device name", text: $model.deviceName)
                LabeledContent("Identity key", value: ABCrypto.displayFingerprint(spki: model.identity.spki))
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
            }
            Section("Receiving") {
                LabeledContent("Save files to") {
                    HStack {
                        Text(model.destination.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") {
                            let p = NSOpenPanel()
                            p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true; p.prompt = "Use Folder"
                            if p.runModal() == .OK, let u = p.url { model.destination = u }
                        }
                    }
                }
                Toggle("Ask before receiving from paired devices", isOn: $model.askBeforeReceiving)
            }
            Section("Performance") {
                Picker("Chunk size", selection: $model.chunkSize) {
                    Text("64 KiB").tag(64 * 1024)
                    Text("256 KiB").tag(256 * 1024)
                    Text("1 MiB (default)").tag(1024 * 1024)
                    Text("4 MiB").tag(4 * 1024 * 1024)
                }
            }
            Section("History") {
                Button("Clear Transfer History", role: .destructive) { model.clearHistory() }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}
