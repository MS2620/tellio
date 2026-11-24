import SwiftUI

// MARK: - Status

/// How a connection is doing, shown as a coloured dot and a short line.
enum ConnectionState: Equatable {
    case checking(String)
    case good(String)
    case problem(String)
    case off(String)

    var text: String {
        switch self {
        case .checking(let text), .good(let text), .problem(let text), .off(let text): return text
        }
    }

    var dot: Color {
        switch self {
        case .checking: return Color.white.opacity(0.4)
        case .good: return Theme.good
        case .problem: return Theme.warning
        case .off: return Color.white.opacity(0.25)
        }
    }
}

/// A connection row: icon tile, name, status line and a note on the right.
struct ConnectionRowLabel: View {
    let title: String
    let icon: String
    var state: ConnectionState? = nil
    var trailing: String? = nil
    var showsChevron = true
    /// A small tag after the title, e.g. "IN USE".
    var badge: String? = nil
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .semibold))
                .frame(width: 56, height: 56)
                .foregroundStyle(Color.white)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isFocused ? Theme.ink : Theme.glassStrong)
                )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 14) {
                    Text(title)
                        .font(.system(size: 28, weight: .semibold))
                        .lineLimit(1)
                    if let badge {
                        Text(badge)
                            .font(.system(size: 17, weight: .heavy))
                            .tracking(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(isFocused ? Theme.ink : Color.white))
                            .foregroundStyle(isFocused ? Color.white : Theme.ink)
                    }
                }
                if let state {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(isFocused && state.dot == Theme.good ? Color(red: 0.12, green: 0.54, blue: 0.3) : state.dot)
                            .frame(width: 11, height: 11)
                        Text(state.text)
                            .font(.system(size: 20, weight: .medium))
                            .opacity(0.72)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 16)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 22, weight: .medium))
                    .opacity(0.7)
                    .lineLimit(1)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 22, weight: .bold))
                    .opacity(isFocused ? 1 : 0.6)
            }
        }
        .foregroundStyle(isFocused ? Theme.ink : Color.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(isFocused ? Color.white : Color.clear)
        )
        .shadow(color: .black.opacity(isFocused ? 0.3 : 0), radius: 14, y: 6)
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

/// A label and value that can't be selected (status details).
private struct InfoLine: View {
    let title: String
    let value: String
    var dot: Color? = nil

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 26, weight: .semibold))
            Spacer(minLength: 16)
            if let dot {
                Circle().fill(dot).frame(width: 11, height: 11)
            }
            Text(value)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

/// Title area of an account page: icon, name and status.
private struct ConnectionHeader: View {
    let title: String
    let icon: String
    let state: ConnectionState

    var body: some View {
        HStack(spacing: 24) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .semibold))
                .frame(width: 88, height: 88)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.glassStrong))
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 48, weight: .heavy))
                    .lineLimit(1)
                HStack(spacing: 10) {
                    Circle().fill(state.dot).frame(width: 12, height: 12)
                    Text(state.text)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
            }
            Spacer()
        }
    }
}

/// Status checks shared by the overview and the account pages.
enum ConnectionCheck {
    static func iptv(_ settings: AppSettings) async -> (ConnectionState, XtreamAccountInfo?) {
        await iptv(settings.xtream, userAgent: settings.prefs.iptvUserAgent)
    }

    static func iptv(_ account: XtreamAccount, userAgent: String) async -> (ConnectionState, XtreamAccountInfo?) {
        guard account.isConfigured else {
            return (.off(String(localized: "IPTV · Not set up")), nil)
        }
        do {
            let info = try await XtreamClient(account: account, userAgent: userAgent).accountInfo()
            guard info.signedIn else { return (.problem(String(localized: "IPTV · Login failed")), info) }
            var parts = ["IPTV", info.isActive ? String(localized: "Online") : info.status]
            if let connections = info.connectionsText { parts.append(connections) }
            if let expires = info.expires {
                parts.append(String(localized: "expires \(expires.formatted(date: .abbreviated, time: .omitted))"))
            }
            let text = parts.joined(separator: " · ")
            return (info.isActive ? .good(text) : .problem(text), info)
        } catch {
            return (.problem(String(localized: "IPTV · Can't reach the server")), nil)
        }
    }

