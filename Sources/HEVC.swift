import AVFoundation
import Foundation
import UniformTypeIdentifiers

// Give AVFoundation an hvc1 view of an MP4 whose hev1 description already
// contains decoder parameter sets. Byte offsets and media samples stay intact.
final class HEVCResource: NSObject, AVAssetResourceLoaderDelegate {
    private let file: FileHandle
    private let length: Int64
    private let assetURL: URL
    private let tagOffsets: [Int64]
    private let queue = DispatchQueue(label: "miru.hevc", qos: .userInitiated)
    private static let hvc1 = Data("hvc1".utf8)

    init?(url: URL) throws {
        guard ["mp4", "m4v"].contains(url.pathExtension.lowercased()),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "miru-hevc"
        guard let assetURL = components.url else { return nil }
        let file = try FileHandle(forReadingFrom: url)
        guard let length = Int64(exactly: try file.seekToEnd()) else { return nil }
        let offsets = try MP4Boxes(file: file).hevcTagOffsets(length: length)
        guard !offsets.isEmpty else { return nil }
        self.file = file
        self.length = length
        self.assetURL = assetURL
        self.tagOffsets = offsets
    }

    func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: assetURL)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func resourceLoader(
        _ loader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard request.request.url == assetURL else { return false }
        if let info = request.contentInformationRequest {
            let type = UTType.mpeg4Movie.identifier
            guard info.allowedContentTypes?.contains(type) != false else { return false }
            info.contentType = type
            info.contentLength = length
            info.isByteRangeAccessSupported = true
            info.isEntireLengthAvailableOnDemand = true
        }
        if let data = request.dataRequest {
            let offset = data.requestedOffset
            guard offset >= 0, data.requestedLength >= 0 else { return false }
            let remaining = max(0, length - offset)
            let end = data.requestsAllDataToEndOfResource ? length : offset + min(remaining, Int64(data.requestedLength))
            respond(to: request, data: data, end: end)
        } else {
            request.finishLoading()
        }
        return true
    }

    private func respond(
        to request: AVAssetResourceLoadingRequest, data: AVAssetResourceLoadingDataRequest, end: Int64
    ) {
        guard !request.isCancelled else { return }
        let start = data.currentOffset
        guard start < end else {
            request.finishLoading()
            return
        }
        do {
            try file.seek(toOffset: UInt64(start))
            let count = Int(min(end - start, 1 << 20))
            guard var bytes = try file.read(upToCount: count), !bytes.isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let next = start + Int64(bytes.count)
            for offset in tagOffsets {
                let lower = max(start, offset)
                let upper = min(next, offset + Int64(Self.hvc1.count))
                guard lower < upper else { continue }
                bytes.replaceSubrange(Int(lower - start)..<Int(upper - start),
                                      with: Self.hvc1[Int(lower - offset)..<Int(upper - offset)])
            }
            guard !request.isCancelled else { return }
            data.respond(with: bytes)
            if next == end { request.finishLoading() }
            else { queue.async { self.respond(to: request, data: data, end: end) } }
        } catch {
            if !request.isCancelled { request.finishLoading(with: error) }
        }
    }
}

private struct MP4Boxes {
    private struct Box {
        let type: String
        let start: Int64
        let contents: Range<Int64>
    }

    let file: FileHandle

    func hevcTagOffsets(length: Int64) throws -> [Int64] {
        guard let movie = try first("moov", in: 0..<length) else { return [] }
        var offsets: [Int64] = []
        var trackOffset = movie.contents.lowerBound
        while trackOffset < movie.contents.upperBound {
            let track = try box(at: trackOffset, end: movie.contents.upperBound)
            trackOffset = track.contents.upperBound
            guard track.type == "trak",
                  let media = try first("mdia", in: track.contents),
                  let info = try first("minf", in: media.contents),
                  let table = try first("stbl", in: info.contents),
                  let descriptions = try first("stsd", in: table.contents),
                  descriptions.contents.count >= 8 else { continue }
            // stsd starts with version, flags and entry count. A visual sample
            // entry has 78 bytes of fields before its child boxes.
            let header = try read(at: descriptions.contents.lowerBound, count: 8)
            var entryOffset = descriptions.contents.lowerBound + 8
            for _ in 0..<header.integer(at: 4, count: 4) {
                let entry = try box(at: entryOffset, end: descriptions.contents.upperBound)
                entryOffset = entry.contents.upperBound
                guard entry.type == "hev1" else { continue }
                guard entry.contents.count >= 78,
                      let config = try first("hvcC", in: (entry.contents.lowerBound + 78)..<entry.contents.upperBound),
                      config.contents.count <= 1 << 20,
                      try hasParameterSets(read(at: config.contents.lowerBound, count: config.contents.count))
                else { return [] }
                offsets.append(entry.start + 4)
            }
        }
        return offsets
    }

    private func first(_ type: String, in range: Range<Int64>) throws -> Box? {
        var offset = range.lowerBound
        while offset < range.upperBound {
            let child = try box(at: offset, end: range.upperBound)
            if child.type == type { return child }
            offset = child.contents.upperBound
        }
        return nil
    }

    private func box(at start: Int64, end: Int64) throws -> Box {
        let remaining = end - start
        guard remaining >= 8 else { throw CocoaError(.fileReadCorruptFile) }
        let header = try read(at: start, count: 8)
        let sizeField = header.integer(at: 0, count: 4)
        var headerSize: Int64 = 8
        var size = sizeField == 0 ? UInt64(remaining) : sizeField
        if sizeField == 1 {
            guard remaining >= 16 else { throw CocoaError(.fileReadCorruptFile) }
            headerSize = 16
            size = try read(at: start + 8, count: 8).integer(at: 0, count: 8)
        }
        guard size >= UInt64(headerSize), size <= UInt64(remaining) else { throw CocoaError(.fileReadCorruptFile) }
        return Box(type: String(decoding: header[4..<8], as: UTF8.self), start: start,
                   contents: (start + headerSize)..<(start + Int64(size)))
    }

    private func read(at offset: Int64, count: Int) throws -> Data {
        try file.seek(toOffset: UInt64(offset))
        guard let bytes = try file.read(upToCount: count), bytes.count == count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return bytes
    }

    private func hasParameterSets(_ config: Data) -> Bool {
        guard config.count >= 23, config[0] == 1 else { return false }
        var position = 23
        var parameterSets: Set<UInt8> = []
        for _ in 0..<config[22] {
            guard config.count - position >= 3 else { return false }
            let type = config[position] & 0x3f
            let count = config.integer(at: position + 1, count: 2)
            position += 3
            for _ in 0..<count {
                guard config.count - position >= 2 else { return false }
                let size = Int(config.integer(at: position, count: 2))
                position += 2
                guard size >= 2, config.count - position >= size,
                      (config[position] >> 1) & 0x3f == type else { return false }
                position += size
            }
            if count > 0 { parameterSets.insert(type) }
        }
        return position == config.count && parameterSets.isSuperset(of: [32, 33, 34])
    }
}

private extension Data {
    func integer(at offset: Int, count: Int) -> UInt64 {
        self[offset..<(offset + count)].reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
