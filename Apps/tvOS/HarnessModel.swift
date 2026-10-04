import Foundation
import LanternaKit
import LanternaPlayer
import Observation
import PlayerCore
import UIKit

struct SelectedStream {
    let stream: StremioStream
    var title: String { stream.title }
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
    enum Screen { case setup, find, file, observations, results }

    static let resultsPort: UInt16 = 8765

    var screen: Screen = .setup
    var keyDraft = ""
    var setupError: String?

    var contentType = "movie"
    var contentID = ""
    var testURL = ""
    var streams: Loadable<[StremioStream]> = .idle
    var selection: SelectedStream?
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
        if ProcessInfo.processInfo.arguments.contains("-uitest-reset") { try? keychain.remove(.aiostreamsManifestURL) }
        runs = await store.runs
        seedDevManifest()
        await startServer()
        if manifestURL() != nil { screen = .find }
        await autorunIfRequested()
    }

    /// Dev convenience: a build made with Config/Local.xcconfig carries the manifest link, so the first launch skips setup.
    private func seedDevManifest() {
        guard !ProcessInfo.processInfo.arguments.contains("-uitest-reset"), manifestURL() == nil,
              let value = Bundle.main.object(forInfoDictionaryKey: "LanternaDevManifest") as? String,
              value.hasSuffix("manifest.json") else { return }
        try? keychain.set("https://" + value, for: .aiostreamsManifestURL)
    }

    /// Headless driving for simulator runs: `-autorun-url <link> -autorun-mode auto|a|c|seek-auto|seek-a|seek-c [-autorun-seconds 20]`.
    private func autorunIfRequested() async {
        let args = ProcessInfo.processInfo.arguments
        func value(_ name: String) -> String? {
            args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        guard let link = value("-autorun-url") else { return }
        testURL = link
        selectTestURL()
        while case .loading = preview { try? await Task.sleep(for: .milliseconds(250)) }
        switch value("-autorun-mode") ?? "auto" {
        case "a": play(.engineA)
        case "c": play(.engineC)
        case "seek-auto": seekEngine = .auto; play(.seekTest)
        case "seek-a": seekEngine = .engineA; play(.seekTest)
        case "seek-c": seekEngine = .engineC; play(.seekTest)
        default: play(.auto)
        }
        // Plain plays have no end of their own; seek tests close themselves.
        if !(value("-autorun-mode") ?? "").hasPrefix("seek") {
            try? await Task.sleep(for: .seconds(Double(value("-autorun-seconds") ?? "") ?? 20))
            coordinator?.requestClose()
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

    // MARK: Manifest

    private func manifestURL() -> URL? {
        guard let text = (try? keychain.string(for: .aiostreamsManifestURL)) ?? nil, let url = URL(string: text) else { return nil }
        return url
    }

    private func client() -> AIOStreamsClient? { manifestURL().flatMap { AIOStreamsClient(manifestURL: $0) } }

    private var secrets: [String] { manifestURL().map { [$0.absoluteString] } ?? [] }

    func saveManifest() async {
        let text = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text.replacingOccurrences(of: "stremio://", with: "https://")),
              let client = AIOStreamsClient(manifestURL: url) else {
            setupError = "That is not a manifest link. It should end in manifest.json."
            return
        }
        setupError = nil
        busy = true
        defer { busy = false }
        do {
            _ = try await client.manifest()
            try keychain.set(url.absoluteString, for: .aiostreamsManifestURL)
            keyDraft = ""
            screen = .find
        } catch {
            setupError = Redactor.text("Could not reach AIOStreams. \(error.localizedDescription)", secrets: [url.absoluteString])
        }
    }

    func removeManifest() {
        try? keychain.remove(.aiostreamsManifestURL)
        streams = .idle
        selection = nil
        screen = .setup
    }

    // MARK: Find

    func findStreams() async {
        guard let client = client() else { screen = .setup; return }
        let id = contentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { streams = .failed("Enter an IMDb ID like tt0133093. For a show use tt0903747:1:2 for season 1, episode 2."); return }
        streams = .loading
        do {
            let found = try await client.streams(type: contentType, id: id)
            streams = found.isEmpty ? .failed("AIOStreams returned no playable streams for that ID.") : .loaded(found)
        } catch {
            streams = .failed(describe(error))
        }
    }

    /// Bypasses AIOStreams: plays any direct video link through the same pipeline (public samples, other sources).
    func selectTestURL() {
        guard let url = URL(string: testURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https" || url.scheme == "http" else {
            streams = .failed("That is not a web link.")
            return
        }
        let name = url.lastPathComponent.isEmpty ? "Test URL" : url.lastPathComponent
        select(StremioStream(name: "Test URL", description: nil, url: url, filename: name, videoSize: nil))
    }

    // MARK: File

    func select(_ stream: StremioStream) {
        selection = SelectedStream(stream: stream)
        playError = nil
        screen = .file
        refreshPreview()
    }

    func refreshPreview() {
        previewTask?.cancel()
        guard let selection else { return }
        preview = .loading
        let target = transcodeTarget
        let secrets = secrets
        previewTask = Task {
            let prepared = try? await PlaybackRouter().prepare(url: selection.stream.url, context: context(forced: nil, target: target))
            guard let prepared else { preview = .failed("Probe failed."); return }
            // The preview only needs the decision; a real play re-prepares and starts its own remux.
            prepared.remux?.stop()
            guard !Task.isCancelled else { return }
            preview = .loaded(Preview(summary: prepared.record.probeSummary ?? "Probe failed", engine: prepared.record.decision.engine,
                                      reasons: prepared.record.decision.reasons,
                                      failure: prepared.record.failure.map { Redactor.text($0, secrets: secrets) }))
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
        guard let selection, !busy else { return }
        let secrets = secrets
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
        let request = PlaybackCoordinator.Request(url: selection.stream.url, forced: forced,
                                                  seekTest: choice == .seekTest, target: transcodeTarget, title: selection.title)
        Task {
            let run = await coordinator.run(request,
                                            scrub: { Redactor.text($0, secrets: secrets) },
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
        screen = observationsReturn == .file && selection == nil ? .find : observationsReturn
    }

    func back() {
        switch screen {
        case .file:
            previewTask?.cancel()
            selection = nil
            screen = .find
        case .results:
            screen = selection == nil ? .find : .file
        case .observations:
            Task { await saveObservations() }
        case .setup, .find:
            break
        }
    }

    func showResults() { screen = .results }

    private func describe(_ error: Error) -> String {
        switch error {
        case AIOStreamsError.http(let status):
            return "AIOStreams returned HTTP \(status)."
        case AIOStreamsError.malformedResponse:
            return "AIOStreams sent a reply Lanterna could not read."
        default:
            return Redactor.text(error.localizedDescription, secrets: secrets)
        }
    }
}