    static func tmdb(_ settings: AppSettings) async -> ConnectionState {
        guard !settings.tmdbToken.isEmpty else { return .off(String(localized: "Catalogue & artwork · Not set up")) }
        do {
            return try await settings.tmdb.validate()
                ? .good(String(localized: "Catalogue & artwork · Connected"))
                : .problem(String(localized: "Catalogue & artwork · Token not accepted"))
        } catch HTTPError.status(let code, _) where code == 401 {
            return .problem(String(localized: "Catalogue & artwork · Token not accepted"))
        } catch {
            return .problem(String(localized: "Catalogue & artwork · Can't reach TMDB"))
        }
    }

    static func addon(_ entry: AddonEntry) async -> (ConnectionState, AddonManifest?) {
        guard let url = URL(string: entry.manifestURL) else { return (.problem(String(localized: "Address isn't valid")), nil) }
        do {
            let manifest = try await StremioAddonClient(manifestURL: url).manifest()
            let kinds = (manifest.types ?? []).map(typeName).joined(separator: ", ")
            return (.good(kinds.isEmpty ? String(localized: "Online") : String(localized: "Online · \(kinds)")), manifest)
        } catch {
            return (.problem(String(localized: "Can't reach the addon")), nil)
        }
    }

    static func typeName(_ type: String) -> String {
        switch type {
        case "movie": return String(localized: "Movies")
        case "series": return String(localized: "Series")
        case "tv": return String(localized: "TV")
        case "channel": return String(localized: "Channels")
        default: return type.capitalized
        }
    }
}

// MARK: - Overview

struct ConnectionsView: View {
    @EnvironmentObject var settings: AppSettings
    /// Status of each IPTV account, by id.
    @State private var iptvStates: [String: ConnectionState] = [:]
    @State private var tmdb: ConnectionState = .checking(String(localized: "Catalogue & artwork · Checking…"))
    @State private var addonStates: [String: ConnectionState] = [:]
    @State private var versions: [String: String] = [:]
    @State private var confirmingDelete = false
    @ObservedObject private var trakt = TraktSync.shared

    private var languageName: String {
        LanguageOptions.catalogue.first { $0.0 == settings.prefs.catalogueLanguage }?.1 ?? settings.prefs.catalogueLanguage
    }

    /// Re-checks whenever a login or the addon list changes.
    private var checkKey: String {
        "\(settings.xtreamAccounts.hashValue)|\(settings.tmdbToken.count)|\(settings.addons.map(\.id).joined(separator: ","))"
    }

