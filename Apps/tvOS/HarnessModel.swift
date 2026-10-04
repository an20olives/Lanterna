import Foundation
import LanternaKit
import LanternaPlayer
import Observation
import PlayerCore
import UIKit

struct LibraryEntry: Identifiable {
    let item: TorBoxItem
    let files: [TorBoxFile]
    var id: String { "\(item.kind.rawValue)-\(item.id)" }
}

struct SelectedFile {
    let entry: LibraryEntry
    let file: TorBoxFile
    var title: String { file.shortName ?? (file.name as NSString).lastPathComponent }
}

enum Loadable<Value> {
    case idle, loading, loaded(Value), failed(String)
}

struct Preview {
    let summary: String
    let engine: EngineID
    let reasons: [RouteReason]
    let failure: String?
}

@MainActor
@Observable
final class HarnessModel {
    enum Screen { case setup, library, file, observations, results }

    static let resultsPort: UInt16 = 8765

    var screen: Screen = .setup
    var keyDraft = ""
    var setupError: String?

    var library: Loadable<[LibraryEntry]> = .idle
    var selection: SelectedFile?
    var preview: Loadable<Preview> = .idle
    var transcodeTarget: AudioTranscodeTarget = .alac
    var busy = false
    var playError: String?

    var playerController: UIViewController?
    var currentRun: HarnessRun?
    var runs: [HarnessRun] = []

    var lanURL: String?
    var serverError: String?

    @ObservationIgnored private let keychain = KeychainStore()
    @ObservationIgnored private let store = RunStore()
    @ObservationIgnored private var server: TinyHTTPServer?
    @ObservationIgnored private var coordinator: PlaybackCoordinator?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var observationsReturn: Screen = .file
    @ObservationIgnored private var started = false

    // MARK: Start

    func bootstrap() async {
        guard !started else { return }
        started = true
        if ProcessInfo.processInfo.arguments.contains("-uitest-reset") { try? keychain.remove(.torboxAPIKey) }
        runs = await store.runs
        await startServer()
        if apiKey() != nil {
            screen = .library
            await loadLibrary()
        }
    }

    private func startServer() async {
        let store = store
        let server = TinyHTTPServer(bind: .allInterfaces(port: Self.resultsPort)) { head in
            let path = head.path.split(separator: "?").first.map(String.init) ?? head.path
            guard path == "/p0/results.json" else { return .notFound() }
            return HTTPResponse(status: 200, contentType: "application/json", body: await store.exportJSON())
        }
        do {
            _ = try await server.start()
            self.server = server
            lanURL = LANAddress.current().map { "http://\($0):\(Self.resultsPort)/p0/results.json" }
        } catch {
            serverError = "Results server did not start: \(error.localizedDescription)"
        }
    }

    // MARK: Key

    private func apiKey() -> String? {
        guard let key = (try? keychain.string(for: .torboxAPIKey)) ?? nil, !key.isEmpty else { return nil }
        return key
    }

    func saveKey() async {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { setupError = "Enter your key first."; return }
        do {
            try keychain.set(key, for: .torboxAPIKey)
            keyDraft = ""
            setupError = nil
            screen = .library
            await loadLibrary()
        } catch {
            setupError = "Could not save the key to the Keychain."
        }
    }

    func removeKey() {
        try? keychain.remove(.torboxAPIKey)
        library = .idle
        selection = nil
        screen = .setup
    }

    // MARK: Library

    func loadLibrary() async {
        guard let key = apiKey() else { screen = .setup; return }
        library = .loading
        let client = TorBoxClient(apiKey: key)
        do {
            async let torrents = client.list(.torrents)
            async let usenet = client.list(.usenet)
            async let web = client.list(.webDownloads)
            let all = try await torrents + usenet + web
            let entries = all.filter(\.isReady).compactMap { item -> LibraryEntry? in
                let files = item.videoFiles
                return files.isEmpty ? nil : LibraryEntry(item: item, files: files)
            }
            library = .loaded(entries.sorted { $0.item.name.localizedCaseInsensitiveCompare($1.item.name) == .orderedAscending })
        } catch {
            library = .failed(describe(error, key: key))
        }
    }

    // MARK: File

    func select(_ file: TorBoxFile, in entry: LibraryEntry) {
        selection = SelectedFile(entry: entry, file: file)
        playError = nil
        screen = .file
        refreshPreview()
    }

