// Vicinia — coherent desktop updates from decoded stripes, and render statistics.
// SPDX-License-Identifier: MIT
//
// Update-completeness rule: all stripes of one desktop update carry the same
// RTP timestamp; the host is done with an update when its last stripe index
// arrived, a newer timestamp started, or no further stripe came for 5 ms.
// Membership is taken at decoder submission, in global decode (DONL) order,
// and the 5 ms rule waits
// while a stripe of that timestamp is still being received (MediaPipeline); an
// update is committed only when its membership is final and every member was
// decoded, strictly in submission order; a lost/failed member discards it (no
// mixed-epoch desktop). Partial updates keep the previous valid content of the
// stripes they do not carry.

import Foundation
import Synchronization

/// How decoded stripe pictures are placed on the desktop canvas.
struct StripeLayout: Sendable, Equatable {
    enum Rule: String, Sendable {
        /// Crop each picture by the SPS conformance window; stack visible heights.
        case conformanceWindow
        /// Stack coded picture heights; clip the canvas bottom (fork renderer rule).
        case codedStack
    }
    var rule: Rule
    var stripeCount: Int
    var canvasWidth: Int
    var canvasHeight: Int
    var pictureWidth: Int        // coded / buffer width
    var pictureHeight: Int       // coded / buffer height
    var cropTop: Int
    var visibleHeight: Int
    var geometry: DesktopGeometry? = nil
    var offerID: UInt64 = 0

    var desktopGeometry: DesktopGeometry {
        geometry ?? DesktopGeometry(logical: CGRect(x: 0, y: 0, width: Double(canvasWidth) / 2, height: Double(canvasHeight) / 2),
                                    backing: CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
    }

    /// Source rows [top, top+rows) of the stripe picture and destination row.
    func placement(stripe i: Int) -> (srcTop: Int, rows: Int, dstY: Int) {
        switch rule {
        case .conformanceWindow:
            let y = i * visibleHeight
            return (cropTop, max(0, min(visibleHeight, canvasHeight - y)), y)
        case .codedStack:
            let y = i * pictureHeight
            return (0, max(0, min(pictureHeight, canvasHeight - y)), y)
        }
    }

    var summary: String {
        "rule=\(rule.rawValue) stripes=\(stripeCount) canvas=\(canvasWidth)x\(canvasHeight) "
            + "picture=\(pictureWidth)x\(pictureHeight) cropTop=\(cropTop) visibleHeight=\(visibleHeight)"
    }
}

/// One coherent desktop: the latest valid picture per stripe.
struct DesktopSnapshot: Sendable {
    let updateSequence: UInt64
    let rtpTimestamp: UInt32
    let generation: UInt64
    let layout: StripeLayout
    let stripes: [DecodedStripe?]
    let changedStripes: [Int]
    let newestSubmitNanos: UInt64
    /// Measurement record of this update; the renderer completes and returns it.
    var timing = UpdateRecord()
}

/// Raw measurement record of one desktop update: what it
/// contained, how its membership became final, when each stage happened and
/// how it ended. Every update submitted to the decoder ends in exactly one
/// record, so `source = presented + each loss category` can be reconciled.
/// Times are `DispatchTime` uptime nanoseconds (0 = stage not reached).
struct UpdateRecord: Sendable, Equatable {
    enum Finality: String, Sendable { case open = "-", lastStripe = "L", newerTimestamp = "N", settled = "S" }
    enum Outcome: String, Sendable {
        case presented = "P"            // new coherent desktop actually presented
        case repeated = "R"             // split commit of the update shown last: presented, not a new desktop
        case supersededInMailbox = "M"  // committed, replaced by a newer commit before a display tick took it
        case replacedWaiting = "W"      // taken by the renderer, replaced by a newer one before it was drawn
        case noPresentedTime = "Z"      // drawn, but the system reported no presentation
        case obsolete = "O"             // taken, then invalidated by a loss or a stream reset
        case abandoned = "A"            // a member was lost or failed: never coherent, never presented
        case voided = "V"               // pending or committed when the stream was reset
        case coverageWait = "C"         // applied, but the generation has no complete desktop yet
        case lateOnly = "T"             // carried only pictures older than the content already shown
    }
    var outcome = Outcome.voided
    var generation: UInt64 = 0
    var rtpTimestamp: UInt32 = 0
    var sequence: UInt64 = 0            // commit sequence; 0 = never published
    var members: UInt8 = 0              // bit i = stripe i was part of the update
    var finality = Finality.open
    var split = false
    var arrival: UInt64 = 0             // first packet of its earliest member
    var firstSubmit: UInt64 = 0, lastSubmit: UInt64 = 0, lastDecoded: UInt64 = 0
    var final: UInt64 = 0, commit: UInt64 = 0, take: UInt64 = 0, draw: UInt64 = 0, presented: UInt64 = 0
    var target: UInt64 = 0              // display link's target presentation time of the drawn frame
    var probe = -1                      // luma of the scripted probe pixel in the drawn desktop (-1: no probe)

