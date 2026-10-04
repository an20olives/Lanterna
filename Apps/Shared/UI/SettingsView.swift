import CoreImage.CIFilterBuiltins
import LanternaKit
import SwiftUI

extension View {
    /// tvOS renders menu pickers as a cramped segmented bar; a row that opens a list reads better and never truncates.
    @ViewBuilder func settingsPicker() -> some View {
        #if os(tvOS)
        self.pickerStyle(.navigationLink)
        #else
        self.pickerStyle(.menu)
        #endif
    }
}

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        List {
            Section("Sources") {
                NavigationLink("Sources and keys") { SourcesSettingsView() }
                NavigationLink("Your Services") { YourServicesView() }
                NavigationLink("Pair \(env.deviceName == "iPhone" ? "Apple TV" : "iPhone")") { pairingDestination }
            }
            Section("Playback") {
                NavigationLink("Streams") { StreamsSettingsView() }
                NavigationLink("Video player") { PlayerSettingsView() }
            }
            Section("Account") {
                NavigationLink("Trakt") { TraktSettingsView() }
            }
            Section("Diagnostics") {
                NavigationLink("Engine and routing log") { DiagnosticsView() }
                if let lab = env.labView { NavigationLink("Player lab (P0)") { lab() } }
            }
        }
        .navigationTitle("Settings")
        .accessibilityIdentifier("settings.list")
    }

    @ViewBuilder private var pairingDestination: some View {
        #if os(tvOS)
        PairingReceiverView()
        #else
        PairingSenderView()
        #endif
    }
}

/// A secret field: shows whether one is saved, takes a pasted value, never shows the saved value.
struct SecretRow: View {
    @Environment(AppEnvironment.self) private var env
    let title: String
    let key: KeychainKey
    var help: String?
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if env.secret(key) != nil { Label("Saved", systemImage: "checkmark.circle").foregroundStyle(.green) }
            }
            if let help { Text(help).font(.caption).foregroundStyle(.secondary) }
            TextField("Paste here", text: $draft)
                .autocorrectionDisabled()
                #if !os(tvOS)
                .textInputAutocapitalization(.never)
                #endif
            HStack {
                Button("Save") {
                    let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else { return }
                    env.setSecret(value, for: key)
                    draft = ""
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                if env.secret(key) != nil { Button("Remove", role: .destructive) { env.setSecret(nil, for: key) } }
            }
        }
        .padding(.vertical, 4)
    }
}

struct SourcesSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var health: [String: String] = [:]

    var body: some View {
        List {
            Section {
                SecretRow(title: "AIOStreams manifest link", key: .aiostreamsManifestURL, help: "Streams for movies and shows. Your debrid key lives inside this config.")
                SecretRow(title: "TMDB read access token", key: .tmdbReadToken, help: "Titles, artwork and where-to-watch data.")
                SecretRow(title: "TorBox API key", key: .torboxAPIKey, help: "Optional. Shows your own TorBox downloads in Library.")
            }
            Section("Media servers") {
                ForEach(env.config.sources.filter { $0.kind == .jellyfin }) { source in
                    HStack {
                        VStack(alignment: .leading) { Text(source.name); Text(source.serverURL ?? "").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Remove", role: .destructive) { removeJellyfin(source) }
                    }
                }
                NavigationLink("Add Jellyfin server") { JellyfinAddView() }
            }
            Section("Health") {
                Button("Check sources") { Task { await checkHealth() } }
                ForEach(health.sorted { $0.key < $1.key }, id: \.key) { Text("\($0.key): \($0.value)") }
            }
        }
        .navigationTitle("Sources")
    }

    private func removeJellyfin(_ source: SourceConfig) {
        try? env.keychain.remove(account: "jellyfin.\(source.id.uuidString).token")
        env.updateConfig { $0.sources.removeAll { $0.id == source.id } }
        env.rebuild()
    }

    private func checkHealth() async {
        health = [:]
        for source in await env.registry.sources(with: [.streams]) + (await env.registry.sources(with: .library)) + (await env.registry.sources(with: .catalogs)) {
            let state = await source.health()
            health[source.displayName] = switch state {
            case .ok: "ready"
            case .needsCredentials: "needs a new login"
            case .unreachable(let reason): reason
            case .rateLimited: "resting"
            }
        }
    }
}

