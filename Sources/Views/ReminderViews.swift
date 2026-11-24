import SwiftUI

/// A programme picked in the guide that hasn't started yet.
struct ReminderPromptItem: Identifiable {
    let channel: XtreamChannel
    let title: String
    let start: Date
    let end: Date

    var id: String { "\(channel.id)|\(Int(start.timeIntervalSince1970))" }

    var reminder: ProgrammeReminder {
        ProgrammeReminder(channelID: channel.id, channelName: channel.name, channelIcon: channel.icon,
                          channelNumber: channel.number, title: title, start: start, end: end)
    }
}

extension PlaybackRequest {
    /// Full-screen live playback of one channel, e.g. from a reminder.
    static func liveChannel(_ channel: XtreamChannel, settings: AppSettings,
                            context: LiveContext? = nil) -> PlaybackRequest? {
        let client = settings.xtreamClient
        guard let url = client.liveURL(for: channel, format: settings.prefs.liveFormat) else { return nil }
        return PlaybackRequest(
            url: url,
            title: channel.name,
            artworkURL: channel.icon.flatMap { URL(string: $0) },
            isLive: true,
            httpHeaders: client.requestHeaders,
            live: context ?? LiveContext(channels: [channel], index: 0)
        )
    }
}

/// "Remind me" or "Watch channel now", over a dimmed guide.
struct ReminderPromptView: View {
    let item: ReminderPromptItem
    let onWatch: () -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ReminderStore.shared
    @FocusState private var focused: Int?

    private var isSet: Bool { store.isSet(channelID: item.channel.id, start: item.start) }

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                Text("\(item.channel.name) · \(DayFormat.label(item.start)) \(DayFormat.time(item.start))–\(DayFormat.time(item.end))".uppercased())
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                Text(item.title)
                    .font(.system(size: 32, weight: .heavy))
                    .lineLimit(2)
                HStack(spacing: 16) {
                    Button {
                        if isSet { store.remove(item.reminder) } else { store.add(item.reminder) }
                        dismiss()
                    } label: {
                        CardButtonLabel(title: isSet ? String(localized: "Cancel reminder") : String(localized: "Remind me"),
                                        icon: isSet ? "bell.slash" : "bell")
                    }
                    .buttonStyle(PlainPressStyle())
                    .focused($focused, equals: 0)

                    Button {
                        dismiss()
                        onWatch()
                    } label: {
                        CardButtonLabel(title: String(localized: "Watch channel now"), icon: "play.fill")
                    }
                    .buttonStyle(PlainPressStyle())
                    .focused($focused, equals: 1)
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 34)
            .frame(width: 860, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color(red: 30 / 255, green: 32 / 255, blue: 38 / 255).opacity(0.96)))
        }
        .onAppear {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                focused = 0
            }
        }
    }
}

/// A wide button that turns white when focused, for cards like the reminder and resume prompts.
struct CardButtonLabel: View {
    let title: String
    var icon: String? = nil
    var compact = false
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 10) {
            if let icon { Image(systemName: icon) }
            Text(title).lineLimit(1)
        }
        .font(.system(size: compact ? 22 : 24, weight: .bold))
        .foregroundStyle(isFocused ? Theme.ink : Color.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, compact ? 14 : 18)
        .background(RoundedRectangle(cornerRadius: compact ? 16 : 18, style: .continuous)
            .fill(isFocused ? Color.white : Color.white.opacity(0.14)))
        .scaleEffect(isFocused ? 1.04 : 1)
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

/// Slides in bottom-right when a reminded programme starts: Watch now or Dismiss.
/// Shown over the tabs by the root view and over the player by the player.
struct ReminderBanner: View {
    let onWatch: (ProgrammeReminder) -> Void
    @ObservedObject private var store = ReminderStore.shared
    @FocusState private var focused: Int?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear
            if let due = store.due {
                card(due)
                    .padding(.trailing, 60)
                    .padding(.bottom, 60)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .task(id: due.id) {
                        try? await Task.sleep(for: .milliseconds(120))
                        focused = 0
                        // Goes away by itself after a couple of minutes.
                        try? await Task.sleep(for: .seconds(120))
                        if store.due?.id == due.id { withAnimation { store.dismissDue() } }
                    }
            }
        }
        .animation(.easeOut(duration: 0.25), value: store.due?.id)
        .ignoresSafeArea()
    }

    private func card(_ due: ProgrammeReminder) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(due.start <= Date() ? "STARTING NOW" : "STARTING AT \(DayFormat.time(due.start))", systemImage: "bell.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color(red: 1, green: 0.7, blue: 0.25))
            Text(due.title)
                .font(.system(size: 26, weight: .heavy))
                .lineLimit(2)
            Text("\(due.channelName) · \(DayFormat.time(due.start))")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
            HStack(spacing: 12) {
                Button {
                    store.dismissDue()
                    onWatch(due)
                } label: {
                    CardButtonLabel(title: String(localized: "Watch now"), compact: true)
                }
                .buttonStyle(PlainPressStyle())
                .focused($focused, equals: 0)

                Button {
                    withAnimation { store.dismissDue() }
                } label: {
                    CardButtonLabel(title: String(localized: "Dismiss"), compact: true)
                }
                .buttonStyle(PlainPressStyle())
                .focused($focused, equals: 1)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(width: 620, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(Color(red: 30 / 255, green: 32 / 255, blue: 38 / 255).opacity(0.97)))
        .shadow(color: .black.opacity(0.5), radius: 25, y: 12)
        .focusSection()
        .onExitCommand { withAnimation { store.dismissDue() } }
    }
}

/// Settings › Live TV & Guide: the reminders that are set, select one to cancel it.
struct RemindersPanel: View {
    @ObservedObject private var store = ReminderStore.shared

    var body: some View {
        GlassPanel("Reminders") {
            if store.reminders.isEmpty {
                ListRowLabel(title: String(localized: "No reminders"), subtitle: String(localized: "Select a programme that hasn't started in the guide"),
                             icon: "bell", dimmed: true)
            } else {
                ForEach(store.reminders) { reminder in
                    Button {
                        store.remove(reminder)
                    } label: {
                        ListRowLabel(title: reminder.title, subtitle: String(localized: "\(reminder.channelName) · select to cancel"),
                                     icon: "bell.fill", trailing: reminder.whenLabel)
                    }
                    .buttonStyle(PlainPressStyle())
                }
            }
        }
    }
}
