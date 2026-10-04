import Foundation
import LanternaKit
import PlayerCore

/// Keeps every run, writes them to Caches (may be purged), and builds the JSON the LAN endpoint serves.
actor RunStore {
    private(set) var runs: [HarnessRun] = []
    private let fileURL: URL

    init(fileURL: URL = RunStore.defaultURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL), let export = try? HarnessExport.decode(data) {
            runs = export.runs
        }
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "p0-runs.json")
    }

    func upsert(_ run: HarnessRun) {
        if let index = runs.firstIndex(where: { $0.id == run.id }) {
            runs[index] = run
        } else {
            runs.append(run)
        }
        try? exportJSON().write(to: fileURL, options: .atomic)
    }

    /// Free text is redacted again here, with the TorBox key as a known secret.
    func exportJSON() -> Data {
        let key = (try? KeychainStore().string(for: .torboxAPIKey)) ?? nil
        return HarnessExport.json(runs: runs, scrub: { Redactor.text($0, secrets: key.map { [$0] } ?? []) })
    }
}