struct JellyfinAddView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var server = "https://"
    @State private var remote = ""
    @State private var name = "Home server"
    @State private var username = ""
    @State private var password = ""
    @State private var quickCode: String?
    @State private var status: String?
    @State private var busy = false

    var body: some View {
        Form {
            TextField("Server address (https)", text: $server).autocorrectionDisabled()
            TextField("Remote address (optional)", text: $remote).autocorrectionDisabled()
            TextField("Name", text: $name)
            Section("Sign in with Quick Connect") {
                Button("Start Quick Connect") { Task { await quickConnect() } }.disabled(busy)
                if let quickCode {
                    Text("Enter this code in Jellyfin on another device: \(quickCode)").font(.title3.bold())
                }
            }
            Section("Or sign in with a password") {
                TextField("Username", text: $username).autocorrectionDisabled()
                SecureField("Password", text: $password)
                Button("Sign in") { Task { await passwordSignIn() } }.disabled(busy || username.isEmpty)
            }
            if let status { Text(status).foregroundStyle(.secondary) }
        }
        .navigationTitle("Add Jellyfin")
    }

    private func client() -> JellyfinClient? {
        guard let url = URL(string: server), url.scheme == "https" || url.scheme == "http" else { status = "That is not a web address."; return nil }
        return JellyfinClient(baseURL: url, device: JellyfinDevice(deviceID: env.jellyfinDeviceID(), deviceName: env.deviceName, version: "0.1"), token: nil, userID: nil)
    }

    private func finish(_ auth: JellyfinAuth, info: JellyfinPublicInfo) {
        let id = UUID()
        try? env.keychain.set(auth.accessToken, account: "jellyfin.\(id.uuidString).token")
        env.updateConfig {
            $0.sources.append(SourceConfig(id: id, kind: .jellyfin, name: name.isEmpty ? info.serverName : name, order: $0.sources.count,
                                           serverURL: server, remoteURL: remote.isEmpty ? nil : remote, userID: auth.userID))
        }
        env.rebuild()
        dismiss()
    }

    private func passwordSignIn() async {
        guard let client = client() else { return }
        busy = true; defer { busy = false }
        do {
            let info = try await client.publicInfo()
            finish(try await client.authenticateByName(username: username, password: password), info: info)
        } catch { status = "Could not sign in. Check the address and login." }
    }

    private func quickConnect() async {
        guard let client = client() else { return }
        busy = true; defer { busy = false }
        do {
            let info = try await client.publicInfo()
            let session = try await client.quickConnectInitiate()
            quickCode = session.code
            for _ in 0..<60 {
                try await Task.sleep(for: .seconds(3))
                if try await client.quickConnectAuthenticated(secret: session.secret) {
                    finish(try await client.authenticateWithQuickConnect(secret: session.secret), info: info)
                    return
                }
            }
            status = "The code expired. Try again."
        } catch { status = "Quick Connect is not available on that server." }
    }
}

struct YourServicesView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var providers: [ProviderOffer] = []
    @State private var loading = true
    private let regions = ["US", "GB", "CA", "AU", "DE", "FR", "ES", "IT", "NL", "SE", "JP", "BR", "MX"]

    var body: some View {
        List {
            Section {
                Picker("Region", selection: Binding(get: { env.config.watchRegion }, set: { value in
                    env.updateConfig { $0.watchRegion = value }
                    env.rebuild()
                })) {
                    ForEach(regions, id: \.self) { Text(Locale.current.localizedString(forRegionCode: $0) ?? $0).tag($0) }
                }
                .settingsPicker()
            } footer: {
                Text("Pick the services you pay for. Lanterna marks titles that stream on them and opens the app. It cannot check your subscription.")
            }
            Section("Services") {
                if env.tmdb == nil { Text("Add a TMDB token to load the service list.").foregroundStyle(.secondary) }
                if loading && env.tmdb != nil { ProgressView() }
                ForEach(listed) { offer in
                    Toggle(offer.name, isOn: Binding(get: { selected(offer.providerID) }, set: { toggle(offer, $0) }))
                }
            }
            let others = env.config.subscribedServices.filter { saved in !providers.contains { $0.providerID == saved.providerID } }
            if !others.isEmpty {
                Section("Saved for other regions") { ForEach(others) { Text($0.name) } }
            }
        }
        .navigationTitle("Your Services")
        .task(id: env.config.watchRegion) { await load() }
    }

    /// Services with a known link strategy first, then the rest of TMDB's list for the region.
    private var listed: [ProviderOffer] {
        let known = Set(env.deepLinks.entries.map(\.providerID))
        return providers.filter { known.contains($0.providerID) } + providers.filter { !known.contains($0.providerID) }.prefix(25)
    }

    private func selected(_ id: Int) -> Bool { env.config.subscribedServices.contains { $0.providerID == id } }

    private func toggle(_ offer: ProviderOffer, _ on: Bool) {
        env.updateConfig {
            $0.subscribedServices.removeAll { $0.providerID == offer.providerID }
            if on { $0.subscribedServices.append(SubscribedService(providerID: offer.providerID, name: offer.name)) }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        guard let tmdb = env.tmdb else { return }
        providers = (try? await tmdb.providerCatalog(region: env.config.watchRegion)) ?? []
    }
}

