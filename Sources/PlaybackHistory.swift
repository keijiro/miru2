import Darwin
import Foundation

struct PlaybackState: Codable, Equatable {
    var position: Double
    var loopStart: Double
    var loopEnd: Double?
}

final class PlaybackHistory {
    private let url: URL
    private let storage = DispatchQueue(label: "miru.playback-history", qos: .utility)
    private var entries: [String: PlaybackState] = [:]
    // Only accessed on the storage queue. Keep failed writes available for retry.
    private var pending: [String: PlaybackState] = [:]

    init(url: URL) {
        self.url = url
        do { entries = try read() }
        catch { print("Could not load playback history: \(error.localizedDescription)") }
    }

    func state(for path: String) -> PlaybackState? { entries[path] }

    func record(_ changes: [String: PlaybackState]) {
        guard !changes.isEmpty else { return }
        entries.merge(changes) { _, latest in latest }
        storage.async {
            self.pending.merge(changes) { _, latest in latest }
            self.writePending()
        }
    }

    func finish() {
        storage.sync { writePending() }
    }

    private func read() throws -> [String: PlaybackState] {
        do { return try JSONDecoder().decode([String: PlaybackState].self, from: Data(contentsOf: url)) }
        catch CocoaError.fileReadNoSuchFile { return [:] }
    }

    private func writePending() {
        guard !pending.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Lock a separate file so atomic replacement of the JSON leaves the lock in place.
            let lockURL = url.appendingPathExtension("lock")
            let descriptor = lockURL.path.withCString { open($0, O_CREAT | O_RDWR, 0o600) }
            guard descriptor >= 0 else { throw posixError() }
            defer { close(descriptor) }
            while flock(descriptor, LOCK_EX) != 0 {
                if errno != EINTR { throw posixError() }
            }

            var saved: [String: PlaybackState]
            do { saved = try read() }
            catch is DecodingError { saved = [:] }
            saved.merge(pending) { _, latest in latest }
            try JSONEncoder().encode(saved).write(to: url, options: .atomic)
            pending.removeAll()
        } catch {
            print("Could not save playback history: \(error.localizedDescription)")
        }
    }

    private func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