    var body: some View {
        SettingsPage("Connections") {
            GlassPanel("IPTV accounts") {
                ForEach(settings.xtreamAccounts) { account in
                    NavigationLink {
                        IPTVAccountView(accountID: account.id)
                    } label: {
                        ConnectionRowLabel(title: account.displayName,
                                           icon: "antenna.radiowaves.left.and.right",
                                           state: iptvStates[account.id] ?? .checking(String(localized: "IPTV · Checking…")),
                                           trailing: account.host,
                                           badge: settings.xtreamAccounts.count > 1 && account.id == settings.xtream.id
                                               ? String(localized: "IN USE") : nil)
                    }
                    .buttonStyle(PlainPressStyle())
                }
                NavigationLink {
                    IPTVAccountView(accountID: nil)
                } label: {
                    ConnectionRowLabel(title: settings.xtreamAccounts.isEmpty ? String(localized: "Add IPTV account") : String(localized: "Add another IPTV account"),
                                       icon: "plus")
                }
                .buttonStyle(PlainPressStyle())
            }
            if settings.xtreamAccounts.count > 1 {
                SettingsNote("Live TV uses one account at a time. Open an account and choose Use for Live TV, or switch from the Live TV sidebar.")
            }

            GlassPanel("Accounts") {
                NavigationLink {
                    TMDBAccountView()
                } label: {
                    ConnectionRowLabel(title: "TMDB", icon: "film", state: tmdb,
                                       trailing: settings.tmdbToken.isEmpty ? String(localized: "Set up") : languageName)
                }
                .buttonStyle(PlainPressStyle())

                NavigationLink {
                    TraktAccountView()
                } label: {
                    ConnectionRowLabel(title: "Trakt", icon: "checkmark.seal",
                                       state: trakt.isSignedIn
                                           ? .good(String(localized: "Sync · \(trakt.username ?? String(localized: "signed in"))"))
                                           : .off(String(localized: "Sync · Not connected")),
                                       trailing: trakt.isSignedIn ? nil : String(localized: "Set up"))
                }
                .buttonStyle(PlainPressStyle())
            }

            GlassPanel("Stremio addons") {
                ForEach(settings.addons) { addon in
                    NavigationLink {
                        AddonDetailView(addonID: addon.id)
                    } label: {
                        ConnectionRowLabel(title: addon.name, icon: "puzzlepiece.extension",
                                           state: addonStates[addon.id] ?? .checking(String(localized: "Checking…")),
                                           trailing: versions[addon.id].map { "v" + $0 })
                    }
                    .buttonStyle(PlainPressStyle())
                }
                NavigationLink {
                    AddAddonView()
                } label: {
                    ConnectionRowLabel(title: String(localized: "Add addon"), icon: "plus")
                }
                .buttonStyle(PlainPressStyle())
            }
            SettingsNote("Movies and series play from your Stremio addons. Streams are tried in the order the addons are listed here.")

            GlassPanel("Account management") {
                Button {
                    confirmingDelete = true
                } label: {
                    ListRowLabel(title: String(localized: "Delete all logins and addons"), icon: "trash", destructive: true)
                }
                .buttonStyle(PlainPressStyle())
            }
        }
        .task(id: checkKey) { await check() }
        .confirmationDialog("Delete all logins and addons?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete all", role: .destructive) { settings.deleteAllConnections() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Signs out of TMDB and your IPTV account and removes every addon. Your favourites, folders and other settings stay.")
        }
    }

    private func check() async {
        let accounts = settings.xtreamAccounts
        let userAgent = settings.prefs.iptvUserAgent
        async let tmdbResult = ConnectionCheck.tmdb(settings)
        let addons = settings.addons
        await withTaskGroup(of: (String, ConnectionState, String?).self) { group in
            for addon in addons {
                group.addTask {
                    let (state, manifest) = await ConnectionCheck.addon(addon)
                    return (addon.id, state, manifest?.version)
                }
            }
            for await (id, state, version) in group {
                addonStates[id] = state
                if let version { versions[id] = version }
            }
        }
        await withTaskGroup(of: (String, ConnectionState).self) { group in
            for account in accounts {
                group.addTask { (account.id, await ConnectionCheck.iptv(account, userAgent: userAgent).0) }
            }
            for await (id, state) in group { iptvStates[id] = state }
        }
        tmdb = await tmdbResult
    }
}

// MARK: - IPTV account

