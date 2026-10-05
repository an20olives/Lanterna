import LanternaKit
import SwiftUI
#if os(iOS)
import VisionKit
#endif

@MainActor
@Observable
final class PairingReceiverModel {
    enum State: Equatable {
        case starting
        case waiting(code: String, qr: Data)
        case receiving(device: String)
        case done([String: String])
        case failed(String)
    }
    var state: State = .starting
    private var server: PairingServer?
    private var task: Task<Void, Never>?

    func start(env: AppEnvironment) {
        stop()
        task = Task {
            let server = PairingServer()
            self.server = server
            guard let host = LANAddress.current() else { state = .failed("No network address. Join the same Wi-Fi as your iPhone."); return }
            do {
                let invitation = try await server.start(host: host)
                if let image = qrImage(invitation.url.absoluteString), let data = image.pngData() {
                    state = .waiting(code: invitation.verificationCode, qr: data)
                }
                Task { [weak self] in
                    for await event in server.events {
                        if case .lockedOut = event { self?.start(env: env); return }
                    }
                }
                for await channel in server.connections {
                    state = .receiving(device: channel.peerName)
                    await handle(channel, env: env)
                    channel.close()
                    return
                }
            } catch {
                state = .failed("Could not start pairing. Allow Local Network access for Lanterna and try again.")
            }
        }
    }

    private func handle(_ channel: PairingChannel, env: AppEnvironment) async {
        do {
            guard case .bundle(let bundle) = try await channel.receive() else { state = .failed("Unexpected message from the iPhone."); return }
            var result = env.apply(bundle)
            try await channel.send(.result(result))
            for case .jellyfin(let id, _, _, let wantsQuickConnect) in bundle.secrets where wantsQuickConnect {
                let ok = await env.signInToJellyfinViaPhone(sourceID: id, channel: channel)
                let label = bundle.secrets.first { if case .jellyfin(let other, _, _, _) = $0 { return other == id } else { return false } }?.label ?? "Jellyfin"
                result.applied[label] = ok ? "ok" : "failed: sign-in"
            }
            state = .done(result.applied)
            env.syncKick?()
        } catch {
            state = .failed("The connection was interrupted. Try again.")
        }
    }

    func stop() {
        task?.cancel()
        server?.stop()
        server = nil
    }
}

struct PairingReceiverView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = PairingReceiverModel()

    var body: some View {
        VStack(spacing: 24) {
            Text("Pair with your iPhone").font(.title.bold())
            switch model.state {
            case .starting:
                ProgressView()
            case .waiting(let code, let qr):
                Text("Open Lanterna on your iPhone, go to Settings, Pair Apple TV, and scan this code.").multilineTextAlignment(.center).frame(maxWidth: 800)
                if let image = PlatformImage(data: qr) { Image(platformImage: image).interpolation(.none).resizable().frame(width: 360, height: 360).background(.white).accessibilityIdentifier("pairing.qr") }
                Text("Check that your iPhone shows \(code)").font(.title3).foregroundStyle(Theme.accent)
            case .receiving(let device):
                ProgressView("Receiving from \(device)")
            case .done(let applied):
                Label("Paired", systemImage: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
                ForEach(applied.sorted { $0.key < $1.key }, id: \.key) { Text("\($0.key): \($0.value)") }
            case .failed(let message):
                Text(message).foregroundStyle(.red)
                Button("Try Again") { model.start(env: env) }
            }
        }
        .padding(Metrics.gutter)
        .task { model.start(env: env) }
        .onDisappear { model.stop() }
    }
}

#if os(iOS)
@MainActor
@Observable
final class PairingSenderModel {
    enum State: Equatable {
        case scanning
        case confirm(PairingInvitation)
        case sending
        case done([String: String])
        case failed(String)
    }
    var state: State = .scanning
    var selected: Set<String> = []
    var pasted = ""

