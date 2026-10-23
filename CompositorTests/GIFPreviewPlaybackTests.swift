import Foundation
import Synchronization
import Testing
@testable import Compositor

@MainActor
struct GIFPreviewPlaybackTests {
    private enum Stop: Error, Equatable { case finished, excessiveSleeps }

    /// Clock reads and simulated decode work share locked time, including across suspension points.
    private nonisolated final class TestClock: Clock {
        struct Instant: InstantProtocol {
            var offset = Duration.zero
            func advanced(by duration: Duration) -> Self { Self(offset: offset + duration) }
            func duration(to other: Self) -> Duration { other.offset - offset }
            static func < (lhs: Self, rhs: Self) -> Bool { lhs.offset < rhs.offset }
        }
        private struct State {
            var now = Instant()
            var sleeps = 0
        }
        private let state = Mutex(State())
        var now: Instant { state.withLock { $0.now } }
        var minimumResolution: Duration { .nanoseconds(1) }
        var sleeps: Int { state.withLock { $0.sleeps } }
        var elapsed: Double { now.offset / .seconds(1) }

        func advance(by duration: Duration) { state.withLock { $0.now = $0.now.advanced(by: duration) } }
        func sleep(until deadline: Instant, tolerance: Duration?) async throws {
            try Task.checkCancellation()
            try state.withLock {
                $0.sleeps += 1
                guard $0.sleeps < 100 else { throw Stop.excessiveSleeps }
                if deadline > $0.now { $0.now = deadline }
            }
        }
    }

    @Test(arguments: [0.25, 1.0, 4.0])
    func decodingDoesNotAccumulateDelayAtAnyPlaybackSpeed(speed: Double) async throws {
        let clock = TestClock()
        var frames: [Int] = [], times: [Double] = []
        try await GIFPreviewPlayback.play(durations: [0.1, 0.2, 0.15].map { $0 / speed }, startingAt: 0,
                                           loops: false, clock: clock) { index in
            frames.append(index)
            times.append(clock.elapsed)
            clock.advance(by: .seconds(0.03 / speed))
        }
        #expect(frames == [1, 2])
        #expect(abs(times[0] - 0.1 / speed) < 1e-9)
        #expect(abs(times[1] - 0.3 / speed) < 1e-9)
        #expect(abs(clock.elapsed - 0.45 / speed) < 1e-9)
    }

    @Test(arguments: [0.25, 0.5])
    func slowDecodingSkipsExpiredIntervalsAndOnceEndsOnTheLastFrame(delay: Double) async throws {
        let clock = TestClock()
        var frames: [Int] = []
        try await GIFPreviewPlayback.play(durations: [0.1, 0.1, 0.1, 0.1], startingAt: 0,
                                           loops: false, clock: clock) { index in
            frames.append(index)
            clock.advance(by: .seconds(delay))
        }
        #expect(frames == [1, 3])
        #expect(clock.sleeps == (delay < 0.4 ? 3 : 2))
    }

    @Test func resumeAndLoopKeepMixedFrameDurations() async throws {
        let clock = TestClock()
        var frames: [Int] = [], times: [Double] = []
        await #expect(throws: Stop.finished) {
            try await GIFPreviewPlayback.play(durations: [0.1, 0.2, 0.3], startingAt: 1, clock: clock) { index in
                frames.append(index)
                times.append(clock.elapsed)
                clock.advance(by: .milliseconds(20))
                if frames.count == 3 { throw Stop.finished }
            }
        }
        #expect(frames == [2, 0, 1])
        for (time, expected) in zip(times, [0.2, 0.5, 0.6]) { #expect(abs(time - expected) < 1e-9) }
    }

