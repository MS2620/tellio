import Foundation

/// A programme the user asked to be reminded about.
struct ProgrammeReminder: Codable, Identifiable, Hashable {
    let channelID: Int
    let channelName: String
    let channelIcon: String?
    let channelNumber: Int?
    let title: String
    let start: Date
    let end: Date
    /// The IPTV account the channel belongs to; nil for reminders made before multiple accounts.
    var accountID: String? = nil

    var id: String { "\(channelID)|\(Int(start.timeIntervalSince1970))" }

    var channel: XtreamChannel {
        XtreamChannel(id: channelID, number: channelNumber, name: channelName, icon: channelIcon)
    }

    /// "Today 15:00", "Sun 20:00".
    var whenLabel: String {
        "\(DayFormat.label(start)) \(DayFormat.time(start))"
    }
}

/// A match or race the user asked to be reminded about. It keeps a copy of the fixture, so its
/// page (and the channels showing it) can be opened even before the schedule has loaded.
struct MatchReminder: Codable, Identifiable, Hashable {
    var fixture: Fixture
    /// Set by "Remind me about my teams' matches" rather than by hand.
    var automatic = false

    var id: String { fixture.id }
    /// Kick-off, or the race itself on a race weekend.
    var start: Date { fixture.date }
    /// "Portugal – Denmark".
    var title: String { fixture.title.replacingOccurrences(of: " v ", with: " – ") }

    /// "Today 15:00", "Sun 20:00".
    var whenLabel: String {
        "\(DayFormat.label(start)) \(DayFormat.time(start))"
    }

    init(fixture: Fixture, automatic: Bool = false) {
        var fixture = fixture
        fixture.score = nil
        self.fixture = fixture
        self.automatic = automatic
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fixture = try c.decode(Fixture.self, forKey: .fixture)
        automatic = (try? c.decodeIfPresent(Bool.self, forKey: .automatic)) ?? false
    }
}

/// How early reminders go off (Preferences.reminderLeadMinutes), and how that reads.
enum ReminderLead {
    static let options: [(Int, String)] = [
        (0, String(localized: "When it starts")),
        (5, String(localized: "5 minutes before")),
        (10, String(localized: "10 minutes before")),
        (15, String(localized: "15 minutes before")),
        (30, String(localized: "30 minutes before")),
    ]

    /// Minutes until `start`, or nil once it's (about to be) under way.
    static func minutesUntil(_ start: Date, from now: Date = Date()) -> Int? {
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded())
        return minutes >= 1 ? minutes : nil
    }

    /// "STARTING NOW", or "IN 10 MIN" while there's still time.
    static func heading(_ start: Date) -> String {
        minutesUntil(start).map { String(localized: "IN \($0) MIN") } ?? String(localized: "STARTING NOW")
    }
}

/// Programme and match reminders, shared by the Apple TV and iPhone apps. While Tellio is open it
/// watches the clock and raises `due` (or `dueMatch`) shortly before something starts; tvOS has
/// no notifications, so a closed app misses them there (the iPhone app schedules notifications).
@MainActor
final class ReminderStore: ObservableObject {
    static let shared = ReminderStore()

    /// Every reminder, for all IPTV accounts.
    @Published private(set) var allReminders: [ProgrammeReminder] = []
    /// Match and race reminders, soonest first. Not tied to an IPTV account: the channels
    /// showing a match are looked for when its page opens.
    @Published private(set) var matches: [MatchReminder] = []
    /// The IPTV account Live TV uses now; only its reminders are shown and fire.
    nonisolated(unsafe) static var activeAccountID: String?
    /// How early reminders go off, in minutes (Preferences.reminderLeadMinutes); 0 is "when it starts".
    nonisolated(unsafe) static var leadMinutes = 0
    /// Whether every match of the followed teams gets a reminder (Preferences.remindTeamMatches).
    nonisolated(unsafe) static var remindTeamMatches = false

    /// How long before the start a reminder goes off. "When it starts" still leaves a little time to switch.
    static var lead: TimeInterval { leadMinutes > 0 ? TimeInterval(leadMinutes) * 60 : 30 }

    private static func belongsToActive(_ reminder: ProgrammeReminder) -> Bool {
        reminder.accountID == nil || reminder.accountID == activeAccountID
    }

