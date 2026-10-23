import Foundation

/// Preview presentation follows elapsed time; decoding never changes the saved frame delays.
nonisolated enum GIFPreviewPlayback {
    @MainActor
    static func play<C: Clock, Frame: Sendable>(durations: [TimeInterval], startingAt initial: Int,
                                               capacity: Int, clock: C = ContinuousClock(),
                                               prepareFrame: @escaping @Sendable (Int) async throws -> GIFPreparedFrame<Frame>,
                                               showFrame: (Int, Frame) throws -> Void) async throws
        where C.Duration == Duration {
        try Task.checkCancellation()
        guard durations.count > 1, durations.indices.contains(initial),
              durations.allSatisfy({ $0.isFinite && $0 > 0 }) else { return }
        let buffer = GIFPlaybackBuffer(count: durations.count, capacity: capacity, durations: durations, decode: prepareFrame)
        defer { buffer.cancel() }
        try await play(durations: durations, startingAt: initial, clock: clock,
                       prepareNextFrame: { buffer.prepare(startingAt: $0) }) { index in
            let frame = try await buffer.frame(at: index)
            try Task.checkCancellation()
            try showFrame(index, frame)
        }
    }

    @MainActor
    static func play<C: Clock>(durations: [TimeInterval], startingAt initial: Int, loops: Bool = true,
                               clock: C = ContinuousClock(), prepareNextFrame: ((Int) -> Void)? = nil,
                               showFrame: (Int) async throws -> Void) async throws
        where C.Duration == Duration {
        try Task.checkCancellation()
        guard durations.count > 1, durations.indices.contains(initial),
              durations.allSatisfy({ $0.isFinite && $0 > 0 }) else { return }
        let seconds = durations.reduce(0, +)
        guard seconds.isFinite, seconds < Double(Int64.max) else { return }
        let holds = durations.map { Duration.seconds($0) }
        guard holds.allSatisfy({ $0 > .zero }) else { return }
        var starts: [Duration] = [], total = Duration.zero
        for duration in holds {
            starts.append(total)
            total += duration
        }
        let started = clock.now, offset = starts[initial]
        func frame(at elapsed: Duration) -> (index: Int, remaining: Duration) {
            let position = offset + elapsed
            var time = position - total * floor(position / total)
            if time < .zero || time >= total { time = .zero }
            var lower = 0, upper = starts.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if starts[middle] <= time { lower = middle + 1 }
                else { upper = middle }
            }
            let index = max(0, lower - 1)
            let end = index + 1 < starts.count ? starts[index + 1] : total
            return (index, end - time)
        }
        var displayed = initial, next = holds[initial]
        prepareNextFrame?((initial + 1) % durations.count)
        while true {
            try await clock.sleep(until: started.advanced(by: next), tolerance: nil)
            try Task.checkCancellation()
            let elapsed = started.duration(to: clock.now)
            if !loops, offset + elapsed >= total {
                // Once always ends on the last frame, even if decoding missed its interval.
                if displayed != durations.count - 1 { try await showFrame(durations.count - 1) }
                try Task.checkCancellation()
                return
            }
            let current = frame(at: elapsed), index = current.index
            // Keep the boundary sampled before decoding. Late frames catch up on the next iteration.
            next = elapsed + current.remaining
            if index != displayed {
                try await showFrame(index)
                try Task.checkCancellation()
                displayed = index
            }
            if let prepareNextFrame {
                let current = frame(at: started.duration(to: clock.now)).index
                // A late decode may have passed several frames; prepare the current interval before later ones.
                prepareNextFrame(current == displayed ? (current + 1) % durations.count : current)
            }
        }
    }
}
