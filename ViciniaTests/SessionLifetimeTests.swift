// Vicinia tests — session lifetime core: identity, authorization, ordered and
// idempotent revocation, and scene-signal classification.
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import UIKit
@testable import Vicinia

@MainActor
@Suite("Session lifetime")
struct SessionLifetimeTests {
    /// A feature that records what it was told and what the lifetime said at that moment.
    @MainActor private final class Probe {
        var log: [String] = []
        var grants: [FeatureAuthorization] = []
        func register(_ lifetime: SessionLifetime, name: String = "probe") {
            lifetime.register(name, grant: { [unowned self] in grants.append($0); log.append("grant") },
                              revoke: { [unowned self, unowned lifetime] reason in
                                  // Already invalid when the feature is told.
                                  log.append("revoke \(reason.rawValue) authorized=\(lifetime.authorization != nil)")
                              },
                              end: { [unowned self] in log.append("end") })
        }
    }

    @Test func everySessionHasItsOwnIncreasingGeneration() {
        let profile = UUID()
        let a = SessionLifetime(profileID: profile), b = SessionLifetime(profileID: profile)
        #expect(b.token.generation > a.token.generation && a.token != b.token && a.token.profileID == profile)
    }

    @Test func effectsAreAuthorizedOnlyOnceTheSessionIsEstablishedAndInTheForeground() throws {
        let lifetime = SessionLifetime(profileID: UUID()), probe = Probe()
        probe.register(lifetime)
        #expect(lifetime.authorization == nil)
        lifetime.sessionEstablished()
        let first = try #require(lifetime.authorization)
        #expect(probe.grants == [first] && lifetime.isValid(first))
        let background = SessionLifetime(profileID: UUID(), scene: SceneState(.background)), late = Probe()
        late.register(background)
        background.sessionEstablished()
        #expect(background.authorization == nil && late.grants.isEmpty)    // established while in the background
        background.sceneSignal(.didActivate)
        #expect(background.authorization != nil && late.grants.count == 1)
    }

    @Test func revocationInvalidatesFirstThenStopsFeaturesAndIsIdempotent() throws {
        let lifetime = SessionLifetime(profileID: UUID()), probe = Probe()
        probe.register(lifetime)
        probe.register(lifetime)                                            // idempotent registration
        lifetime.sessionEstablished()
        let granted = try #require(lifetime.authorization)
        lifetime.revoke(.background)
        lifetime.revoke(.background)
        #expect(probe.log == ["grant", "revoke background authorized=false"])
        #expect(!lifetime.isValid(granted))
        lifetime.end(.voluntaryClose)
        lifetime.end(.sessionEnded)
        #expect(probe.log == ["grant", "revoke background authorized=false", "end"])
        #expect(lifetime.ended && lifetime.lastRevocation == .voluntaryClose)
        lifetime.sceneSignal(.didActivate)
        lifetime.sessionEstablished()
        #expect(lifetime.authorization == nil && probe.grants.count == 1)  // nothing after the end
        let afterEnd = Probe()
        afterEnd.register(lifetime, name: "late")
        #expect(afterEnd.log == ["end"])                                    // a late feature is ended at once
    }

    @Test func endWhileAuthorizedRevokesBeforeEnding() {
        let lifetime = SessionLifetime(profileID: UUID()), probe = Probe()
        probe.register(lifetime)
        lifetime.sessionEstablished()
        lifetime.end(.voluntaryClose)
        #expect(probe.log == ["grant", "revoke voluntaryClose authorized=false", "end"])
    }

    @Test func lateRevocationKeepsTheTerminalReason() {
        let lifetime = SessionLifetime(profileID: UUID())
        lifetime.sessionEstablished()
        lifetime.end(.voluntaryClose)
        lifetime.revoke(.background)
        #expect(lifetime.lastRevocation == .voluntaryClose)
    }

    @Test func initialProtectedDataLockBlocksGrantEvenWithAnActiveScene() {
        let lifetime = SessionLifetime(profileID: UUID(), scene: SceneState(.active, protectedDataAvailable: false))
        lifetime.sessionEstablished()
        lifetime.sceneSignal(.didActivate)
        #expect(lifetime.activity == .locked && lifetime.authorization == nil)
        lifetime.sceneSignal(.protectedDataDidBecomeAvailable)
        #expect(lifetime.activity == .active && lifetime.authorization != nil)
    }

    @Test func registrationWhileAuthorizedIsGrantedAtOnce() {
        let lifetime = SessionLifetime(profileID: UUID())
        lifetime.sessionEstablished()
        let probe = Probe()
        probe.register(lifetime)
        #expect(probe.grants == [lifetime.authorization!])
    }