    static let csvHeader = "kind,outcome,generation,rtpTimestamp,sequence,members,finality,split,"
        + "arrival,firstSubmit,lastSubmit,lastDecoded,final,commit,take,draw,presented,target,probe"
    var csv: String {
        "U,\(outcome.rawValue),\(generation),\(rtpTimestamp),\(sequence),\(members),\(finality.rawValue),\(split ? 1 : 0),"
            + "\(arrival),\(firstSubmit),\(lastSubmit),\(lastDecoded),\(final),\(commit),\(take),\(draw),\(presented),\(target),\(probe)"
    }
}

/// One drawn local-cursor movement. `event`: UIKit timestamp (seconds,
/// uptime) of the OLDEST movement not yet drawn when the frame was drawn —
/// conservative when several movements share a frame; `moves`: movements
/// merged into the frame (the newest position is drawn, the older ones are
/// superseded and never shown); `handled`: when the app received that oldest
/// movement; `draw`: when the frame was drawn; `presented`: the drawable's
/// actual presentation time. Trace row `C`: outcome = L (drawn after pending
/// input, `DesktopRenderer.lateDrawNanos`) or T (drawn in the display-link
/// callback), members = moves, arrival = event, firstSubmit = handled.
struct CursorSample: Sendable, Equatable {
    var event: Double, handled: UInt64, draw: UInt64, presented: Double
    var moves = 1, late = false
    var csv: String {
        "C,\(late ? "L" : "T"),,,,\(moves),,,\(UInt64(event * 1e9)),\(handled),,,,,,\(draw),\(UInt64(presented * 1e9)),,"
    }
}

struct DesktopPresentation: Sendable {
    let generation: UInt64
    let offerID: UInt64
    let geometry: DesktopGeometry
    let nanos: UInt64
}

/// Desktop updates in decode order. Media queue: `noteSubmitted`, `noteFinal`,
/// `noteAbandoned`, `reset`; VideoToolbox threads: `deliver`, `noteFailed`;
/// display link: `take`. Short lock only; never blocks either side. Holds one
/// committed desktop plus the bounded updates still being decoded.
final class DesktopUpdateMailbox: Sendable {
    /// The stripe pictures submitted with one RTP timestamp.
    private struct Update {
        let timestamp: UInt32
        var members: Set<Int>
        var decoded: [Int: DecodedStripe] = [:]
        /// No further stripe can join: its last index or a newer timestamp was
        /// submitted, or it settled with nothing of it still arriving.
        var finality = UpdateRecord.Finality.open
        var finalNanos: UInt64 = 0
        var final: Bool { finality != .open }
        var resolved: Bool { decoded.count == members.count }
        mutating func finalize(_ how: UpdateRecord.Finality, _ now: UInt64) {
            if !final { finality = how; finalNanos = now }
        }
    }

