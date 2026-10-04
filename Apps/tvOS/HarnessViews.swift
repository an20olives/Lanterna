import PlayerCore
import SwiftUI

struct HarnessRoot: View {
    @Bindable var model: HarnessModel

    var body: some View {
        Group {
            switch model.screen {
            case .setup: SetupView(model: model)
            case .find: FindView(model: model)
            case .file: FileView(model: model)
            case .observations: ObservationsView(model: model)
            case .results: ResultsView(model: model)
            }
        }
        .task { await model.bootstrap() }
        .fullScreenCover(isPresented: Binding(get: { model.playerController != nil }, set: { if !$0 { model.playerDismissed() } })) {
            if let controller = model.playerController {
                PlayerHost(controller: controller)
                    .ignoresSafeArea()
                    .onDisappear { model.playerDismissed() }
            }
        }
    }
}

struct SetupView: View {
    @Bindable var model: HarnessModel

    var body: some View {
        VStack(spacing: 40) {
            Text("Connect AIOStreams").font(.largeTitle.bold()).accessibilityIdentifier("setup.title")
            Text("Paste your AIOStreams manifest link. It stays in this Apple TV's Keychain.")
                .foregroundStyle(.secondary)
            TextField("AIOStreams manifest link", text: $model.keyDraft)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(maxWidth: 900)
            Button("Save") { Task { await model.saveManifest() } }
                .disabled(model.busy)
            if model.busy { ProgressView("Checking") }
            if let error = model.setupError { Text(error).foregroundStyle(.red) }
            if let server = model.serverError { Text(server).foregroundStyle(.secondary) }
        }
        .padding(60)
    }
}

struct FindView: View {
    @Bindable var model: HarnessModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 30) {
                Text("Find streams").font(.largeTitle.bold())
                Spacer()
                Button("Results") { model.showResults() }
                Button("Remove link") { model.removeManifest() }
            }
            HStack(spacing: 24) {
                Picker("Type", selection: $model.contentType) {
                    Text("Movie").tag("movie")
                    Text("Show").tag("series")
                }
                TextField("IMDb ID, e.g. tt0133093 or tt0903747:1:2", text: $model.contentID)
                Button("Find") { Task { await model.findStreams() } }
            }
            HStack(spacing: 24) {
                TextField("Or paste a direct video link to test", text: $model.testURL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Play link") { model.selectTestURL() }
            }
            switch model.streams {
            case .idle:
                Spacer()
            case .loading:
                Spacer()
                HStack { Spacer(); ProgressView("Asking AIOStreams"); Spacer() }
                Spacer()
            case .failed(let message):
                Text(message).foregroundStyle(.secondary)
                Spacer()
            case .loaded(let streams):
                List(streams) { stream in
                    Button { model.select(stream) } label: {
                        HStack {
                            Text(stream.summary).lineLimit(2)
                            Spacer()
                            Text(gigabytes(stream.videoSize)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 60)
    }
}

func gigabytes(_ bytes: Int64?) -> String {
    guard let bytes else { return "" }
    return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
}

struct FileView: View {
    @Bindable var model: HarnessModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let selection = model.selection {
                    Text(selection.title).font(.title2.bold()).lineLimit(2)
                    Text(gigabytes(selection.stream.videoSize)).foregroundStyle(.secondary)
                }
                previewSection
                Picker("Audio transcode", selection: $model.transcodeTarget) {
                    ForEach(AudioTranscodeTarget.allCases, id: \.self) { target in
                        Text(label(target)).tag(target)
                    }
                }
                .onChange(of: model.transcodeTarget) { model.refreshPreview() }
                HStack(spacing: 24) {
                    Button("Play Auto") { model.play(.auto) }
                    Button("Play A") { model.play(.engineA) }
                    Button("Play C") { model.play(.engineC) }
                }
                .disabled(model.busy)
                HStack(spacing: 24) {
                    Picker("Seek test engine", selection: $model.seekEngine) {
                        ForEach(HarnessModel.SeekEngine.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Button("Seek test") { model.play(.seekTest) }
                }
                .disabled(model.busy)
                if model.busy { ProgressView("Preparing") }
                if let error = model.playError { Text(error).foregroundStyle(.red) }
                HStack(spacing: 24) {
                    Button("Back") { model.back() }
                    Button("Results") { model.showResults() }
                }
            }
            .padding(60)
        }
        .onExitCommand { model.back() }
    }

    @ViewBuilder private var previewSection: some View {
        switch model.preview {
        case .idle, .loading:
            ProgressView("Probing")
        case .failed(let message):
            VStack(alignment: .leading, spacing: 16) {
                Text(message).foregroundStyle(.red)
                Button("Try Again") { model.refreshPreview() }
            }
        case .loaded(let preview):
            VStack(alignment: .leading, spacing: 10) {
                Text(preview.summary)
                Text("Engine \(preview.engine.rawValue)" + (preview.reasons.isEmpty ? "" : ": " + preview.reasons.map(\.rawValue).joined(separator: ", ")))
                    .foregroundStyle(Theme.accent)
                if let failure = preview.failure { Text(failure).foregroundStyle(.secondary) }
            }
        }
    }

    private func label(_ target: AudioTranscodeTarget) -> String {
        switch target {
        case .alac: "ALAC"
        case .flac: "FLAC"
        case .aac51: "AAC 5.1"
        }
    }
}

struct ChoiceRow<Option: Hashable>: View {
    let title: String
    let options: [Option]
    let label: (Option) -> String
    @Binding var selection: Option?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            HStack(spacing: 20) {
                ForEach(options, id: \.self) { option in
                    Button { selection = option } label: {
                        Text(label(option)).fontWeight(selection == option ? .bold : .regular)
                    }
                    .tint(selection == option ? Theme.accent : nil)
                }
            }
        }
    }
}

