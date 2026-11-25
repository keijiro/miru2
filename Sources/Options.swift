import Foundation

struct Options {
    static let usage = """
        Usage: ./run.sh [--simulator] [--library DIRECTORY] [--open FILE]…
                        [--panorama] [--metrics] [--stress-count COUNT] [--seconds N]
                        [--layout-directory DIRECTORY]
        """

    var root: URL
    var layoutDirectory: URL
    var media: [URL] = []
    var simulator = false
    var metrics = false
    var startPanorama = false
    var stressCount: Int?
    var seconds: Double?

    init(arguments: [String]) throws {
        let files = FileManager.default
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let project = executable.deletingLastPathComponent().deletingLastPathComponent()
        let sampleFolder = project.deletingLastPathComponent().appendingPathComponent("miru/samples", isDirectory: true)
        let movies = files.homeDirectoryForCurrentUser.appendingPathComponent("Movies", isDirectory: true)
        root = files.fileExists(atPath: sampleFolder.path) ? sampleFolder : movies
        if !files.fileExists(atPath: root.path) {
            root = URL(fileURLWithPath: files.currentDirectoryPath, isDirectory: true)
        }
        layoutDirectory = files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Miru/Layouts")
        var args = arguments.makeIterator()
        func value(for option: String) throws -> String {
            guard let value = args.next(), !value.hasPrefix("--") else { throw MiruError("Missing value for \(option)") }
            return value
        }
        while let arg = args.next() {
            switch arg {
            case "--library":
                root = URL(fileURLWithPath: try value(for: arg), isDirectory: true)
            case "--layout-directory":
                layoutDirectory = URL(fileURLWithPath: try value(for: arg), isDirectory: true)
            case "--open":
                media.append(URL(fileURLWithPath: try value(for: arg)).standardizedFileURL)
            case "--simulator": simulator = true
            case "--metrics": metrics = true
            case "--panorama": startPanorama = true
            case "--stress-count":
                guard let count = Int(try value(for: arg)), (1...100).contains(count) else {
                    throw MiruError("--stress-count expects an integer from 1 to 100")
                }
                stressCount = count
                metrics = true
            case "--seconds":
                guard let duration = Double(try value(for: arg)), duration.isFinite, duration > 0 else {
                    throw MiruError("--seconds expects a positive number")
                }
                seconds = duration
            default: throw MiruError("Unknown option: \(arg)\n\(Self.usage)")
            }
        }
        root = root.standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard files.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else {
            throw MiruError("Media library does not exist or is not a directory: \(root.path)")
        }
        for url in media {
            var directory: ObjCBool = false
            guard files.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue,
                  MediaKind(url: url) != nil else {
                throw MiruError("Media file is missing or has an unsupported type: \(url.path)")
            }
        }
        if let count = stressCount {
            let videos = media.filter { MediaKind(url: $0) == .video }
            guard !videos.isEmpty, videos.count == media.count else { throw MiruError("--stress-count requires --open video files") }
            media = (0..<count).map { videos[$0 % videos.count] }
        }
        guard !startPanorama || media.contains(where: { MediaKind(url: $0) == .video }) else {
            throw MiruError("--panorama requires a video with --open")
        }
    }
}
