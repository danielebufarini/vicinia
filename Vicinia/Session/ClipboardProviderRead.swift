// SPDX-License-Identifier: MIT

import Foundation
import Synchronization

enum ClipboardReadStop: Error {
    case cancelled, timedOut
}

/// All representations of one copy share this monotonic deadline.
struct ClipboardReadDeadline: Sendable {
    static let budget: Duration = .seconds(10)
    let instant: ContinuousClock.Instant
    let sleep: @Sendable (ContinuousClock.Instant) async throws -> Void

    init(instant: ContinuousClock.Instant = .now + Self.budget,
         sleep: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void = {
             try await ContinuousClock().sleep(until: $0)
         }) {
        self.instant = instant
        self.sleep = sleep
    }

    func check() throws(ClipboardReadStop) {
        if Task.isCancelled { throw .cancelled }
        if ContinuousClock.now >= instant { throw .timedOut }
    }
}

/// A single callback adapter. Provider code, Progress cancellation and
/// continuation resumption all run outside the lock.
final class ClipboardProviderRead<Value: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Result<Value, ClipboardReadStop>, Never>?
        var progress: Progress?
        var callbackStarted = false
        var finished = false
        var stop: ClipboardReadStop?
    }
    private let state = Mutex(State())
    private let deadline: ClipboardReadDeadline

    init(deadline: ClipboardReadDeadline) { self.deadline = deadline }

    @MainActor
    func value(start: (ClipboardProviderRead<Value>) -> Progress) async throws(ClipboardReadStop) -> Value {
        let timer = Task.detached { [self] in
            do { try await deadline.sleep(deadline.instant) } catch { return }
            if !Task.isCancelled { finish(.failure(.timedOut)) }
        }
        defer { timer.cancel() }
        let result: Result<Value, ClipboardReadStop> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let stop = state.withLock { state -> ClipboardReadStop? in
                    if let stop = state.stop { return stop }
                    state.continuation = continuation
                    return nil
                }
                if let stop {
                    continuation.resume(returning: .failure(stop))
                } else if ContinuousClock.now >= deadline.instant {
                    finish(.failure(.timedOut))
                } else if state.withLock({ !$0.finished }) {
                    register(start(self))
                }
            }
        } onCancel: {
            finish(.failure(.cancelled))
        }
        return try result.get()
    }

    /// Reserve callback processing once. A stop can still win while the
    /// callback is consuming its temporary file.
    func complete(_ read: () -> Value) {
        let claimed = state.withLock { state in
            guard !state.finished, !state.callbackStarted else { return false }
            state.callbackStarted = true
            return true
        }
        guard claimed else { return }
        guard ContinuousClock.now < deadline.instant else { return finish(.failure(.timedOut)) }
        let value = read()
        finish(ContinuousClock.now < deadline.instant ? .success(value) : .failure(.timedOut))
    }

    private func register(_ progress: Progress) {
        let abandoned = state.withLock { state in
            if state.finished { return state.stop != nil }
            state.progress = progress
            return false
        }
        if abandoned { cancel(progress) }
    }

    private func finish(_ result: Result<Value, ClipboardReadStop>) {
        let (continuation, progress) = state.withLock { state -> (CheckedContinuation<Result<Value, ClipboardReadStop>, Never>?, Progress?) in
            guard !state.finished else { return (nil, nil) }
            state.finished = true
            if case .failure(let stop) = result { state.stop = stop }
            let continuation = state.continuation
            let progress = state.progress
            state.continuation = nil
            state.progress = nil
            return (continuation, progress)
        }
        continuation?.resume(returning: result)
        if case .failure = result, let progress { cancel(progress) }
    }

    private func cancel(_ progress: Progress) {
        // Cancellation handlers belong to the provider. Logical completion
        // and the main actor must be able to proceed while they run.
        DispatchQueue.global().async { progress.cancel() }
    }
}