struct IPTVAccountView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    /// The account to show; nil adds a new one (saved once server, username and password are in).
    let accountID: String?
    @State private var newAccount = XtreamAccount()
    @State private var createdID: String?

    private enum Field: String, Identifiable {
        case name, server, username, password
        var id: String { rawValue }
    }

    @State private var state: ConnectionState = .checking(String(localized: "Checking…"))
    @State private var info: XtreamAccountInfo?
    @State private var channelCount: Int?
    @State private var groupCount: Int?
    @State private var confirmingRemove = false
    @State private var testNote: String?

    private var currentID: String? { accountID ?? createdID }

    private var account: XtreamAccount {
        guard let id = currentID else { return newAccount }
        if settings.xtream.id == id { return settings.xtream }
        return settings.xtreamAccounts.first { $0.id == id } ?? newAccount
    }

    private var isInUse: Bool { settings.xtream.isConfigured && settings.xtream.id == account.id }

    /// Applies an edit to this account, wherever it lives.
    private func update(_ change: (inout XtreamAccount) -> Void) {
        var edited = account
        change(&edited)
        if currentID != nil {
            settings.updateAccount(edited)
        } else {
            newAccount = edited
            if edited.isConfigured {
                settings.addAccount(edited)
                createdID = edited.id
            }
        }
    }

    private var refreshText: String {
        switch settings.prefs.epgRefreshHours {
        case ..<0: return String(localized: "Refreshed when you ask")
        case 0: return String(localized: "Refreshed every launch")
        case 1: return String(localized: "Refreshed every hour")
        case 24: return String(localized: "Refreshed once a day")
        case let hours: return String(localized: "Refreshed every \(hours) hours")
        }
    }

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    ConnectionHeader(title: account.isConfigured ? account.displayName : "IPTV",
                                     icon: "antenna.radiowaves.left.and.right",
                                     state: state)

                    if account.isConfigured && !isInUse {
                        GlassPanel {
                            Button {
                                settings.switchAccount(to: account.id)
                            } label: {
                                ListRowLabel(title: String(localized: "Use for Live TV"), icon: "checkmark")
                            }
                            .buttonStyle(PlainPressStyle())
                        }
                        .frame(maxWidth: 760)
                    }

                    HStack(alignment: .top, spacing: 40) {
                        VStack(spacing: 18) {
                            GlassPanel("Login") {
                                fieldRow(.name, title: String(localized: "Name"), icon: "textformat",
                                         value: account.name.isEmpty ? String(localized: "Optional") : account.name)
                                fieldRow(.server, title: String(localized: "Server"), icon: "globe",
                                         value: account.server.isEmpty ? String(localized: "Not set") : account.host)
                                fieldRow(.username, title: String(localized: "Username"), icon: "person",
                                         value: account.username.isEmpty ? String(localized: "Not set") : account.username)
                                fieldRow(.password, title: String(localized: "Password"), icon: "lock",
                                         value: account.password.isEmpty ? String(localized: "Not set") : "••••••••")
                            }
                            SettingsNote("Select a field to type in it. The name is only for you; without one the server is shown.")
                                .padding(.top, 14)
                        }

                        VStack(spacing: 34) {
                            GlassPanel("Status") {
                                if let info, info.signedIn {
                                    InfoLine(title: String(localized: "Account"), value: info.status.capitalized,
                                             dot: info.isActive ? Theme.good : Theme.warning)
                                    if let connections = info.connectionsText {
                                        InfoLine(title: String(localized: "Connections"), value: connections)
                                    }
                                    if let expires = info.expires {
                                        InfoLine(title: String(localized: "Expires"), value: expires.formatted(date: .abbreviated, time: .omitted))
                                    }
                                    if let channelCount, let groupCount {
                                        InfoLine(title: String(localized: "Live TV"), value: String(localized: "\(channelCount) channels · \(groupCount) groups"))
                                    }
                                    InfoLine(title: String(localized: "TV guide"), value: refreshText)
                                } else {
                                    InfoLine(title: String(localized: "Account"), value: state.text, dot: state.dot)
                                }
                            }

                            GlassPanel {
                                Button {
                                    Task { await check(announce: true) }
                                } label: {
                                    ListRowLabel(title: String(localized: "Test connection"), icon: "arrow.clockwise", trailing: testNote)
                                }
                                .buttonStyle(PlainPressStyle())
                                .disabled(!account.isConfigured)

                                Button {
                                    confirmingRemove = true
                                } label: {
                                    ListRowLabel(title: String(localized: "Remove account"), icon: "trash", destructive: true)
                                }
                                .buttonStyle(PlainPressStyle())
                                .disabled(!account.isConfigured)
                            }
                        }
                    }
                }
                .frame(maxWidth: 1560)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            }
        }
        .task(id: account) { await check(announce: false) }
        .confirmationDialog("Remove this IPTV account?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove account", role: .destructive) {
                let wasInUse = isInUse
                settings.removeAccount(id: account.id)
                if wasInUse {
                    Task {
                        await XtreamCache.shared.clearGuide()
                        await SportsGuide.shared.clear()
                    }
                }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(settings.xtreamAccounts.count > 1
                 ? "Its favourites, folders and reminders are removed too."
                 : "Live TV and Sports channels stop working until you add a login again.")
        }
    }

    private func fieldRow(_ field: Field, title: String, icon: String, value: String) -> some View {
        TypingRow(title: title, icon: icon, value: value, initial: initial(field),
                  secure: field == .password, autocapitalize: field == .name,
                  allowsEmpty: field == .name) { value in
            update {
                switch field {
                case .name: $0.name = value
                case .server: $0.server = value
                case .username: $0.username = value
                case .password: $0.password = value
                }
            }
        }
    }

    private func initial(_ field: Field) -> String {
        switch field {
        case .name: return account.name
        case .server: return account.server
        case .username: return account.username
        case .password: return account.password
        }
    }

    private func check(announce: Bool) async {
        if announce { testNote = String(localized: "Checking…") }
        state = .checking(String(localized: "Checking…"))
        let (newState, newInfo) = await ConnectionCheck.iptv(account, userAgent: settings.prefs.iptvUserAgent)
        state = newState
        info = newInfo
        if announce {
            if case .good = newState { testNote = String(localized: "Working") } else { testNote = String(localized: "Not working") }
        }
        guard newInfo?.signedIn == true else {
            channelCount = nil
            groupCount = nil
            return
        }
        let client = XtreamClient(account: account, userAgent: settings.prefs.iptvUserAgent)
        channelCount = (try? await XtreamCache.shared.liveStreams(client))?.count
        groupCount = (try? await XtreamCache.shared.liveCategories(client))?.count
    }
}

