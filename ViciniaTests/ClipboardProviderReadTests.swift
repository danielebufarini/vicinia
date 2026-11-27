// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import Vicinia

final class ManualClipboardDeadline: Sendable {
    private struct State {
        var expired = false
        var waits: [ContinuousClock.Instant] = []
        var sleepers: [AsyncStream<Void>.Continuation] = []
    }
    private let state = Mutex(State())

    var waits: [ContinuousClock.Instant] { state.withLock { $0.waits } }

    func deadline() -> ClipboardReadDeadline {
        ClipboardReadDeadline { [self] instant in
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            let expired = state.withLock { state in
                state.waits.append(instant)
                if !state.expired { state.sleepers.append(continuation) }
                return state.expired
            }
            if expired { continuation.finish() }
            for await _ in stream {}
            try Task.checkCancellation()
        }
    }

    func expire() {
        let sleepers = state.withLock { state in
            state.expired = true
            defer { state.sleepers.removeAll() }
            return state.sleepers
        }
        for sleeper in sleepers { sleeper.finish() }
    }
}

/// Poll only for acknowledgements. Test interleavings are driven by explicit gates.
@MainActor
func clipboardReached(_ predicate: () -> Bool) async -> Bool {
    let limit = ContinuousClock.now + .seconds(3)
    while !predicate(), ContinuousClock.now < limit { try? await Task.sleep(for: .milliseconds(2)) }
    return predicate()
}

@Suite("Clipboard provider reads")
@MainActor
struct ClipboardProviderReadTests {
    @Test func synchronousCompletionWinsAndOnlyProcessesTheFirstCallback() async throws {
        let clock = ManualClipboardDeadline()
        let progress = Progress(totalUnitCount: 1)
        var calls = 0
        let read = ClipboardProviderRead<Int>(deadline: clock.deadline())
        let outcome = try await read.value { read in
            read.complete { calls += 1; return 7 }
            read.complete { calls += 1; return 8 }
            return progress
        }
        clock.expire()
        #expect(outcome == 7)
        #expect(calls == 1)
        #expect(!progress.isCancelled)
    }

    @Test(arguments: [ClipboardReadStop.cancelled, .timedOut])
    func aStalledReadTerminatesAndIgnoresLateCallbacks(_ stop: ClipboardReadStop) async throws {
        let clock = ManualClipboardDeadline(), progress = Progress(totalUnitCount: 1)
        let read = ClipboardProviderRead<Int>(deadline: clock.deadline())
        var started = false
        var outcome: Result<Int, ClipboardReadStop>?
        let task = Task {
            do throws(ClipboardReadStop) {
                outcome = .success(try await read.value { _ in started = true; return progress })
            } catch { outcome = .failure(error) }
        }
        defer { task.cancel(); read.complete { 0 }; clock.expire() }
        try #require(await clipboardReached { started })
        if stop == .cancelled { task.cancel() } else { clock.expire() }
        try #require(await clipboardReached { outcome != nil })
        #expect(outcome == .failure(stop))
        #expect(await clipboardReached { progress.isCancelled })
        read.complete { Issue.record("Abandoned callback processed"); return 9 }
        #expect(outcome == .failure(stop))
    }

    @Test func continuousClockExpiresAStalledReadBeforeItsCallbackArrives() async throws {
        let deadline = ClipboardReadDeadline(instant: .now + .seconds(1))
        let read = ClipboardProviderRead<Int>(deadline: deadline)
        let progress = Progress(totalUnitCount: 1)
        var started = false
        var outcome: Result<Int, ClipboardReadStop>?
        let task = Task {
            do throws(ClipboardReadStop) {
                outcome = .success(try await read.value { _ in started = true; return progress })
            } catch { outcome = .failure(error) }
        }
        defer { task.cancel(); read.complete { 0 } }
        try #require(await clipboardReached { started })
        try #require(await clipboardReached { outcome != nil })
        #expect(ContinuousClock.now >= deadline.instant)
        #expect(outcome == .failure(.timedOut))
        #expect(await clipboardReached { progress.isCancelled })
        read.complete { Issue.record("Expired callback processed"); return 1 }
        #expect(outcome == .failure(.timedOut))
    }