    struct Counters: Sendable {
        var committedUnique = 0         // coherent updates committed, one per RTP timestamp
        var committedPartial = 0        // … carrying fewer than all stripes (legitimate partial updates)
        var splitCommits = 0            // the same timestamp committed again (member arrived after it settled)
        var discardedIncomplete = 0     // a member lost/failed or the update abandoned: never presented
        var orphanedStripes = 0         // decoded picture of an abandoned/unknown update: not applied
        var lateStripes = 0             // not newer than the stripe content already committed: not applied
        var supersededUnpresented = 0
        var staleGenerationDrops = 0
        var failedStripes = 0
        var initialCoverageWaits = 0
        var voidedByReset = 0           // pending or untaken committed updates dropped by a stream reset
        var pendingUpdatesMax = 0       // deepest queue of updates still being decoded
        var heldForPacing = 0           // display ticks that left a just-committed desktop for the next refresh
        var recordsDropped = 0          // measurement records beyond the undrained bound
    }

    private struct State {
        var generation: UInt64 = 0
        var layout: StripeLayout?
        var current: [DecodedStripe?] = []
        var updates: [Update] = []                // submission (= decode) order
        var committed: DesktopSnapshot?
        var sequence: UInt64 = 0
        var lastTaken: UInt64 = 0
        var lastCommittedTimestamp: UInt32?
        var abandoned: Set<UInt32> = []
        var abandonedOrder: [UInt32] = []
        var counters = Counters()
        let recordsUpdates: Bool
        var records: [UpdateRecord] = []
        /// When a desktop was last actually presented, and whether the display
        /// side is expected to present at all (false while the app is not active).
        var lastPresented: UInt64 = 0
        var displayActive = true
    }
    private let state: Mutex<State>
    static let maxUpdates = 16
    static let maxUndrainedRecords = 100_000
    static var uptime: UInt64 { DispatchTime.now().uptimeNanoseconds }

    init(recordsUpdates: Bool = false) {
        state = Mutex(State(recordsUpdates: recordsUpdates))
    }

    /// Starts a media/display generation (`layout` nil: no stream). Callbacks,
    /// updates and an untaken committed desktop of older generations are void.
    func reset(generation: UInt64, layout: StripeLayout?) {
        state.withLock { s in
            let oldGeneration = s.generation
            for u in s.updates {
                Self.note(Self.record(u, oldGeneration), .voided, &s)
                s.counters.voidedByReset += 1
            }
            if let c = s.committed, c.updateSequence > s.lastTaken {
                Self.note(c.timing, .voided, &s); s.counters.voidedByReset += 1
            }
            s.generation = generation
            s.layout = layout
            s.current = Array(repeating: nil, count: layout?.stripeCount ?? 0)
            s.updates = []
            s.committed = nil
            s.lastCommittedTimestamp = nil
            s.abandoned = []; s.abandonedOrder = []
        }
    }

    func isCurrent(generation: UInt64) -> Bool {
        state.withLock { $0.layout != nil && $0.generation == generation }
    }

    /// A snapshot can already have left the mailbox when a late loss invalidates
    /// one of its regions. Generation identity alone is then insufficient.
    func isCurrent(_ snapshot: DesktopSnapshot) -> Bool {
        state.withLock { s in
            s.layout != nil && s.generation == snapshot.generation
                && !snapshot.stripes.contains { stripe in
                    stripe.map { s.abandoned.contains($0.rtpTimestamp) } ?? false
                }
        }
    }

    /// Media queue, in decode order: `stripe` of update `ts` went to the decoder.
    func noteSubmitted(stripe: Int, rtpTimestamp ts: UInt32, generation: UInt64, now: UInt64 = uptime) {
        state.withLock { s in
            guard generation == s.generation, let layout = s.layout,
                  stripe >= 0, stripe < layout.stripeCount, !s.abandoned.contains(ts) else { return }
            if let i = s.updates.indices.last, s.updates[i].timestamp == ts, !s.updates[i].final {
                s.updates[i].members.insert(stripe)
            } else {
                if let i = s.updates.indices.last { s.updates[i].finalize(.newerTimestamp, now) }
                s.updates.append(Update(timestamp: ts, members: [stripe]))
                s.counters.pendingUpdatesMax = max(s.counters.pendingUpdatesMax, s.updates.count)
                if s.updates.count > Self.maxUpdates, let oldest = s.updates.first { Self.abandon(oldest.timestamp, &s) }
            }
            if stripe == layout.stripeCount - 1 { s.updates[s.updates.count - 1].finalize(.lastStripe, now) }
            Self.drain(&s, now)
        }
    }