// MARK: - TMDB

struct TMDBAccountView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var state: ConnectionState = .checking(String(localized: "Checking…"))
    @State private var confirmingRemove = false

    private var maskedToken: String {
        let token = settings.ownTmdbToken
        guard !token.isEmpty else { return settings.usingBuiltInTMDB ? String(localized: "Built in") : String(localized: "Not set") }
        return "••••" + String(token.suffix(4))
    }

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    ConnectionHeader(title: "TMDB", icon: "film", state: state)

                    GlassPanel("Login") {
                        TypingRow(title: String(localized: "API Read Access Token"), icon: "key", value: maskedToken,
                                  initial: settings.ownTmdbToken, secure: true) { value in
                            settings.tmdbToken = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    SettingsNote(!AppSettings.builtInTMDBToken.isEmpty
                        ? "Tellio has a TMDB key built in, so there's nothing to set up. To use your own instead, get the long \"API Read Access Token\" from themoviedb.org → Settings → API."
                        : "Free from themoviedb.org → Settings → API. Use the long \"API Read Access Token\", not the short API key.")

                    GlassPanel("Catalogue") {
                        SettingsOptionRow("Language", icon: "globe", selection: $settings.prefs.catalogueLanguage,
                                          options: LanguageOptions.catalogue)
                        SettingsOptionRow("Region", icon: "mappin.and.ellipse", selection: $settings.prefs.tmdbRegion,
                                          options: LanguageOptions.regions.map { ($0.code, $0.name) })
                    }

                    GlassPanel {
                        Button {
                            Task { await check() }
                        } label: {
                            ListRowLabel(title: String(localized: "Test connection"), icon: "arrow.clockwise")
                        }
                        .buttonStyle(PlainPressStyle())
                        .disabled(settings.tmdbToken.isEmpty)

                        Button {
                            confirmingRemove = true
                        } label: {
                            ListRowLabel(title: AppSettings.builtInTMDBToken.isEmpty ? String(localized: "Remove token") : String(localized: "Remove your token"),
                                         icon: "trash", destructive: true)
                        }
                        .buttonStyle(PlainPressStyle())
                        .disabled(settings.ownTmdbToken.isEmpty)
                    }
                }
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            }
        }
        .task(id: settings.tmdbToken) { await check() }
        .confirmationDialog("Remove the TMDB token?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove token", role: .destructive) { settings.tmdbToken = "" }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(AppSettings.builtInTMDBToken.isEmpty
                 ? "Home, Movies, Series, Calendar and Search need it to show anything."
                 : "Tellio goes back to its built-in key.")
        }
    }

    private func check() async {
        state = .checking(String(localized: "Checking…"))
        state = await ConnectionCheck.tmdb(settings)
    }
}