struct StreamsSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var env = env
        List {
            Toggle("Auto-select a stream", isOn: Binding(get: { env.config.streamPrefs.autoSelect }, set: { v in env.updateConfig { $0.streamPrefs.autoSelect = v } }))
            Toggle("Prefer my library", isOn: Binding(get: { env.config.streamPrefs.preferLibrary }, set: { v in env.updateConfig { $0.streamPrefs.preferLibrary = v } }))
            Picker("Sort", selection: Binding(get: { env.config.streamPrefs.sort }, set: { v in env.updateConfig { $0.streamPrefs.sort = v } })) {
                Text("Quality").tag(StreamPrefs.Sort.quality)
                Text("Size").tag(StreamPrefs.Sort.size)
                Text("Ready first").tag(StreamPrefs.Sort.cachedFirst)
            }
            .settingsPicker()
            Picker("Minimum resolution", selection: Binding(get: { env.config.streamPrefs.minResolution }, set: { v in env.updateConfig { $0.streamPrefs.minResolution = v } })) {
                Text("Any").tag(Resolution?.none)
                ForEach(Resolution.allCases, id: \.self) { Text($0.label).tag(Resolution?.some($0)) }
            }
            .settingsPicker()
            Toggle("Require Dolby Vision", isOn: Binding(get: { env.config.streamPrefs.requireDolbyVision }, set: { v in env.updateConfig { $0.streamPrefs.requireDolbyVision = v } }))
            Toggle("Require Atmos", isOn: Binding(get: { env.config.streamPrefs.requireAtmos }, set: { v in env.updateConfig { $0.streamPrefs.requireAtmos = v } }))
            Section("Source order") {
                ForEach(env.config.streamPrefs.sourceOrder, id: \.self) { kind in
                    HStack {
                        Text(StreamPickerView.name(kind))
                        Spacer()
                        Button { move(kind, by: -1) } label: { Image(systemName: "arrow.up") }
                        Button { move(kind, by: 1) } label: { Image(systemName: "arrow.down") }
                    }
                }
            }
        }
        .navigationTitle("Streams")
    }

    private func move(_ kind: SourceKind, by offset: Int) {
        env.updateConfig {
            var order = $0.streamPrefs.sourceOrder
            guard let index = order.firstIndex(of: kind), order.indices.contains(index + offset) else { return }
            order.swapAt(index, index + offset)
            $0.streamPrefs.sourceOrder = order
        }
    }
}

struct PlayerSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        List {
            Picker("Audio for DTS and TrueHD", selection: Binding(get: { env.config.playerPrefs.audioTranscode }, set: { v in env.updateConfig { $0.playerPrefs.audioTranscode = v } })) {
                Text("ALAC (lossless)").tag("alac")
                Text("FLAC (lossless)").tag("flac")
                Text("AAC 5.1").tag("aac51")
            }
            .settingsPicker()
            Toggle("Subtitles on by default", isOn: Binding(get: { env.config.playerPrefs.subtitlesEnabled }, set: { v in env.updateConfig { $0.playerPrefs.subtitlesEnabled = v } }))
            Toggle("Show forced subtitles", isOn: Binding(get: { env.config.playerPrefs.showForcedSubtitles }, set: { v in env.updateConfig { $0.playerPrefs.showForcedSubtitles = v } }))
            Picker("Next episode card", selection: Binding(get: { env.config.playerPrefs.nextEpisodeLeadSeconds }, set: { v in env.updateConfig { $0.playerPrefs.nextEpisodeLeadSeconds = v } })) {
                ForEach([15, 30, 45, 60, 90], id: \.self) { Text("\($0) seconds before the end").tag($0) }
            }
            .settingsPicker()
            Picker("Skip intro", selection: Binding(get: { env.config.playerPrefs.skipIntro }, set: { v in env.updateConfig { $0.playerPrefs.skipIntro = v } })) {
                Text("Off").tag(PlayerPrefs.SkipIntro.off)
                Text("Show button").tag(PlayerPrefs.SkipIntro.button)
                Text("Skip automatically").tag(PlayerPrefs.SkipIntro.auto)
            }
            .settingsPicker()
        }
        .navigationTitle("Video player")
    }
}

struct DiagnosticsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var entries: [CacheStore.ProbeLogEntry] = []

    var body: some View {
        List {
            if entries.isEmpty { Text("Nothing played yet.").foregroundStyle(.secondary) }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text("Engine \(entry.engine)  ·  \(entry.outcome)").font(.headline)
                    if !entry.reasons.isEmpty { Text(entry.reasons.joined(separator: ", ")).font(.caption) }
                    if let key = entry.titleKey { Text(key).font(.caption2).foregroundStyle(.secondary) }
                    if let failure = entry.failure { Text(failure).font(.caption2).foregroundStyle(.red) }
                    Text(entry.probedAt.formatted(date: .abbreviated, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Routing log")
        .task { entries = await env.cache.recentProbes() }
    }
}
