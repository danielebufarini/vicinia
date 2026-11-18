// Vicinia tests — credential ownership: one owner for the password
// across authentication and teardown.
// SPDX-License-Identifier: MIT
//
// The real HPSSSession against the loopback fake host. Authentication and
// teardown are held at chosen points with gates, so every interleaving below
// is constructed, not won by timing.
// RED state: restoring the reviewed defect (shared, unsynchronized password;
// no check after authentication) must fail every test of the first suite.

import Foundation
import Testing
@testable import Vicinia

@Suite("Credential ownership (F01)", .serialized)
struct CredentialOwnershipTests {
    static let salt = [UInt8](repeating: 7, count: 32)
    static let password = "correct horse"

    static func derive(_ secret: SecretBytes) throws -> [UInt8] {
        try SRPClient.derivePrivateKey(salt: salt, iterations: 2, password: secret).padded(64)
    }

    /// True when nothing can be derived from `secret` any more.
    static func isSpent(_ secret: SecretBytes) -> Bool {
        do { _ = try derive(secret); return false } catch { return "\(error)".contains("credentials") }
    }

    private func eventually(_ timeout: Duration = .seconds(8), _ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    // MARK: the container

    /// One derivation consumes the password; a second finds nothing.
    @Test func passwordIsConsumedByItsSingleUse() throws {
        let secret = SecretBytes(Self.password)
        #expect(try Self.derive(secret) == Self.derive(SecretBytes(Self.password)))
        #expect(Self.isSpent(secret))
    }

    /// A wiped password (teardown, repeated or not) derives nothing — in
    /// particular not the key of an empty password.
    @Test func wipedPasswordDerivesNothing() {
        let secret = SecretBytes(Self.password)
        secret.wipe()
        secret.wipe()
        #expect(Self.isSpent(secret))
    }

    // MARK: the session

    private struct Rig {
        let host: FakeHost, session: HPSSSession, pipeline: MediaPipeline, secret: SecretBytes
        let phases: Recorder<SessionPhase>, trustGate: SendGate, sendGate: SendGate
        let run: Task<Void, Never>, pinHost: String

        func finish() {
            host.stop()
            try? HostKeyPinStore.forget(host: pinHost)
        }
    }

    /// The real session against the fake host. `holdTrust` parks authentication
    /// at the host-key prompt (before the identity envelope); `holdSend` parks
    /// the n-th control send (4 = the SRP proof, i.e. after derivation).
    private func start(_ behavior: FakeHost.Behavior = .valid, holdTrust: Bool = false,
                       holdSend: Int? = nil) async throws -> Rig {
        let pinHost = "f01-\(UUID().uuidString)"                      // never pinned: the prompt always appears
        let host = try FakeHost(behavior: behavior)
        let peer = FakeControlPeer()
        host.afterAuthentication = { channel, key in await peer.serve(channel, wrapKey: key) }
        let port = try await host.start()
        let trustGate = SendGate(), sendGate = SendGate(), sends = Recorder<Int>()
        if holdTrust { trustGate.close() }
        sendGate.close()
        let channel = ControlChannel(host: "127.0.0.1", port: port)
        await channel.gateSends {
            sends.add(1)
            if sends.all.count == holdSend { await sendGate.pass() }
        }
        let phases = Recorder<SessionPhase>()
        let evidence = EvidenceLog()
        let pipeline = MediaPipeline(ssrcToStripe: [:], canvas: nil, ruleOverride: nil,
                                     mailbox: DesktopUpdateMailbox(), evidence: evidence)
        let config = SessionConfiguration(host: pinHost, port: port, username: "tester", logicalWidth: 1164,
                                          logicalHeight: 600, hardwareModel: "test", osBuild: "test", osVersion: (27, 2, 1))
        let secret = SecretBytes(Self.password)
        let session = HPSSSession(
            config: config, password: secret, pipeline: pipeline, evidence: evidence, channel: channel,
            trust: { _, _ in await trustGate.pass(); return true }, onPhase: { phase, _ in phases.add(phase) })
        let run = Task { await session.run() }
        return Rig(host: host, session: session, pipeline: pipeline, secret: secret, phases: phases,
                   trustGate: trustGate, sendGate: sendGate, run: run, pinHost: pinHost)
    }

    /// Starts `disconnect()` and holds its teardown at the media-queue hop: the
    /// session is finished and has ended the credential's lifetime, while the
    /// control connection is still open. `signal()` lets the teardown complete.
    private func holdTeardownBeforeClose(_ rig: Rig) async -> (task: Task<Void, Never>, hold: DispatchSemaphore) {
        let hold = DispatchSemaphore(value: 0)
        rig.pipeline.queue.async { hold.wait() }
        let session = rig.session
        let task = Task { await session.disconnect() }
        #expect(await eventually { rig.phases.all.contains(.disconnecting) })
        _ = await session.pendingWrites                               // actor round trip: teardown is at its first suspension
        return (task, hold)
    }

    /// The session is closed while authentication waits at the host-key prompt;
    /// the connection is still open when authentication resumes. It must not
    /// derive anything from the password teardown has wiped: no proof — in
    /// particular none for an empty password — reaches the host.
    @Test func teardownBeforeDerivationSendsNoProof() async throws {
        let rig = try await start(holdTrust: true)
        #expect(await eventually { rig.trustGate.waiting == 1 })
        let teardown = await holdTeardownBeforeClose(rig)
        rig.trustGate.open()
        await rig.run.value                                           // authentication ended on its own
        #expect(rig.host.proofs.all.isEmpty)
        #expect(Self.isSpent(rig.secret))
        teardown.hold.signal()
        await teardown.task.value
        await rig.session.disconnect()                                // repeated teardown: no effect
        #expect(rig.phases.all == [.connecting, .rfbHandshake, .authenticating, .disconnecting, .idle])
        rig.finish()
    }

    /// The session is closed after the derivation, with the proof about to be
    /// sent; the host then accepts it. The password was used intact, and the
    /// late success must not continue the finished session.
    @Test func authenticationFinishingAfterTeardownIsDiscarded() async throws {
        let rig = try await start(holdSend: 4)
        #expect(await eventually { rig.sendGate.waiting == 1 })       // derived; the proof is not yet on the wire
        let teardown = await holdTeardownBeforeClose(rig)
        rig.sendGate.open()
        await rig.run.value
        #expect(rig.host.proofs.all == [true])                        // the host verified the proof and answered
        #expect(rig.phases.all.last == .disconnecting)                // nothing of the session ran on that answer
        #expect(Self.isSpent(rig.secret))
        teardown.hold.signal()
        await teardown.task.value
        #expect(rig.phases.all == [.connecting, .rfbHandshake, .authenticating, .disconnecting, .idle])
        rig.finish()
    }

    /// A refused authentication (here: before any derivation) ends the
    /// credential's lifetime as well.
    @Test func failedAuthenticationEndsTheCredentialLifetime() async throws {
        let rig = try await start(.wrongGroup)
        await rig.run.value
        #expect(rig.phases.all.last == .failed)
        #expect(rig.host.proofs.all.isEmpty)
        #expect(Self.isSpent(rig.secret))
        await rig.session.disconnect()
        rig.finish()
    }

    /// A completed login has consumed the password; closing afterwards is clean.
    @Test func successfulAuthenticationConsumesThePassword() async throws {
        let rig = try await start()
        #expect(await eventually { rig.phases.all.contains(.virtualDisplayReady) || rig.phases.all.contains(.failed) })
        #expect(!rig.phases.all.contains(.failed))
        #expect(rig.host.proofs.all == [true])
        #expect(Self.isSpent(rig.secret))
        await rig.session.disconnect()
        await rig.run.value
        #expect(rig.phases.all.last == .idle)
        rig.finish()
    }
}

/// The original defect as a race: teardown's wipe on one thread, the
/// derivation on another, same password. Whatever the order, the derivation
/// used the intact password or was refused. (Also the Thread Sanitizer case.)
@Suite("Credential race (F01)")
struct CredentialRaceTests {
    @Test func wipeRacingDerivationYieldsTheRightKeyOrNothing() async throws {
        let expected = try CredentialOwnershipTests.derive(SecretBytes(CredentialOwnershipTests.password))
        for _ in 0..<200 {
            let secret = SecretBytes(CredentialOwnershipTests.password)
            let derivation = Task.detached { try? CredentialOwnershipTests.derive(secret) }
            secret.wipe()
            if let key = await derivation.value { #expect(key == expected) }
        }
    }
}