    @Test func aCallbackThatStartsInTimeCannotReturnContentAfterTheDeadline() async throws {
        let timer = ManualClipboardDeadline()
        let deadline = ClipboardReadDeadline(instant: .now + .seconds(1), sleep: timer.deadline().sleep)
        let read = ClipboardProviderRead<Int>(deadline: deadline)
        let release = DispatchSemaphore(value: 0)
        let reading = Mutex(false)
        var outcome: Result<Int, ClipboardReadStop>?
        let task = Task {
            do throws(ClipboardReadStop) {
                outcome = .success(try await read.value { read in
                    DispatchQueue.global().async {
                        read.complete {
                            reading.withLock { $0 = true }
                            _ = release.wait(timeout: .now() + .seconds(6))
                            return 1
                        }
                    }
                    return Progress(totalUnitCount: 1)
                })
            } catch { outcome = .failure(error) }
        }
        defer { release.signal(); task.cancel(); timer.expire() }
        try #require(await clipboardReached { reading.withLock { $0 } })
        try await ContinuousClock().sleep(until: deadline.instant)
        #expect(outcome == nil)
        release.signal()
        try #require(await clipboardReached { outcome != nil })
        #expect(outcome == .failure(.timedOut))
    }

    @Test func cancellationBeforeContinuationRegistrationNeverStartsTheProvider() async throws {
        let clock = ManualClipboardDeadline()
        let read = ClipboardProviderRead<Int>(deadline: clock.deadline())
        var outcome: Result<Int, ClipboardReadStop>?
        let task = Task {
            do throws(ClipboardReadStop) {
                outcome = .success(try await read.value { read in
                    Issue.record("Cancelled provider started")
                    read.complete { 1 }
                    return Progress(totalUnitCount: 1)
                })
            } catch { outcome = .failure(error) }
        }
        task.cancel()
        defer { clock.expire() }
        try #require(await clipboardReached { outcome != nil })
        #expect(outcome == .failure(.cancelled))
    }

    @Test func cancellationBeforeTheProviderReturnsCancelsItsProgress() async throws {
        let read = ClipboardProviderRead<Int>(deadline: .init())
        let progress = Progress(totalUnitCount: 1)
        var task: Task<Void, Never>?
        var outcome: Result<Int, ClipboardReadStop>?
        task = Task {
            do throws(ClipboardReadStop) {
                outcome = .success(try await read.value { _ in
                    task?.cancel()
                    return progress
                })
            } catch { outcome = .failure(error) }
        }
        defer { task?.cancel(); read.complete { 0 } }
        try #require(await clipboardReached { outcome != nil })
        #expect(outcome == .failure(.cancelled))
        #expect(await clipboardReached { progress.isCancelled })
    }

    @Test(arguments: [ClipboardReadStop.cancelled, .timedOut])
    func aStopWinsAgainstAnInProgressCallback(_ stop: ClipboardReadStop) async throws {
        let clock = ManualClipboardDeadline()
        let read = ClipboardProviderRead<Int>(deadline: clock.deadline())
        let release = DispatchSemaphore(value: 0)
        let callback = Mutex((started: false, ended: false))
        var outcome: Result<Int, ClipboardReadStop>?
        let task = Task {
            do throws(ClipboardReadStop) {
                outcome = .success(try await read.value { read in
                    DispatchQueue.global().async {
                        read.complete {
                            callback.withLock { $0.started = true }
                            _ = release.wait(timeout: .now() + 10)
                            return 1
                        }
                        callback.withLock { $0.ended = true }
                    }
                    return Progress(totalUnitCount: 1)
                })
            } catch { outcome = .failure(error) }
        }
        defer { release.signal(); task.cancel(); clock.expire() }
        try #require(await clipboardReached { callback.withLock { $0.started } })
        read.complete { Issue.record("Duplicate callback processed concurrently"); return 2 }
        if stop == .cancelled { task.cancel() } else { clock.expire() }
        try #require(await clipboardReached { outcome != nil })
        #expect(outcome == .failure(stop))
        release.signal()
        try #require(await clipboardReached { callback.withLock { $0.ended } })
        #expect(outcome == .failure(stop))
    }

