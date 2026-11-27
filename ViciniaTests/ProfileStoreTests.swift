// Vicinia tests — saved Mac profiles and per-Mac preferences: round trip,
// isolation, exact endpoint resolution, one-time V1 migration and failure
// handling without silent data loss. Each test uses its own directory.
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import Vicinia

@MainActor
@Suite("Profile store", .serialized)
struct ProfileStoreTests {
    /// The name contains a space, like Application Support.
    private final class Directory {
        let url = FileManager.default.temporaryDirectory.appending(path: "vicinia profiles \(UUID().uuidString)")
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    private func reopen(_ d: Directory, legacy: UserDefaults? = nil) -> ProfileStore {
        ProfileStore(directory: d.url, legacyDefaults: legacy)
    }

    @Test func preferencesRoundTripAndStayIsolatedBetweenMacs() async throws {
        let d = Directory()
        let store = reopen(d)
        let a = store.binding(host: "mac-a.local", username: "anna")
        let b = store.binding(host: "192.0.2.20", username: "bob")
        #expect(a.profileID != b.profileID && store.document.profiles.isEmpty)    // unused: nothing saved yet
        a.save(ProfilePreferences(audio: AudioPreference(enabled: false)))
        b.recordSuccessfulConnection()
        await store.flush()
        #expect(store.lastWriteError == nil)
        let again = reopen(d)
        #expect(again.document.profiles.count == 2 && again.loadIssue == nil)
        #expect(again.profile(a.profileID)?.preferences.audio == AudioPreference(enabled: false))
        #expect(again.profile(b.profileID)?.preferences.audio == nil)            // another Mac keeps its default
        #expect(again.profile(b.profileID)?.lastSuccessfulConnection != nil)
        #expect(again.profile(a.profileID)?.endpoint == ConnectionEndpoint(host: "mac-a.local", port: 5900))
        let resolved = again.binding(host: "mac-a.local", username: "anna")
        #expect(resolved.profileID == a.profileID && resolved.preferences.audio?.enabled == false)
        // Session snapshots are copies: a later save does not change an earlier snapshot.
        resolved.save(ProfilePreferences(audio: AudioPreference(enabled: true)))
        #expect(resolved.preferences.audio?.enabled == false && again.profile(a.profileID)?.preferences.audio?.enabled == true)
        await again.flush()
    }

    @Test func resolutionIsExactAndNeverEditsOrMergesAProfile() async throws {
        let d = Directory()
        let store = reopen(d)
        let original = store.binding(host: "mac.local", username: "anna")
        original.recordSuccessfulConnection()
        let before = try #require(store.profile(original.profileID))
        for (host, port, user) in [("MAC.local", UInt16(5900), "anna"), ("mac.local ", 5900, "anna"), ("mac.local", 5901, "anna"),
                                   ("mac.local", 5900, "Anna"), ("mac.local", 5900, "")] {
            let other = store.binding(host: host, port: port, username: user)
            #expect(other.profileID != original.profileID)                   // no merge by similar name/address
            other.recordSuccessfulConnection()
        }
        #expect(store.document.profiles.count == 6)
        #expect(store.profile(original.profileID)?.endpoint == before.endpoint)
        #expect(store.profile(original.profileID)?.username == before.username)
        #expect(store.profile(original.profileID)?.hostTrustIdentifier == nil && store.profile(original.profileID)?.credentialReference == nil)
        #expect(store.binding(host: "mac.local", username: "anna").profileID == original.profileID)
        await store.flush()
    }