// MARK: - Addons

struct AddonDetailView: View {
    let addonID: String
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var state: ConnectionState = .checking(String(localized: "Checking…"))
    @State private var manifest: AddonManifest?
    @State private var confirmingRemove = false
    @State private var renaming = false

    private var addon: AddonEntry? {
        settings.addons.first { $0.id == addonID }
    }

    private var index: Int? {
        settings.addons.firstIndex { $0.id == addonID }
    }

    private var address: String {
        guard let addon, let url = URL(string: addon.manifestURL) else { return "—" }
        return url.host ?? addon.manifestURL
    }

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    ConnectionHeader(title: addon?.name ?? String(localized: "Addon"), icon: "puzzlepiece.extension", state: state)

                    GlassPanel("About") {
                        InfoLine(title: String(localized: "Version"), value: manifest?.version ?? "—")
                        InfoLine(title: String(localized: "Provides"),
                                 value: (manifest?.types ?? []).map(ConnectionCheck.typeName).joined(separator: ", ").nonEmpty ?? "—")
                        InfoLine(title: String(localized: "Address"), value: address)
                        if let description = manifest?.description, !description.isEmpty {
                            Text(description)
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(3)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 10)
                        }
                    }

                    GlassPanel("Order") {
                        Button {
                            move(by: -1)
                        } label: {
                            ListRowLabel(title: String(localized: "Move up"), icon: "arrow.up",
                                         trailing: index.map { String(localized: "\($0 + 1) of \(settings.addons.count)") })
                        }
                        .buttonStyle(PlainPressStyle())
                        .disabled((index ?? 0) == 0)

                        Button {
                            move(by: 1)
                        } label: {
                            ListRowLabel(title: String(localized: "Move down"), icon: "arrow.down")
                        }
                        .buttonStyle(PlainPressStyle())
                        .disabled((index ?? 0) >= settings.addons.count - 1)
                    }
                    SettingsNote("When streams are sorted by addon order (Settings → Streams), addons higher in the list come first.")

                    GlassPanel {
                        Button {
                            renaming = true
                        } label: {
                            ListRowLabel(title: String(localized: "Rename"), icon: "pencil")
                        }
                        .buttonStyle(PlainPressStyle())

                        Button {
                            confirmingRemove = true
                        } label: {
                            ListRowLabel(title: String(localized: "Remove addon"), icon: "trash", destructive: true)
                        }
                        .buttonStyle(PlainPressStyle())
                    }
                }
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            }
        }
        .task {
            guard let addon else { return }
            let result = await ConnectionCheck.addon(addon)
            state = result.0
            manifest = result.1
        }
        .sheet(isPresented: $renaming) {
            NameSheet(title: String(localized: "Rename addon"), initial: addon?.name ?? "") { value in
                guard let index else { return }
                settings.addons[index].name = value
            }
        }
        .confirmationDialog("Remove this addon?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove addon", role: .destructive) {
                settings.addons.removeAll { $0.id == addonID }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func move(by offset: Int) {
        guard let from = index else { return }
        let to = from + offset
        guard settings.addons.indices.contains(to) else { return }
        var list = settings.addons
        list.swapAt(from, to)
        settings.addons = list
    }
}