    func refreshPreview() {
        previewTask?.cancel()
        guard let selection, let key = apiKey() else { return }
        preview = .loading
        let target = transcodeTarget
        previewTask = Task {
            do {
                let client = TorBoxClient(apiKey: key)
                let link = try await client.downloadLink(kind: selection.entry.item.kind, itemID: selection.entry.item.id, fileID: selection.file.id)
                let prepared = try await PlaybackRouter().prepare(url: link, context: context(forced: nil, target: target))
                // The preview only needs the decision; a real play re-prepares and starts its own remux.
                prepared.remux?.stop()
                guard !Task.isCancelled else { return }
                preview = .loaded(Preview(summary: prepared.record.probeSummary ?? "Probe failed", engine: prepared.record.decision.engine,
                                          reasons: prepared.record.decision.reasons,
                                          failure: prepared.record.failure.map { Redactor.text($0, secrets: [key]) }))
            } catch {
                guard !Task.isCancelled else { return }
                preview = .failed(describe(error, key: key))
            }
        }
    }

    private func context(forced: EngineID?, target: AudioTranscodeTarget) -> RoutingContext {
        RoutingContext(preferences: PlaybackCoordinator.preferences, hardware: PlaybackRouter.hardwareCapabilities(),
                       transcodeTarget: target, forcedEngine: forced)
    }

    enum PlayChoice { case auto, engineA, engineC, seekTest }

    enum SeekEngine: String, CaseIterable { case auto = "Auto", engineA = "A", engineC = "C" }

    var seekEngine: SeekEngine = .auto

    func play(_ choice: PlayChoice) {
        guard let selection, let key = apiKey(), !busy else { return }
        previewTask?.cancel()
        let engineChoice: SeekEngine
        switch choice {
        case .auto: engineChoice = .auto
        case .engineA: engineChoice = .engineA
        case .engineC: engineChoice = .engineC
        case .seekTest: engineChoice = seekEngine
        }
        let forced: EngineID?
        switch engineChoice {
        case .auto:
            forced = nil
        case .engineA:
            // Match what Auto would use for A: direct for plain MP4, remux otherwise.
            if case .loaded(let preview) = preview, preview.engine == .aDirect { forced = .aDirect } else { forced = .aRemux }
        case .engineC:
            forced = .c
        }
        busy = true
        playError = nil
        let coordinator = PlaybackCoordinator()
        self.coordinator = coordinator
        let request = PlaybackCoordinator.Request(item: selection.entry.item, file: selection.file, forced: forced,
                                                  seekTest: choice == .seekTest, target: transcodeTarget, title: selection.title)
        Task {
            let run = await coordinator.run(request, client: TorBoxClient(apiKey: key),
                                            scrub: { Redactor.text($0, secrets: [key]) },
                                            present: { [weak self] in self?.playerController = $0 })
            self.coordinator = nil
            self.busy = false
            await store.upsert(run)
            runs = await store.runs
            if run.enginePlayed == nil {
                playError = run.failure ?? "Could not start playback."
            } else {
                currentRun = run
                observationsReturn = .file
                screen = .observations
            }
        }
    }

    /// Menu pressed or the cover went away.
    func playerDismissed() { coordinator?.requestClose() }

    // MARK: Observations and results

    func editObservations(of run: HarnessRun) {
        currentRun = run
        observationsReturn = .results
        screen = .observations
    }

    func saveObservations() async {
        if let run = currentRun { await store.upsert(run); runs = await store.runs }
        currentRun = nil
        screen = observationsReturn == .file && selection == nil ? .library : observationsReturn
    }

    func back() {
        switch screen {
        case .file:
            previewTask?.cancel()
            selection = nil
            screen = .library
        case .results:
            screen = selection == nil ? .library : .file
        case .observations:
            Task { await saveObservations() }
        case .setup, .library:
            break
        }
    }

    func showResults() { screen = .results }

    private func describe(_ error: Error, key: String) -> String {
        switch error {
        case TorBoxError.api(let code, let detail):
            return Redactor.text("TorBox said \(code). \(detail)", secrets: [key])
        case TorBoxError.http(let status):
            return "TorBox returned HTTP \(status)."
        case TorBoxError.malformedResponse:
            return "TorBox sent a reply Lanterna could not read."
        default:
            return Redactor.text(error.localizedDescription, secrets: [key])
        }
    }
}