    @Test func legacyDefaultsAreMigratedOnceWithoutCredentialsOrTrust() async throws {
        let d = Directory(), legacy = TestDefaults()
        defer { legacy.remove() }
        let host = "migration-\(UUID().uuidString).invalid"
        legacy.defaults.set(host, forKey: "host")
        legacy.defaults.set("alice", forKey: "user")
        try HostKeyPinStore.pin(host: host, fingerprint: "ab12")          // an existing host-key pin
        defer { try? HostKeyPinStore.forget(host: host) }
        let store = reopen(d, legacy: legacy.defaults)
        await store.flush()
        #expect(try HostKeyPinStore.pinned(host: host) == "ab12")          // trust is untouched
        let migrated = try #require(store.document.profiles.first)
        #expect(store.document.profiles.count == 1 && store.document.migratedLegacyDefaults)
        #expect(migrated.endpoint == ConnectionEndpoint(host: host, port: 5900) && migrated.username == "alice")
        #expect(migrated.credentialReference == nil && migrated.hostTrustIdentifier == nil && migrated.preferences == ProfilePreferences())
        #expect(legacy.defaults.string(forKey: "host") == host)             // the V1 form keeps its prefill
        #expect(store.binding(host: host, username: "alice").profileID == migrated.id)
        // Once only: a later launch with other defaults does not add a profile.
        legacy.defaults.set("other.invalid", forKey: "host")
        let later = reopen(d, legacy: legacy.defaults)
        #expect(later.document.profiles.map(\.id) == [migrated.id])
        // No V1 host: nothing invented.
        let empty = Directory(), none = TestDefaults()
        defer { none.remove() }
        let fresh = reopen(empty, legacy: none.defaults)
        #expect(fresh.document.profiles.isEmpty && fresh.document.migratedLegacyDefaults)
        await fresh.flush()
    }

    @Test func anUnreadableFileIsSetAsideNotOverwritten() async throws {
        let d = Directory()
        try FileManager.default.createDirectory(at: d.url, withIntermediateDirectories: true)
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: d.url.appending(path: "profiles.json"))
        let store = reopen(d)
        guard case .unreadable(let aside?) = store.loadIssue else { Issue.record("expected a set-aside file, got \(String(describing: store.loadIssue))"); return }
        #expect(try Data(contentsOf: d.url.appending(path: aside)) == garbage)  // kept byte for byte
        store.binding(host: "mac.local", username: "anna").recordSuccessfulConnection()
        await store.flush()
        #expect(reopen(d).document.profiles.count == 1)                    // a fresh document works again
    }