    @Test func cancelingDuringDecodeDoesNotRequestAnotherFrame() async throws {
        let clock = TestClock()
        var frames: [Int] = []
        let task = Task {
            do {
                try await GIFPreviewPlayback.play(durations: [0.1, 0.2, 0.3], startingAt: 0, clock: clock) { index in
                    frames.append(index)
                    clock.advance(by: .milliseconds(30))
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                return false
            } catch is CancellationError { return true }
            catch { Issue.record(error); return false }
        }
        #expect(await task.value)
        #expect(frames == [1])
    }

    @Test func emptySingleFrameAndInvalidTimingDoNotStartPlayback() async throws {
        for durations in [[], [0.1], [0.1, 0], [0.1, -.infinity], [0.1, .nan]] as [[Double]] {
            let clock = TestClock()
            try await GIFPreviewPlayback.play(durations: durations, startingAt: 0, clock: clock) { _ in
                Issue.record("Invalid or still timing must not request a frame")
            }
            #expect(clock.sleeps == 0)
        }
        let clock = TestClock()
        try await GIFPreviewPlayback.play(durations: [0.1, 0.2], startingAt: 2, clock: clock) { _ in
            Issue.record("An invalid starting frame must not play")
        }
        #expect(clock.sleeps == 0)
    }

    @Test func canceledNavigationDoesNotAdvanceTheDisplayedFrame() async throws {
        let url = try GIFLayerTests().fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let request = Task { await session.selectGIFTimelineFrame(1) }
        request.cancel()
        await request.value
        #expect(session.gifTimelineSelectedFrameIndex == 0)
        #expect(!session.gifTimelineIsLoadingFrame && session.importError == nil)
    }

    @Test func preparingFramesKeepsDeadlinesAndStableIdentities() async throws {
        let clock = TestClock()
        let identities = [0, 4, 2, 3]
        var frames: [Int] = [], times: [Double] = []
        await #expect(throws: Stop.finished) {
            try await GIFPreviewPlayback.play(durations: [0.04, 0.16, 0.08, 0.24], startingAt: 1,
                capacity: 3, clock: clock, prepareFrame: { GIFPreparedFrame(identities[$0]) }, showFrame: { _, identity in
                    frames.append(identity)
                    times.append(clock.elapsed)
                    clock.advance(by: .milliseconds(30))
                    if frames.count == 3 { throw Stop.finished }
                })
        }
        #expect(frames == [2, 3, 0])
        for (time, deadline) in zip(times, [0.16, 0.24, 0.48]) { #expect(abs(time - deadline) < 1e-9) }
    }

    @Test func preparationFollowsElapsedTimeAfterALateFrame() async throws {
        let clock = TestClock()
        var prepared: [Int] = [], shown: [Int] = []
        await #expect(throws: Stop.finished) {
            try await GIFPreviewPlayback.play(durations: [0.1, 0.1, 0.1, 0.1, 0.1], startingAt: 0,
                clock: clock, prepareNextFrame: { prepared.append($0) }) { index in
                    shown.append(index)
                    clock.advance(by: .milliseconds(250))
                    if shown.count == 2 { throw Stop.finished }
                }
        }
        #expect(shown == [1, 3])
        #expect(prepared == [1, 3])
    }

    private actor Decoder {
        private var started: [Int] = []
        private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

        func decode(_ index: Int) -> Int {
            started.append(index)
            let ready = waiters.filter { $0.0 <= started.count }
            waiters.removeAll { $0.0 <= started.count }
            for (_, waiter) in ready { waiter.resume() }
            return index
        }

        func indices() -> [Int] { started }
        func waitForReads(_ count: Int) async {
            if started.count >= count { return }
            await withCheckedContinuation { waiters.append((count, $0)) }
        }
    }

    @Test(.timeLimit(.minutes(1))) func preparesOnlyTheUpcomingWindowAndCancelsStaleFrames() async throws {
        let decoder = Decoder()
        let buffer = GIFPlaybackBuffer(count: 8, capacity: 3) { GIFPreparedFrame(await decoder.decode($0)) }
        defer { buffer.cancel() }
        buffer.prepare(startingAt: 1)
        await decoder.waitForReads(3)
        #expect(await decoder.indices().sorted() == [1, 2, 3])
        buffer.prepare(startingAt: 2)
        await decoder.waitForReads(4)
        #expect(await decoder.indices().sorted() == [1, 2, 3, 4])
        #expect(try await buffer.frame(at: 2) == 2)
        #expect(try await buffer.frame(at: 3) == 3)
        buffer.cancel()
        await #expect(throws: CancellationError.self) { try await buffer.frame(at: 4) }
    }

    @Test func cancelingBeforePreparationStartsDoesNotDecode() async throws {
        let reads = Mutex(0)
        let buffer = GIFPlaybackBuffer(count: 4, capacity: 3) { index in
            reads.withLock { $0 += 1 }
            return GIFPreparedFrame(index)
        }
        buffer.prepare(startingAt: 1)
        buffer.cancel()
        await Task.yield()
        #expect(reads.withLock { $0 } == 0)
        await #expect(throws: CancellationError.self) { try await buffer.frame(at: 1) }
    }

