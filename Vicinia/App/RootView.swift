// Vicinia — home screen: connection form (manual LAN host/IP).
// Developer builds also offer sample discovery and viewport measurement.
// SPDX-License-Identifier: MIT

import SwiftUI

struct RootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #if DEBUG && VICINIA_DEVELOPER_TOOLS
    @State private var clips: [URL] = []
    #endif
    #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
    @State private var autoplayHandled = false
    #endif
    @State private var host = UserDefaults.standard.string(forKey: "host") ?? ""
    @State private var user = UserDefaults.standard.string(forKey: "user") ?? ""
    @State private var password = ""
    @State private var notice: String?
    /// This view's own window: a session is presented in the window that asked for it.
    @State private var anchor = WindowAnchor()

    /// Width-driven adaptation: regular-width windows (full-screen iPad in any
    /// orientation) center the connection module; compact-width windows
    /// (iPhone, narrow iPad multitasking) keep the existing list layout.
    private var isRegularWidth: Bool { horizontalSizeClass == .regular }

    var body: some View {
        Group {
            if isRegularWidth {
                regularWidthLayout
            } else {
                compactWidthLayout
            }
        }
        .background(WindowReader(anchor: anchor))
        .onAppear { notice = notice ?? Self.storeNotice(ProfileStore.shared.loadIssue) }
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        .onAppear {
            #if DEBUG && VICINIA_DEVELOPER_TOOLS
            reload()
            #endif
            handleAutoplay()
        }
        #endif
    }

    /// Compact-width layout: the existing iPhone connection screen, unchanged.
    private var compactWidthLayout: some View {
        NavigationStack {
            List {
                Section("Connect to a Mac (LAN)") {
                    TextField("Host or IP address", text: $host)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("macOS user name", text: $user)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password)
                    Button("Connect", action: connect)
                        .disabled(host.isEmpty || user.isEmpty || password.isEmpty)
                    Button("Forget pinned host key", role: .destructive, action: forget)
                        .disabled(host.isEmpty)
                    if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
                    if let error = ProfileStore.shared.lastWriteError {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                #if DEBUG && VICINIA_DEVELOPER_TOOLS
                Section("Recorded HPSS clips (Documents)") {
                    if clips.isEmpty {
                        Text("No .vclip files. Copy one into the app's Documents folder.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(clips, id: \.self) { url in
                        Button(url.lastPathComponent) { present(SessionSource(id: url.path(), clipURL: url)) }
                    }
                }
                Section("Diagnostics") {
                    Button("Measure session viewport") { present(SessionSource(id: "measure", clipURL: nil)) }
                }
                #endif
            }
            .navigationTitle("Vicinia")
            #if DEBUG && VICINIA_DEVELOPER_TOOLS
            .toolbar { Button("Refresh", action: reload) }
            #endif
        }
    }

    /// Regular-width layout: the same connection state and actions, centered
    /// in a 520-point module. The scroll view only scrolls when the content
    /// exceeds the window (short heights, large text, software keyboard).
    private var regularWidthLayout: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 6) {
                        Text("Vicinia")
                            .font(.largeTitle.bold())
                        Text("Connect to your Mac")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    VStack(spacing: 0) {
                        TextField("Host or IP address", text: $host)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .padding()
                        Divider().padding(.leading)
                        TextField("macOS user name", text: $user)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .padding()
                        Divider().padding(.leading)
                        SecureField("Password", text: $password)
                            .padding()
                    }
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
                    Button(action: connect) {
                        Text("Connect").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(host.isEmpty || user.isEmpty || password.isEmpty)
                    Button("Forget pinned host key", role: .destructive, action: forget)
                        .disabled(host.isEmpty)
                    if let notice {
                        Text(notice).font(.footnote).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    if let error = ProfileStore.shared.lastWriteError {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    #if DEBUG && VICINIA_DEVELOPER_TOOLS
                    developerToolsBox
                    #endif
                }
                .frame(maxWidth: 520)
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .center)
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    #if DEBUG && VICINIA_DEVELOPER_TOOLS
    /// Developer-tools sections for regular-width windows; same actions as the
    /// compact layout, with Refresh inline since there is no navigation bar.
    private var developerToolsBox: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recorded HPSS clips (Documents)").font(.headline)
                Spacer()
                Button("Refresh", action: reload)
            }
            if clips.isEmpty {
                Text("No .vclip files. Copy one into the app's Documents folder.")
                    .foregroundStyle(.secondary)
            }
            ForEach(clips, id: \.self) { url in
                Button(url.lastPathComponent) { present(SessionSource(id: url.path(), clipURL: url)) }
            }
            Divider()
            Text("Diagnostics").font(.headline)
            Button("Measure session viewport") { present(SessionSource(id: "measure", clipURL: nil)) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }
    #endif

    private func connect() {
        switch Self.reserveLiveSession(in: anchor.window) {
        case .refused(let reason):
            notice = reason                             // nothing saved, consumed or presented
        case .reserved(let claim):
            UserDefaults.standard.set(host, forKey: "host")
            UserDefaults.standard.set(user, forKey: "user")
            let secret = SecretBytes(password)
            password = ""                               // credential lifetime: until consumed by SRP
            let profile = ProfileStore.shared.binding(host: host, username: user)
            let source = SessionSource(id: "live-\(UUID().uuidString)", clipURL: nil,
                                       live: LiveRequest(host: host, username: user, password: secret,
                                                         profile: profile, claim: claim))
            if !SessionPresenter.present(source, in: anchor.window) {
                secret.wipe()
                LiveSessionSlot.shared.finish(claim)    // never presented: never started
                notice = String(localized: "The session could not be opened in this window. Try again.")
            }
        }
    }

    enum Reservation: Equatable {
        case reserved(LiveSessionSlot.Claim)
        case refused(String)
    }

    /// The single-session claim for a request made in `window`, taken before
    /// any side effect: refused when another window's session is live, or when
    /// this window cannot present a session now.
    static func reserveLiveSession(in window: UIWindow?, slot: LiveSessionSlot = .shared) -> Reservation {
        guard SessionPresenter.presenter(in: window) != nil else {
            return .refused(String(localized: "The session could not be opened in this window. Try again."))
        }
        guard let claim = slot.claim() else {
            return .refused(String(localized: "Another Mac session is open in another window. Close it there before connecting here."))
        }
        return .reserved(claim)
    }

    /// Saved Mac settings that could not be read are kept, never overwritten; say so.
    static func storeNotice(_ issue: ProfileStore.LoadIssue?) -> String? {
        switch issue {
        case .unreadable(let aside?): String(localized: "Saved Mac settings could not be read. They were kept as \(aside); defaults apply.")
        case .unreadable(nil): String(localized: "Saved Mac settings could not be read. They were kept unchanged; defaults apply.")
        case .newerSchema: String(localized: "Saved Mac settings come from a newer Vicinia. They are kept unchanged; changes are not saved.")
        case nil: nil
        }
    }

    private func forget() {
        do { try HostKeyPinStore.forget(host: host); notice = "Pinned key for \(host) removed." } catch {
            notice = "\(error)"
        }
    }

    private func present(_ source: SessionSource) {
        SessionPresenter.present(source, in: anchor.window)
    }

    #if DEBUG && VICINIA_DEVELOPER_TOOLS
    /// Sample discovery for the developer-tools documents section and Refresh button.
    private func reload() {
        let docs = URL.documentsDirectory
        let files = (try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil)) ?? []
        clips = files.filter { $0.pathExtension == "vclip" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    #endif

    #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
    /// Launch arguments for scripted physical tests: `-autoplay <file.vclip>`
    /// or `-autoplay measure`.
    private func handleAutoplay() {
        guard !autoplayHandled, let name = UserDefaults.standard.string(forKey: "autoplay") else { return }
        autoplayHandled = true
        if name == "measure" {
            present(SessionSource(id: "measure", clipURL: nil))
        } else {
            let url = URL.documentsDirectory.appending(path: name)
            present(SessionSource(id: url.path(), clipURL: url))
        }
    }
    #endif
}

/// The window that hosts a view, read from UIKit (SwiftUI does not expose it).
@MainActor final class WindowAnchor {
    weak var window: UIWindow?
    /// A view's stored default: created wherever the view value is.
    nonisolated init() {}
}

private struct WindowReader: UIViewRepresentable {
    let anchor: WindowAnchor

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.anchor = anchor
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: AnchorView, context: Context) { view.anchor = anchor }

    final class AnchorView: UIView {
        weak var anchor: WindowAnchor? { didSet { anchor?.window = window } }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            anchor?.window = window
        }
    }
}