    @Test func aNewerSchemaIsReadOnly() async throws {
        let d = Directory()
        try FileManager.default.createDirectory(at: d.url, withIntermediateDirectories: true)
        let newer = Data(#"{"schemaVersion": 99, "profiles": [], "somethingNew": true}"#.utf8)
        let file = d.url.appending(path: "profiles.json")
        try newer.write(to: file)
        let store = reopen(d, legacy: nil)
        #expect(store.loadIssue == .newerSchema(99))
        store.binding(host: "mac.local", username: "anna").recordSuccessfulConnection()
        #expect(store.document.profiles.count == 1)                         // usable in memory
        await store.flush()
        #expect(try Data(contentsOf: file) == newer)                       // never written back
    }

    @Test(arguments: [0, -1]) func nonpositiveSchemaIsUnreadable(_ version: Int) {
        let data = Data("{\"schemaVersion\":\(version),\"profiles\":[],\"migratedLegacyDefaults\":true}".utf8)
        if case .failure(.unreadable) = ProfileStore.decode(data) {} else {
            Issue.record("Schema version \(version) must be treated as unreadable")
        }
    }

    @Test func twoCorruptDocumentsInTheSameSecondAreBothKept() async throws {
        let d = Directory()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try FileManager.default.createDirectory(at: d.url, withIntermediateDirectories: true)
        let file = d.url.appending(path: "profiles.json")
        let first = Data("first corrupt document".utf8), second = Data("second corrupt document".utf8)
        try first.write(to: file)
        let one = ProfileStore(directory: d.url, legacyDefaults: nil, now: now)
        await one.flush()
        try second.write(to: file)
        let two = ProfileStore(directory: d.url, legacyDefaults: nil, now: now)
        await two.flush()
        guard case .unreadable(let a?) = one.loadIssue, case .unreadable(let b?) = two.loadIssue else {
            Issue.record("Both original files must be preserved")
            return
        }
        #expect(a != b)
        #expect(try Data(contentsOf: d.url.appending(path: a)) == first)
        #expect(try Data(contentsOf: d.url.appending(path: b)) == second)
    }

    @Test func writeFailureNoticeContainsNoUnderlyingPathOrErrorText() async throws {
        let d = Directory()
        let store = ProfileStore(directory: d.url, legacyDefaults: nil, write: { _, url in
            throw NSError(domain: "TestDisk", code: 71, userInfo: [NSFilePathErrorKey: url.path])
        })
        store.binding(host: "mac.local", username: "user").recordSuccessfulConnection()
        await store.flush()
        let notice = try #require(store.lastWriteError)
        #expect(notice == String(localized: "Mac preferences could not be saved."))
        #expect(!notice.contains("TestDisk") && !notice.contains(d.url.path))
    }

    @Test func aFailedAtomicWriteLeavesThePreviousFileAndIsReported() async throws {
        let d = Directory()
        let first = reopen(d)
        let a = first.binding(host: "mac.local", username: "anna")
        a.save(ProfilePreferences(audio: AudioPreference(enabled: true)))
        await first.flush()
        let file = d.url.appending(path: "profiles.json")
        let before = try Data(contentsOf: file)
        struct DiskFull: Error {}
        let failing = ProfileStore(directory: d.url, legacyDefaults: nil, write: { _, _ in throw DiskFull() })
        failing.binding(host: "mac.local", username: "anna").save(ProfilePreferences(audio: AudioPreference(enabled: false)))
        await failing.flush()
        #expect(failing.lastWriteError != nil)
        #expect(try Data(contentsOf: file) == before)
        #expect(reopen(d).profile(a.profileID)?.preferences.audio?.enabled == true)
    }

    /// The first session after migration: an adopted V1 profile has no audio
    /// choice yet, so its binding carries none and the default applies.
    @Test func aMigratedProfileCarriesNoAudioChoice() async throws {
        let d = Directory(), legacy = TestDefaults()
        defer { legacy.remove() }
        legacy.defaults.set("192.0.2.47", forKey: "host")
        legacy.defaults.set("alice", forKey: "user")
        let first = reopen(d, legacy: legacy.defaults)
        await first.flush()
        let later = reopen(d, legacy: legacy.defaults)                    // the next launch reads the file
        let binding = later.binding(host: "192.0.2.47", username: "alice")
        #expect(binding.profileID == first.document.profiles.first?.id && binding.preferences.audio == nil)
        #expect((binding.preferences.audio?.enabled ?? AudioPipeline.defaultEnabled) == true)
    }

    @Test func aStoreThatCouldNotBeReadIsReportedOnTheConnectionScreen() {
        #expect(RootView.storeNotice(nil) == nil)
        #expect(RootView.storeNotice(.unreadable(setAsideName: "profiles-unreadable-x.json"))?.contains("profiles-unreadable-x.json") == true)
        #expect(RootView.storeNotice(.unreadable(setAsideName: nil)) != nil && RootView.storeNotice(.newerSchema(2)) != nil)
    }

    @Test func storedDocumentHoldsNoSecretFields() throws {
        let profile = ConnectionProfile(id: UUID(), name: "Studio", endpoint: ConnectionEndpoint(host: "mac.local", port: 5900),
                                        username: "anna", credentialReference: "ref-1", hostTrustIdentifier: "pin-1",
                                        lastSuccessfulConnection: nil, preferences: ProfilePreferences(), created: Date())
        let json = String(decoding: try JSONEncoder().encode(profile), as: UTF8.self).lowercased()
        #expect(!json.contains("password") && !json.contains("secret"))
        #expect(!URL.applicationSupportDirectory.path().contains("/Documents"))
        // The app's own store is never opened by tests: that would migrate and write the real container.
        #expect(ProfileStore.defaultDirectory.path(percentEncoded: false).contains("/Library/Application Support/Profiles"))
    }
}