struct AddAddonView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var status: String?
    @State private var adding = false

    var body: some View {
        SettingsPage("Add addon") {
            GlassPanel("Manifest address") {
                TextField("https://…/manifest.json", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                Button {
                    Task { await add() }
                } label: {
                    ListRowLabel(title: adding ? String(localized: "Checking…") : String(localized: "Add addon"), icon: "plus", trailing: status)
                }
                .buttonStyle(PlainPressStyle())
                .disabled(adding || address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            SettingsNote("Use the manifest link from the addon's own configuration page (stremio:// links work too). Only results with a direct link can be played; torrent-only results are hidden.")
        }
    }

    private func add() async {
        guard let url = StremioAddonClient.normalize(address) else {
            status = String(localized: "That isn't a valid address")
            return
        }
        guard !settings.addons.contains(where: { $0.manifestURL == url.absoluteString }) else {
            status = String(localized: "Already added")
            return
        }
        adding = true
        defer { adding = false }
        do {
            let manifest = try await StremioAddonClient(manifestURL: url).manifest()
            settings.addons.append(AddonEntry(manifestURL: url.absoluteString, name: manifest.name))
            dismiss()
        } catch {
            status = String(localized: "Couldn't load it")
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Trakt

struct TraktAccountView: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var trakt = TraktSync.shared

    @State private var code: TraktDeviceCode?
    @State private var codeStarted = Date()
    @State private var signInMessage: String?
    @State private var confirmingSignOut = false

    private var state: ConnectionState {
        if let error = trakt.lastError { return .problem(error) }
        if trakt.isSignedIn { return .good(trakt.username.map { String(localized: "Signed in as \($0)") } ?? String(localized: "Signed in")) }
        if code != nil { return .checking(String(localized: "Waiting for you to approve…")) }
        return .off(trakt.hasApp ? String(localized: "Not signed in") : String(localized: "Add a Trakt Client ID first"))
    }

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    ConnectionHeader(title: "Trakt", icon: "checkmark.seal", state: state)

                    if let code, !trakt.isSignedIn {
                        codePanel(code)
                    }

                    if trakt.isSignedIn {
                        accountPanel
                        syncPanel
                    } else if code == nil {
                        GlassPanel {
                            Button {
                                Task { await startSignIn() }
                            } label: {
                                ListRowLabel(title: String(localized: "Sign in to Trakt"), icon: "person.crop.circle.badge.plus")
                            }
                            .buttonStyle(PlainPressStyle())
                            .disabled(!trakt.hasApp)
                        }
                        if let signInMessage {
                            SettingsNote(signInMessage)
                        } else {
                            SettingsNote(trakt.hasApp
                                ? "Sign in with your Trakt account. No Trakt app or keys to set up."
                                : "This copy of Tellio has no Trakt app built in. Add your own below to sign in.")
                        }
                    }

                    GlassPanel {
                        SettingsLinkRow("Use your own Trakt app", icon: "gearshape",
                                        value: trakt.usingOwnApp ? String(localized: "Your own") : (trakt.hasBuiltInApp ? String(localized: "Built in") : String(localized: "Set up"))) {
                            TraktOwnAppView()
                        }
                    }
                }
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            }
        }
        .confirmationDialog("Sign out of Trakt?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { trakt.signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Progress and ticks already on this Apple TV stay. Nothing is deleted on Trakt.")
        }
        .task(id: code?.deviceCode) { await pollLoop() }
    }

    private func codePanel(_ code: TraktDeviceCode) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("On your phone or computer, go to")
                .font(.system(size: 28, weight: .bold))
            Text(code.verificationUrl.replacingOccurrences(of: "https://", with: ""))
                .font(.system(size: 44, weight: .heavy))
                .foregroundStyle(Color(red: 0.93, green: 0.11, blue: 0.14))
            Text("and enter this code")
                .font(.system(size: 26, weight: .semibold))
            HStack(spacing: 12) {
                ForEach(Array(code.userCode.enumerated()), id: \.offset) { _, character in
                    Text(String(character))
                        .font(.system(size: 48, weight: .heavy))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 72, height: 92)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, Int(codeStarted.addingTimeInterval(TimeInterval(code.expiresIn)).timeIntervalSince(context.date)))
                Text("Waiting for you to approve… code expires in \(left / 60):\(String(format: "%02d", left % 60))")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Button {
                self.code = nil
            } label: {
                PillLabel(title: String(localized: "Cancel"), icon: "xmark")
            }
            .buttonStyle(PlainPressStyle())
        }
        .padding(40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 34, style: .continuous).fill(Theme.glass))
    }

    private var accountPanel: some View {
        GlassPanel("Trakt") {
            Button {
                confirmingSignOut = true
            } label: {
                ListRowLabel(title: String(localized: "Signed in as \(trakt.username ?? String(localized: "your account"))"), icon: "person.crop.circle",
                             trailing: String(localized: "Sign out"))
            }
            .buttonStyle(PlainPressStyle())
            Button {
                Task { await trakt.sync() }
            } label: {
                ListRowLabel(title: trakt.syncing ? String(localized: "Syncing…") : String(localized: "Sync now"), icon: "arrow.triangle.2.circlepath",
                             trailing: trakt.lastSync.map { String(localized: "Last synced \($0.formatted(.relative(presentation: .named)))") })
            }
            .buttonStyle(PlainPressStyle())
            .disabled(trakt.syncing)
        }
    }

    private var syncPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            GlassPanel("What to sync") {
                SettingsToggleRow("Watch progress & Continue Watching", icon: "play.circle", isOn: $settings.prefs.traktProgress)
                SettingsToggleRow("Watched history", icon: "checkmark.circle", isOn: $settings.prefs.traktHistory)
                SettingsToggleRow("Watchlist ↔ My List", icon: "plus.circle", isOn: $settings.prefs.traktWatchlist)
                SettingsToggleRow("Scrobble while watching", icon: "dot.radiowaves.left.and.right", isOn: $settings.prefs.traktScrobble)
            }
            SettingsNote("Syncs when Tellio opens and every 10 minutes. Scrobbling shows \u{201C}Watching now\u{201D} on your Trakt profile and marks things watched at 80%.")
        }
    }

    private func startSignIn() async {
        signInMessage = nil
        do {
            let fresh = try await trakt.startSignIn()
            codeStarted = Date()
            code = fresh
        } catch {
            signInMessage = String(localized: "Couldn't start sign-in: \(error.localizedDescription). Check the client ID.")
        }
    }

    private func pollLoop() async {
        guard let code else { return }
        var interval = max(code.interval, 5)
        let deadline = codeStarted.addingTimeInterval(TimeInterval(code.expiresIn))
        while !Task.isCancelled, Date() < deadline {
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            switch await trakt.poll(code) {
            case .approved:
                self.code = nil
                return
            case .pending:
                continue
            case .slowDown:
                interval += 5
            case .expired:
                self.code = nil
                signInMessage = String(localized: "The code expired. Sign in again.")
                return
            case .denied:
                self.code = nil
                signInMessage = String(localized: "Sign-in was declined on Trakt.")
                return
            case .failed(let message):
                self.code = nil
                signInMessage = message
                return
            }
        }
        if !Task.isCancelled, self.code != nil {
            self.code = nil
            signInMessage = String(localized: "The code expired. Sign in again.")
        }
    }
}

