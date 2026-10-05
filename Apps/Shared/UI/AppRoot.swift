import AVFoundation
import LanternaKit
import SwiftUI

struct AppRoot: View {
    let env: AppEnvironment
    @State private var playback = PlaybackController()
    @State private var flow = PlayFlow()
    @State private var sync: SyncEngine
    @State private var tab: AppTab = DebugRoute.current.map { DebugRoute.tab($0) ?? .debug } ?? .home
    @Environment(\.scenePhase) private var scenePhase

    /// The environment is created once by the App and passed in, so a re-evaluated root never builds a second one.
    init(env: AppEnvironment) {
        self.env = env
        #if !os(macOS)
        // Playback category so audio continues with the screen locked and PiP works on iPhone.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        #endif
        _sync = State(initialValue: SyncEngine(env: env))
    }

    var body: some View {
        TabView(selection: $tab) {
            if let route = DebugRoute.current, DebugRoute.tab(route) == nil {
                Tab("Debug", systemImage: "ladybug", value: AppTab.debug) { NavigationStack { DebugRouteView(route: route) } }
            } else {
                Tab("Home", systemImage: "house", value: AppTab.home) { HomeView() }
                Tab("Library", systemImage: "books.vertical", value: AppTab.library) { LibraryView() }
                Tab("Settings", systemImage: "gearshape", value: AppTab.settings) { NavigationStack { SettingsView() } }
                Tab("Search", systemImage: "magnifyingglass", value: AppTab.search, role: .search) { SearchView() }
            }
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .environment(env)
        .environment(flow)
        .environment(playback)
        .overlay {
            if playback.isBusy && playback.presented == nil {
                ZStack { Color.black.opacity(0.6); ProgressView("Opening") }.ignoresSafeArea()
            }
        }
        .lanternaCover(isPresented: Binding(get: { flow.isPresented }, set: { if !$0 { flow.cancel() } })) {
            StreamPickerView().environment(env).environment(flow)
        }
        .lanternaCover(isPresented: Binding(get: { playback.presented != nil }, set: { if !$0 { playback.dismissed() } })) {
            if let controller = playback.presented {
                ZStack(alignment: .bottomTrailing) {
                    Color.black.ignoresSafeArea()
                    PlayerHost(controller: controller).ignoresSafeArea().accessibilityIdentifier("player.host")
                    if let next = playback.upNext {
                        UpNextCard(upNext: next).padding(60)
                    }
                    #if os(macOS)
                    Button { playback.dismissed() } label: { Image(systemName: "xmark").padding(10) }
                        .buttonStyle(.plain)
                        .background(.black.opacity(0.55), in: Circle())
                        .foregroundStyle(.white)
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .accessibilityLabel("Close player")
                    #endif
                }
                #if !os(macOS)
                .presentationBackground(.black)
                #else
                .onExitCommand { playback.dismissed() }
                #endif
                .onDisappear { playback.dismissed() }
            }
        }
        .alert("Playback", isPresented: Binding(get: { playback.errorMessage != nil }, set: { if !$0 { playback.errorMessage = nil } })) {
            Button("OK") { playback.errorMessage = nil }
        } message: { Text(playback.errorMessage ?? "") }
        .task {
            flow.playback = playback
            playback.onAdvance = { next in
                Task { await flow.start(ref: next.ref, displayTitle: next.title, forcePicker: false, env: env) }
            }
            await sync.syncNow()
            sync.startTimer()
            if let route = DebugRoute.current, route.hasPrefix("picker/"), let id = Int(route.dropFirst(7)) {
                await flow.start(ref: .movie(tmdbID: id, imdbID: nil), displayTitle: "Debug", forcePicker: true, env: env)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                sync.kick()
                #if !os(tvOS)
                Task { await ReleaseNotifier.refresh(env: env) }
                #endif
            }
        }
    }
}

struct UpNextCard: View {
    let upNext: PlaybackController.UpNext

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Up Next in \(upNext.secondsLeft)s").font(.headline)
            Text(upNext.title).font(.subheadline).foregroundStyle(.secondary)
            Text("Press Menu to stay here").font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .allowsHitTesting(false)
    }
}

extension View {
    /// A cover over the whole window: a full-screen cover on iPhone and Apple TV, an overlay on the Mac.
    @ViewBuilder
    func lanternaCover<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(macOS)
        overlay {
            if isPresented.wrappedValue {
                content().background(Color.black).transition(.opacity)
            }
        }
        #else
        fullScreenCover(isPresented: isPresented, content: content)
        #endif
    }
}
