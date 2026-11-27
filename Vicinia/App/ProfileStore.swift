// Vicinia — saved Mac connection profiles and their per-Mac preferences:
// a versioned JSON document written atomically in Application Support (never
// in Documents). Profiles hold non-secret data only: no password, key or
// trust material is stored here, and resolving or saving a profile never
// touches the host-key pin store.
// SPDX-License-Identifier: MIT

import Foundation
import Observation

/// The logical endpoint as entered; it is resolved at connection time and
/// never identifies a Mac by itself.
struct ConnectionEndpoint: Codable, Hashable, Sendable {
    var host: String
    var port: UInt16
}

struct AudioPreference: Codable, Equatable, Sendable {
    var enabled: Bool
}

/// Display settings use a nested record in the profile schema.
struct DisplayPreference: Codable, Equatable, Sendable {
    enum Profile: String, Codable, Sendable { case retina, moreSpace }
    var profile: Profile
}

struct PointerPreference: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable { case trackpad, direct }
    var mode: Mode
}

struct ClipboardPreference: Codable, Equatable, Sendable {
    var automaticSync: Bool
}

/// Per-Mac preferences. `nil` means never set: the feature's
/// default applies.
struct ProfilePreferences: Codable, Equatable, Sendable {
    var audio: AudioPreference?
    var display: DisplayPreference?
    var pointer: PointerPreference?
    var clipboard: ClipboardPreference?
}

/// A saved Mac connection with optional per-feature settings.
struct ConnectionProfile: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String?
    var endpoint: ConnectionEndpoint
    var username: String?
    /// Reference to a Keychain item, never the secret itself.
    var credentialReference: String?
    /// Association with an accepted host-key pin; the pin itself stays in the pin store.
    var hostTrustIdentifier: String?
    var lastSuccessfulConnection: Date?
    var preferences: ProfilePreferences
    let created: Date
}

struct ProfileDocument: Codable, Equatable, Sendable {
    static let currentSchema = 1
    var schemaVersion = ProfileDocument.currentSchema
    var profiles: [ConnectionProfile] = []
    /// The V1 `host`/`user` defaults were adopted (once).
    var migratedLegacyDefaults = false
}

/// The profile a live session belongs to: its identity, the preference
/// snapshot taken at connection time, and writers that can change only this
/// profile's record.
struct ProfileBinding: Sendable {
    let profileID: UUID
    let preferences: ProfilePreferences
    /// Saves the session's preference snapshot for this profile only.
    let save: @MainActor @Sendable (ProfilePreferences) -> Void
    /// The first desktop of a session was presented.
    let recordSuccessfulConnection: @MainActor @Sendable () -> Void
}

@MainActor
@Observable
final class ProfileStore {
    enum LoadIssue: Equatable, Sendable {
        /// The file could not be decoded; it was kept under `setAsideName`.
        case unreadable(setAsideName: String?)
        /// Written by a newer Vicinia: kept untouched, changes stay in memory.
        case newerSchema(Int)
    }

    private(set) var document = ProfileDocument()
    private(set) var loadIssue: LoadIssue?
    private(set) var lastWriteError: String?
    @ObservationIgnored let fileURL: URL
    @ObservationIgnored private let readOnly: Bool
    @ObservationIgnored private let writes: DispatchQueue
    @ObservationIgnored private let write: @Sendable (Data, URL) throws -> Void

    static var defaultDirectory: URL { URL.applicationSupportDirectory.appending(path: "Profiles") }
    static let shared = ProfileStore(directory: defaultDirectory, legacyDefaults: .standard)

    /// Loads synchronously (a few kilobytes). An unreadable file is set aside,
    /// not overwritten; a newer schema is never written back.
    init(directory: URL, legacyDefaults: UserDefaults?, now: Date = Date(),
         write: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        fileURL = directory.appending(path: "profiles.json")
        writes = DispatchQueue(label: "it.danielebufarini.vicinia.profiles", qos: .utility)
        self.write = write
        let fm = FileManager.default
        var readOnly = false
        if fm.fileExists(atPath: fileURL.path(percentEncoded: false)) {
            switch (try? Data(contentsOf: fileURL)).map(Self.decode) ?? .failure(.unreadable) {
            case .success(let doc): document = doc
            case .failure(.newerSchema(let version)):
                loadIssue = .newerSchema(version)
                readOnly = true
            case .failure(.unreadable):
                let aside = "profiles-unreadable-\(Self.stamp(now))-\(UUID().uuidString).json"
                let moved = (try? fm.moveItem(at: fileURL, to: directory.appending(path: aside))) != nil
                loadIssue = .unreadable(setAsideName: moved ? aside : nil)
                readOnly = !moved                       // never overwrite data that could not be kept
            }
        }
        self.readOnly = readOnly
        if !readOnly, !document.migratedLegacyDefaults { migrateLegacyDefaults(legacyDefaults) }
    }