    /// Media queue: the update settled (no stripe of it submitted or arriving for 5 ms).
    func noteFinal(rtpTimestamp ts: UInt32, generation: UInt64, now: UInt64 = uptime) {
        state.withLock { s in
            guard generation == s.generation,
                  let i = s.updates.lastIndex(where: { $0.timestamp == ts && !$0.final }) else { return }
            s.updates[i].finalize(.settled, now)
            Self.drain(&s, now)
        }
    }

    /// A lost picture invalidates ITS desktop update, even when it has not been
    /// submitted yet or a newer update is open. Remember the timestamp so late
    /// members/callbacks cannot resurrect it (bounded to the assembly horizon).
    func noteAbandoned(rtpTimestamp ts: UInt32, generation: UInt64) {
        state.withLock { s in
            guard generation == s.generation else { return }
            Self.abandon(ts, &s)
            Self.drain(&s, Self.uptime)
        }
    }

    func noteFailed(stripe: Int, rtpTimestamp ts: UInt32, generation: UInt64) {
        state.withLock { s in
            guard generation == s.generation else { return }
            s.counters.failedStripes += 1
            Self.abandon(ts, &s)
            Self.drain(&s, Self.uptime)
        }
    }

    func deliver(_ d: DecodedStripe) {
        state.withLock { s in
            guard d.generation == s.generation, let layout = s.layout, d.stripe >= 0, d.stripe < layout.stripeCount else {
                s.counters.staleGenerationDrops += 1
                return
            }
            guard let i = s.updates.firstIndex(where: {
                $0.timestamp == d.rtpTimestamp && $0.members.contains(d.stripe)
                    && $0.decoded[d.stripe] == nil
            }) else {
                s.counters.orphanedStripes += 1
                return
            }
            s.updates[i].decoded[d.stripe] = d
            Self.drain(&s, Self.uptime)
        }
    }

    /// Returns a new coherent desktop if one is ready (display-link side). A
    /// desktop committed after `limit` stays for the next tick (`PresentationPacing`).
    func take(committedBy limit: UInt64 = .max) -> DesktopSnapshot? {
        state.withLock { s in
            guard let c = s.committed, c.updateSequence > s.lastTaken else { return nil }
            guard c.timing.commit <= limit else { s.counters.heldForPacing += 1; return nil }
            s.lastTaken = c.updateSequence
            return c
        }
    }

    var counters: Counters { state.withLock { $0.counters } }

    /// The renderer reports how a snapshot it took ended.
    func note(_ record: UpdateRecord, _ outcome: UpdateRecord.Outcome) {
        state.withLock { Self.note(record, outcome, &$0) }
    }

    /// Hands the finished measurement records to the evidence writer.
    func drainRecords() -> [UpdateRecord] {
        state.withLock { s in
            let out = s.records
            s.records = []
            return out
        }
    }

    /// Video progress as seen by the display side (media-stall check).
    var presentationProgress: (last: UInt64, displayActive: Bool) {
        state.withLock { ($0.lastPresented, $0.displayActive) }
    }
    func setDisplayActive(_ active: Bool) { state.withLock { $0.displayActive = active } }

    private static func note(_ record: @autoclosure () -> UpdateRecord, _ outcome: UpdateRecord.Outcome, _ s: inout State) {
        if outcome == .presented || outcome == .repeated { s.lastPresented = uptime }
        guard s.recordsUpdates else { return }
        guard s.records.count < maxUndrainedRecords else { s.counters.recordsDropped += 1; return }
        var r = record()
        r.outcome = outcome
        s.records.append(r)
    }