struct ObservationsView: View {
    @Bindable var model: HarnessModel

    private var observations: Binding<HarnessObservations> {
        Binding(get: { model.currentRun?.observations ?? HarnessObservations() },
                set: { model.currentRun?.observations = $0 })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                if let run = model.currentRun {
                    Text("What did you see?").font(.largeTitle.bold())
                    Text("\(run.fileName), engine \(run.enginePlayed?.rawValue ?? "none")").foregroundStyle(.secondary)
                    ChoiceRow(title: "Dolby Vision or HDR mode on the TV", options: YesNoNA.allCases, label: \.title,
                              selection: observations.dynamicRangeSwitch)
                    ChoiceRow(title: "Atmos on the receiver", options: YesNoNA.allCases, label: \.title, selection: observations.atmos)
                    ChoiceRow(title: "Subtitles render", options: SubtitleOutcome.allCases, label: \.title, selection: observations.subtitles)
                    if run.enginePlayed == .aRemux || run.enginePlayed == .aDirect {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Native features present").font(.headline)
                            HStack(spacing: 20) {
                                ForEach(NativeFeature.allCases, id: \.self) { feature in
                                    let on = observations.wrappedValue.nativeFeatures.contains(feature)
                                    Button { observations.wrappedValue.toggle(feature) } label: {
                                        Text((on ? "✓ " : "") + feature.title)
                                    }
                                    .tint(on ? Theme.accent : nil)
                                }
                            }
                        }
                    }
                    ChoiceRow(title: "A/V drift after 10 minutes", options: DriftOutcome.allCases, label: \.title, selection: observations.drift)
                    TextField("Notes (optional)", text: observations.notes)
                    Button("Save") { Task { await model.saveObservations() } }
                }
            }
            .padding(60)
        }
        .onExitCommand { model.back() }
    }
}

struct ResultsView: View {
    @Bindable var model: HarnessModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Results").font(.largeTitle.bold())
                if let url = model.lanURL {
                    Text("Fetch from your computer:").foregroundStyle(.secondary)
                    Text(url).font(.title3.monospaced()).foregroundStyle(Theme.accent)
                } else if let error = model.serverError {
                    Text(error).foregroundStyle(.red)
                } else {
                    Text("No network address found.").foregroundStyle(.secondary)
                }
                if model.runs.isEmpty {
                    Text("No runs yet.")
                }
                ForEach(model.runs) { run in
                    Button { model.editObservations(of: run) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(run.fileName)").lineLimit(1)
                            Text(summary(run)).font(.callout).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Button("Back") { model.back() }
            }
            .padding(60)
        }
        .onExitCommand { model.back() }
    }

    private func summary(_ run: HarnessRun) -> String {
        var parts = ["Engine " + (run.enginePlayed?.rawValue ?? "none")]
        if let ttff = run.ttffMillis { parts.append("TTFF \(ttff) ms") }
        if let median = run.seekMedianMillis, let p90 = run.seekP90Millis {
            parts.append("seek \(Int(median)) / \(Int(p90)) ms")
        }
        if let memory = run.peakMemoryMB { parts.append("\(Int(memory)) MB") }
        if run.failure != nil || run.enginePlayed == nil { parts.append("failed") }
        return parts.joined(separator: ", ")
    }
}

/// Hosts a session's view controller inside the full screen cover. Menu is left to the player so the
/// native info panel and transport bar behave as they would in a plain AVPlayerViewController.
struct PlayerHost: UIViewControllerRepresentable {
    let controller: UIViewController

    func makeUIViewController(context: Context) -> PlayerContainer { PlayerContainer() }

    func updateUIViewController(_ container: PlayerContainer, context: Context) { container.show(controller) }
}

final class PlayerContainer: UIViewController {
    private var child: UIViewController?

    func show(_ next: UIViewController) {
        guard next !== child else { return }
        if let child {
            child.willMove(toParent: nil)
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        addChild(next)
        next.view.frame = view.bounds
        next.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(next.view)
        next.didMove(toParent: self)
        child = next
    }

    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        child.map { [$0] } ?? []
    }
}