    @Test(.timeLimit(.minutes(1))) func cancelingPlaybackCancelsThePendingRead() async throws {
        let started = AsyncStream<Int>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let buffer = GIFPlaybackBuffer(count: 4, capacity: 1) { index in
            started.continuation.yield(index)
            for await _ in release.stream { break }
            return GIFPreparedFrame(index)
        }
        defer {
            buffer.cancel()
            started.continuation.finish()
            release.continuation.finish()
        }
        let task = Task { try await buffer.frame(at: 1) }
        var reads = started.stream.makeAsyncIterator()
        #expect(await reads.next() == 1)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func twoFramePlaybackWrapsAndOversizedFramesDecodeOnDemand() async throws {
        let calls = Mutex([Int]())
        let decode: @Sendable (Int) async throws -> GIFPreparedFrame<Int> = { index in
            calls.withLock { $0.append(index) }
            return GIFPreparedFrame(index)
        }
        let buffer = GIFPlaybackBuffer(count: 2, capacity: 3, decode: decode)
        buffer.prepare(startingAt: 1)
        #expect(try await buffer.frame(at: 1) == 1)
        buffer.prepare(startingAt: 0)
        #expect(try await buffer.frame(at: 0) == 0)
        buffer.cancel()
        #expect(calls.withLock { $0.sorted() } == [0, 1])

        calls.withLock { $0.removeAll() }
        let unbuffered = GIFPlaybackBuffer(count: 8, capacity: 0, decode: decode)
        unbuffered.prepare(startingAt: 1)
        #expect(calls.withLock { $0.isEmpty })
        #expect(try await unbuffered.frame(at: 4) == 4)
        #expect(calls.withLock { $0 } == [4])
    }

    @Test func sustainedSlowDecodingStopsSpeculativeReads() async throws {
        let calls = Mutex([Int]())
        let buffer = GIFPlaybackBuffer(count: 8, capacity: 3, durations: Array(repeating: 1e-9, count: 8)) { index in
            calls.withLock { $0.append(index) }
            return GIFPreparedFrame(index, decodeDuration: .seconds(1))
        }
        defer { buffer.cancel() }
        // Simulate two reads that exceed the saved frame duration.
        #expect(try await buffer.frame(at: 1) == 1)
        #expect(try await buffer.frame(at: 2) == 2)
        buffer.prepare(startingAt: 3)
        await Task.yield()
        #expect(calls.withLock { $0 } == [1, 2])
        #expect(try await buffer.frame(at: 4) == 4)
        #expect(calls.withLock { $0 } == [1, 2, 4])
    }

    @Test func prefetchCapacityIsBoundedByBytesAndFrameCount() {
        #expect(GIFPlaybackBufferLimits.capacity(width: 1024, height: 1024, frameCount: 20) == 3)
        #expect(GIFPlaybackBufferLimits.capacity(width: 1920, height: 1080, frameCount: 20) == 3)
        #expect(GIFPlaybackBufferLimits.capacity(width: 3840, height: 2160, frameCount: 20) == 1)
        #expect(GIFPlaybackBufferLimits.capacity(width: 4096, height: 4096, frameCount: 20) == 0)
        #expect(GIFPlaybackBufferLimits.capacity(width: 32, height: 24, frameCount: 2) == 1)
        #expect(GIFPlaybackBufferLimits.capacity(width: 32, height: 24, frameCount: 1) == 0)
    }

    @Test func stoppingPreparedPlaybackDoesNotAdvanceOrKeepLoading() async throws {
        let url = try GIFLayerTests().fixture(delays: [0.02, 0.02, 0.02, 0.02])
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let layerID = try #require(session.activeLayerID)
        session.toggleGIFPlayback(for: layerID)
        var displayed: [Int] = []
        session.refreshCanvasPreview = {
            displayed.append(session.gifTimelineSelectedFrameIndex)
            session.pauseGIFForEditing(for: layerID)
        }
        await session.playGIFTimeline(for: layerID)
        #expect(displayed == [1])
        #expect(!session.gifTimelineIsLoadingFrame && !session.gifTimelineIsPlaying)
        #expect(session.importError == nil)
        await session.selectGIFTimelineFrame(3)
        #expect(session.gifTimelineSelectedFrameIndex == 3)
    }
    @Test func playbackKeepsEditedPixelsAndUndoRestoresThePreparedOriginal() async throws {
        let url = try GIFLayerTests().fixture(delays: [0.02, 0.02, 0.02, 0.02])
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let layerID = try #require(session.activeLayerID)
        await session.selectGIFTimelineFrame(1)
        await session.invertPixels()
        let edited = try #require(session.activeLayer?.gifAnimation?.framePixels[1])
        await session.selectGIFTimelineFrame(0)
        session.toggleGIFPlayback(for: layerID)
        session.refreshCanvasPreview = { session.pauseGIFForEditing(for: layerID) }
        await session.playGIFTimeline(for: layerID)
        #expect(session.gifTimelineSelectedFrameIndex == 1)
        #expect(session.activeLayer.flatMap { session.displayedAsset(for: $0)?.image } === edited.image)
        session.undo()
        #expect(session.activeLayer?.gifAnimation?.framePixels.isEmpty == true)
        #expect(session.activeLayer.flatMap { session.displayedAsset(for: $0)?.image } !== edited.image)
        #expect(session.importError == nil)
    }

}