    func accept(_ text: String) {
        guard let url = URL(string: text), let invitation = PairingInvitation(url: url) else { state = .failed("That is not a Lanterna pairing code."); return }
        guard !invitation.isExpired() else { state = .failed("That code expired. Show a new one on the Apple TV."); return }
        state = .confirm(invitation)
    }

    func send(invitation: PairingInvitation, env: AppEnvironment) async {
        state = .sending
        let offers = env.pairingOffers().filter { selected.contains($0.id) }
        let secrets = offers.compactMap(\.secret)
        let config = offers.contains { $0.isSettings } ? env.config : nil
        let bundle = PairingBundle(sentAt: Date(), fromDeviceName: env.deviceName, config: config, secrets: secrets)
        do {
            let channel = try await PairingClient.connect(invitation: invitation, deviceName: env.deviceName)
            try await channel.send(.bundle(bundle))
            var applied: [String: String] = [:]
            // The TV may ask this phone to approve a Jellyfin Quick Connect code before it is finished.
            var waitingForQuickConnect = secrets.filter { if case .jellyfin = $0 { return true } else { return false } }.count
            var sawResult = false
            while !sawResult || waitingForQuickConnect > 0 {
                switch try await channel.receive() {
                case .result(let result):
                    applied = result.applied
                    sawResult = true
                    if waitingForQuickConnect == 0 { break }
                case .quickConnectCode(let id, let code):
                    let ok = await env.authorizeQuickConnect(sourceID: id, code: code)
                    try await channel.send(.quickConnectDone(sourceID: id, ok: ok))
                    waitingForQuickConnect -= 1
                default:
                    break
                }
                if sawResult && waitingForQuickConnect == 0 { break }
            }
            channel.close()
            state = .done(applied)
        } catch PairingError.authenticationFailed {
            state = .failed("The Apple TV did not match this code. Show a new one and scan it again.")
        } catch {
            state = .failed("Could not reach the Apple TV. Check that both are on the same network and Local Network is allowed.")
        }
    }
}

struct PairingSenderView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = PairingSenderModel()

    var body: some View {
        VStack(spacing: 16) {
            switch model.state {
            case .scanning:
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    QRScannerView { model.accept($0) }.frame(maxHeight: 360).clipShape(RoundedRectangle(cornerRadius: 16))
                }
                Text("Scan the code on your Apple TV.").foregroundStyle(.secondary)
                TextField("Or paste the pairing link", text: $model.pasted).neverCapitalize().autocorrectionDisabled()
                Button("Use link") { model.accept(model.pasted) }.disabled(model.pasted.isEmpty)
            case .confirm(let invitation):
                Text("Your Apple TV should show \(invitation.verificationCode)").font(.headline)
                List(env.pairingOffers()) { offer in
                    Toggle(offer.label, isOn: Binding(get: { model.selected.contains(offer.id) }, set: { on in
                        if on { model.selected.insert(offer.id) } else { model.selected.remove(offer.id) }
                    }))
                }
                Button("Send to Apple TV") { Task { await model.send(invitation: invitation, env: env) } }
                    .buttonStyle(.borderedProminent).disabled(model.selected.isEmpty)
            case .sending:
                ProgressView("Sending")
            case .done(let applied):
                Label("Sent", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                ForEach(applied.sorted { $0.key < $1.key }, id: \.key) { Text("\($0.key): \($0.value)") }
            case .failed(let message):
                Text(message).foregroundStyle(.red)
                Button("Try Again") { model.state = .scanning }
            }
        }
        .padding()
        .navigationTitle("Pair Apple TV")
        .onAppear { model.selected = Set(env.pairingOffers().map(\.id)) }
    }
}

struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                                recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let text = barcode.payloadStringValue { done = true; onCode(text); return }
            }
        }
    }
}
#else
struct PairingSenderView: View {
    #if os(tvOS)
    var body: some View { Text("Open Lanterna on your iPhone to send settings to this Apple TV.").padding() }
    #else
    var body: some View { Text("Pair from your iPhone. On the Mac, enter your keys under Settings, Sources and keys.").padding() }
    #endif
}
#endif
