// VCLP v1 format for recording and replaying HPSS sessions.
// SPDX-License-Identifier: MIT

import Foundation

struct HPSSClip: Sendable {
    struct Packet: Sendable {
        let tNanos: UInt64
        let bytes: Data          // plaintext RTP packet (post-SRTP)
    }
    let name: String
    let byteCount: Int
    let meta: String
    let events: [String]
    let packets: [Packet]
    let ssrcToStripe: [UInt32: Int]
    let canvas: (width: Int, height: Int)?
    let declaredStripes: Int?

    enum ClipError: Error { case format(String) }

    static func load(_ url: URL) throws -> HPSSClip {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let b = data.startIndex
        guard data.count >= 6, data[b ..< b + 4] == Data("VCLP".utf8) else { throw ClipError.format("magic") }
        guard data[b + 4] == 0, data[b + 5] == 1 else { throw ClipError.format("version") }
        var pos = b + 6
        var meta = "", events: [String] = [], packets: [Packet] = []
        while pos < data.endIndex {
            guard data.endIndex - pos >= 5 else { throw ClipError.format("truncated record header") }
            let kind = data[pos]
            let len = data[pos + 1 ..< pos + 5].reduce(0) { $0 << 8 | Int($1) }
            pos += 5
            guard len <= 4 << 20, data.endIndex - pos >= len else { throw ClipError.format("record length") }
            let body = data[pos ..< pos + len]
            pos += len
            switch kind {
            case 0: meta = String(decoding: body, as: UTF8.self)
            case 1:
                guard body.count >= 8 + 12 else { throw ClipError.format("rtp record") }
                let t = body.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                packets.append(Packet(tNanos: t, bytes: body.dropFirst(8)))
            case 2: events.append(String(decoding: body, as: UTF8.self))
            default: throw ClipError.format("record kind \(kind)")
            }
        }
        var map: [UInt32: Int] = [:]
        var canvas: (Int, Int)?
        var tiles: Int?
        for e in events {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(e.utf8)) as? [String: Any],
                  obj["event"] as? String == "session" else { continue }
            for (k, v) in obj["ssrc_to_tile"] as? [String: Int] ?? [:] {
                if let s = UInt32(k) { map[s] = v }
            }
            if let c = obj["canvas"] as? [Int], c.count == 2, c[0] > 0, c[1] > 0 { canvas = (c[0], c[1]) }
            tiles = obj["canvas_tiles"] as? Int
            break                                   // first session of the clip
        }
        guard !map.isEmpty, Set(map.values) == Set(0..<map.count) else {
            throw ClipError.format("no usable session/SSRC map event")
        }
        return HPSSClip(name: url.lastPathComponent, byteCount: data.count, meta: meta, events: events,
                        packets: packets, ssrcToStripe: map, canvas: canvas, declaredStripes: tiles)
    }

    var durationSeconds: Double {
        guard let f = packets.first, let l = packets.last else { return 0 }
        return Double(l.tNanos - f.tNanos) / 1e9
    }
}

/// Replays a clip's packets into the pipeline at their recorded arrival times.
/// Invariant (why @unchecked Sendable is sound): mutable state is touched only
/// on `pipeline.queue`.
final class ClipReplayer: @unchecked Sendable {
    let clip: HPSSClip
    let pipeline: MediaPipeline
    private var index = 0
    private var offset: UInt64 = 0
    private var running = false
    private var passes = 0
    let loop: Bool

    init(clip: HPSSClip, pipeline: MediaPipeline, loop: Bool) {
        self.clip = clip
        self.pipeline = pipeline
        self.loop = loop
    }

    func start() {
        pipeline.queue.async { [self] in
            running = true
            begin()
        }
    }

    func stop(then done: @escaping @Sendable () -> Void) {
        pipeline.queue.async { [self] in
            running = false
            pipeline.resetStream()
            pipeline.publishEvidence()
            done()
        }
    }

    private func begin() {
        passes += 1
        index = 0
        pipeline.resetStream()
        offset = DispatchTime.now().uptimeNanoseconds &- (clip.packets.first?.tNanos ?? 0)
        pump()
    }

    private func pump() {
        guard running else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        while index < clip.packets.count, clip.packets[index].tNanos &+ offset <= now {
            pipeline.ingest(clip.packets[index].bytes, arrival: now)
            index += 1
        }
        guard index < clip.packets.count else {
            pipeline.poll(now: now &+ 1_000_000_000)          // flush trailing gap waits
            pipeline.publishEvidence()
            if loop { begin() } else { running = false }
            return
        }
        let next = DispatchTime(uptimeNanoseconds: clip.packets[index].tNanos &+ offset)
        pipeline.queue.asyncAfter(deadline: min(next, .now() + .milliseconds(5))) { [weak self] in
            guard let self else { return }
            self.pipeline.poll(now: DispatchTime.now().uptimeNanoseconds)
            self.pump()
        }
    }
}
