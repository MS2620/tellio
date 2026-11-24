import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var updates = UpdateChecker.shared
    @State private var showingNotes = false
    @State private var language = AppLanguage.chosen

    var body: some View {
        NavigationStack {
            SettingsPage("Settings") {
                GlassPanel("Media") {
                    SettingsLinkRow("Connections", icon: "link") { ConnectionsView() }
                    SettingsLinkRow("Live TV & Guide", icon: "antenna.radiowaves.left.and.right",
                                    value: settings.prefs.liveLayout.label) { LiveTVSettingsView() }
                    SettingsLinkRow("Content", icon: "square.stack.3d.up") { ContentSettingsView() }
                    SettingsLinkRow("Streams", icon: "list.bullet.rectangle") { StreamSettingsView() }
                }

                GlassPanel("Playback") {
                    SettingsLinkRow("Player", icon: "play.rectangle") { PlayerSettingsView() }
                    SettingsLinkRow("Subtitles", icon: "captions.bubble") { SubtitleSettingsView() }
                }

                GlassPanel("Personalise") {
                    SettingsOptionRow("Language", icon: "globe", selection: $language, options: AppLanguage.options)
                        .onChange(of: language) { _, value in AppLanguage.chosen = value }
                    SettingsLinkRow("Home screen", icon: "house") { HomeScreenSettingsView() }
                    SettingsLinkRow("Appearance", icon: "paintbrush",
                                    value: settings.prefs.backgroundStyle.label) { AppearanceSettingsView() }
                    SettingsLinkRow("Sports", icon: "sportscourt") { SportsSettingsView() }
                    SettingsLinkRow("Calendar", icon: "calendar") { CalendarSettingsView() }
                    SettingsLinkRow("Parental controls", icon: "lock",
                                    value: settings.prefs.parentalControlsOn ? String(localized: "On") : String(localized: "Off")) { ParentalControlsView() }
                }
                if language != AppLanguage.atLaunch {
                    SettingsNote("Tellio changes language the next time it opens. To close it now, press the TV button twice and swipe Tellio up.")
                }

                GlassPanel("Backup") {
                    SettingsLinkRow("Backup & restore", icon: "externaldrive",
                                    value: BackupService.shared.isConfigured ? String(localized: "Ready") : String(localized: "Set up")) { BackupView() }
                }

                GlassPanel("About") {
                    SettingsInfoRow("Version", icon: "info.circle", value: Self.version)
                    Button {
                        if updates.latest != nil { showingNotes = true }
                    } label: {
                        ListRowLabel(title: String(localized: "Updates"), icon: "arrow.up.circle",
                                     trailing: updates.updateAvailable
                                         ? String(localized: "Build \(updates.latest?.build ?? 0) available")
                                         : (updates.latest == nil ? String(localized: "Checking…") : String(localized: "Up to date")))
                    }
                    .buttonStyle(PlainPressStyle())
                    .sheet(isPresented: $showingNotes) {
                        if let latest = updates.latest { UpdateNotes(release: latest) }
                    }
                    NavigationLink {
                        FeedbackView()
                    } label: {
                        ListRowLabel(title: String(localized: "Send feedback"), subtitle: String(localized: "Report a problem or suggest an idea"),
                                     icon: "bubble.left", trailing: FeedbackService.isAvailable ? nil : String(localized: "Not in this build"),
                                     trailingIcon: "chevron.right")
                    }
                    .buttonStyle(PlainPressStyle())
                    SettingsToggleRow("Send crash reports", icon: "ant",
                                      subtitle: CrashReporting.isAvailable
                                          ? String(localized: "Anonymous; no logins, links or watch history")
                                          : String(localized: "Not in this build"),
                                      isOn: Binding(
                                          get: { settings.prefs.crashReports },
                                          set: { on in
                                              settings.prefs.crashReports = on
                                              CrashReporting.apply(enabled: on)
                                          }))
                    SettingsInfoRow("Top Shelf", icon: "rectangle.topthird.inset.filled", value: Self.topShelfStatus)
                    SettingsInfoRow("Player engine", icon: "cpu", value: "AetherEngine")
                    NavigationLink {
                        AcknowledgementsView()
                    } label: {
                        ListRowLabel(title: String(localized: "Acknowledgements"), subtitle: String(localized: "Open-source software in Tellio"),
                                     icon: "doc.text", trailingIcon: "chevron.right")
                    }
                    .buttonStyle(PlainPressStyle())
                }
                SettingsNote("Crash reports are on by default. When Tellio crashes, a report is sent the next time it opens.")
            }
        }
    }

    /// "Ready · 12 cards · shown 2 minutes ago", or why it isn't working.
    static var topShelfStatus: String {
        guard TopShelfStore.isAvailable else { return String(localized: "Blocked by signing (no App Group)") }
        let cards = TopShelfStore.read()?.cardCount ?? 0
        var parts = [String(localized: "Ready"), String(localized: "\(cards) cards")]
        if let read = TopShelfStore.lastRead {
            parts.append(String(localized: "shown \(read.date.formatted(.relative(presentation: .named)))"))
        } else {
            parts.append(String(localized: "not shown yet"))
        }
        return parts.joined(separator: " · ")
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

// MARK: - Building blocks

/// A settings page: frosted background, a title and a centred column of panels.
struct SettingsPage<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: LocalizedStringResource, @ViewBuilder content: () -> Content) {
        self.init(String(localized: title), content: content)
    }

    @_disfavoredOverload
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(spacing: 30) {
                    Text(title)
                        .font(.system(size: 44, weight: .heavy))
                        .padding(.top, 10)
                    content
                }
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 80)
            }
        }
    }
}

