import Foundation

nonisolated enum GIFPlaybackBufferLimits {
    // Bounds queued RGBA pixels and thumbnails; ImageIO's working buffers and canvas textures are separate.
    static let byteBudget = 32 * 1024 * 1024
    static let maxFrames = 3

    static func capacity(width: Int, height: Int, frameCount: Int) -> Int {
        guard width > 0, height > 0, width <= DocumentLimits.maxSide, height <= DocumentLimits.maxSide else { return 0 }
        let bytes = width * height * 4 + GIFTimelineLimits.thumbnailSide * GIFTimelineLimits.thumbnailSide * 4
        return min(maxFrames, max(0, frameCount - 1), byteBudget / bytes)
    }
}

nonisolated struct GIFPreparedFrame<Frame: Sendable>: Sendable {
    let frame: Frame
    let decodeDuration: Duration

    init(_ frame: Frame, decodeDuration: Duration = .zero) {
        self.frame = frame
        self.decodeDuration = decodeDuration
    }
}

/// Upcoming frames only, including pending reads. Consumed frames leave the buffer instead of becoming a loop cache.
final class GIFPlaybackBuffer<Frame: Sendable> {
    private let count: Int
    private let decode: @Sendable (Int) async throws -> GIFPreparedFrame<Frame>
    private var pending: [Int: Task<Frame, Error>] = [:]
    private let durations: [TimeInterval]
    private var lookahead: Int
    private var slowReads = 0
    private var isCanceled = false

    init(count: Int, capacity: Int, durations: [TimeInterval] = [],
         decode: @escaping @Sendable (Int) async throws -> GIFPreparedFrame<Frame>) {
        self.count = count
        lookahead = max(0, min(capacity, count - 1))
        self.decode = decode
        self.durations = durations
    }

    func prepare(startingAt index: Int) {
        guard !isCanceled, count > 1, lookahead > 0 else { return }
        let indices = (0..<lookahead).map { (index + $0) % count }
        for (position, task) in pending where !indices.contains(position) {
            task.cancel()
            pending.removeValue(forKey: position)
        }
        var previous: Task<Frame, Error>?
        for position in indices {
            if pending[position] == nil {
                let preceding = previous
                pending[position] = Task { [weak self, decode] in
                    // Only one read enters the decoder at a time; canceled queued reads do no pixel work.
                    if let preceding { _ = await preceding.result }
                    try Task.checkCancellation()
                    let prepared = try await decode(position)
                    try Task.checkCancellation()
                    self?.decoded(position, taking: prepared.decodeDuration)
                    return prepared.frame
                }
            }
            previous = pending[position]
        }
    }

    private func decoded(_ index: Int, taking elapsed: Duration) {
        guard durations.indices.contains(index) else { return }
        slowReads = elapsed > .seconds(durations[index]) ? slowReads + 1 : 0
        guard slowReads >= 2 else { return }
        // A buffer cannot sustain a decoder slower than playback; keep the scheduler's on-demand path.
        lookahead = 0
        for (position, task) in pending where position != index {
            task.cancel()
            pending.removeValue(forKey: position)
        }
    }

    func frame(at index: Int) async throws -> Frame {
        try Task.checkCancellation()
        guard !isCanceled else { throw CancellationError() }
        if lookahead > 0 { prepare(startingAt: index) }
        guard let task = pending[index] else {
            let prepared = try await decode(index)
            try Task.checkCancellation()
            guard !isCanceled else { throw CancellationError() }
            return prepared.frame
        }
        let tasks = Array(pending.values)
        let frame = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            for task in tasks { task.cancel() }
        }
        try Task.checkCancellation()
        guard !isCanceled else { throw CancellationError() }
        pending.removeValue(forKey: index)
        return frame
    }

    func cancel() {
        isCanceled = true
        for task in pending.values { task.cancel() }
        pending.removeAll()
    }
}
