// Vicinia — TCP control channel (Network.framework) with bounded, deadline-
// based reads. Exactly one receive is outstanding; the next is issued only
// after the previous chunk has been appended, so byte order is preserved.
// SPDX-License-Identifier: MIT

import Foundation
import Network

enum ChannelError: Error, Equatable, CustomStringConvertible {
    case closed(String)
    case timeout(String)
    case overflow

    var description: String {
        switch self {
        case .closed(let w): "connection closed (\(w))"
        case .timeout(let w): "timed out waiting for \(w)"
        case .overflow: "control receive buffer limit exceeded"
        }
    }
}

actor ControlChannel {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "it.danielebufarini.vicinia.control")
    private var buffer: [UInt8] = []
    private var head = 0
    private var closedReason: String?
    private var waiter: (id: Int, continuation: CheckedContinuation<Void, Never>)?
    private var nextWaiterID = 0
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private(set) var lastStateDescription = "setup"
    static let maxBuffered = 16 << 20

    init(host: String, port: UInt16) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 10
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 5900,
                                  using: NWParameters(tls: nil, tcp: tcp))
    }

    /// Wraps an already-created connection (e.g. one accepted by a listener).
    init(connection: NWConnection) {
        self.connection = connection
    }

    var available: Int { buffer.count - head }

    /// Connects; `.waiting` (e.g. pending Local Network permission) keeps waiting until `timeout`.
    func open(timeout: Duration) async throws {
        connection.stateUpdateHandler = { [weak self] state in
            Task { await self?.stateChanged(state) }
        }
        connection.start(queue: queue)
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.failReady(ChannelError.timeout("TCP connection"))
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            if closedReason != nil { c.resume(throwing: ChannelError.closed(closedReason!)) } else { readyContinuation = c }
        }
        pump()
    }

    private func stateChanged(_ state: NWConnection.State) {
        lastStateDescription = "\(state)"
        switch state {
        case .ready:
            readyContinuation?.resume(); readyContinuation = nil
        case .failed(let e):
            markClosed("failed: \(e)")
        case .cancelled:
            markClosed("cancelled")
        default:
            break
        }
    }

    private func failReady(_ error: Error) {
        guard let c = readyContinuation else { return }
        readyContinuation = nil
        c.resume(throwing: error)
        connection.cancel()
    }

    private func markClosed(_ reason: String) {
        if closedReason == nil { closedReason = reason }
        if let c = readyContinuation { readyContinuation = nil; c.resume(throwing: ChannelError.closed(reason)) }
        wake()
    }

    private nonisolated func pumpReceive(_ deliver: @escaping @Sendable (Data?, Bool, NWError?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            deliver(data, complete, error)
        }
    }

    private func pump() {
        guard closedReason == nil else { return }
        pumpReceive { [weak self] data, complete, error in
            Task { await self?.received(data, complete: complete, error: error) }
        }
    }

    private func received(_ data: Data?, complete: Bool, error: NWError?) {
        if let data, !data.isEmpty {
            if head > 65536 { buffer.removeFirst(head); head = 0 }
            buffer += data
            if buffer.count - head > Self.maxBuffered { markClosed("buffer overflow"); connection.cancel(); return }
        }
        if let error { markClosed("receive error: \(error)"); return }
        if complete { markClosed("peer closed"); return }
        wake()
        pump()
    }

    private func wake() {
        if let w = waiter { waiter = nil; w.continuation.resume() }
    }

    /// Suspends until new bytes arrive, the connection closes, or `deadline`.
    private func waitForData(until deadline: ContinuousClock.Instant) async {
        guard closedReason == nil, ContinuousClock.now < deadline else { return }
        nextWaiterID += 1
        let id = nextWaiterID
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiter = (id, c)
            Task { [weak self] in
                try? await Task.sleep(until: deadline, clock: .continuous)
                await self?.expire(id)
            }
        }
    }

    private func expire(_ id: Int) {
        if let w = waiter, w.id == id { waiter = nil; w.continuation.resume() }
    }

    func read(_ n: Int, timeout: Duration, _ what: String) async throws -> [UInt8] {
        let deadline = ContinuousClock.now + timeout
        while available < n {
            if let r = closedReason { throw ChannelError.closed(r) }
            if ContinuousClock.now >= deadline { throw ChannelError.timeout(what) }
            await waitForData(until: deadline)
        }
        defer { head += n }
        return Array(buffer[head ..< head + n])
    }

    /// Returns the next `n` bytes without consuming them, or nil if they don't arrive in time.
    func peek(_ n: Int, timeout: Duration) async throws -> [UInt8]? {
        let deadline = ContinuousClock.now + timeout
        while available < n {
            if let r = closedReason { throw ChannelError.closed(r) }
            if ContinuousClock.now >= deadline { return nil }
            await waitForData(until: deadline)
        }
        return Array(buffer[head ..< head + n])
    }

    /// Waits until at least one byte is buffered (or `timeout`); returns whether data is available.
    func awaitData(timeout: Duration) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while available == 0 {
            if let r = closedReason { throw ChannelError.closed(r) }
            if ContinuousClock.now >= deadline { return false }
            await waitForData(until: deadline)
        }
        return true
    }

    /// Waits up to `timeout` for data, then consumes and returns at most `max` buffered bytes.
    func readAvailable(max: Int, timeout: Duration) async throws -> [UInt8] {
        let deadline = ContinuousClock.now + timeout
        while available < max, closedReason == nil, ContinuousClock.now < deadline { await waitForData(until: deadline) }
        let n = min(max, available)
        defer { head += n }
        return Array(buffer[head ..< head + n])
    }

    /// Test seam, never set by the app: awaited before every send so
    /// a session test can hold one control write in flight deterministically.
    private var sendGate: (@Sendable () async -> Void)?
    func gateSends(_ gate: @escaping @Sendable () async -> Void) { sendGate = gate }

    func send(_ bytes: [UInt8]) async throws {
        if let sendGate { await sendGate() }
        if let r = closedReason { throw ChannelError.closed(r) }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error { c.resume(throwing: ChannelError.closed("send: \(error)")) } else { c.resume() }
            })
        }
    }

    func close() {
        markClosed("closed locally")
        connection.cancel()
    }
}