/// A row that opens another settings page.
struct SettingsLinkRow<Destination: View>: View {
    let title: String
    let icon: String
    let value: String?
    let destination: Destination

    init(_ title: LocalizedStringResource, icon: String, value: String? = nil,
         @ViewBuilder destination: () -> Destination) {
        self.init(String(localized: title), icon: icon, value: value, destination: destination)
    }

    @_disfavoredOverload
    init(_ title: String, icon: String, value: String? = nil, @ViewBuilder destination: () -> Destination) {
        self.title = title
        self.icon = icon
        self.value = value
        self.destination = destination()
    }

    var body: some View {
        NavigationLink {
            destination
        } label: {
            ListRowLabel(title: title, icon: icon, trailing: value, trailingIcon: "chevron.right")
        }
        .buttonStyle(PlainPressStyle())
    }
}

/// A row that only shows a value.
struct SettingsInfoRow: View {
    let title: String
    let icon: String
    let value: String

    init(_ title: LocalizedStringResource, icon: String, value: String) {
        self.init(String(localized: title), icon: icon, value: value)
    }

    @_disfavoredOverload
    init(_ title: String, icon: String, value: String) {
        self.title = title
        self.icon = icon
        self.value = value
    }

    var body: some View {
        Button {} label: {
            ListRowLabel(title: title, icon: icon, trailing: value)
        }
        .buttonStyle(PlainPressStyle())
    }
}

/// An on/off row. Selecting it flips the setting.
struct SettingsToggleRow: View {
    let title: String
    let icon: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    init(_ title: LocalizedStringResource, icon: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.init(String(localized: title), icon: icon, subtitle: subtitle, isOn: isOn)
    }

    @_disfavoredOverload
    init(_ title: String, icon: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.icon = icon
        self.subtitle = subtitle
        self._isOn = isOn
    }

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ListRowLabel(title: title, subtitle: subtitle, icon: icon, trailing: isOn ? String(localized: "On") : String(localized: "Off"),
                         trailingIcon: isOn ? "checkmark.circle.fill" : "circle")
        }
        .buttonStyle(PlainPressStyle())
    }
}

/// A row with the current choice on the right. Selecting it lists the choices.
struct SettingsOptionRow<Value: Hashable>: View {
    let title: String
    let icon: String
    @Binding var selection: Value
    let options: [(Value, String)]
    @State private var choosing = false

    init(_ title: LocalizedStringResource, icon: String, selection: Binding<Value>, options: [(Value, String)]) {
        self.init(String(localized: title), icon: icon, selection: selection, options: options)
    }

    @_disfavoredOverload
    init(_ title: String, icon: String, selection: Binding<Value>, options: [(Value, String)]) {
        self.title = title
        self.icon = icon
        self._selection = selection
        self.options = options
    }

    private var currentLabel: String {
        options.first { $0.0 == selection }?.1 ?? "—"
    }

