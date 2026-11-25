// Vicinia tests — SRP-6a math reference vectors and type-33 negative paths.
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import Vicinia

@Suite("SRP and type-33 authentication", .serialized)
struct AuthenticationTests {
    @Test func groupIsRFC5054Prime() {
        #expect(SRPGroup.N.count == 512)
        #expect(Crypto.sha256(SRPGroup.N).hex == "4ee95187682bcb230ad26a95205f6920e84708f6251b3894329b09ec23919e33")
    }

    /// Verifies native SRP-6a key derivation and proofs against reference vectors.
    @Test func srpMatchesOracle() throws {
        let c = SRPChallenge(N: SRPGroup.N, g: [5], salt: OracleVectors.srpSalt, B: OracleVectors.srpB,
                             iterations: OracleVectors.srpIterations, options: Array("mda=SHA-512".utf8))
        let p = try SRPClient.respond(to: c, password: SecretBytes(OracleVectors.srpPassword), secretA: OracleVectors.srpA)
        #expect(p.A == OracleVectors.srpExpectedA)
        #expect(p.M1 == OracleVectors.srpM1)
        #expect(p.expectedM2 == OracleVectors.srpM2)
        #expect(p.sessionKey == OracleVectors.srpSessionKey)
    }

    @Test func challengeValidation() {
        let ok = SRPChallenge(N: SRPGroup.N, g: [5], salt: [UInt8](repeating: 1, count: 32), B: [1], iterations: 1000,
                              options: Array("mda=SHA-512".utf8))
        var c = ok; c.N[100] ^= 1
        #expect(throws: SRPError.group) { try c.validate() }
        c = ok; c.g = [2]
        #expect(throws: SRPError.generator) { try c.validate() }
        c = ok; c.salt = [1, 2]
        #expect(throws: SRPError.salt) { try c.validate() }
        c = ok; c.B = []
        #expect(throws: SRPError.publicValue) { try c.validate() }
        c = ok; c.iterations = 0
        #expect(throws: SRPError.iterations) { try c.validate() }
        c = ok; c.iterations = 1_000_001
        #expect(throws: SRPError.iterations) { try c.validate() }
        c = ok; c.options = Array("mda=SHA-1".utf8)
        #expect(throws: SRPError.options) { try c.validate() }
        // B ≡ 0 (mod N) is refused before any secret computation.
        c = ok; c.B = SRPGroup.N
        #expect(throws: SRPError.publicValue) { _ = try SRPClient.respond(to: c, password: SecretBytes("x")) }
    }

    // MARK: against the fake host

    private func authenticate(_ behavior: FakeHost.Behavior, pinKey: String = "fake-\(UUID().uuidString)",
                              password: String = "correct horse", trust: Bool = true)
        async throws -> (key: [UInt8], transcript: AuthTranscript, host: FakeHost) {
        let host = try FakeHost(behavior: behavior)
        let port = try await host.start()
        defer { host.stop() }
        let channel = ControlChannel(host: "127.0.0.1", port: port)
        try await channel.open(timeout: .seconds(5))
        defer { Task { await channel.close() } }
        let auth = HPSSAuthenticator(channel: channel, host: pinKey, trustOnFirstUse: { _, _ in trust })
        var t = AuthTranscript()
        let key = try await auth.run(username: "tester", password: SecretBytes(password), transcript: &t)
        return (key, t, host)
    }

    @Test func validLoginVerifiesM2AndPins() async throws {
        let pinKey = "fake-\(UUID().uuidString)"
        defer { try? HostKeyPinStore.forget(host: pinKey) }
        let r = try await authenticate(.valid, pinKey: pinKey)
        #expect(r.transcript.m2Verified)
        #expect(r.key == r.host.serverSessionKey)
        #expect(r.transcript.pinStatus.contains("TOFU"))
        #expect(try HostKeyPinStore.pinned(host: pinKey) == r.host.fingerprint)
    }

    @Test func invalidM2IsRefused() async {
        await #expect(throws: AuthFailure.invalidServerProof) { _ = try await authenticate(.corruptM2) }
    }

    @Test func wrongGroupIsRefused() async {
        await #expect(throws: AuthFailure.srp(.group)) { _ = try await authenticate(.wrongGroup) }
    }

    @Test(arguments: [UInt64(0), 1_000_001, 50_000_000])
    func unsupportedCostIsRefused(_ iterations: UInt64) async {
        await #expect(throws: AuthFailure.srp(.iterations)) { _ = try await authenticate(.iterations(iterations)) }
    }

    @Test func malformedEnvelopeIsRefused() async {
        await #expect { _ = try await authenticate(.badEnvelope) } throws: { error in
            if case AuthFailure.protocolViolation(let w) = error { return w.contains("envelope framing") }
            return false
        }
    }

    @Test func wrongPasswordIsRejectedByHost() async {
        await #expect { _ = try await authenticate(.wrongPassword) } throws: { error in
            if case AuthFailure.rejected(let detail) = error { return detail.contains("empty proof envelope: step=2 x=0") }
            return false
        }
    }

    @Test func noTypeThirtyThreeNoDowngrade() async {
        await #expect(throws: AuthFailure.typeNotOffered([30, 36])) { _ = try await authenticate(.noType33) }
    }

    @Test func changedHostKeyIsRefused() async throws {
        let pinKey = "fake-\(UUID().uuidString)"
        try HostKeyPinStore.pin(host: pinKey, fingerprint: String(repeating: "ab", count: 32))
        defer { try? HostKeyPinStore.forget(host: pinKey) }
        await #expect { _ = try await authenticate(.valid, pinKey: pinKey) } throws: { error in
            if case AuthFailure.hostKey(.changed) = error { return true }
            return false
        }
    }

    @Test func unacceptedHostKeyIsRefused() async {
        await #expect(throws: AuthFailure.hostKey(.rejectedByUser)) { _ = try await authenticate(.valid, trust: false) }
    }
}