    enum DecodeFailure: Error { case unreadable, newerSchema(Int) }

    nonisolated static func decode(_ data: Data) -> Result<ProfileDocument, DecodeFailure> {
        struct Version: Decodable { let schemaVersion: Int }
        guard let version = try? JSONDecoder().decode(Version.self, from: data) else { return .failure(.unreadable) }
        guard version.schemaVersion > 0 else { return .failure(.unreadable) }
        guard version.schemaVersion <= ProfileDocument.currentSchema else { return .failure(.newerSchema(version.schemaVersion)) }
        guard let doc = try? Self.decoder.decode(ProfileDocument.self, from: data) else { return .failure(.unreadable) }
        return .success(doc)
    }

    private nonisolated static var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    private nonisolated static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }

    private static func stamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "")
    }

    /// V1 kept only the last `host` and `user`. They become one profile, with
    /// no credential and no trust association; the defaults themselves stay.
    private func migrateLegacyDefaults(_ defaults: UserDefaults?) {
        document.migratedLegacyDefaults = true
        if let host = defaults?.string(forKey: "host"), !host.isEmpty {
            let user = defaults?.string(forKey: "user")
            document.profiles.append(ConnectionProfile(
                id: UUID(), name: nil, endpoint: ConnectionEndpoint(host: host, port: 5900),
                username: user?.isEmpty == false ? user : nil, credentialReference: nil, hostTrustIdentifier: nil,
                lastSuccessfulConnection: nil, preferences: ProfilePreferences(), created: Date()))
        }
        persist()
    }

    func profile(_ id: UUID) -> ConnectionProfile? { document.profiles.first { $0.id == id } }

    /// The connection form's profile: the one with exactly this endpoint and
    /// account name, or a new one that is saved only once it is used (first
    /// presented desktop or a preference change). An existing profile is never
    /// edited or merged here, and trust is never touched.
    func binding(host: String, port: UInt16 = 5900, username: String) -> ProfileBinding {
        let endpoint = ConnectionEndpoint(host: host, port: port)
        let account: String? = username.isEmpty ? nil : username
        let existing = document.profiles.first { $0.endpoint == endpoint && $0.username == account }
        let draft = existing ?? ConnectionProfile(
            id: UUID(), name: nil, endpoint: endpoint, username: account, credentialReference: nil,
            hostTrustIdentifier: nil, lastSuccessfulConnection: nil, preferences: ProfilePreferences(), created: Date())
        let id = draft.id
        return ProfileBinding(
            profileID: id, preferences: draft.preferences,
            save: { [weak self] preferences in self?.update(draft) { $0.preferences = preferences } },
            recordSuccessfulConnection: { [weak self] in self?.update(draft) { $0.lastSuccessfulConnection = Date() } })
    }

    /// Changes only the owned fields of one profile, inserting `draft` first if it is not saved yet.
    private func update(_ draft: ConnectionProfile, _ change: (inout ConnectionProfile) -> Void) {
        if let index = document.profiles.firstIndex(where: { $0.id == draft.id }) {
            change(&document.profiles[index])
        } else {
            var profile = draft
            change(&profile)
            document.profiles.append(profile)
        }
        persist()
    }

    private func persist() {
        guard !readOnly else { return }
        let url = fileURL, write = self.write, document = self.document
        writes.async { [weak self] in
            var failure: String?
            do {
                let data = try Self.encoder.encode(document)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try write(data, url)
            } catch { failure = String(localized: "Mac preferences could not be saved.") }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.lastWriteError = failure } }
        }
    }

    /// Waits until the writes queued so far, and their reported outcome, are done (tests).
    func flush() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            writes.async { DispatchQueue.main.async { c.resume() } }
        }
    }
}