    var body: some View {
        Button {
            choosing = true
        } label: {
            ListRowLabel(title: title, icon: icon, trailing: currentLabel, trailingIcon: "chevron.up.chevron.down")
        }
        .buttonStyle(PlainPressStyle())
        .confirmationDialog(title, isPresented: $choosing, titleVisibility: .visible) {
            ForEach(options.indices, id: \.self) { index in
                Button((options[index].0 == selection ? "✓ " : "") + options[index].1) {
                    selection = options[index].0
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// A row that does something when selected.
struct SettingsActionRow: View {
    let title: String
    let icon: String
    let value: String?
    let action: () -> Void

    init(_ title: LocalizedStringResource, icon: String, value: String? = nil, action: @escaping () -> Void) {
        self.init(String(localized: title), icon: icon, value: value, action: action)
    }

    @_disfavoredOverload
    init(_ title: String, icon: String, value: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.value = value
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ListRowLabel(title: title, icon: icon, trailing: value)
        }
        .buttonStyle(PlainPressStyle())
    }
}

/// Small explanatory text under a panel.
struct SettingsNote: View {
    let text: String

    init(_ text: LocalizedStringResource) { self.text = String(localized: text) }

    @_disfavoredOverload
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(.white.opacity(0.65))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 30)
            .padding(.top, -14)
    }
}

// MARK: - Live TV & Guide

struct LiveTVSettingsView: View {
    @EnvironmentObject var settings: AppSettings

    private static let userAgentPresets: [Choice] = [
        Choice("", String(localized: "Default")),
        Choice("VLC/3.0.21 LibVLC/3.0.21", "VLC"),
        Choice("TiviMate/5.1.6 (Android 12)", "TiviMate"),
        Choice("IPTVSmartersPro", "IPTV Smarters"),
    ]

    private var userAgentOptions: [(String, String)] {
        var options = Self.userAgentPresets.map { ($0.code, $0.name) }
        let current = settings.prefs.iptvUserAgent
        if !Self.userAgentPresets.contains(where: { $0.code == current }) {
            options.append((current, String(localized: "Custom")))
        }
        return options
    }

    var body: some View {
        SettingsPage("Live TV & Guide") {
            RemindersPanel()
            GlassPanel {
                SettingsOptionRow("Remind me", icon: "bell", selection: $settings.prefs.reminderLeadMinutes,
                                  options: ReminderLead.options)
            }
            SettingsNote("Select a programme that hasn't started in the guide, or Remind me on a match, to be reminded before it begins. Reminders appear while Tellio is open, including over the player; tvOS doesn't let apps notify you when they're closed.")

            GlassPanel("Layout") {
                SettingsOptionRow("Default view", icon: "square.grid.2x2", selection: $settings.prefs.liveLayout,
                                  options: LiveLayout.allCases.map { ($0, $0.label) })
                SettingsOptionRow("Guide shows", icon: "clock", selection: $settings.prefs.guideHours,
                                  options: [(1, String(localized: "1 hour at a time")), (2, String(localized: "2 hours at a time")), (3, String(localized: "3 hours at a time"))])
                SettingsToggleRow("Live preview in the guide", icon: "play.tv", isOn: $settings.prefs.guidePreview)
                SettingsToggleRow("Channel numbers", icon: "number", isOn: $settings.prefs.showChannelNumbers)
            }
            SettingsNote("The preview plays the highlighted channel, muted, in the corner of the guide. Turn it off if your provider only allows one connection at a time or zapping feels slow.")

            GlassPanel("Channels") {
                SettingsToggleRow("Show programme information (EPG)", icon: "text.justify.left", isOn: $settings.prefs.showEPG)
                SettingsOptionRow("Sort channels by", icon: "arrow.up.arrow.down", selection: $settings.prefs.channelSort,
                                  options: ChannelSort.allCases.map { ($0, $0.label) })
                SettingsToggleRow("Favourites at the top", icon: "star", isOn: $settings.prefs.favouritesFirst)
                SettingsToggleRow("Remember last group", icon: "arrow.uturn.backward", isOn: $settings.prefs.rememberLastCategory)
                SettingsActionRow("Clear favourites", icon: "star.slash",
                                  value: "\(settings.prefs.favouriteChannelIDs.count)") {
                    settings.prefs.favouriteChannelIDs.removeAll()
                }
            }
            SettingsNote("Hide groups and channels, or build your own folders, in Settings → Content.")

            GlassPanel("Streaming") {
                SettingsOptionRow("Stream format", icon: "waveform", selection: $settings.prefs.liveFormat,
                                  options: LiveStreamFormat.allCases.map { ($0, $0.label) })
                SettingsOptionRow("Channel switching", icon: "hare", selection: $settings.prefs.channelSwitching,
                                  options: ChannelSwitching.allCases.map { ($0, $0.label) })
                SettingsOptionRow("Timeshift (pause & rewind)", icon: "gobackward", selection: $settings.prefs.timeshiftMinutes,
                                  options: [(0, String(localized: "Off")), (30, String(localized: "30 minutes")), (60, String(localized: "1 hour")), (120, String(localized: "2 hours"))])
                SettingsToggleRow("Match frame rate on live channels", icon: "tv", isOn: $settings.prefs.matchContentLive)
            }
            SettingsNote("Try MPEG-TS if channels fail on HLS. Stable switching starts slower but buffers more. Timeshift keeps recent video on the Apple TV so you can pause and rewind live channels. Matching the frame rate makes the TV go black for a moment each time you change channel, so it's off for live TV unless you turn it on here.")

            GlassPanel("Provider compatibility") {
                SettingsOptionRow("User agent", icon: "person.badge.key", selection: $settings.prefs.iptvUserAgent,
                                  options: userAgentOptions)
                TextField("Custom user agent", text: $settings.prefs.iptvUserAgent)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
            }
            SettingsNote("Some providers only allow certain players. Change this if your login works but channels don't.")
        }
    }
}

// MARK: - Content

struct ContentSettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var refreshStatus: String?

    private var hiddenSummary: String {
        let groups = settings.prefs.hiddenCategoryIDs.count
        let channels = settings.prefs.hiddenChannelIDs.count
        if groups == 0 && channels == 0 { return String(localized: "Nothing hidden") }
        return String(localized: "\(groups) groups, \(channels) channels hidden")
    }

    var body: some View {
        SettingsPage("Content") {
            GlassPanel("Live TV") {
                SettingsLinkRow("Groups & channels", icon: "eye", value: hiddenSummary) {
                    ChannelBrowser(mode: .visibility)
                }
                SettingsLinkRow("My folders", icon: "folder.badge.plus",
                                value: "\(settings.prefs.folders.count)") {
                    FoldersSettingsView()
                }
                NavigationLink {
                    QualitySortSettingsView()
                } label: {
                    let count = settings.prefs.qualitySortCategoryIDs.count
                    ListRowLabel(title: String(localized: "Sort by quality"), subtitle: String(localized: "Split groups into 4K, FHD, HD and SD folders"),
                                 icon: "line.3.horizontal.decrease",
                                 trailing: count == 0 ? String(localized: "Off") : String(localized: "\(count) groups"),
                                 trailingIcon: "chevron.right")
                }
                .buttonStyle(PlainPressStyle())
            }
            SettingsNote("Hide whole groups or single channels you never watch, and collect channels from any group into folders of your own. Folders appear at the top of Live TV.")

            GlassPanel("TV guide data") {
                SettingsOptionRow("Refresh guide", icon: "arrow.triangle.2.circlepath", selection: $settings.prefs.epgRefreshHours,
                                  options: [(0, String(localized: "Every time the app opens")), (1, String(localized: "Every hour")), (3, String(localized: "Every 3 hours")),
                                            (6, String(localized: "Every 6 hours")), (12, String(localized: "Every 12 hours")), (24, String(localized: "Once a day")),
                                            (-1, String(localized: "Only when I ask"))])
                SettingsActionRow("Refresh now", icon: "arrow.clockwise", value: refreshStatus) {
                    refreshStatus = String(localized: "Clearing…")
                    Task {
                        await XtreamCache.shared.clearGuide()
                        await SportsGuide.shared.clear()
                        refreshStatus = String(localized: "Done — guide reloads when you open Live TV")
                    }
                }
            }
            SettingsNote("Guide data is kept on the Apple TV between refreshes, so the guide opens quickly and your provider is asked less often.")

            GlassPanel("From your IPTV provider") {
                SettingsToggleRow("Show provider movies", icon: "film", isOn: $settings.prefs.showProviderMovies)
                SettingsToggleRow("Show provider series", icon: "play.tv", isOn: $settings.prefs.showProviderSeries)
            }
            SettingsNote("Adds the movie and series libraries that come with your IPTV login as extra rows on the Movies and Series tabs. Off by default.")

            GlassPanel("Catalogue") {
                SettingsOptionRow("Language", icon: "globe", selection: $settings.prefs.catalogueLanguage,
                                  options: LanguageOptions.catalogue)
                SettingsOptionRow("Region", icon: "mappin.and.ellipse", selection: $settings.prefs.tmdbRegion,
                                  options: LanguageOptions.regions.map { ($0.code, $0.name) })
            }
            SettingsNote("Language of titles and descriptions, and the region used for cinema releases.")
        }
    }
}

// MARK: - Groups, channels and folder contents

/// Two panes: groups on the left, the highlighted group's channels on the right.
/// Used to hide groups and channels, and to pick channels for a folder.
struct ChannelBrowser: View {
    enum Mode: Equatable {
        case visibility
        case folder(String)
    }