    private static func record(_ u: Update, _ generation: UInt64) -> UpdateRecord {
        var r = UpdateRecord()
        r.generation = generation
        r.rtpTimestamp = u.timestamp
        r.members = u.members.reduce(0) { $0 | (1 << UInt8($1 & 7)) }
        r.finality = u.finality
        r.final = u.finalNanos
        for d in u.decoded.values {
            if d.arrivalNanos > 0, r.arrival == 0 || d.arrivalNanos < r.arrival { r.arrival = d.arrivalNanos }
            if r.firstSubmit == 0 || d.submitNanos < r.firstSubmit { r.firstSubmit = d.submitNanos }
            r.lastSubmit = max(r.lastSubmit, d.submitNanos)
            r.lastDecoded = max(r.lastDecoded, d.decodedNanos)
        }
        return r
    }

    private static func abandon(_ ts: UInt32, _ s: inout State) {
        if s.abandoned.insert(ts).inserted {
            s.abandonedOrder.append(ts)
            if s.abandonedOrder.count > 1024 { s.abandoned.remove(s.abandonedOrder.removeFirst()) }
            s.counters.discardedIncomplete += 1
            // One record per lost update; members 0 = lost before any stripe was submitted.
            if s.recordsUpdates {
                var r = UpdateRecord()
                r.generation = s.generation
                r.rtpTimestamp = ts
                for u in s.updates where u.timestamp == ts { r = record(u, s.generation) }
                note(r, .abandoned, &s)
            }
        }
        s.updates.removeAll { $0.timestamp == ts }
        for i in s.current.indices where s.current[i]?.rtpTimestamp == ts { s.current[i] = nil }
        if let c = s.committed, c.stripes.contains(where: { $0?.rtpTimestamp == ts }) {
            if c.updateSequence > s.lastTaken { note(c.timing, .obsolete, &s) }   // committed, untaken, now invalid
            s.committed = nil
        }
    }

    /// Commits finished updates strictly in decode order.
    private static func drain(_ s: inout State, _ now: UInt64) {
        while let head = s.updates.first, head.final, head.resolved {
            s.updates.removeFirst()
            if !head.decoded.isEmpty { commit(head, &s, now) }
        }
    }

    private static func commit(_ u: Update, _ s: inout State, _ now: UInt64) {
        guard let layout = s.layout else { return }
        var timing = s.recordsUpdates ? record(u, s.generation) : UpdateRecord()
        timing.commit = now
        var applied: [Int] = []
        for (i, d) in u.decoded.sorted(by: { $0.key < $1.key }) {
            if let shown = s.current[i], !HEVCAssembler.timestampNewer(d.rtpTimestamp, than: shown.rtpTimestamp) {
                s.counters.lateStripes += 1             // never replace newer content with an older picture
                continue
            }
            s.current[i] = d
            applied.append(i)
        }
        guard !applied.isEmpty else { note(timing, .lateOnly, &s); return }
        // Partial updates may reuse valid regions ONLY within this generation.
        // A last-index/settled initial update is not a usable desktop until all
        // visible regions have actually been decoded. Keep the previous display
        // in the renderer until this barrier is satisfied.
        guard s.current.indices.allSatisfy({ layout.placement(stripe: $0).rows == 0 || s.current[$0] != nil }) else {
            s.counters.initialCoverageWaits += 1
            note(timing, .coverageWait, &s)
            return
        }
        timing.split = s.lastCommittedTimestamp == u.timestamp
        if timing.split { s.counters.splitCommits += 1 } else {
            s.counters.committedUnique += 1
            if u.members.count < layout.stripeCount { s.counters.committedPartial += 1 }
        }
        s.lastCommittedTimestamp = u.timestamp
        if let c = s.committed, c.updateSequence > s.lastTaken {
            s.counters.supersededUnpresented += 1
            note(c.timing, .supersededInMailbox, &s)
        }
        s.sequence += 1
        timing.sequence = s.sequence
        s.committed = DesktopSnapshot(
            updateSequence: s.sequence, rtpTimestamp: u.timestamp, generation: s.generation, layout: layout,
            stripes: s.current, changedStripes: applied,
            newestSubmitNanos: timing.lastSubmit, timing: timing)
    }
}

/// Presentation pacing (measured). A 60 Hz source on a 120 Hz display
/// is shown every second refresh; its commits jitter by a few milliseconds, so
/// while their phase lies on a refresh boundary some just make a tick and some
/// just miss it: pairs of 3-refresh and 1-refresh intervals. Rule: a desktop
/// committed less than `holdNanos` before the tick is left for the next
/// refresh when the previous new desktop went out on the refresh just before —
/// the cadence then stays on the later refresh instead of alternating. Costs
/// such an update at most one refresh, never more; inactive at 60 Hz ticks.
enum PresentationPacing {
    static let holdNanos: UInt64 = 2_000_000
    /// Targets closer than this are adjacent 120 Hz refreshes (8.3 ms; a 60 Hz tick is 16.7 ms).
    static let adjacentRefresh: Double = 0.0125

