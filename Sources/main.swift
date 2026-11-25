import Dispatch
import Foundation
import os

setlinebuf(stdout)

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--help") || arguments.contains("-h") {
    print(Options.usage)
    exit(EXIT_SUCCESS)
}

let stop = OSAllocatedUnfairLock(initialState: false)
let signals = [SIGINT, SIGTERM].map { number in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
    source.setEventHandler { stop.withLock { $0 = true } }
    source.resume()
    return source
}

// AVFoundation has access to the main queue while the XR frame loop owns a separate thread.
Thread.detachNewThread {
    do {
        let options = try Options(arguments: arguments)
        try withExtendedLifetime(signals) { try runMiru(stop: stop, options: options) }
        exit(EXIT_SUCCESS)
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }
}
dispatchMain()
