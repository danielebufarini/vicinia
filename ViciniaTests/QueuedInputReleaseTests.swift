// Vicinia — queued events must not clear transport-dispatched state.
// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import Vicinia

@Suite("Queued input release")
struct QueuedInputReleaseTests {
    private let geometry = DesktopGeometry(logical: CGRect(x: 10, y: 20, width: 100, height: 50),
                                           backing: CGRect(x: 20, y: 40, width: 200, height: 100))
    private let point = CGPoint(x: 35, y: 30)

    private func pair() throws -> (RecordLayer, RecordLayer) {
        (try RecordLayer(rekey: OracleVectors.recordRekey, wrapKey: OracleVectors.recordWrapKey),
         try RecordLayer(rekey: OracleVectors.recordRekey, wrapKey: OracleVectors.recordWrapKey))
    }
    // The production enqueue and invalidation operations, before any IO completes.
    private func queue(_ event: RemoteInput, input: inout InputState) -> ControlWrite {
        .input(event, epoch: input.epoch)
    }
    private func suspend(_ input: inout InputState) -> ControlWrite {
        input.invalidate()
        return .release
    }
    private func transmit(_ write: ControlWrite, input: inout InputState,
                          sender: RecordLayer, receiver: RecordLayer) throws -> [UInt8]? {
        guard let wire = try write.seal(records: sender, input: &input) else { return nil }
        var r = ByteReader(wire)
        return try receiver.open(r.take(Int(r.u16())))
    }

    @Test func transmittedButtonDownSurvivesObsoleteQueuedUp() throws {
        var input = InputState(); input.activate(geometry)
        let (sender, receiver) = try pair()
        let down = queue(.buttons(point, 1), input: &input)
        _ = try transmit(down, input: &input, sender: sender, receiver: receiver)
        let up = queue(.buttons(point, 0), input: &input)
        let release = suspend(&input)
        #expect(try transmit(up, input: &input, sender: sender, receiver: receiver) == nil)
        #expect(sender.sendSequence == 1)
        let expected = try AppleInputWire.wrap(RFB.pointer(x: 70, y: 60, buttons: 0), key: sender.wrapKey)
        #expect(try transmit(release, input: &input, sender: sender, receiver: receiver) == expected)
        #expect(sender.sendSequence == 2 && input.buttons == 0)
    }

    @Test func transmittedModifierDownSurvivesObsoleteQueuedUp() throws {
        var input = InputState(); input.activate(geometry)
        let (sender, receiver) = try pair()
        let down = queue(.key(0xffeb, true), input: &input)
        _ = try transmit(down, input: &input, sender: sender, receiver: receiver)
        let up = queue(.key(0xffeb, false), input: &input)
        let release = suspend(&input)
        #expect(try transmit(up, input: &input, sender: sender, receiver: receiver) == nil)
        #expect(sender.sendSequence == 1)
        #expect(try transmit(release, input: &input, sender: sender, receiver: receiver) == RFB.key(0xffeb, down: false))
        #expect(sender.sendSequence == 2 && input.keys.isEmpty)
    }

    @Test func obsoleteQueuedReleaseCannotEraseTransmittedPresses() throws {
        var input = InputState(); input.activate(geometry)
        let (sender, receiver) = try pair()
        let button = queue(.buttons(point, 1), input: &input)
        _ = try transmit(button, input: &input, sender: sender, receiver: receiver)
        let modifier = queue(.key(0xffe1, true), input: &input)
        _ = try transmit(modifier, input: &input, sender: sender, receiver: receiver)
        let queuedRelease = queue(.release, input: &input)
        let mandatory = suspend(&input)
        #expect(try transmit(queuedRelease, input: &input, sender: sender, receiver: receiver) == nil)
        #expect(sender.sendSequence == 2)
        let expected = try AppleInputWire.wrap(RFB.pointer(x: 70, y: 60, buttons: 0)
            + RFB.key(0xffe1, down: false), key: sender.wrapKey)
        #expect(try transmit(mandatory, input: &input, sender: sender, receiver: receiver) == expected)
        #expect(sender.sendSequence == 3 && input.buttons == 0 && input.keys.isEmpty)
    }

    @Test func inFlightDownRemainsHeldUntilMandatoryReleaseDispatch() throws {
        var input = InputState(); input.activate(geometry)
        let (sender, receiver) = try pair()
        let down = queue(.buttons(point, 1), input: &input)
        #expect(input.buttons == 0) // enqueue has no transport effect
        let inFlight = try #require(down.seal(records: sender, input: &input))
        #expect(input.buttons == 1 && sender.sendSequence == 1)
        let mandatory = suspend(&input) // IO completion for the down is still pending
        #expect(input.buttons == 1 && !input.enabled)
        var r = ByteReader(inFlight)
        let deliveredDown = try receiver.open(r.take(Int(r.u16())))
        #expect(deliveredDown == (try AppleInputWire.wrap(RFB.pointer(x: 70, y: 60, buttons: 1), key: sender.wrapKey)))
        let expectedUp = try AppleInputWire.wrap(RFB.pointer(x: 70, y: 60, buttons: 0), key: sender.wrapKey)
        #expect(try transmit(mandatory, input: &input, sender: sender, receiver: receiver) == expectedUp)
        #expect(input.buttons == 0 && sender.sendSequence == 2 && receiver.receiveSequence == 2)
    }
}