    let mode: Mode
    @EnvironmentObject var settings: AppSettings
    @State private var categories: [XtreamCategory] = []
    @State private var byGroup: [String: [XtreamChannel]] = [:]
    @State private var currentGroup: String?
    @State private var loading = true
    @State private var error: String?
    @FocusState private var focusedGroup: String?

    private var prefs: Preferences { settings.prefs }

    private var folderID: String? {
        if case .folder(let id) = mode { return id }
        return nil
    }

    private var folder: ChannelFolder? {
        guard let folderID else { return nil }
        return prefs.folders.first { $0.id == folderID }
    }

    private var title: String {
        if let folder { return String(localized: "Add to \(folder.name)") }
        return String(localized: "Groups & channels")
    }

    /// Picking for a folder only offers what isn't hidden.
    private var shownGroups: [XtreamCategory] {
        mode == .visibility ? categories : categories.filter { !prefs.hiddenCategoryIDs.contains($0.id) }
    }

    private var shownChannels: [XtreamChannel] {
        let all = currentGroup.flatMap { byGroup[$0] } ?? []
        return mode == .visibility ? all : all.filter { !prefs.hiddenChannelIDs.contains($0.id) }
    }

    var body: some View {
        ZStack {
            AppBackground()
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 24) {
                    Text(title)
                        .font(.system(size: 44, weight: .heavy))
                        .lineLimit(1)
                    Spacer()
                    if mode == .visibility {
                        Button {
                            settings.prefs.hiddenCategoryIDs.removeAll()
                            settings.prefs.hiddenChannelIDs.removeAll()
                        } label: {
                            PillLabel(title: String(localized: "Show everything"), icon: "eye")
                        }
                        .buttonStyle(PlainPressStyle())
                    }
                }

                if let error {
                    Text(error).foregroundStyle(.white.opacity(0.7))
                    Spacer()
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(alignment: .top, spacing: 30) {
                        groupsPane.frame(width: 560)
                        channelsPane.frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.top, 10)
        }
        .task { await load() }
        .onChange(of: focusedGroup) { _, id in
            if let id { currentGroup = id }
        }
    }

