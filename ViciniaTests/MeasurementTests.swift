// Vicinia tests — measurement records and aggregation.
// SPDX-License-Identifier: MIT

import CoreVideo
import Foundation
import Testing
@testable import Vicinia

@Suite("Measurement records")
struct MeasurementTests {
    private let layout = StripeLayout(rule: .codedStack, stripeCount: 4, canvasWidth: 64, canvasHeight: 64,
                                      pictureWidth: 64, pictureHeight: 16, cropTop: 0, visibleHeight: 16)
    private let buffer: CVPixelBuffer = {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 8, 8, kCVPixelFormatType_32BGRA, nil, &pb)
        return pb!
    }()
    private func picture(_ stripe: Int, ts: UInt32, arrival: UInt64, submit: UInt64, decoded: UInt64) -> DecodedStripe {
        DecodedStripe(pixelBuffer: buffer, stripe: stripe, rtpTimestamp: ts, generation: 1, auSequence: 0,
                      submitNanos: submit, decodedNanos: decoded, arrivalNanos: arrival)
    }
    private func mailbox() -> DesktopUpdateMailbox {
        let m = DesktopUpdateMailbox(recordsUpdates: true)
        m.reset(generation: 1, layout: layout)
        return m
    }
    /// A complete first desktop (all four stripes), taken, so later partial updates publish.
    private func prime(_ m: DesktopUpdateMailbox) {
        for s in 0..<4 { m.noteSubmitted(stripe: s, rtpTimestamp: 10, generation: 1, now: 1) }
        for s in 0..<4 { m.deliver(picture(s, ts: 10, arrival: 1, submit: 1, decoded: 2)) }
        _ = m.take()
        _ = m.drainRecords()
    }

    /// How an update became final, what it contained and when each stage
    /// happened travel with the snapshot; the three finalisation rules are distinguished.
    @Test func snapshotCarriesMembershipFinalityAndStageTimes() throws {
        let m = mailbox()
        prime(m)
        m.noteSubmitted(stripe: 0, rtpTimestamp: 100, generation: 1, now: 1_000)
        m.noteSubmitted(stripe: 1, rtpTimestamp: 100, generation: 1, now: 1_100)
        m.deliver(picture(0, ts: 100, arrival: 700, submit: 1_000, decoded: 1_400))
        m.deliver(picture(1, ts: 100, arrival: 800, submit: 1_100, decoded: 1_500))
        m.noteFinal(rtpTimestamp: 100, generation: 1, now: 6_100)                // settled, upper stripes only
        let settled = try #require(m.take()).timing
        #expect(settled.members == 0b0011 && settled.finality == .settled && !settled.split)
        #expect(settled.arrival == 700 && settled.firstSubmit == 1_000 && settled.lastSubmit == 1_100)
        #expect(settled.lastDecoded == 1_500 && settled.final == 6_100 && settled.commit == 6_100)

        m.noteSubmitted(stripe: 3, rtpTimestamp: 200, generation: 1, now: 7_000)  // last stripe index: final at once
        m.deliver(picture(3, ts: 200, arrival: 6_900, submit: 7_000, decoded: 7_300))
        let last = try #require(m.take()).timing
        #expect(last.members == 0b1000 && last.finality == .lastStripe && last.final == 7_000)

        m.noteSubmitted(stripe: 1, rtpTimestamp: 300, generation: 1, now: 8_000)
        m.deliver(picture(1, ts: 300, arrival: 7_900, submit: 8_000, decoded: 8_200))
        #expect(m.take() == nil)                                                 // might still grow
        m.noteSubmitted(stripe: 0, rtpTimestamp: 400, generation: 1, now: 9_000)  // a newer timestamp closes it
        let newer = try #require(m.take()).timing
        #expect(newer.rtpTimestamp == 300 && newer.finality == .newerTimestamp && newer.final == 9_000)
    }

    /// Pacing: a desktop that only just made the tick waits one refresh
    /// when the previous new desktop went out on the adjacent refresh, and only then.
    @Test func justCommittedDesktopWaitsOneRefreshAfterAnAdjacentPresentation() throws {
        let refresh = 1 / 119.96, now: UInt64 = 50_000_000
        let adjacent = PresentationPacing.commitLimit(now: now, target: 10 + refresh, lastNewTarget: 10)
        #expect(adjacent == now - PresentationPacing.holdNanos)
        #expect(PresentationPacing.commitLimit(now: now, target: 10 + 2 * refresh, lastNewTarget: 10) == .max)  // normal cadence
        #expect(PresentationPacing.commitLimit(now: now, target: 10 + 1.0 / 60, lastNewTarget: 10) == .max)     // 60 Hz ticks
        #expect(PresentationPacing.commitLimit(now: now, target: 10, lastNewTarget: 0) == .max)                 // nothing shown yet

        let m = mailbox()
        prime(m)
        m.noteSubmitted(stripe: 3, rtpTimestamp: 100, generation: 1, now: now - 1_000_000)
        m.deliver(picture(3, ts: 100, arrival: 1, submit: now - 1_000_000, decoded: now - 900_000))
        #expect(m.take(committedBy: 0) == nil)                                   // committed after the limit: held
        #expect(m.counters.heldForPacing == 1 && m.counters.supersededUnpresented == 0)
        #expect(m.take(committedBy: .max)?.rtpTimestamp == 100)                  // the next tick takes it, nothing lost
        #expect(m.take() == nil)
    }

    /// Every update submitted to the decoder ends in exactly one record, so
    /// source updates reconcile with presented + each loss category.
    @Test func everyUpdateEndsInExactlyOneRecord() throws {
        let m = mailbox()
        // Coverage wait: a first update that does not cover the desktop is not publishable.
        m.noteSubmitted(stripe: 3, rtpTimestamp: 5, generation: 1, now: 1)
        m.deliver(picture(3, ts: 5, arrival: 1, submit: 1, decoded: 2))
        prime(m)                                                                  // drains the coverage record too
        // 100 committed, never taken, superseded by 200 (mailbox loss).
        for ts: UInt32 in [100, 200] {
            m.noteSubmitted(stripe: 3, rtpTimestamp: ts, generation: 1, now: UInt64(ts))
            m.deliver(picture(3, ts: ts, arrival: UInt64(ts), submit: UInt64(ts), decoded: UInt64(ts) + 1))
        }
        // 200 is taken by the renderer and reported presented.
        var shown = try #require(m.take()).timing
        shown.presented = 250
        m.note(shown, .presented)
        // 300 loses a member: abandoned. 400 is pending when the stream resets: voided.
        m.noteSubmitted(stripe: 0, rtpTimestamp: 300, generation: 1, now: 300)
        m.noteAbandoned(rtpTimestamp: 300, generation: 1)
        m.noteSubmitted(stripe: 0, rtpTimestamp: 400, generation: 1, now: 400)
        m.reset(generation: 2, layout: layout)

        let records = m.drainRecords()
        #expect(records.map(\.rtpTimestamp) == [100, 200, 300, 400])
        #expect(records.map(\.outcome) == [.supersededInMailbox, .presented, .abandoned, .voided])
        #expect(records[0].sequence > 0 && records[1].sequence == records[0].sequence + 1 && records[1].presented == 250)
        #expect(records[2].sequence == 0 && records[2].members == 0b0001 && records[3].members == 0b0001)
        #expect(m.drainRecords().isEmpty)                                         // drained exactly once
        let c = m.counters
        #expect(c.supersededUnpresented == 1 && c.discardedIncomplete == 1 && c.voidedByReset == 1 && c.recordsDropped == 0)
    }

    /// A committed but untaken desktop invalidated by a later loss is recorded, not silently dropped.
    @Test func lossInvalidatingAnUntakenCommitIsRecordedAsObsolete() {
        let m = mailbox()
        prime(m)
        m.noteSubmitted(stripe: 3, rtpTimestamp: 100, generation: 1, now: 100)
        m.deliver(picture(3, ts: 100, arrival: 90, submit: 100, decoded: 110))
        m.noteAbandoned(rtpTimestamp: 100, generation: 1)
        #expect(m.take() == nil)
        let records = m.drainRecords()
        #expect(records.map(\.outcome) == [.abandoned, .obsolete] && records[1].sequence > 0)
    }

    @Test func traceRowsMatchTheHeader() {
        var r = UpdateRecord()
        r.outcome = .replacedWaiting; r.generation = 7; r.rtpTimestamp = 42; r.sequence = 3
        r.members = 0b0101; r.finality = .settled; r.split = true
        r.arrival = 1; r.firstSubmit = 2; r.lastSubmit = 3; r.lastDecoded = 4; r.final = 5; r.commit = 6; r.take = 7; r.draw = 8
        r.target = 9
        #expect(r.csv == "U,W,7,42,3,5,S,1,1,2,3,4,5,6,7,8,0,9,-1")
        let columns = UpdateRecord.csvHeader.split(separator: ",").count
        #expect(r.csv.split(separator: ",", omittingEmptySubsequences: false).count == columns)
        let cursor = CursorSample(event: 1.0, handled: 1_002_000_000, draw: 1_003_000_000, presented: 1.02, moves: 2, late: true)
        #expect(cursor.csv == "C,L,,,,2,,,1000000000,1002000000,,,,,,1003000000,1020000000,,")
        #expect(cursor.csv.split(separator: ",", omittingEmptySubsequences: false).count == columns)
    }

    /// Fresh samples move into the whole-run history exactly once; counters persist.
    @Test func renderSamplesAreDrainedIntoHistory() {
        let stats = RenderStats()
        stats.update { v in
            v.newDesktopsPresented = 2
            v.fresh.presentedTimes += [1.0, 1.5]; v.fresh.submitToPresentMs += [20, 30]; v.fresh.cursor.append(CursorSample(event: 1.0, handled: 1_002_000_000, draw: 1_003_000_000, presented: 1.01))
        }
        let first = stats.collect()
        #expect(first.fresh.presentedTimes == [1.0, 1.5] && first.all.submitToPresentMs == [20, 30])
        #expect(first.counters.newDesktopsPresented == 2 && first.counters.fresh.presentedTimes.isEmpty)
        stats.update { $0.fresh.presentedTimes.append(2.0) }
        let second = stats.collect()
        #expect(second.fresh.presentedTimes == [2.0] && second.all.presentedTimes == [1.0, 1.5, 2.0])
        #expect(second.all.cursor.count == 1 && stats.counters.newDesktopsPresented == 2)
    }

    @Test func distributionUsesNearestRank() {
        #expect(distribution([]) == "N=0")
        #expect(distribution((1...100).map(Double.init).reversed()) == "N=100 median=50.00 p95=95.00 p99=99.00 max=100.00")
        #expect(distribution([5, 1, 3]) == "N=3 median=3.00 p95=5.00 p99=5.00 max=5.00")
    }
}
