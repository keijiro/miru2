import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

actor ThumbnailCache {
    private let directory: URL
    private let byteLimit: Int
    private var bytesBeforePrune = 0

    init(directory: URL, byteLimit: Int = 256 * 1024 * 1024) {
        self.directory = directory
        self.byteLimit = byteLimit
    }

    func image(for entry: MediaEntry) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let destination = cacheURL(for: entry)
        if let destination,
           let data = try? Data(contentsOf: destination),
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
            // Use the cache file's modification date as its last-use time.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
            pruneIfNeeded()
            return image
        }

        guard let image = await loadThumbnail(entry), !Task.isCancelled else { return nil }
        if let destination, destination == cacheURL(for: entry) {
            store(image, at: destination)
        }
        return image
    }

    private func cacheURL(for entry: MediaEntry) -> URL? {
        let path = entry.url.standardizedFileURL.resolvingSymlinksInPath().path
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let date = values.contentModificationDate, let size = values.fileSize else { return nil }
        let key = "\(entry.kind.rawValue)\u{0}\(date.timeIntervalSinceReferenceDate.bitPattern)\u{0}\(size)\u{0}\(path)"
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name)
    }

    private func store(_ image: CGImage, at url: URL) {
        let hasAlpha = [.first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly].contains(image.alphaInfo)
        let format = hasAlpha ? UTType.png : UTType.jpeg
        let data = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(data, format.identifier as CFString, 1, nil) else { return }
        let options = hasAlpha ? nil : [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
        CGImageDestinationAddImage(encoder, image, options)
        guard CGImageDestinationFinalize(encoder) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try (data as Data).write(to: url, options: .atomic)
            pruneIfNeeded(adding: data.length)
        } catch {
            // A generated thumbnail can still be displayed when the cache is unavailable.
        }
    }

    private func pruneIfNeeded(adding bytes: Int = 0) {
        bytesBeforePrune -= bytes
        guard bytesBeforePrune <= 0 else { return }
        let files = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys),
                                                        options: .skipsHiddenFiles) else { return }
        let entries = urls.compactMap { url -> (url: URL, size: Int, used: Date)? in
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let size = values.fileSize, let date = values.contentModificationDate else { return nil }
            return (url, size, date)
        }
        var size = entries.reduce(0) { $0 + $1.size }
        if size > byteLimit {
            let target = byteLimit - byteLimit / 10
            for entry in entries.sorted(by: { $0.used < $1.used }) where size > target {
                do {
                    try files.removeItem(at: entry.url)
                    size -= entry.size
                } catch { continue }
            }
        }
        bytesBeforePrune = max(1, byteLimit - size + 1)
    }
}
