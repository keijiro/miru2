import Foundation
import Metal
import QuartzCore
import os

final class SubmittedFrames {
    private var pending: [MTLCommandBuffer] = []

    func append(_ command: MTLCommandBuffer) { pending.append(command) }

    func makeRoom() throws {
        while let command = pending.first {
            if pending.count >= 2 { command.waitUntilCompleted() }
            if command.status == .error { throw command.error ?? MiruError("Metal command failed") }
            guard command.status == .completed else { return }
            pending.removeFirst()
        }
    }

    func drain() {
        for command in pending { command.waitUntilCompleted() }
    }
}

final class FrameMetrics: @unchecked Sendable {
    private let gpu = OSAllocatedUnfairLock<[Double]>(initialState: [])
    private var cpu: [Double] = []
    private var intervals: [Double] = []
    private var previous: Double?
    private var windowStart: Double?
    private var updates = 0

    func recordGPU(_ time: Double) {
        if time > 0 { gpu.withLock { $0.append(time * 1000) } }
    }

    func record(start: Double, period: Double, videoUpdates: Int, workspace: Workspace) {
        let now = CACurrentMediaTime()
        if windowStart == nil { windowStart = start }
        if let previous { intervals.append((start - previous) * 1000) }
        previous = start
        cpu.append((now - start) * 1000)
        updates += videoUpdates
        guard let windowStart, now - windowStart >= 2 else { return }

        let elapsed = now - windowStart
        let completed = gpu.withLock {
            let result = $0
            $0.removeAll(keepingCapacity: true)
            return result
        }
        let videos = workspace.panels.filter { $0.entry?.kind == .video }
        let ready = videos.filter { $0.playback?.frame != nil }.count
        let budget = period * 1000
        let late = intervals.filter { $0 > budget * 1.5 }.count
        let summary = String(
            format: "%.1f stereo fps, CPU p95 %.2f ms, GPU p95 %.2f ms, interval p95 %.2f ms, long intervals %d/%d (target %.2f ms)",
            Double(cpu.count) / elapsed, percentile(cpu), percentile(completed), percentile(intervals),
            late, intervals.count, budget
        )
        print("[miru] \(ready)/\(videos.count) video textures, \(Int((Double(updates) / elapsed).rounded())) new frames/s, \(summary)")
        cpu.removeAll(keepingCapacity: true)
        intervals.removeAll(keepingCapacity: true)
        updates = 0
        self.windowStart = now
    }

    private func percentile(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.sorted()[Int(ceil(0.95 * Double(values.count))) - 1]
    }
}
