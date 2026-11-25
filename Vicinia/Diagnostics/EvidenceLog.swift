// Vicinia — minimal evidence log (facts + counters), redacted by construction:
// it only ever receives geometry, formats, statuses and timings.
// SPDX-License-Identifier: MIT
//
// Measurement validity: formatting, sorting, serialization and
// file I/O never run on the main run loop or the media queue while streaming.
// Producers hand over value snapshots with `deferred`; everything expensive
// happens on this log's own utility queue.

import Foundation
import Synchronization

final class EvidenceLog: Sendable {
    private let facts = Mutex([String: String]())
    private let recordsFacts: Bool

    static var measurementEnabled: Bool {
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        true
        #else
        false
        #endif
    }

    /// In-memory facts for fixtures; the standard app shares a disabled log.
    init(recordsFacts: Bool = true) {
        self.recordsFacts = recordsFacts
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        output = nil
        #endif
    }

    static let disabled = EvidenceLog(recordsFacts: false)

    #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
    struct Output: Sendable {
        let fileURL: URL
        let traceURL: URL
        let queue = DispatchQueue(label: "it.danielebufarini.vicinia.evidence", qos: .utility)
    }
    let output: Output?

    init(name: String, directory: URL = .documentsDirectory) {
        recordsFacts = true
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        output = Output(fileURL: directory.appending(path: "evidence-\(name)-\(stamp).json"),
                        traceURL: directory.appending(path: "evidence-\(name)-\(stamp).trace.csv"))
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        set("device.machine", machine)
        set("device.os", ProcessInfo.processInfo.operatingSystemVersionString)
        set("evidence.started", ISO8601DateFormatter().string(from: Date()))
        #if DEBUG
        set("build.configuration", "Debug")
        #else
        set("build.configuration", "Release")
        #endif
    }

    #endif

    func set(_ key: @autoclosure () -> String, _ value: @autoclosure () -> String) {
        guard recordsFacts else { return }
        let k = key(), v = value()
        facts.withLock { $0[k] = v }
    }

    func set(_ values: @autoclosure () -> [String: String]) {
        guard recordsFacts else { return }
        let values = values()
        facts.withLock { f in for (k, v) in values { f[k] = v } }
    }

    func value(_ key: String) -> String? { facts.withLock { $0[key] } }

    #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
    /// Runs `body` on the evidence queue, in call order with every write.
    func deferred(_ body: @escaping @Sendable (EvidenceLog) -> Void) {
        output?.queue.async { body(self) }
    }

    /// Appends raw trace lines. Evidence queue only (call inside `deferred`).
    func appendTrace(_ lines: [String]) {
        guard let output, !lines.isEmpty else { return }
        dispatchPrecondition(condition: .onQueue(output.queue))
        let traceURL = output.traceURL
        let fm = FileManager.default
        if !fm.fileExists(atPath: traceURL.path()) {
            fm.createFile(atPath: traceURL.path(), contents: Data((UpdateRecord.csvHeader + "\n").utf8))
        }
        guard let handle = try? FileHandle(forWritingTo: traceURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    /// Serializes and writes the facts. Evidence queue only.
    func write() {
        guard let output else { return }
        dispatchPrecondition(condition: .onQueue(output.queue))
        set("evidence.written", ISO8601DateFormatter().string(from: Date()))
        set("device.thermalState", "\(ProcessInfo.processInfo.thermalState.rawValue)")
        let snapshot = facts.withLock { $0 }
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: output.fileURL, options: .atomic)
    }
    #endif
}

func ms(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "n/a" }

/// Nearest-rank summary "N=… median=… p95=… p99=… max=…".
func distribution(_ xs: [Double]) -> String {
    guard !xs.isEmpty else { return "N=0" }
    let s = xs.sorted()
    func rank(_ p: Double) -> Double { s[max(0, min(s.count - 1, Int((p / 100 * Double(s.count)).rounded(.up)) - 1))] }
    return "N=\(s.count) median=\(ms(rank(50))) p95=\(ms(rank(95))) p99=\(ms(rank(99))) max=\(ms(s.last))"
}
