import LanternaKit
import SwiftUI
import UIKit

extension AppEnvironment {
    var deepLinks: DeepLinkArchive {
        guard let url = Bundle.main.url(forResource: "DeepLinkArchive", withExtension: "json"),
              let data = try? Data(contentsOf: url), let archive = try? DeepLinkArchive.decode(data) else { return DeepLinkArchive(entries: []) }
        return archive
    }

    /// Where a title streams in the watch region. Cached for 7 days.
    func availability(for ref: TitleRef) async -> [ProviderOffer] {
        let show = ref.showRef
        if let cached = await cache.availability(titleKey: show.key, region: config.watchRegion) { return cached }
        guard let tmdb, show.tmdbID > 0 else { return [] }
        guard let offers = try? await tmdb.watchProviders(for: show, region: config.watchRegion) else { return [] }
        await cache.saveAvailability(titleKey: show.key, region: config.watchRegion, offers: offers)
        return offers
    }

    func enqueueListOp(_ op: String, ref: TitleRef) async {
        let payload = ListOpPayload(titleKey: ref.key, imdbID: ref.imdbID, watchedAt: op.hasPrefix("history") ? Date() : nil)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        await outbox.enqueue(idempotencyKey: "\(op):\(ref.key):\(Int(Date().timeIntervalSince1970))", target: .trakt, op: op, payload: data)
        syncKick?()
    }
}

/// "Open in <service>" cards for services the owner declared. There is no subscription API: this only reads TMDB
/// watch-provider data and the owner's own list.
struct ServiceCards: View {
    @Environment(AppEnvironment.self) private var env
    let ref: TitleRef
    @State private var offers: [ProviderOffer] = []
    @State private var message: String?

    private var subscribedIDs: Set<Int> { Set(env.config.subscribedServices.map(\.providerID)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let streaming = offers.filter { [.flatrate, .free, .ads].contains($0.type) }
            let mine = streaming.filter { subscribedIDs.contains($0.providerID) }
            if !mine.isEmpty {
                HRow {
                    HStack(spacing: Metrics.rowSpacing) {
                        ForEach(mine) { offer in
                            Button { open(offer) } label: {
                                HStack(spacing: 16) {
                                    RemoteImage(url: TMDBImage.url(offer.logoPath, .providerLogo), placeholder: "")
                                        .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 10))
                                    Text("Open in \(offer.name)").lineLimit(1)
                                }
                                .padding(.horizontal, 20).padding(.vertical, 12)
                            }
                            .cardButtonStyle()
                        }
                    }
                    .padding(.vertical, Metrics.rowPadding)
                }
            }
            let others = streaming.filter { !subscribedIDs.contains($0.providerID) }
            if !others.isEmpty {
                Text("Also on \(others.map(\.name).joined(separator: ", "))").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if streaming.isEmpty && !offers.isEmpty {
                Text("Rent or buy: \(offers.map(\.name).joined(separator: ", "))").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let message { Text(message).font(.callout).foregroundStyle(.orange) }
            if !offers.isEmpty { Text("Availability data from JustWatch via TMDB.").font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: ref.key) { offers = await env.availability(for: ref) }
    }

    private func open(_ offer: ProviderOffer) {
        let title = ref.showRef.key
        guard let link = env.deepLinks.link(providerID: offer.providerID, title: title, ref: ref) else {
            message = "Lanterna has no link for \(offer.name) yet. Open the app yourself."
            return
        }
        Task {
            if await UIApplication.shared.open(link.url) { message = nil } else { message = "\(offer.name) does not seem to be installed." }
        }
    }
}
