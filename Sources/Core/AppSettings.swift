import Foundation
import Combine

struct XtreamAccount: Codable, Hashable, Identifiable {
    /// Stable id, so an account keeps its favourites etc. even if its server is edited.
    var id = UUID().uuidString
    var server = ""
    var username = ""
    var password = ""
    /// The user's own label for the account; empty shows the server name.
    var name = ""
    /// Set for an M3U playlist account, which has no server, username or password.
    var playlistURL = ""
    /// The playlist's XMLTV guide, when it isn't named in the playlist itself.
    var guideURL = ""

    var isM3U: Bool { !playlistURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var isConfigured: Bool { isM3U || (!server.isEmpty && !username.isEmpty && !password.isEmpty) }

    /// The server (or playlist site) without "http://", port or path, e.g. "vpn.example.com".
    var host: String {
        if isM3U { return URL(string: playlistURL.trimmingCharacters(in: .whitespaces))?.host ?? playlistURL }
        return URL(string: normalizedServer)?.host ?? server
    }

    /// Identifies the account's downloads (channel lists, guide files) across launches.
    var cacheKey: String {
        isM3U ? "m3u|" + playlistURL : normalizedServer + "|" + username
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? host : trimmed
    }

    var normalizedServer: String {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.lowercased().hasPrefix("http") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

extension XtreamAccount {
    private enum CodingKeys: String, CodingKey {
        case id, server, username, password, name, playlistURL, guideURL
    }

    /// Accounts saved by older versions have no name; every field is optional.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        // Accounts from before multiple accounts have no id; they get one and keep it once saved.
        if let saved = try? c.decodeIfPresent(String.self, forKey: .id), !saved.isEmpty { id = saved }
        server = (try? c.decodeIfPresent(String.self, forKey: .server)) ?? ""
        username = (try? c.decodeIfPresent(String.self, forKey: .username)) ?? ""
        password = (try? c.decodeIfPresent(String.self, forKey: .password)) ?? ""
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        playlistURL = (try? c.decodeIfPresent(String.self, forKey: .playlistURL)) ?? ""
        guideURL = (try? c.decodeIfPresent(String.self, forKey: .guideURL)) ?? ""
    }
}

struct AddonEntry: Codable, Identifiable, Hashable {
    var id: String { manifestURL }
    let manifestURL: String
    var name: String
    /// Off: kept with its settings, but not used for anything.
    var enabled = true
    /// What it's searched for, as chosen by hand; nil follows `detectedUses`.
    var chosenUses: Set<AddonUse>? = nil
    /// What its manifest says it offers, saved when it was last read; nil until then.
    var detectedUses: Set<AddonUse>? = nil

    /// What it's searched for: the user's choice, or else what it offers.
    var uses: Set<AddonUse> { chosenUses ?? detectedUses ?? Set(AddonUse.allCases) }

    func isUsed(for use: AddonUse) -> Bool { enabled && uses.contains(use) }

    init(manifestURL: String, name: String, detectedUses: Set<AddonUse>? = nil) {
        self.manifestURL = manifestURL
        self.name = name
        self.detectedUses = detectedUses
    }

    // Addons saved before these settings existed come back switched on and automatic.
    private enum CodingKeys: String, CodingKey { case manifestURL, name, enabled, chosenUses, detectedUses }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        manifestURL = try c.decode(String.self, forKey: .manifestURL)
        name = try c.decode(String.self, forKey: .name)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        chosenUses = (try? c.decodeIfPresent([Lenient<AddonUse>].self, forKey: .chosenUses))
            .map { Set($0.compactMap(\.value)) }
        detectedUses = (try? c.decodeIfPresent([Lenient<AddonUse>].self, forKey: .detectedUses))
            .map { Set($0.compactMap(\.value)) }
    }
}

/// What an addon is searched for. Sports & live TV covers channels, games and highlights.
enum AddonUse: String, Codable, CaseIterable, Identifiable {
    case movies, series, live

    var id: String { rawValue }

    var label: String {
        switch self {
        case .movies: return String(localized: "Movies")
        case .series: return String(localized: "Series")
        case .live: return String(localized: "Sports & live TV")
        }
    }

    /// For a Stremio type: "movie" is Movies, "series" (and "anime") Series.
    init(stremioType: String) {
        switch stremioType.lowercased() {
        case "movie": self = .movies
        case "series", "anime": self = .series
        default: self = .live
        }
    }

    /// What a manifest says the addon offers: the types it states (a movie addon with an odd
    /// extra list stays a movie addon), or else the kinds of lists it has. Nothing stated means everything.
    static func offered(by manifest: AddonManifest) -> Set<AddonUse> {
        let stated = manifest.types ?? []
        let types = stated.isEmpty ? (manifest.catalogs ?? []).map(\.type) : stated
        let uses = Set(types.map(AddonUse.init(stremioType:)))
        return uses.isEmpty ? Set(allCases) : uses
    }
}

/// All user-supplied credentials. Everything is stored in the Keychain because
/// addon URLs can carry private configuration.
final class AppSettings: ObservableObject {
    /// The token you entered yourself, if any (Settings › Connections › TMDB).
    @Published var ownTmdbToken: String { didSet { Keychain.set(ownTmdbToken, for: "tmdbToken") } }

