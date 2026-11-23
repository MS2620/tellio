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

/// Reminders, kept on the Apple TV. While Tellio is open it watches the clock and
/// raises `due` when a programme starts; tvOS has no notifications, so a closed app misses them.
@MainActor
final class ReminderStore: ObservableObject {
    static let shared = ReminderStore()

    /// Every reminder, for all IPTV accounts.
    @Published private(set) var allReminders: [ProgrammeReminder] = []
    /// The IPTV account Live TV uses now; only its reminders are shown and fire.
    nonisolated(unsafe) static var activeAccountID: String?

    private static func belongsToActive(_ reminder: ProgrammeReminder) -> Bool {
        reminder.accountID == nil || reminder.accountID == activeAccountID
    }

    /// The reminders of the account in use.
    var reminders: [ProgrammeReminder] { allReminders.filter(Self.belongsToActive) }
    /// The reminder to show now, if any.
    @Published private(set) var due: ProgrammeReminder?

    private static let storageKey = "programmeReminders"
    /// Shown this long before the start, so there's time to switch.
    private static let lead: TimeInterval = 30

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([ProgrammeReminder].self, from: data) {
            allReminders = saved.filter { $0.end > Date() }.sorted { $0.start < $1.start }
        }
    }

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

    /// Checks the clock every 10 seconds. Started once from the app's root view.
    func run() async {
        while !Task.isCancelled {
            check()
            try? await Task.sleep(for: .seconds(10))
        }
    }

    private func check() {
        let now = Date()
        // Programmes that have ended are dropped, reminded or not.
        let before = allReminders.count
        allReminders.removeAll { $0.end <= now }
        // One at a time: the next waits until the shown one is dismissed or acted on.
        // Only the account in use: another account's channel can't be played right now.
        if due == nil, let next = allReminders.first(where: {
            Self.belongsToActive($0) && $0.start <= now.addingTimeInterval(Self.lead)
        }) {
            due = next
            allReminders.removeAll { $0.id == next.id && $0.accountID == next.accountID }
        }
        if allReminders.count != before || due != nil { save() }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(allReminders) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