    /// The reminders of the account in use.
    var reminders: [ProgrammeReminder] { allReminders.filter(Self.belongsToActive) }
    /// The programme reminder to show now, if any.
    @Published private(set) var due: ProgrammeReminder?
    /// The match reminder to show now, if any. Only one of `due` and `dueMatch` is shown at a time.
    @Published private(set) var dueMatch: MatchReminder?

    private static let storageKey = "programmeReminders"
    private static let matchesKey = "matchReminders"
    /// Automatic reminders the user cancelled, so loading the schedule again doesn't bring them back.
    private static let skippedKey = "skippedMatchReminders"
    /// A match reminder that couldn't go off (Tellio was closed) is dropped this long after kick-off.
    private static let matchGrace: TimeInterval = 3 * 3600

    /// Cancelled automatic reminders: fixture id → kick-off, kept until the match is over.
    private var skipped: [String: Date] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([ProgrammeReminder].self, from: data) {
            allReminders = saved.filter { $0.end > Date() }.sorted { $0.start < $1.start }
        }
        if let data = UserDefaults.standard.data(forKey: Self.matchesKey),
           let saved = try? JSONDecoder().decode([Lenient<MatchReminder>].self, from: data) {
            matches = Self.current(saved.compactMap(\.value))
        }
        if let data = UserDefaults.standard.data(forKey: Self.skippedKey),
           let saved = try? JSONDecoder().decode([String: Date].self, from: data) {
            skipped = saved.filter { $0.value.addingTimeInterval(Self.matchGrace) > Date() }
        }
    }

    // MARK: Programmes

    func isSet(channelID: Int, start: Date) -> Bool {
        reminders.contains { $0.channelID == channelID && $0.start == start }
    }

    func add(_ reminder: ProgrammeReminder) {
        guard !reminders.contains(where: { $0.id == reminder.id }) else { return }
        var reminder = reminder
        if reminder.accountID == nil { reminder.accountID = Self.activeAccountID }
        allReminders.append(reminder)
        allReminders.sort { $0.start < $1.start }
        save()
    }

    func remove(_ reminder: ProgrammeReminder) {
        // The guide passes a reminder without its account (add() fills that in when storing it),
        // so a missing account means the one in use.
        let account = reminder.accountID ?? Self.activeAccountID
        allReminders.removeAll { $0.id == reminder.id && ($0.accountID == account || $0.accountID == nil) }
        save()
    }

    /// Replaces the reminders with a backup's (past ones are dropped).
    func restore(_ saved: [ProgrammeReminder]) {
        allReminders = saved.filter { $0.end > Date() }.sorted { $0.start < $1.start }
        save()
    }

    func dismissDue() {
        due = nil
    }

    // MARK: Matches

    func isSet(fixture: Fixture) -> Bool {
        matches.contains { $0.id == fixture.id }
    }

    /// A reminder set by hand. One set automatically before becomes the user's own.
    func add(fixture: Fixture) {
        skipped[fixture.id] = nil
        matches.removeAll { $0.id == fixture.id }
        matches = Self.current(matches + [MatchReminder(fixture: fixture)])
        saveMatches()
    }

    func remove(fixture: Fixture) {
        guard let reminder = matches.first(where: { $0.id == fixture.id }) else { return }
        if reminder.automatic { skipped[fixture.id] = reminder.start }
        matches.removeAll { $0.id == fixture.id }
        saveMatches()
    }

    func toggle(fixture: Fixture) {
        if isSet(fixture: fixture) { remove(fixture: fixture) } else { add(fixture: fixture) }
    }

    /// Replaces the match reminders with a backup's (past ones are dropped).
    func restoreMatches(_ saved: [MatchReminder]) {
        matches = Self.current(saved)
        saveMatches()
    }

    func dismissDueMatch() {
        dueMatch = nil
    }

    /// A match to open once nothing is in the way, e.g. "Where to watch" in the player, which
    /// closes the player first. The app's root view opens it.
    @Published private(set) var matchToOpen: Fixture?

    func open(_ reminder: MatchReminder) {
        // The schedule's copy has the latest time and score, when it has loaded.
        matchToOpen = LiveScores.shared.fixture(id: reminder.id) ?? reminder.fixture
    }

    /// The match's page was opened from its reminder (e.g. a notification), so it's done:
    /// it won't come up again as a banner.
    func opened(matchID: String) {
        if dueMatch?.id == matchID { dueMatch = nil }
        guard matches.contains(where: { $0.id == matchID }) else { return }
        matches.removeAll { $0.id == matchID }
        saveMatches()
    }

    func takeMatchToOpen() -> Fixture? {
        defer { matchToOpen = nil }
        return matchToOpen
    }

    /// Called whenever the followed teams' schedule loads: reminders get the latest kick-off
    /// times, and with "Remind me about my teams' matches" on, new matches get one.
    func fixturesLoaded(_ fixtures: [Fixture], teams: Set<String>) {
        let fresh = Dictionary(fixtures.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var updated = matches.map { reminder in
            fresh[reminder.id].map { MatchReminder(fixture: $0, automatic: reminder.automatic) } ?? reminder
        }
        // Automatic reminders go with the team that brought them.
        updated.removeAll { $0.automatic && (!Self.remindTeamMatches || teams.isDisjoint(with: $0.fixture.followed)) }
        if Self.remindTeamMatches {
            let earliest = Date().addingTimeInterval(Self.lead)
            let known = Set(updated.map(\.id))
            for fixture in fixtures where fixture.date > earliest && !fixture.followed.isEmpty
                && !known.contains(fixture.id) && skipped[fixture.id] == nil {
                updated.append(MatchReminder(fixture: fixture, automatic: true))
            }
        }
        updated = Self.current(updated)
        guard updated != matches else { return }
        matches = updated
        saveMatches()
    }

    /// "Remind me about my teams' matches" was switched: on sets reminders for the matches
    /// already loaded, off removes the automatic ones.
    func teamMatchesSettingChanged(teams: Set<String>) {
        if !Self.remindTeamMatches { skipped = [:] }
        fixturesLoaded(LiveScores.shared.trackedFixtures, teams: teams)
    }

    // MARK: Clock

    /// Checks the clock every 10 seconds. Started once from the app's root view.
    func run() async {
        while !Task.isCancelled {
            check()
            try? await Task.sleep(for: .seconds(10))
        }
    }

    private func check() {
        let now = Date()
        let soon = now.addingTimeInterval(Self.lead)
        // Programmes that have ended are dropped, reminded or not; so are matches long started.
        let before = (allReminders.count, matches.count)
        allReminders.removeAll { $0.end <= now }
        matches = Self.current(matches)
        // One at a time: the next waits until the shown one is dismissed or acted on.
        // Only the account in use: another account's channel can't be played right now.
        if due == nil && dueMatch == nil {
            let programme = allReminders.first { Self.belongsToActive($0) && $0.start <= soon }
            let match = matches.first { $0.start <= soon }
            if let programme, match.map({ programme.start <= $0.start }) ?? true {
                due = programme
                allReminders.removeAll { $0.id == programme.id && $0.accountID == programme.accountID }
            } else if let match {
                dueMatch = match
                matches.removeAll { $0.id == match.id }
            }
        }
        if allReminders.count != before.0 || due != nil { save() }
        if matches.count != before.1 || dueMatch != nil { saveMatches() }
    }

    /// Soonest first, without ones whose match is long under way.
    private static func current(_ reminders: [MatchReminder]) -> [MatchReminder] {
        let cutoff = Date().addingTimeInterval(-matchGrace)
        return reminders.filter { $0.start > cutoff }.sorted { $0.start != $1.start ? $0.start < $1.start : $0.id < $1.id }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(allReminders) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private func saveMatches() {
        let cutoff = Date().addingTimeInterval(-Self.matchGrace)
        skipped = skipped.filter { $0.value > cutoff }
        if let data = try? JSONEncoder().encode(matches) {
            UserDefaults.standard.set(data, forKey: Self.matchesKey)
        }
        if let data = try? JSONEncoder().encode(skipped) {
            UserDefaults.standard.set(data, forKey: Self.skippedKey)
        }
    }
}

/// Decodes a value, or nil if this one can't be read, so one bad entry doesn't lose a whole list.
struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
