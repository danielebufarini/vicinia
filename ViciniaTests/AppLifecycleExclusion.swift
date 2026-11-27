// Vicinia tests — suites run in parallel in one process, and a few tests post
// app lifecycle notifications process-wide. A live session without a window
// scene observes exactly those (the controller's fallback), so it would be
// sent to the background or deactivated by another suite's test. Tests that
// post them and suites whose sessions depend on them never overlap.
// SPDX-License-Identifier: MIT

import Testing

/// FIFO mutual exclusion across suites, held for one test case at a time.
actor AppLifecycleLock {
    static let shared = AppLifecycleLock()
    private var held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func run(_ body: @Sendable () async throws -> Void) async throws {
        if held { await withCheckedContinuation { waiting.append($0) } } else { held = true }
        defer { if waiting.isEmpty { held = false } else { waiting.removeFirst().resume() } }   // handed over, still held
        try await body()
    }
}

/// Applied to a suite, every test case in it takes the lock; applied to a test, that test does.
struct AppLifecycleExclusive: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        guard testCase != nil else { return try await function() }   // the suite itself: its test cases lock
        try await AppLifecycleLock.shared.run(function)
    }
}

extension Trait where Self == AppLifecycleExclusive {
    /// Posts, or depends on not receiving, process-wide app lifecycle notifications.
    static var appLifecycleExclusive: Self { Self() }
}
