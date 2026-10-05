import CoreImage.CIFilterBuiltins
import LanternaKit
import SwiftUI

@MainActor
@Observable
final class TraktSignInModel {
    enum State: Equatable {
        case idle, requesting
        case waiting(code: String, url: String)
        case failed(String)
    }
    var state: State = .idle
    private var task: Task<Void, Never>?

    func start(env: AppEnvironment) {
        guard let client = env.traktClient(authorized: false) else { state = .failed("Add the Trakt client ID and secret in Sources first."); return }
        state = .requesting
        task?.cancel()
        task = Task {
            do {
                let code = try await client.deviceCode()
                state = .waiting(code: code.userCode, url: code.verificationURL.absoluteString)
                var interval = code.interval
                let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
                while Date() < deadline, !Task.isCancelled {
                    try await Task.sleep(for: .seconds(interval))
                    switch try await client.pollDeviceToken(deviceCode: code.deviceCode) {
                    case .signedIn(let tokens):
                        env.storeTrakt(tokens)
                        state = .idle
                        env.syncKick?()
                        return
                    case .slowDown: interval += 2
                    case .pending: continue
                    case .expired: state = .failed("The code expired. Try again."); return
                    case .denied: state = .failed("Sign-in was denied."); return
                    case .invalid, .alreadyUsed: state = .failed("Trakt rejected that code. Try again."); return
                    }
                }
                state = .failed("The code expired. Try again.")
            } catch {
                if !Task.isCancelled { state = .failed("Could not reach Trakt.") }
            }
        }
    }

    func cancel() { task?.cancel(); state = .idle }
}

struct TraktSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = TraktSignInModel()

    var body: some View {
        List {
            Section {
                SecretRow(title: "Trakt client ID", key: .traktClientID, help: "From your own Trakt app (trakt.tv/oauth/applications).")
                SecretRow(title: "Trakt client secret", key: .traktClientSecret)
            }
            Section("Account") {
                if env.secret(.traktAccessToken) != nil {
                    Label("Signed in", systemImage: "checkmark.circle").foregroundStyle(.green)
                    if let last = env.lastSync { Text("Last sync \(last.formatted(date: .omitted, time: .shortened))").font(.caption) }
                    Button("Sync now") { env.syncKick?() }
                    Button("Sign out", role: .destructive) { env.signOutTrakt() }
                } else {
                    signIn
                }
            }
        }
        .navigationTitle("Trakt")
        .onDisappear { model.cancel() }
    }

    @ViewBuilder private var signIn: some View {
        switch model.state {
        case .idle: Button("Sign in with a code") { model.start(env: env) }
        case .requesting: ProgressView()
        case .waiting(let code, let url):
            VStack(alignment: .leading, spacing: 12) {
                Text("Go to \(url) and enter").foregroundStyle(.secondary)
                Text(code).font(.system(size: 48, weight: .bold, design: .monospaced)).foregroundStyle(Theme.accent)
                if let image = qrImage(url) { Image(uiImage: image).interpolation(.none).resizable().frame(width: 200, height: 200) }
                Button("Cancel") { model.cancel() }
            }
        case .failed(let message):
            Text(message).foregroundStyle(.red)
            Button("Try Again") { model.start(env: env) }
        }
    }
}

func qrImage(_ text: String) -> PlatformImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
          let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
    #if canImport(UIKit)
    return UIImage(cgImage: cg)
    #else
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    #endif
}