    @Test func aDeadlineAlreadyElapsedNeverStartsTheProvider() async {
        let read = ClipboardProviderRead<Int>(deadline: .init(instant: .now - .seconds(1)))
        await #expect(throws: ClipboardReadStop.timedOut) {
            try await read.value { _ in
                Issue.record("Expired provider started")
                return Progress(totalUnitCount: 1)
            }
        }
    }

    @Test(arguments: [true, false])
    func stoppingLaterInACopyDiscardsEarlierRepresentations(_ timeout: Bool) async throws {
        let clock = ManualClipboardDeadline()
        let firstProbe = ProviderProbe(), secondProbe = ProviderProbe(), deadline = clock.deadline()
        firstProbe.hold()
        secondProbe.hold()
        let text = ClipboardFormats.text, html = ClipboardFormats.html, rtf = ClipboardFormats.rtf
        let first = firstProbe.provider([(text, Data("first".utf8))])
        let second = secondProbe.provider([(html, Data("second".utf8)), (rtf, Data("third".utf8))])
        var outcome: ClipboardReadStop?
        var completed = false
        let task = Task {
            do throws(ClipboardReadStop) {
                _ = try await LocalClipboardReader.load([first, second], limits: .standard, deadline: deadline)
            } catch { outcome = error }
            completed = true
        }
        defer { task.cancel(); firstProbe.release(); secondProbe.release(); clock.expire() }
        try #require(await clipboardReached { firstProbe.parkedLoads == 1 && clock.waits.count == 1 })
        firstProbe.release()
        try #require(await clipboardReached { clock.waits.count == 2 && secondProbe.parkedLoads == 1 })
        if timeout { clock.expire() } else { task.cancel() }
        try #require(await clipboardReached { completed })
        #expect(outcome == (timeout ? .timedOut : .cancelled))
        #expect(clock.waits.allSatisfy { $0 == deadline.instant })
        #expect(firstProbe.loads(text) == 1)
        #expect(secondProbe.loads(rtf) == 1 && secondProbe.loads(html) == 0)
    }

    @Test func aURLProviderIsReadAsAnObject() async throws {
        let url = URL(string: "https://example.test/path")!
        let provider = NSItemProvider(object: url as NSURL)
        try #require(provider.canLoadObject(ofClass: NSURL.self))
        let result = try await LocalClipboardReader.load([provider], limits: .standard, deadline: .init()).get()
        #expect(result.items.first?[ClipboardFormats.url] == Data(url.absoluteString.utf8))
    }

    @Test func fileBytesAreOwnedBeforeTheCompletionReturns() async throws {
        let png = ClipboardFixture.image(.png), type = UTType.png.identifier
        let provider = CallbackFileProvider(bytes: png)
        let result = try await LocalClipboardReader.image(of: provider, type: type, budget: png.count, limits: .standard)
        #expect(result == .loaded(png))
        #expect(provider.removedFile)
    }
}

private final class CallbackFileProvider: NSItemProvider, @unchecked Sendable {
    private let bytes: Data
    private let removed = Mutex(false)
    var removedFile: Bool { removed.withLock { $0 } }

    init(bytes: Data) { self.bytes = bytes; super.init() }

    override func loadFileRepresentation(forTypeIdentifier typeIdentifier: String,
                                         completionHandler: @escaping @Sendable (URL?, (any Error)?) -> Void) -> Progress {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try bytes.write(to: url)
            defer {
                try? FileManager.default.removeItem(at: url)
                removed.withLock { $0 = !FileManager.default.fileExists(atPath: url.path) }
            }
            completionHandler(url, nil)
        } catch {
            completionHandler(nil, error)
        }
        return Progress(totalUnitCount: 1)
    }
}
