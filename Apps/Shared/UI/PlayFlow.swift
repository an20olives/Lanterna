import LanternaKit
import Observation
import SwiftUI

/// Search streams, auto-select or show the picker, then hand off to the player.
@MainActor
@Observable
final class PlayFlow {
    enum Phase: Equatable {
        case idle
        case searching(checked: Int, total: Int)
        case picking
        case empty(String)
    }

    struct Pending {
        var ref: TitleRef
        var displayTitle: String
        var startAt: Double
        var next: NextEpisode?
    }

    var phase: Phase = .idle
    var groups: [(kind: SourceKind, items: [StreamCandidate])] = []
    var failures: [String] = []
    var heading = ""
    /// When true the next chosen stream is downloaded instead of played.
    var downloadOnly = false
    @ObservationIgnored var posterPath: String?
    @ObservationIgnored var pending: Pending?
    @ObservationIgnored weak var playback: PlaybackController?
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    var isPresented: Bool { phase != .idle }

    func start(ref: TitleRef, displayTitle: String, forcePicker: Bool, download: Bool = false, posterPath: String? = nil, env: AppEnvironment) async {
        guard let playback else { return }
        downloadOnly = download
        self.posterPath = posterPath
        #if !os(tvOS)
        // A finished download plays without a stream search.
        if !download, !forcePicker, let file = env.downloads.fileURL(for: ref.key) {
            let candidate = StreamCandidate(id: "download:\(ref.key)", sourceID: AppEnvironment.sourceID(.tmdb), sourceKind: .tmdb, title: ref,
                                            displayName: "Downloaded", locatorHint: .url(file))
            let progress = await env.progress.progress(for: ref.key)
            let resume = (progress.map { !$0.isCompleted && $0.fraction < 0.95 && $0.positionSeconds > 5 } ?? false) ? (progress?.positionSeconds ?? 0) : 0
            await playback.play(.init(candidate: candidate, ref: ref, displayTitle: displayTitle, startAt: resume, next: nil, directURL: file), env: env)
            return
        }
        #endif
        searchTask?.cancel()
        heading = displayTitle
        failures = []
        phase = .searching(checked: 0, total: 1)
        let resolved = await env.withIMDb(ref)
        let progress = await env.progress.progress(for: ref.key)
        let resume = (progress.map { !$0.isCompleted && $0.fraction < 0.95 && $0.positionSeconds > 5 } ?? false) ? (progress?.positionSeconds ?? 0) : 0
        let next = await env.nextEpisode(after: resolved)
        pending = Pending(ref: resolved, displayTitle: displayTitle, startAt: resume, next: next)

        let request = StreamRequest(title: resolved, preferredLanguages: env.config.playerPrefs.audioLanguages, region: env.config.watchRegion)
        let flow = self
        let outcome = await env.registry.streams(for: request) { checked, total in
            Task { @MainActor in
                if case .searching = flow.phase { flow.phase = .searching(checked: checked, total: total) }
            }
        }
        guard phase != .idle else { return }   // cancelled while searching
        let prefs = env.config.streamPrefs
        let usable = outcome.candidates
        failures = outcome.failures.values.map(Self.describe)

        if prefs.autoSelect, !forcePicker, !download, let pick = StreamSelector.autoSelect(usable, prefs: prefs, remembered: progress?.lastStreamID) {
            phase = .idle
            await playback.play(.init(candidate: pick, ref: resolved, displayTitle: displayTitle, startAt: resume, next: next), env: env)
            return
        }
        if usable.isEmpty {
            phase = .empty(failures.first ?? "No streams found for this title.")
        } else {
            groups = StreamSelector.grouped(usable, prefs: prefs)
            phase = .picking
        }
    }

    func choose(_ candidate: StreamCandidate, env: AppEnvironment) async {
        guard let playback, let pending else { return }
        phase = .idle
        #if !os(tvOS)
        if downloadOnly {
            downloadOnly = false
            await env.downloads.start(ref: pending.ref, title: pending.displayTitle, posterPath: posterPath, candidate: candidate, env: env)
            return
        }
        #endif
        await playback.play(.init(candidate: candidate, ref: pending.ref, displayTitle: pending.displayTitle, startAt: pending.startAt, next: pending.next), env: env)
    }