    private var groupsPane: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(shownGroups) { group in
                    let hidden = prefs.hiddenCategoryIDs.contains(group.id)
                    Button {
                        currentGroup = group.id
                        if mode == .visibility { toggleGroup(group.id) }
                    } label: {
                        ListRowLabel(title: group.name,
                                     subtitle: String(localized: "\(byGroup[group.id]?.count ?? 0) channels"),
                                     trailing: mode == .visibility ? (hidden ? String(localized: "Hidden") : nil) : nil,
                                     trailingIcon: mode == .visibility ? (hidden ? "eye.slash" : "eye") : "chevron.right",
                                     selected: group.id == currentGroup,
                                     dimmed: hidden)
                    }
                    .buttonStyle(PlainPressStyle())
                    .focused($focusedGroup, equals: group.id)
                }
            }
            .padding(.vertical, 10)
        }
    }

    private var channelsPane: some View {
        let channels = shownChannels
        let groupHidden = currentGroup.map { prefs.hiddenCategoryIDs.contains($0) } ?? false
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if mode == .visibility {
                    if groupHidden {
                        Text("This whole group is hidden. Select it on the left to show it again.")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, 18)
                            .padding(.bottom, 8)
                    } else if !channels.isEmpty {
                        HStack(spacing: 14) {
                            Button {
                                settings.prefs.hiddenChannelIDs.subtract(channels.map(\.id))
                            } label: {
                                PillLabel(title: String(localized: "Show all"), icon: "eye")
                            }
                            .buttonStyle(PlainPressStyle())
                            Button {
                                settings.prefs.hiddenChannelIDs.formUnion(channels.map(\.id))
                            } label: {
                                PillLabel(title: String(localized: "Hide all"), icon: "eye.slash")
                            }
                            .buttonStyle(PlainPressStyle())
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, 10)
                    }
                }

                ForEach(channels) { channel in
                    channelRow(channel, groupHidden: groupHidden)
                }

                if channels.isEmpty {
                    Text("No channels in this group.")
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(18)
                }
            }
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private func channelRow(_ channel: XtreamChannel, groupHidden: Bool) -> some View {
        let logo = channel.icon.flatMap { URL(string: $0) }
        if mode == .visibility {
            let hidden = prefs.hiddenChannelIDs.contains(channel.id)
            Button {
                if hidden {
                    settings.prefs.hiddenChannelIDs.remove(channel.id)
                } else {
                    settings.prefs.hiddenChannelIDs.insert(channel.id)
                }
            } label: {
                ListRowLabel(title: channel.name, logoURL: logo, showsLogo: true,
                             trailing: hidden ? String(localized: "Hidden") : nil,
                             trailingIcon: hidden ? "eye.slash" : "eye",
                             dimmed: hidden || groupHidden)
            }
            .buttonStyle(PlainPressStyle())
        } else {
            let included = folder?.channelIDs.contains(channel.id) ?? false
            Button {
                toggleInFolder(channel.id)
            } label: {
                ListRowLabel(title: channel.name, logoURL: logo, showsLogo: true,
                             trailing: included ? String(localized: "In folder") : nil,
                             trailingIcon: included ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(PlainPressStyle())
        }
    }

    private func toggleGroup(_ id: String) {
        if settings.prefs.hiddenCategoryIDs.contains(id) {
            settings.prefs.hiddenCategoryIDs.remove(id)
        } else {
            settings.prefs.hiddenCategoryIDs.insert(id)
        }
    }

    private func toggleInFolder(_ channelID: Int) {
        guard let folderID, let index = settings.prefs.folders.firstIndex(where: { $0.id == folderID }) else { return }
        var folder = settings.prefs.folders[index]
        if let position = folder.channelIDs.firstIndex(of: channelID) {
            folder.channelIDs.remove(at: position)
        } else {
            folder.channelIDs.append(channelID)
        }
        settings.prefs.folders[index] = folder
    }

    private func load() async {
        guard settings.xtream.isConfigured else {
            error = String(localized: "Add your IPTV login in Settings → Connections first.")
            loading = false
            return
        }
        let client = settings.xtreamClient
        do {
            let groups = try await XtreamCache.shared.liveCategories(client)
            let channels = try await XtreamCache.shared.liveStreams(client)
            var grouped: [String: [XtreamChannel]] = [:]
            for channel in channels {
                if let category = channel.categoryID {
                    grouped[category, default: []].append(channel)
                }
            }
            categories = groups
            byGroup = grouped
            if currentGroup == nil { currentGroup = shownGroups.first?.id }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

// MARK: - My folders

struct FoldersSettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var naming = false

    var body: some View {
        SettingsPage("My folders") {
            GlassPanel {
                SettingsActionRow("New folder", icon: "plus") { naming = true }
            }

            if !settings.prefs.folders.isEmpty {
                GlassPanel("Folders") {
                    ForEach(settings.prefs.folders) { folder in
                        SettingsLinkRow(folder.name, icon: "square.stack.3d.up",
                                        value: String(localized: "\(folder.channelIDs.count) channels")) {
                            FolderDetailView(folderID: folder.id)
                        }
                    }
                }
            }
            SettingsNote("Folders are your own Live TV groups. A channel can be in several folders and stays in its original group too. You can also long-press any channel in Live TV to add it to a folder.")
        }
        .sheet(isPresented: $naming) {
            NameSheet(title: String(localized: "New folder")) { name in
                settings.prefs.folders.append(ChannelFolder(id: UUID().uuidString, name: name, channelIDs: []))
            }
        }
    }
}

struct FolderDetailView: View {
    let folderID: String
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var names: [Int: XtreamChannel] = [:]
    @State private var renaming = false
    @State private var confirmingDelete = false
    @State private var selected: Int?

    private var folder: ChannelFolder? {
        settings.prefs.folders.first { $0.id == folderID }
    }

    var body: some View {
        SettingsPage(folder?.name ?? String(localized: "Folder")) {
            GlassPanel {
                SettingsLinkRow("Add or remove channels", icon: "plus.circle") {
                    ChannelBrowser(mode: .folder(folderID))
                }
                SettingsActionRow("Rename", icon: "pencil") { renaming = true }
                SettingsActionRow("Delete folder", icon: "trash") { confirmingDelete = true }
            }

            if let folder, !folder.channelIDs.isEmpty {
                GlassPanel("Channels, in order") {
                    ForEach(folder.channelIDs, id: \.self) { channelID in
                        Button {
                            selected = channelID
                        } label: {
                            ListRowLabel(title: names[channelID]?.name ?? String(localized: "Channel \(channelID)"),
                                         logoURL: names[channelID]?.icon.flatMap { URL(string: $0) },
                                         showsLogo: true,
                                         trailingIcon: "ellipsis")
                        }
                        .buttonStyle(PlainPressStyle())
                    }
                }
                SettingsNote("Select a channel to move it up or down, or to take it out of the folder.")
            } else {
                SettingsNote("This folder is empty. Choose \"Add or remove channels\" to fill it.")
            }
        }
        .task {
            guard settings.xtream.isConfigured else { return }
            let all = (try? await XtreamCache.shared.liveStreams(settings.xtreamClient)) ?? []
            names = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        .sheet(isPresented: $renaming) {
            NameSheet(title: String(localized: "Rename folder"), initial: folder?.name ?? "") { name in
                update { folder in folder.name = name }
            }
        }
        .confirmationDialog("Delete this folder?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete folder", role: .destructive) {
                settings.prefs.folders.removeAll { $0.id == folderID }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The channels stay in their original groups.")
        }
        .confirmationDialog(
            selected.map { names[$0]?.name ?? String(localized: "Channel \($0)") } ?? "",
            isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }),
            titleVisibility: .visible,
            presenting: selected
        ) { channelID in
            Button("Move up") { move(channelID, by: -1) }
            Button("Move down") { move(channelID, by: 1) }
            Button("Move to top") { move(channelID, by: -100_000) }
            Button("Remove from folder", role: .destructive) {
                update { folder in folder.channelIDs.removeAll { $0 == channelID } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func update(_ change: (inout ChannelFolder) -> Void) {
        guard let index = settings.prefs.folders.firstIndex(where: { $0.id == folderID }) else { return }
        var folder = settings.prefs.folders[index]
        change(&folder)
        settings.prefs.folders[index] = folder
    }

    private func move(_ channelID: Int, by offset: Int) {
        update { folder in
            guard let from = folder.channelIDs.firstIndex(of: channelID) else { return }
            let to = min(max(from + offset, 0), folder.channelIDs.count - 1)
            guard to != from else { return }
            folder.channelIDs.remove(at: from)
            folder.channelIDs.insert(channelID, at: to)
        }
    }
}

// MARK: - Streams

struct StreamSettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        SettingsPage("Streams") {
            GlassPanel {
                SettingsOptionRow("Maximum resolution", icon: "4k.tv", selection: $settings.prefs.maxResolution,
                                  options: MaxResolution.allCases.map { ($0, $0.label) })
                SettingsOptionRow("Sort streams", icon: "arrow.up.arrow.down", selection: $settings.prefs.streamSort,
                                  options: StreamSort.allCases.map { ($0, $0.label) })
                SettingsToggleRow("Play the first stream automatically", icon: "play.circle",
                                  isOn: $settings.prefs.autoPlayFirstStream)
            }
            SettingsNote("Resolution is read from the addon's stream labels; streams without one are always shown.")
        }
    }
}

// MARK: - Player

struct PlayerSettingsView: View {
    @EnvironmentObject var settings: AppSettings

    private static let seekOptions = [5, 10, 15, 30, 60, 120]

    var body: some View {
        SettingsPage("Player") {
            GlassPanel("Audio language") {
                SettingsOptionRow("Preferred audio", icon: "speaker.wave.2", selection: $settings.prefs.audioLanguage,
                                  options: LanguageOptions.audio.map { ($0.code, $0.name) })
            }

            GlassPanel("Remote") {
                SettingsOptionRow("Skip back", icon: "gobackward", selection: $settings.prefs.seekBackSeconds,
                                  options: Self.seekOptions.map { ($0, String(localized: "\($0) seconds")) })
                SettingsOptionRow("Skip forward", icon: "goforward", selection: $settings.prefs.seekForwardSeconds,
                                  options: Self.seekOptions.map { ($0, String(localized: "\($0) seconds")) })
            }

            GlassPanel("Video") {
                SettingsToggleRow("Match content (frame rate & HDR)", icon: "tv", isOn: $settings.prefs.matchContent)
                SettingsToggleRow("Upscale low-resolution video", icon: "arrow.up.left.and.arrow.down.right",
                                  isOn: $settings.prefs.upscaleLowResolution)
            }
            SettingsNote("Match content switches your TV to the video's frame rate and HDR mode, when Match Content is also on in the Apple TV's own settings. Upscaling works on video below 1080p (SDR only, tvOS 26 or later); 1080p is left to the Apple TV, which already scales it to your TV.")

            GlassPanel("Audio") {
                SettingsToggleRow("Dialogue boost", icon: "person.wave.2", isOn: $settings.prefs.dialogueBoost)
                SettingsToggleRow("Night mode (quieter loud scenes)", icon: "moon", isOn: $settings.prefs.nightMode)
            }
            SettingsNote("Either option decodes the audio on the Apple TV, so Dolby Atmos passthrough is off while they're on.")
        }
    }
}

// MARK: - Subtitles

struct SubtitleSettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        SettingsPage("Subtitles") {
            GlassPanel {
                SettingsToggleRow("Turn subtitles on automatically", icon: "captions.bubble",
                                  isOn: $settings.prefs.autoSubtitles)
                SettingsOptionRow("Subtitle language", icon: "globe", selection: $settings.prefs.subtitleLanguage,
                                  options: LanguageOptions.audio.map { ($0.code, $0.name) })
            }
            SettingsNote("When on, subtitles in this language are picked automatically if the video has them.")

            GlassPanel("Appearance") {
                SettingsOptionRow("Size", icon: "textformat.size", selection: $settings.prefs.subtitleSize,
                                  options: SubtitleSize.allCases.map { ($0, $0.label) })
                Text("The quick brown fox jumps over the lazy dog")
                    .font(.system(size: settings.prefs.subtitleSize.points, weight: .semibold))
                    .shadow(color: .black, radius: 3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }
        }
    }
}

// MARK: - Home screen

struct HomeScreenSettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var selected: HomeRow?

    var body: some View {
        let rows = settings.homeRowOrder
        SettingsPage("Home screen") {
            GlassPanel("Rows, top to bottom") {
                ForEach(rows) { row in
                    let hidden = settings.prefs.hiddenHomeRows.contains(row.rawValue)
                    Button {
                        selected = row
                    } label: {
                        ListRowLabel(title: row.title, icon: "line.3.horizontal",
                                     trailing: hidden ? String(localized: "Hidden") : String(localized: "Shown"),
                                     trailingIcon: hidden ? "eye.slash" : "eye",
                                     dimmed: hidden)
                    }
                    .buttonStyle(PlainPressStyle())
                }
            }
            SettingsNote("Select a row to show or hide it, or to move it up or down. My List, Favourite Channels and My Teams only appear once they have something in them.")

            GlassPanel("Apple TV Top Shelf") {
                SettingsOptionRow("Top Shelf also shows", icon: "rectangle.topthird.inset.filled",
                                  selection: $settings.prefs.topShelfExtra,
                                  options: TopShelfExtra.allCases.map { ($0, $0.label) })
            }
            SettingsNote("Live games and Continue Watching are always on the Top Shelf. Coming up is your teams' games and races today and tomorrow. When there's nothing to show, it shows what's trending.")

            GlassPanel {
                SettingsActionRow("Reset to default", icon: "arrow.counterclockwise") {
                    settings.prefs.homeRows = HomeRow.allCases.map(\.rawValue)
                    settings.prefs.hiddenHomeRows = []
                }
            }
        }
        .confirmationDialog(
            selected?.title ?? "",
            isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }),
            titleVisibility: .visible,
            presenting: selected
        ) { row in
            if settings.prefs.hiddenHomeRows.contains(row.rawValue) {
                Button("Show on Home") { settings.prefs.hiddenHomeRows.remove(row.rawValue) }
            } else {
                Button("Hide from Home") { settings.prefs.hiddenHomeRows.insert(row.rawValue) }
            }
            Button("Move up") { move(row, by: -1) }
            Button("Move down") { move(row, by: 1) }
            Button("Move to top") { move(row, by: -100) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func move(_ row: HomeRow, by offset: Int) {
        var order = settings.homeRowOrder
        guard let from = order.firstIndex(of: row) else { return }
        let to = min(max(from + offset, 0), order.count - 1)
        guard to != from else { return }
        order.remove(at: from)
        order.insert(row, at: to)
        settings.prefs.homeRows = order.map(\.rawValue)
    }
}

// MARK: - Appearance

struct AppearanceSettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        SettingsPage("Appearance") {
            GlassPanel {
                SettingsOptionRow("Background", icon: "paintbrush", selection: $settings.prefs.backgroundStyle,
                                  options: BackgroundStyle.allCases.map { ($0, $0.label) })
            }
            SettingsNote("The backdrop behind Live TV, Sports, Calendar, Search and Settings. Frosted, Ocean, Sunset, Forest, Aurora and Rosé are soft coloured glows; Dark is plain and easier on the eyes at night; Black is pure black, best on OLED TVs.")
        }
    }
}

// MARK: - Sports

struct SportsSettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        SettingsPage("Sports") {
            GlassPanel {
                SettingsOptionRow("Show fixtures for the next", icon: "calendar", selection: $settings.prefs.sportsDaysAhead,
                                  options: [(7, String(localized: "7 days")), (14, String(localized: "14 days")), (30, String(localized: "30 days"))])
                SettingsLinkRow("My teams", icon: "star", value: "\(settings.prefs.favouriteTeams.count)") {
                    TeamsManagerView()
                }
                SettingsToggleRow("Remind me about my teams' matches", icon: "bell", isOn: $settings.prefs.remindTeamMatches)
            }
            SettingsNote("Fixtures cover every competition a team plays in, not just the league you picked it from. Match reminders go off as set in Live TV & Guide › Remind me.")
        }
    }
}

// MARK: - Calendar

struct CalendarSettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        SettingsPage("Calendar") {
            GlassPanel {
                SettingsOptionRow("Episodes per series", icon: "list.number", selection: $settings.prefs.calendarEpisodesPerSeries,
                                  options: [(1, String(localized: "Next episode only")), (2, String(localized: "Next 2 episodes")), (3, String(localized: "Next 3 episodes")), (5, String(localized: "Next 5 episodes"))])
                SettingsOptionRow("Look ahead", icon: "calendar", selection: $settings.prefs.calendarDaysAhead,
                                  options: [(30, String(localized: "30 days")), (60, String(localized: "60 days")), (90, String(localized: "90 days")), (180, String(localized: "6 months"))])
            }
            SettingsNote("The calendar lists upcoming episodes of the series in My List. Episodes that have already aired are never shown.")
        }
    }
}