    /// The token built into this copy (GitHub secret TMDB_TOKEN), if any. The build stores it
    /// scrambled ("x1:" + base64 of the token XOR-ed with `tokenMask`) so it isn't readable as
    /// plain text in the app file; a plain value (e.g. a fork's own build) still works.
    static let builtInTMDBToken: String = {
        let value = (Bundle.main.object(forInfoDictionaryKey: "TMDBToken") as? String ?? "")
            .trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("$(") { return "" }
        guard value.hasPrefix("x1:") else { return value }
        guard let data = Data(base64Encoded: String(value.dropFirst(3))) else { return "" }
        let bytes = data.enumerated().map { $0.element ^ tokenMask[$0.offset % tokenMask.count] }
        return String(decoding: bytes, as: UTF8.self)
    }()

    /// Must match TOKEN_MASK in .github/workflows/build.yml.
    private static let tokenMask: [UInt8] = Array("T3ll10-sh3lf-m4sk-2026".utf8)

    /// The token in use: yours if you've entered one, otherwise the built-in one.
    /// Setting it sets yours; setting "" goes back to the built-in one.
    var tmdbToken: String {
        get { ownTmdbToken.isEmpty ? Self.builtInTMDBToken : ownTmdbToken }
        set { ownTmdbToken = newValue }
    }
    var usingBuiltInTMDB: Bool { ownTmdbToken.isEmpty && !Self.builtInTMDBToken.isEmpty }
    /// The IPTV account Live TV uses now. Editing it also updates its entry in `xtreamAccounts`.
    @Published var xtream: XtreamAccount {
        didSet {
            Keychain.setCodable(xtream, for: "xtream")
            guard xtream.isConfigured else { return }
            if let index = xtreamAccounts.firstIndex(where: { $0.id == xtream.id }) {
                if xtreamAccounts[index] != xtream { xtreamAccounts[index] = xtream }
            } else {
                xtreamAccounts.append(xtream)
            }
        }
    }
    /// Every IPTV account, the one in use included. Live TV uses one at a time.
    @Published var xtreamAccounts: [XtreamAccount] {
        didSet { Keychain.setCodable(xtreamAccounts, for: "xtreamAccounts") }
    }
    @Published var addons: [AddonEntry] { didSet { Keychain.setCodable(addons, for: "addons") } }

    /// The addons switched on.
    var enabledAddons: [AddonEntry] { addons.filter(\.enabled) }

    /// The addons switched on and searched for `use` (parental locks aside).
    func addons(for use: AddonUse) -> [AddonEntry] { addons.filter { $0.isUsed(for: use) } }

    /// Saves what an addon offers, from its manifest just read.
    @MainActor
    func noteManifest(_ manifest: AddonManifest, for addonID: String) {
        let uses = AddonUse.offered(by: manifest)
        guard let index = addons.firstIndex(where: { $0.id == addonID }), addons[index].detectedUses != uses else { return }
        addons[index].detectedUses = uses
    }

    /// Reads every addon's manifest (kept for an hour) and saves what each offers. Run at launch,
    /// so addons added before categories existed get theirs.
    @MainActor
    func detectAddonUses() async {
        for addon in addons {
            guard let url = URL(string: addon.manifestURL),
                  let manifest = await AddonManifests.shared.manifest(url) else { continue }
            noteManifest(manifest, for: addon.id)
        }
    }
    @Published var prefs: Preferences {
        didSet {
            prefs.save()
            QualitySort.activeCategoryIDs = prefs.qualitySortCategoryIDs
            QualitySort.activeCustomNames = prefs.channelNames
            ReminderStore.leadMinutes = prefs.reminderLeadMinutes
            ReminderStore.remindTeamMatches = prefs.remindTeamMatches
            if prefs.remindTeamMatches != oldValue.remindTeamMatches
                || prefs.favouriteTeams != oldValue.favouriteTeams {
                let teams = Set(prefs.favouriteTeams.map(\.name))
                Task { @MainActor in ReminderStore.shared.teamMatchesSettingChanged(teams: teams) }
            }
            if prefs.epgRefreshHours != oldValue.epgRefreshHours {
                let hours = prefs.epgRefreshHours
                Task {
                    await XtreamCache.shared.configure(refreshHours: hours)
                    await SportsGuide.shared.configure(refreshHours: hours)
                    await M3UGuide.shared.configure(refreshHours: hours)
                }
            }
        }
    }

    var tmdb: TMDBClient {
        TMDBClient(token: tmdbToken, language: prefs.catalogueLanguageInUse, region: prefs.tmdbRegion)
    }

    var xtreamClient: XtreamClient {
        XtreamClient(account: xtream, userAgent: prefs.iptvUserAgent)
    }