    @Test func transientInactivityKeepsAuthorizationTrueBackgroundAndLockRevokeAndReturnReauthorizes() throws {
        let lifetime = SessionLifetime(profileID: UUID()), probe = Probe()
        probe.register(lifetime)
        lifetime.sessionEstablished()
        let first = try #require(lifetime.authorization)
        // Control Center, a system prompt, the app switcher shown and dismissed.
        for signal: SceneSignal in [.willDeactivate, .didActivate, .willDeactivate, .didActivate] { lifetime.sceneSignal(signal) }
        #expect(lifetime.authorization == first && probe.grants.count == 1)
        // App switcher, then another app: true background.
        lifetime.sceneSignal(.willDeactivate)
        lifetime.sceneSignal(.didEnterBackground)
        #expect(lifetime.authorization == nil && lifetime.lastRevocation == .background)
        lifetime.sceneSignal(.willEnterForeground)
        #expect(lifetime.authorization == nil && lifetime.activity == .inactive)   // not before it is active
        lifetime.sceneSignal(.didActivate)
        let second = try #require(lifetime.authorization)
        #expect(second.operation > first.operation && second.session == first.session && !lifetime.isValid(first))
        // Device lock as iOS 27.2.1 reports it on an iPhone: protected data first,
        // then the scene active again for a moment, then the background.
        for signal: SceneSignal in [.protectedDataWillBecomeUnavailable, .willDeactivate, .didActivate, .willDeactivate, .didEnterBackground] {
            lifetime.sceneSignal(signal)
            #expect(lifetime.authorization == nil && lifetime.activity == .locked, "\(signal)")
        }
        #expect(lifetime.lastRevocation == .deviceLock && probe.grants.count == 2)   // never re-granted while locking
        // Unlock, then back to the app.
        lifetime.sceneSignal(.protectedDataDidBecomeAvailable)
        #expect(lifetime.activity == .background && lifetime.authorization == nil)
        lifetime.sceneSignal(.willEnterForeground)
        lifetime.sceneSignal(.didActivate)
        #expect(lifetime.authorization != nil && probe.grants.count == 3)
        // Unlocked while the app is frontmost: the scene may be active before protected data returns.
        for signal: SceneSignal in [.protectedDataWillBecomeUnavailable, .didActivate] { lifetime.sceneSignal(signal) }
        #expect(lifetime.authorization == nil)
        lifetime.sceneSignal(.protectedDataDidBecomeAvailable)
        #expect(lifetime.authorization != nil && probe.grants.count == 4)
        #expect(probe.log.filter { $0.hasPrefix("revoke") } == ["revoke background authorized=false", "revoke deviceLock authorized=false",
                                                                 "revoke deviceLock authorized=false"])
    }

    @Test func sceneSignalClassificationTable() {
        let cases: [(SceneActivity, SceneSignal, SceneActivity)] = [
            (.active, .willDeactivate, .inactive), (.inactive, .didActivate, .active),
            (.inactive, .didEnterBackground, .background), (.active, .didEnterBackground, .background),
            (.background, .willEnterForeground, .inactive), (.background, .willDeactivate, .background),
            (.background, .protectedDataWillBecomeUnavailable, .locked), (.active, .protectedDataWillBecomeUnavailable, .locked),
            (.locked, .didEnterBackground, .locked), (.locked, .protectedDataDidBecomeAvailable, .background),
            (.active, .protectedDataDidBecomeAvailable, .active), (.locked, .willEnterForeground, .locked),
            (.locked, .didActivate, .locked), (.active, .willEnterForeground, .active),
        ]
        for (from, signal, to) in cases {
            var state = SceneState(from)
            state.apply(signal)
            #expect(state.activity == to, "\(from) + \(signal)")
        }
        #expect(SceneActivity(.foregroundActive) == .active && SceneActivity(.foregroundInactive) == .inactive)
        #expect(SceneActivity(.background) == .background && SceneActivity(.unattached) == .background)
    }

    @Test func aLockAfterABackgroundRevocationStillDeliversTheLockResetExactlyOnce() throws {
        let lifetime = SessionLifetime(profileID: UUID()), probe = Probe()
        probe.register(lifetime)
        lifetime.sessionEstablished()
        let first = try #require(lifetime.authorization)
        lifetime.sceneSignal(.willDeactivate)
        lifetime.sceneSignal(.didEnterBackground)                     // revoked: background
        #expect(lifetime.authorization == nil)
        // Locked while already revoked: the reset is still owed, and nothing is granted.
        for signal: SceneSignal in [.protectedDataWillBecomeUnavailable, .didActivate, .willDeactivate, .didEnterBackground] {
            lifetime.sceneSignal(signal)
            #expect(lifetime.authorization == nil && lifetime.activity == .locked, "\(signal)")
        }
        lifetime.revoke(.deviceLock)                                   // idempotent
        #expect(probe.log.filter { $0.hasPrefix("revoke") } == ["revoke background authorized=false", "revoke deviceLock authorized=false"])
        #expect(probe.grants == [first] && !lifetime.isValid(first))
        // Unlock, then foreground: a new grant, once active.
        lifetime.sceneSignal(.protectedDataDidBecomeAvailable)
        #expect(lifetime.authorization == nil)
        lifetime.sceneSignal(.willEnterForeground)
        lifetime.sceneSignal(.didActivate)
        let second = try #require(lifetime.authorization)
        #expect(second.operation > first.operation && probe.grants == [first, second])
        // The next lock after a grant is delivered once more.
        lifetime.sceneSignal(.protectedDataWillBecomeUnavailable)
        lifetime.sceneSignal(.protectedDataWillBecomeUnavailable)
        #expect(probe.log.filter { $0 == "revoke deviceLock authorized=false" }.count == 2)
    }
}