    /// Plays a file from the user's own library (TorBox or Jellyfin) without a stream search.
    func playLibraryFile(_ hint: LocatorHint, sourceID: SourceID, kind: SourceKind, name: String, ref: TitleRef, env: AppEnvironment) async {
        guard let playback else { return }
        let candidate = StreamCandidate(id: "lib:\(sourceID.rawValue.uuidString):\(name)", sourceID: sourceID, sourceKind: kind, title: ref,
                                        displayName: name, locatorHint: hint)
        let progress = await env.progress.progress(for: ref.key)
        let resume = (progress.map { !$0.isCompleted && $0.positionSeconds > 5 } ?? false) ? (progress?.positionSeconds ?? 0) : 0
        await playback.play(.init(candidate: candidate, ref: ref, displayTitle: name, startAt: resume, next: nil), env: env)
    }

    func cancel() {
        searchTask?.cancel()
        phase = .idle
    }

    static func describe(_ error: SourceError) -> String {
        switch error {
        case .needsCredentials: "A source rejected its login."
        case .unreachable: "A source did not answer."
        case .rateLimited: "A source is resting after errors."
        default: "A source failed."
        }
    }
}

struct StreamPickerView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlayFlow.self) private var flow

    var body: some View {
        NavigationStack {
            Group {
                switch flow.phase {
                case .idle:
                    EmptyView()
                case .searching(let checked, let total):
                    VStack(spacing: 20) {
                        ProgressView()
                        Text("Checking \(min(checked + 1, total)) of \(total) sources").font(.headline)
                        Text(flow.heading).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("picker.searching")
                case .empty(let message):
                    NoStreamsView(message: message, heading: flow.heading, ref: flow.pending?.ref)
                case .picking:
                    list
                }
            }
            .navigationTitle(flow.heading)
        }
        // A cover is see-through by default, which let Home bleed behind the picker.
        .background(Color.black.ignoresSafeArea())
        .presentationBackground(.black)
        #if os(tvOS)
        .onExitCommand { flow.cancel() }
        #endif
    }

    private var list: some View {
        List {
            ForEach(flow.groups, id: \.kind) { group in
                Section(Self.name(group.kind)) {
                    ForEach(group.items) { candidate in
                        Button { Task { await flow.choose(candidate, env: env) } } label: { StreamCard(candidate: candidate) }
                            .disabled(candidate.availability != .playable)
                    }
                }
            }
        }
        .accessibilityIdentifier("picker.list")
    }

    static func name(_ kind: SourceKind) -> String {
        switch kind {
        case .jellyfin: "Media Server"
        case .torbox: "TorBox"
        case .aiostreams: "Streams"
        case .tmdb: "TMDB"
        case .trakt: "Trakt"
        }
    }
}

struct StreamCard: View {
    let candidate: StreamCandidate

    /// "4K · REMUX · HEVC · DV · HDR10 · Atmos": what the stream is, before its file name.
    private var summary: String {
        var parts: [String] = []
        if let resolution = candidate.claimed.resolution { parts.append(resolution.label) }
        if let source = candidate.claimed.source { parts.append(source) }
        if let codec = candidate.claimed.videoCodec { parts.append(codec) }
        parts += candidate.claimed.hdr.sorted { $0.rawValue < $1.rawValue }.map(\.label)
        if candidate.claimed.hasAtmos { parts.append("Atmos") }
        else if let audio = candidate.claimed.audioCodecs.sorted().first { parts.append(audio) }
        return parts.isEmpty ? "Unknown format" : parts.joined(separator: "  ·  ")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(summary).font(.headline).lineLimit(1)
                MarqueeText(text: candidate.displayName, color: .secondary)
                if case .unavailable(let reason) = candidate.availability { Text(reason).font(.caption).foregroundStyle(.red) }
            }
            Spacer(minLength: 12)
            if candidate.isCached == true {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Ready")
            }
            if let size = formatSize(candidate.sizeBytes) {
                Text(size).foregroundStyle(.secondary).frame(minWidth: 110, alignment: .trailing)
            }
        }
        .padding(.vertical, 6)
    }
}

struct NoStreamsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlayFlow.self) private var flow
    let message: String
    let heading: String
    let ref: TitleRef?

    var body: some View {
        VStack(spacing: 24) {
            Text("No streams found").font(.title2.bold()).accessibilityIdentifier("nostreams.title")
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let ref { ServiceCards(ref: ref) }
            Button("Close") { flow.cancel() }
        }
        .padding(Metrics.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
