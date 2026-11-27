// Vicinia — lifetime of one live session: its identity, the authorization that
// gates feature side effects (playback today), ordered revocation and the
// classification of its scene's lifecycle signals.
// SPDX-License-Identifier: MIT
//
// Ordering: a revocation invalidates the authorization first, then stops every
// registered feature, synchronously; only then does the caller run the
// existing input release and session teardown. Tokens are local metadata:
// never sent to the Mac and never credentials.

import Foundation
import UIKit

/// One live session in this process.
struct SessionToken: Hashable, Sendable {
    let profileID: UUID
    let generation: UInt64
}

/// Permission for one session's feature effects. Every grant issues a new
/// operation number, so an effect that captured an older one is rejected.
struct FeatureAuthorization: Hashable, Sendable {
    let session: SessionToken
    let operation: UInt64

    /// What the session's shared writer checks before sealing an accessory write.
    var accessoryToken: AccessoryToken { AccessoryToken(generation: session.generation, operation: operation) }
}

enum RevocationReason: String, Sendable {
    case voluntaryClose, sessionEnded, background, deviceLock
}

/// What the owning scene's signals mean for the session. Only true background
/// and device lock revoke; transient inactivity (Control Center, a system
/// prompt, the app switcher, another window focused) does not.
enum SceneActivity: String, Sendable {
    case active, inactive, background, locked

    init(_ state: UIScene.ActivationState) {
        switch state {
        case .foregroundActive: self = .active
        case .foregroundInactive: self = .inactive
        default: self = .background
        }
    }
}

enum SceneSignal: String, Sendable {
    case willDeactivate, didEnterBackground, willEnterForeground, didActivate
    case protectedDataWillBecomeUnavailable, protectedDataDidBecomeAvailable
}

/// The owning scene's activation and the device lock, kept apart: a lock lasts
/// until protected data is available again, whatever the scene reports in
/// between. Observed on iOS 27.2.1: locking posts the protected-data signal
/// first, then reports the scene active again for a moment before it goes to
/// the background.
struct SceneState: Equatable, Sendable {
    private(set) var scene: SceneActivity            // .active, .inactive or .background
    private(set) var locked: Bool

    init(_ activity: SceneActivity = .active, protectedDataAvailable: Bool = true) {
        locked = activity == .locked || !protectedDataAvailable
        scene = activity == .locked ? .background : activity
    }

    var activity: SceneActivity { locked ? .locked : scene }

    mutating func apply(_ signal: SceneSignal) {
        switch signal {
        case .willDeactivate: if scene == .active { scene = .inactive }
        case .didEnterBackground: scene = .background
        case .willEnterForeground: if scene != .active { scene = .inactive }
        case .didActivate: scene = .active
        case .protectedDataWillBecomeUnavailable: locked = true
        case .protectedDataDidBecomeAvailable: locked = false
        }
    }
}

@MainActor
final class SessionLifetime {
    private static var lastGeneration: UInt64 = 0
    private static var lastOperation: UInt64 = 0

    let token: SessionToken
    private(set) var authorization: FeatureAuthorization?
    private(set) var scene: SceneState
    var activity: SceneActivity { scene.activity }
    private(set) var established = false
    private(set) var ended = false
    private(set) var lastRevocation: RevocationReason?
    /// Revoked by true background or lock; cleared only when the scene is active again.
    private(set) var sceneRevoked = false
    /// The features received the device-lock revocation since the last grant.
    /// A lock that follows a background revocation still owes them its
    /// semantic reset (their memory of pre-lock content), exactly once.
    private var lockDelivered = false

    private struct Feature {
        let name: String
        let grant: @MainActor (FeatureAuthorization) -> Void
        let revoke: @MainActor (RevocationReason) -> Void
        let end: @MainActor () -> Void
    }
    private var features: [Feature] = []

    init(profileID: UUID, scene: SceneState = SceneState()) {
        Self.lastGeneration &+= 1
        token = SessionToken(profileID: profileID, generation: Self.lastGeneration)
        self.scene = scene
        sceneRevoked = scene.activity == .background || scene.activity == .locked
    }

    /// Idempotent: a second registration under the same name is ignored. A
    /// feature registered after the end is ended at once; one registered
    /// while authorized is granted at once.
    func register(_ name: String, grant: @escaping @MainActor (FeatureAuthorization) -> Void,
                  revoke: @escaping @MainActor (RevocationReason) -> Void, end: @escaping @MainActor () -> Void) {
        guard !features.contains(where: { $0.name == name }) else { return }
        guard !ended else { end(); return }
        features.append(Feature(name: name, grant: grant, revoke: revoke, end: end))
        if let authorization { grant(authorization) }
    }

    func isValid(_ authorization: FeatureAuthorization) -> Bool { !ended && self.authorization == authorization }

    /// The first desktop was presented: effects may start if the scene permits.
    func sessionEstablished() {
        guard !ended else { return }
        established = true
        grantIfPermitted()
    }

    func sceneSignal(_ signal: SceneSignal) {
        var updated = scene
        updated.apply(signal)
        updateScene(updated)
    }

    func updateScene(_ updated: SceneState) {
        guard !ended else { return }
        scene = updated
        switch scene.activity {
        case .background, .locked:
            sceneRevoked = true
            revoke(scene.activity == .locked ? .deviceLock : .background)
        case .active:
            sceneRevoked = false
            grantIfPermitted()
        case .inactive:
            break                                       // transient: nothing is revoked or granted
        }
    }

    /// Invalidates the authorization first, then stops each feature. Idempotent.
    /// A device lock is delivered even when the authorization is already gone
    /// (background first): it never grants, it only resets.
    func revoke(_ reason: RevocationReason) {
        guard !ended else { return }
        lastRevocation = reason
        let escalation = reason == .deviceLock && !lockDelivered
        guard authorization != nil || escalation else { return }
        authorization = nil
        if reason == .deviceLock { lockDelivered = true }
        for feature in features { feature.revoke(reason) }
    }

    /// Terminal: revokes, then ends every feature; later grants are refused.
    func end(_ reason: RevocationReason) {
        guard !ended else { return }
        revoke(reason)
        ended = true
        for feature in features { feature.end() }
    }

    private func grantIfPermitted() {
        guard established, !ended, !sceneRevoked, authorization == nil,
              activity == .active || activity == .inactive else { return }
        Self.lastOperation &+= 1
        let granted = FeatureAuthorization(session: token, operation: Self.lastOperation)
        authorization = granted
        lockDelivered = false
        for feature in features { feature.grant(granted) }
    }
}
