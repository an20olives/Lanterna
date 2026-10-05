#if !os(tvOS)
import Foundation
import LanternaKit
import Observation

struct DownloadRecord: Codable, Identifiable, Hashable {
    enum State: String, Codable { case downloading, done, failed }
    /// The title key, e.g. `movie:603` or `episode:1396:1:1`.
    var id: String
    var title: String
    var posterPath: String?
    var fileName: String
    var sourceName: String
    var state: State
    var receivedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var createdAt = Date()
    var errorText: String?

    var fraction: Double { totalBytes > 0 ? min(Double(receivedBytes) / Double(totalBytes), 1) : 0 }
}

/// Offline copies of streams, for iPhone and Mac. A background URLSession keeps downloads going when the app is not in front.
/// Files live in Application Support (not backed up). The list is a small JSON file next to them.
@MainActor
@Observable
final class DownloadManager: NSObject {
    private(set) var records: [DownloadRecord] = []
    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private let directory: URL

    override init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        directory = base.appending(path: "Downloads", directoryHint: .isDirectory)
        super.init()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = directory
        try? dir.setResourceValues(values)
        records = Self.load(from: recordsURL)
        let configuration = URLSessionConfiguration.background(withIdentifier: "lanterna.downloads")
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        // A download that was running when the app was killed either finished (the delegate marks it) or is gone.
        Task { await reconcile() }
    }

    private var recordsURL: URL { directory.appending(path: "records.json") }

    private static func load(from url: URL) -> [DownloadRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([DownloadRecord].self, from: data)) ?? []
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: recordsURL, options: .atomic) }
    }

    func record(for key: String) -> DownloadRecord? { records.first { $0.id == key } }

    /// The finished file for a title, if there is one.
    func fileURL(for key: String) -> URL? {
        guard let record = record(for: key), record.state == .done else { return nil }
        let url = directory.appending(path: record.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func start(ref: TitleRef, title: String, posterPath: String?, candidate: StreamCandidate, env: AppEnvironment) async {
        guard record(for: ref.key)?.state != .downloading, let source = await env.registry.source(for: candidate.sourceID) else { return }
        do {
            let locator = try await source.resolve(candidate.locatorHint)
            let ext = locator.url.pathExtension.lowercased()
            let fileName = Self.safeName(ref.key) + "." + (["mkv", "mp4", "m4v", "mov", "avi", "ts"].contains(ext) ? ext : "mkv")
            var request = URLRequest(url: locator.url)
            for (name, value) in locator.headers { request.setValue(value, forHTTPHeaderField: name) }
            let task = session.downloadTask(with: request)
            task.taskDescription = ref.key + "\n" + fileName
            records.removeAll { $0.id == ref.key }
            records.insert(DownloadRecord(id: ref.key, title: title, posterPath: posterPath, fileName: fileName, sourceName: candidate.displayName,
                                          state: .downloading), at: 0)
            save()
            task.resume()
        } catch {
            records.removeAll { $0.id == ref.key }
            records.insert(DownloadRecord(id: ref.key, title: title, posterPath: posterPath, fileName: "", sourceName: candidate.displayName,
                                          state: .failed, errorText: "Could not get a download link."), at: 0)
            save()
        }
    }

    func cancel(_ key: String) {
        session.getAllTasks { tasks in
            tasks.filter { $0.taskDescription?.hasPrefix(key + "\n") == true }.forEach { $0.cancel() }
        }
        records.removeAll { $0.id == key && $0.state == .downloading }
        save()
    }

    func delete(_ key: String) {
        if let record = record(for: key), !record.fileName.isEmpty { try? FileManager.default.removeItem(at: directory.appending(path: record.fileName)) }
        cancel(key)
        records.removeAll { $0.id == key }
        save()
    }

    private func reconcile() async {
        let tasks = await session.allTasks
        let live = Set(tasks.compactMap { $0.taskDescription?.components(separatedBy: "\n").first })
        var changed = false
        for index in records.indices where records[index].state == .downloading && !live.contains(records[index].id) {
            records[index].state = .failed
            records[index].errorText = "The download was interrupted."
            changed = true
        }
        if changed { save() }
    }

    nonisolated static func safeName(_ key: String) -> String {
        String(key.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
    }

    fileprivate func update(_ key: String, _ change: (inout DownloadRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == key }) else { return }
        change(&records[index])
        save()
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let key = downloadTask.taskDescription?.components(separatedBy: "\n").first else { return }
        Task { @MainActor in
            // Saving the list on every tick is wasteful; the in-memory value drives the progress bar.
            guard let index = self.records.firstIndex(where: { $0.id == key }) else { return }
            self.records[index].receivedBytes = totalBytesWritten
            self.records[index].totalBytes = max(totalBytesExpectedToWrite, 0)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let parts = downloadTask.taskDescription?.components(separatedBy: "\n") ?? []
        guard parts.count == 2 else { return }
        let key = parts[0], fileName = parts[1]
        // The temporary file disappears when this returns, so the move happens here.
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
        let destination = base?.appending(path: "Downloads").appending(path: fileName)
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        var failure: String?
        if !(200..<300).contains(status) {
            failure = "The server answered \(status)."
        } else if let destination {
            try? FileManager.default.removeItem(at: destination)
            do { try FileManager.default.moveItem(at: location, to: destination) } catch { failure = "Could not save the file." }
        }
        let size = destination.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int64 } ?? 0
        Task { @MainActor in
            self.update(key) {
                $0.state = failure == nil ? .done : .failed
                $0.errorText = failure
                if failure == nil { $0.receivedBytes = size; $0.totalBytes = size }
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as? URLError)?.code != .cancelled, let key = task.taskDescription?.components(separatedBy: "\n").first else { return }
        Task { @MainActor in
            self.update(key) {
                $0.state = .failed
                $0.errorText = (error as? URLError)?.code == .notConnectedToInternet ? "No internet connection." : "The download failed."
            }
        }
    }
}
#endif