    /// Latest commit time the tick presenting at `target` may take.
    static func commitLimit(now: UInt64, target: Double, lastNewTarget: Double) -> UInt64 {
        lastNewTarget > 0 && target > lastNewTarget && target - lastNewTarget < adjacentRefresh ? now &- holdNanos : .max
    }
}

/// Presentation accounting. Counts only new coherent desktop updates that were
/// actually presented (drawable presented handler), never display refreshes.
final class RenderStats: Sendable {
    struct UpdateID: Equatable, Sendable {
        let generation: UInt64
        let rtpTimestamp: UInt32
    }
    struct Values: Sendable {
        var displayTicks = 0
        var skippedGPUBusy = 0
        /// Unique coherent desktop updates presented: (generation, RTP timestamp) not presented before.
        var newDesktopsPresented = 0
        /// Another presentation of the update shown last (a split commit), not a new desktop.
        var repeatedUpdatePresentations = 0
        var obsoleteSnapshotsDropped = 0
        var lastPresented: UpdateID?
        var presentationsWithoutTime = 0
        /// A taken snapshot replaced by a newer one before it could be drawn.
        var replacedWhileWaiting = 0
        var cursorDrawsWithoutTime = 0
        /// A frame deferred for pending input that was not drawn before the next display tick.
        var lateDrawsMissed = 0
        /// Samples since the last `collect()`; appended on the measured paths.
        var fresh = Samples()
    }
    struct Samples: Sendable {
        var presentedTimes: [Double] = []          // CACurrentMediaTime seconds, new desktops only
        var submitToPresentMs: [Double] = []       // decoder submit → actual presentation
        var arrivalToPresentMs: [Double] = []      // first packet of the update → actual presentation
        var refreshIntervals: [Double] = []        // display-link target intervals
        var cursor: [CursorSample] = []
        mutating func append(_ o: Samples) {
            presentedTimes += o.presentedTimes; submitToPresentMs += o.submitToPresentMs
            arrivalToPresentMs += o.arrivalToPresentMs; refreshIntervals += o.refreshIntervals; cursor += o.cursor
        }
    }
    private let values = Mutex(Values())
    /// Whole-run samples; touched only by `collect()` (evidence queue), so
    /// summarising them never contends with or copies on the measured paths.
    private let history = Mutex(Samples())
    let inFlight = Atomic<Int>(0)
    /// Bound for the undrained hot buffers and for the whole-run history.
    static let maxFresh = 20_000, maxHistory = 400_000

    func update(_ body: (inout Values) -> Void) { values.withLock { body(&$0) } }
    /// Counters only (the sample buffers are moved out, not copied, by `collect`).
    var counters: Values { values.withLock { var v = $0; v.fresh = Samples(); return v } }

    /// Moves the fresh samples into the whole-run history and returns both.
    func collect() -> (counters: Values, fresh: Samples, all: Samples) {
        var v = values.withLock { v in
            let out = v
            v.fresh = Samples()
            return out
        }
        let fresh = v.fresh
        v.fresh = Samples()
        let all = history.withLock { h in
            if h.presentedTimes.count + h.refreshIntervals.count + h.cursor.count < Self.maxHistory { h.append(fresh) }
            return h
        }
        return (v, fresh, all)
    }
}

func percentile(_ xs: [Double], _ p: Double) -> Double? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted()
    let rank = Int((p / 100 * Double(s.count)).rounded(.up))     // nearest-rank
    return s[max(0, min(s.count - 1, rank - 1))]
}