/// Settings › Connections › Trakt › Use your own Trakt app: swaps the built-in Client ID for yours.
struct TraktOwnAppView: View {
    @ObservedObject private var trakt = TraktSync.shared

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    Text("Your own Trakt app")
                        .font(.system(size: 44, weight: .heavy))
                    GlassPanel {
                        TypingRow(title: String(localized: "Client ID"), icon: "key",
                                  value: trakt.clientID.isEmpty
                                      ? (trakt.hasBuiltInApp ? String(localized: "Built in") : String(localized: "Not set"))
                                      : "••••" + String(trakt.clientID.suffix(4)),
                                  initial: trakt.clientID, allowsEmpty: true) { trakt.clientID = $0 }
                        if !trakt.clientID.isEmpty {
                            TypingRow(title: String(localized: "Client secret (older apps only)"), icon: "lock",
                                      value: trakt.clientSecret.isEmpty ? String(localized: "None") : "••••••",
                                      initial: trakt.clientSecret, secure: true, allowsEmpty: true) {
                                trakt.clientSecret = $0
                            }
                        }
                        if trakt.usingOwnApp && trakt.hasBuiltInApp {
                            Button {
                                trakt.clientID = ""
                                trakt.clientSecret = ""
                            } label: {
                                ListRowLabel(title: String(localized: "Go back to the built-in app"), icon: "arrow.uturn.backward")
                            }
                            .buttonStyle(PlainPressStyle())
                        }
                    }
                    SettingsNote("On trakt.tv go to Settings › Your API Apps › New Application, give it any name and use urn:ietf:wg:oauth:2.0:oob as the redirect URI. New apps only have a Client ID; a secret is only needed for apps made before October 2026. After changing the app, sign in to Trakt again.")
                }
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            }
        }
    }
}
