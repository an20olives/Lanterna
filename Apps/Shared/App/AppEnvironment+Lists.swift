import Foundation
import LanternaKit

/// Custom lists and public lists from outside TMDB (MDBList, Letterboxd).
extension AppEnvironment {
    /// Makes a list and puts it on Home as a shelf (when there is room).
    @discardableResult
    func createCustomList(named name: String) -> CustomList {
        let list = CustomList(name: name)
        var shelves = effectiveShelves
        let showOnHome = shelves.count < DeviceConfig.maxShelves
        if showOnHome { shelves.append(ShelfConfig(title: name, query: .customList(list.id))) }
        updateConfig {
            $0.customLists.append(list)
            if showOnHome { $0.shelves = shelves }
        }
        return list
    }

    func deleteCustomList(_ id: UUID) {
        updateConfig {
            $0.customLists.removeAll { $0.id == id }
            $0.shelves.removeAll { if case .customList(id) = $0.query { true } else { false } }
        }
    }

    func isInCustomList(_ id: UUID, key: String) -> Bool {
        config.customLists.first { $0.id == id }?.titleKeys.contains(key) ?? false
    }

    func toggleInCustomList(_ id: UUID, key: String) {
        updateConfig { config in
            guard let index = config.customLists.firstIndex(where: { $0.id == id }) else { return }
            if let at = config.customLists[index].titleKeys.firstIndex(of: key) { config.customLists[index].titleKeys.remove(at: at) }
            else { config.customLists[index].titleKeys.append(key) }
        }
    }

    func customListItems(_ id: UUID) async -> [TitleSummary] {
        guard let list = config.customLists.first(where: { $0.id == id }) else { return [] }
        var items: [TitleSummary] = []
        for key in list.titleKeys.prefix(40) { if let summary = await self.summary(forKey: key) { items.append(summary) } }
        return items
    }

    /// Resolves list entries to TMDB titles: by ID when the list carries one, else by title and year.
    func resolve(_ entries: [ExternalListClient.Entry]) async -> [TitleSummary] {
        var items: [TitleSummary] = []
        for entry in entries.prefix(24) {
            if let id = entry.tmdbID {
                if let summary = await self.summary(forKey: "\(entry.kind == .show ? "show" : "movie"):\(id)") { items.append(summary) }
            } else if let tmdb, let results = try? await tmdb.search(entry.title) {
                let candidates = results.titles.filter { $0.ref.kind == .movie }
                let match = candidates.first { $0.title.caseInsensitiveCompare(entry.title) == .orderedSame && (entry.year == nil || $0.year == entry.year) }
                    ?? candidates.first { entry.year != nil && $0.year == entry.year }
                if let match { items.append(match) }
            }
        }
        return items
    }

    func externalList(_ query: ShelfQuery) async -> [TitleSummary] {
        let client = ExternalListClient()
        switch query {
        case .mdblist(let path): return await resolve((try? await client.mdblist(path: path)) ?? [])
        case .letterboxd(let path): return await resolve((try? await client.letterboxd(path: path)) ?? [])
        default: return []
        }
    }
}