    init() {
        ownTmdbToken = Keychain.string(for: "tmdbToken") ?? ""
        // Older versions stored a Real-Debrid key; Tellio no longer uses one.
        Keychain.setData(nil, for: "realDebridKey")
        let active = Keychain.codable(XtreamAccount.self, for: "xtream") ?? XtreamAccount()
        var accounts = Keychain.codable([XtreamAccount].self, for: "xtreamAccounts") ?? []
        if accounts.isEmpty, active.isConfigured { accounts = [active] }
        xtream = active
        xtreamAccounts = accounts
        // Save once so an account from an older version keeps the id it was just given.
        Keychain.setCodable(active, for: "xtream")
        Keychain.setCodable(accounts, for: "xtreamAccounts")
        ReminderStore.activeAccountID = active.isConfigured ? active.id : nil
        addons = Keychain.codable([AddonEntry].self, for: "addons") ?? []
        let freshInstall = !Preferences.hasSaved
        prefs = Preferences.load()
        ReminderStore.leadMinutes = prefs.reminderLeadMinutes
        ReminderStore.remindTeamMatches = prefs.remindTeamMatches
        QualitySort.activeCategoryIDs = prefs.qualitySortCategoryIDs
        QualitySort.activeCustomNames = prefs.channelNames
        // Anyone who already set Tellio up (before the setup screens existed) skips them.
        // A fresh install always gets setup, even with logins left in the Keychain by an
        // earlier install; its steps start filled in with them.
        if !freshInstall && !prefs.setupDone && (active.isConfigured || !addons.isEmpty
                                                 || !prefs.myList.isEmpty || !prefs.favouriteTeams.isEmpty) {
            prefs.setupDone = true
            prefs.save()
        }
        let hours = prefs.epgRefreshHours
        Task {
            await XtreamCache.shared.configure(refreshHours: hours)
            await SportsGuide.shared.configure(refreshHours: hours)
            await M3UGuide.shared.configure(refreshHours: hours)
        }
    }

    // MARK: IPTV accounts

    /// Adds an account. The first one, or `use: true`, becomes the one Live TV uses.
    func addAccount(_ account: XtreamAccount, use: Bool = false) {
        if let index = xtreamAccounts.firstIndex(where: { $0.id == account.id }) {
            xtreamAccounts[index] = account
        } else {
            xtreamAccounts.append(account)
        }
        if use || !xtream.isConfigured || xtream.id == account.id {
            switchAccount(to: account.id)
        }
    }

    /// Saves changes to an account that may or may not be the one in use.
    func updateAccount(_ account: XtreamAccount) {
        if xtream.id == account.id {
            xtream = account
        } else if let index = xtreamAccounts.firstIndex(where: { $0.id == account.id }) {
            xtreamAccounts[index] = account
        }
    }

    func removeAccount(id: String) {
        xtreamAccounts.removeAll { $0.id == id }
        prefs.liveAccountStates[id] = nil
        guard xtream.id == id else { return }
        if let next = xtreamAccounts.first {
            switchAccount(to: next.id, saveCurrent: false)
        } else {
            // Last account gone: Live TV data stays, as it always has, for the next login.
            xtream = XtreamAccount()
            ReminderStore.activeAccountID = nil
        }
    }

    /// Makes Live TV use another account. Its favourites, recent channels, hidden and locked
    /// groups, folders and reminders come back with it; the current account's are kept for later.
    func switchAccount(to id: String, saveCurrent: Bool = true) {
        guard let account = xtreamAccounts.first(where: { $0.id == id }) else { return }
        guard account.id != xtream.id || !xtream.isConfigured else { xtream = account; return }
        var updated = prefs
        if xtream.isConfigured {
            if saveCurrent { updated.liveAccountStates[xtream.id] = updated.liveState }
            updated.restoreLiveState(updated.liveAccountStates[account.id] ?? LiveAccountState())
        } else if let saved = updated.liveAccountStates[account.id] {
            // No account in use (e.g. after removing the last one): keep what's there unless
            // this account has its own saved data.
            updated.restoreLiveState(saved)
        }
        updated.liveAccountStates[account.id] = nil
        prefs = updated
        xtream = account
        ReminderStore.activeAccountID = account.id
        Task {
            await XtreamCache.shared.clearGuide()
            await SportsGuide.shared.clear()
        }
    }

    /// False for channels the user hid, or whose whole group is hidden.
    func isVisible(_ channel: XtreamChannel) -> Bool {
        if prefs.hiddenChannelIDs.contains(channel.id) { return false }
        if let category = channel.categoryID, prefs.hiddenCategoryIDs.contains(category) { return false }
        return true
    }

    /// Home rows in the user's order (rows added in newer versions go last).
    var homeRowOrder: [HomeRow] {
        var rows = prefs.homeRows.compactMap { HomeRow(rawValue: $0) }
        for row in HomeRow.allCases where !rows.contains(row) { rows.append(row) }
        return rows
    }

    /// Signs out of TMDB and IPTV and removes every addon. Preferences stay.
    func deleteAllConnections() {
        tmdbToken = ""
        xtreamAccounts = []
        xtream = XtreamAccount()
        addons = []
        Task {
            await XtreamCache.shared.clearGuide()
            await SportsGuide.shared.clear()
        }
    }

    var visibleHomeRows: [HomeRow] {
        homeRowOrder.filter { !prefs.hiddenHomeRows.contains($0.rawValue) }
    }
}
