import SwiftUI
import AetherEngine

private struct GroupEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String
}

/// One block in a guide row: a programme, or an empty gap between listings.
private struct GuideSegment: Identifiable {
    let id: String
    let title: String
    let time: String
    let width: CGFloat
    let isGap: Bool
    let onNow: Bool
    var start: Date? = nil
    var end: Date? = nil
}

/// Live TV, as a TV guide (EPG grid) or a channel list. The layout is chosen
/// with the Guide / List buttons here or in Settings → Live TV & Guide.
struct LiveTVView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject private var player: PlayerEngineHolder
    /// False while another tab is showing; the preview only plays on screen.
    @State private var onScreen = false

    @State private var categories: [XtreamCategory] = []
    @State private var selectedID: String?
    @State private var channels: [XtreamChannel] = []
    @State private var epg: [Int: [XtreamEPGEntry]] = [:]
    @State private var loadingChannels = false
    @State private var error: String?
    @State private var playback: PlaybackRequest?
    @State private var infoChannel: XtreamChannel?
    @State private var infoEntry: XtreamEPGEntry?
    @State private var windowStart = LiveTVView.halfHourFloor(Date())
    @State private var now = Date()
    @FocusState private var focusedCell: String?
    @State private var reminderPrompt: ReminderPromptItem?
    @ObservedObject private var reminders = ReminderStore.shared
    @ObservedObject private var parental = ParentalLock.shared
    /// A locked group waiting for the PIN.
    @State private var pendingGroup: GroupEntry?
    @State private var askingPIN = false
    @State private var channelsReload = 0
    @State private var choosingAccount = false
    /// The account the groups were loaded for, so switching account starts on its own groups.
    @State private var loadedAccountID: String?
    /// For groups sorted by quality: the qualities that have channels, in folder order.
    @State private var qualityFolders: [String: [ChannelQuality]] = [:]
    /// The channel being renamed (long-press › Rename…).
    @State private var renaming: XtreamChannel?

    private static let favouritesID = "__favourites"
    private static let recentID = "__recent"
    private static let searchID = "__search"
    private static let folderPrefix = "folder:"
    /// The guide builds every row up front, so very large groups are capped.
    private static let guideRowLimit = 200
    /// Listings are downloaded for this many channels per group.
    private static let guideLoadLimit = 300
    private static let timelineHours = 6
    private static let channelColumn: CGFloat = 290
    private static let gridWidth: CGFloat = 1030
    private static let rowHeight: CGFloat = 76
    private static let headerHeight: CGFloat = 40

    private var client: XtreamClient { settings.xtreamClient }
    private var prefs: Preferences { settings.prefs }

    static func halfHourFloor(_ date: Date) -> Date {
        let seconds = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (seconds / 1800).rounded(.down) * 1800)
    }

    private var pixelsPerMinute: CGFloat {
        Self.gridWidth / CGFloat(max(1, prefs.guideHours) * 60)
    }

    // MARK: - Groups and channels

    /// Favourites, the user's own folders, then the provider's groups that aren't hidden.
    private var groups: [GroupEntry] {
        var list = prefs.folders.map {
            GroupEntry(id: Self.folderPrefix + $0.id, name: $0.name, icon: "square.stack.3d.up")
        }
        let merged = QualitySort.mergedGroups(categories, chosen: prefs.qualitySortCategoryIDs)
        var shownLeads = Set<String>()
        for category in categories {
            if let group = merged[category.id] {
                // Sorted by quality: the 4K, FHD, HD and SD folders of it and its twins take
                // their place, where the first of them was.
                guard shownLeads.insert(group.lead).inserted else { continue }
                let twins = merged.filter { $0.value.lead == group.lead }.map(\.key)
                if twins.allSatisfy({ prefs.hiddenCategoryIDs.contains($0) }) { continue }
                let locked = isLocked(groupID: group.lead)
                if prefs.hideLockedGroups && locked { continue }
                for quality in qualityFolders[group.lead] ?? [] {
                    list.append(GroupEntry(id: QualitySort.folderID(category: group.lead, quality: quality),
                                           name: "\(group.name) \(quality.label)", icon: locked ? "lock.fill" : "folder"))
                }
                continue
            }
            if prefs.hiddenCategoryIDs.contains(category.id) { continue }
            let locked = parental.isLocked(categoryID: category.id, prefs: prefs)
            if prefs.hideLockedGroups && locked { continue }
            list.append(GroupEntry(id: category.id, name: category.name, icon: locked ? "lock.fill" : "folder"))
        }
        if !prefs.favouriteChannelIDs.isEmpty {
            let favourites = GroupEntry(id: Self.favouritesID, name: String(localized: "Favourites"), icon: "star")
            if prefs.favouritesFirst {
                list.insert(favourites, at: 0)
            } else {
                list.append(favourites)
            }
        }
        // Search, then Recent, always at the top.
        var top = [GroupEntry(id: Self.searchID, name: String(localized: "Search"), icon: "magnifyingglass")]
        if !prefs.recentChannelIDs.isEmpty {
            top.append(GroupEntry(id: Self.recentID, name: String(localized: "Recent"), icon: "clock.arrow.circlepath"))
        }
        return top + list
    }

    /// Favourites, Recent and your own folders mix channels from several groups, so a channel
    /// from a group sorted by quality shows which folder it came from.
    private var showsFolderNames: Bool {
        guard let selectedID else { return false }
        return selectedID == Self.favouritesID || selectedID == Self.recentID || selectedID.hasPrefix(Self.folderPrefix)
    }

    private var isFolderSelected: Bool {
        (selectedID?.hasPrefix(Self.folderPrefix) ?? false) || selectedID == Self.recentID
    }

    private var sortedChannels: [XtreamChannel] {
        // Folders keep the order the user gave them.
        if isFolderSelected { return channels }
        switch prefs.channelSort {
        case .server:
            return channels
        case .number:
            return channels.sorted { ($0.number ?? .max) < ($1.number ?? .max) }
        case .name:
            return channels.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private var guideChannels: [XtreamChannel] {
        Array(sortedChannels.prefix(Self.guideRowLimit))
    }

    private var channelsKey: String {
        "\(channelsReload)|\(selectedID ?? "")|\(prefs.hiddenChannelIDs.count)|\(prefs.folders.hashValue)|\(prefs.favouriteChannelIDs.count)"
            + "|\(prefs.qualitySortCategoryIDs.sorted())|\(prefs.channelNames.hashValue)"
            + (selectedID == Self.recentID ? "|\(prefs.recentChannelIDs)" : "")
    }

    private var guideKey: String {
        "\(selectedID ?? "")|\(channels.count)|\(channels.first?.id ?? 0)|\(prefs.showEPG)"
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            AppBackground()

            if !settings.xtream.isConfigured {
                ContentUnavailableView("Add your IPTV login", systemImage: "tv",
                                       description: Text("Open Settings → Connections and enter your Xtream Codes server, username and password."))
            } else if let error {
                ContentUnavailableView("Couldn't load channels", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else {
                HStack(alignment: .top, spacing: 30) {
                    // Focus sections let Right / Left jump between the groups and the
                    // channels even when nothing lines up exactly (the preview box sits
                    // beside the top of the group list and can't take focus).
                    sidebar
                        .frame(width: 400)
                        .focusSection()
                        .pinPrompt($askingPIN) {
                            guard let group = pendingGroup else { return }
                            pendingGroup = nil
                            if group.id == selectedID {
                                // Was already selected while locked: reload it now it's open.
                                channelsReload += 1
                            } else {
                                select(group)
                            }
                        }
                    Group {
                        if selectedID == Self.searchID {
                            LiveSearchView { channel, results in
                                play(channel, in: results, groupName: String(localized: "Search"))
                            }
                        } else if prefs.liveLayout == .guide {
                            guide
                        } else {
                            list
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .focusSection()
                }
                .padding(.top, 10)
            }
        }
        .task(id: settings.xtream) { await loadCategories() }
        .task(id: prefs.qualitySortCategoryIDs) {
            await loadQualityFolders()
            chooseGroupIfNeeded()
        }
        .task(id: channelsKey) { await loadChannels() }
        .task(id: guideKey) { await loadGuide() }
        .task {
            // Keeps "now" (progress bars, the red line) and the guide's start time moving.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                now = Date()
                let floor = Self.halfHourFloor(now)
                if floor > windowStart { windowStart = floor }
            }
        }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .onChange(of: focusedCell) { _, id in
            focusChanged(id)
        }
        .fullScreenCover(item: $playback) { request in
            PlayerView(request: request).ignoresSafeArea()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            if settings.xtreamAccounts.count > 1 {
                Button {
                    choosingAccount = true
                } label: {
                    ListRowLabel(title: settings.xtream.displayName, subtitle: String(localized: "Switch account"),
                                 icon: "arrow.left.arrow.right")
                }
                .buttonStyle(PlainPressStyle())
                .confirmationDialog("Live TV account", isPresented: $choosingAccount, titleVisibility: .visible) {
                    ForEach(settings.xtreamAccounts) { account in
                        Button((account.id == settings.xtream.id ? "✓ " : "") + account.displayName) {
                            settings.switchAccount(to: account.id)
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                }
            }

            HStack(spacing: 10) {
                ForEach(LiveLayout.allCases) { layout in
                    Button {
                        settings.prefs.liveLayout = layout
                    } label: {
                        PillLabel(title: layout.label,
                                  icon: layout == .guide ? "square.grid.2x2" : "list.bullet",
                                  selected: prefs.liveLayout == layout)
                    }
                    .buttonStyle(PlainPressStyle())
                }
            }

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(groups) { group in
                        Button {
                            select(group)
                        } label: {
                            ListRowLabel(title: group.name, icon: group.icon, selected: group.id == selectedID)
                        }
                        .buttonStyle(PlainPressStyle())
                    }
                }
                .padding(.vertical, 10)
            }
        }
    }

    // MARK: - Guide (EPG grid)

    private var guide: some View {
        VStack(alignment: .leading, spacing: 18) {
            infoPanel

            if loadingChannels && channels.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
            } else if channels.isEmpty {
                emptyNote
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 8) {
                            VStack(spacing: 8) {
                                Text(now.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + "  " + DayFormat.time(now))
                                    .font(.system(size: 22, weight: .bold))
                                    .frame(width: Self.channelColumn, height: Self.headerHeight, alignment: .leading)
                                ForEach(guideChannels) { channel in
                                    GuideChannelCell(channel: channel,
                                                     number: prefs.showChannelNumbers ? channel.number : nil,
                                                     highlighted: infoChannel?.id == channel.id,
                                                     favourite: prefs.favouriteChannelIDs.contains(channel.id),
                                                     folderName: showsFolderNames ? channel.folderName : nil)
                                        .frame(width: Self.channelColumn, height: Self.rowHeight)
                                }
                            }

                            ScrollView(.horizontal) {
                                VStack(alignment: .leading, spacing: 8) {
                                    timeHeader
                                    ForEach(guideChannels) { channel in
                                        programmeRow(channel)
                                    }
                                }
                                .overlay(alignment: .topLeading) {
                                    Rectangle()
                                        .fill(Theme.live)
                                        .frame(width: 3)
                                        .padding(.top, Self.headerHeight + 4)
                                        .offset(x: CGFloat(now.timeIntervalSince(windowStart) / 60) * pixelsPerMinute)
                                        .allowsHitTesting(false)
                                }
                            }
                            .focusRow()
                        }

                        if channels.count > Self.guideRowLimit {
                            Text("Showing the first \(Self.guideRowLimit) channels of \(channels.count). Switch to List to see them all.")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .padding(.bottom, 60)
                }
            }
        }
        .fullScreenCover(item: $renaming) { channel in
            NavigationStack {
                RenameChannelView(channel: channel)
            }
            .background { AppBackground() }
            .environmentObject(settings)
        }
        .fullScreenCover(item: $reminderPrompt) { item in
            ReminderPromptView(item: item) {
                // Waits for the prompt to close before the player opens.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(450))
                    play(item.channel)
                }
            }
            .presentationBackground(.clear)
        }
    }

    private var timeHeader: some View {
        HStack(spacing: 0) {
            ForEach(0..<(Self.timelineHours * 2), id: \.self) { slot in
                Text(DayFormat.time(windowStart.addingTimeInterval(TimeInterval(slot) * 1800)))
                    .font(.system(size: 22, weight: .bold))
                    .frame(width: pixelsPerMinute * 30, height: Self.headerHeight, alignment: .leading)
            }
        }
    }

    private func programmeRow(_ channel: XtreamChannel) -> some View {
        let segments = segments(for: channel)
        return HStack(spacing: 0) {
            ForEach(segments) { segment in
                if segment.isGap {
                    Color.clear.frame(width: segment.width, height: Self.rowHeight)
                } else {
                    Button {
                        // A programme that hasn't started: offer a reminder. Otherwise watch.
                        if let start = segment.start, let end = segment.end, start > Date() {
                            reminderPrompt = ReminderPromptItem(channel: channel, title: segment.title,
                                                                start: start, end: end)
                        } else {
                            play(channel)
                        }
                    } label: {
                        ProgrammeCell(title: segment.title, time: segment.time, onNow: segment.onNow,
                                      width: max(segment.width - 6, 4), height: Self.rowHeight,
                                      reminded: segment.start.map { reminders.isSet(channelID: channel.id, start: $0) } ?? false)
                    }
                    .buttonStyle(PlainPressStyle())
                    .focused($focusedCell, equals: segment.id)
                    .contextMenu { channelMenu(channel) }
                    .frame(width: segment.width, alignment: .leading)
                }
            }
        }
        .frame(height: Self.rowHeight)
    }

    /// Lays a channel's listings along the timeline, filling holes with gaps.
    private func segments(for channel: XtreamChannel) -> [GuideSegment] {
        let start = windowStart
        let end = start.addingTimeInterval(TimeInterval(Self.timelineHours) * 3600)
        let scale = pixelsPerMinute

        let listings = (epg[channel.id] ?? [])
            .filter { entry in
                guard let begins = entry.start, let ends = entry.end else { return false }
                return ends > start && begins < end
            }
            .sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }

        var result: [GuideSegment] = []
        var cursor = start
        for entry in listings {
            guard let begins = entry.start, let ends = entry.end else { continue }
            let from = max(begins, cursor)
            let to = min(ends, end)
            // Skips listings that overlap one already placed.
            guard to > from else { continue }
            if from > cursor {
                result.append(GuideSegment(id: "\(channel.id)|gap|\(result.count)", title: "", time: "",
                                           width: CGFloat(from.timeIntervalSince(cursor) / 60) * scale,
                                           isGap: true, onNow: false))
            }
            result.append(GuideSegment(
                id: "\(channel.id)|\(Int(begins.timeIntervalSince1970))|\(result.count)",
                title: entry.title.isEmpty ? String(localized: "No information") : entry.title,
                time: "\(DayFormat.time(begins)) – \(DayFormat.time(ends))",
                width: CGFloat(to.timeIntervalSince(from) / 60) * scale,
                isGap: false,
                onNow: begins <= now && now < ends,
                start: begins,
                end: ends
            ))
            cursor = to
        }

        if !result.contains(where: { !$0.isGap }) {
            // No listings: one block across the visible window, still selectable to watch.
            let waiting = epg[channel.id] == nil && prefs.showEPG
            return [GuideSegment(id: "\(channel.id)|0|0", title: waiting ? String(localized: "Loading guide…") : String(localized: "No information"),
                                 time: "", width: Self.gridWidth, isGap: false, onNow: false)]
        }
        return result
    }

    private var infoPanel: some View {
        let entry = infoEntry ?? infoChannel.flatMap { current($0.id) }
        return HStack(alignment: .top, spacing: 30) {
            if prefs.guidePreview {
                LivePreview(channel: infoChannel,
                            active: playback == nil && onScreen && !player.isPresentingPlayer)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(infoChannel?.name ?? (groups.first { $0.id == selectedID }?.name ?? String(localized: "Live TV")))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Text(entry?.title ?? (infoChannel == nil ? String(localized: "Choose a programme") : String(localized: "No information")))
                    .font(.system(size: 44, weight: .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let entry, let begins = entry.start, let ends = entry.end, ends > begins {
                    HStack(spacing: 16) {
                        Text("\(DayFormat.time(begins)) – \(DayFormat.time(ends))")
                            .font(.system(size: 22, weight: .semibold))
                        if begins <= now && now < ends {
                            ThinProgress(fraction: now.timeIntervalSince(begins) / ends.timeIntervalSince(begins))
                                .frame(width: 260)
                            Text("\(max(1, Int(ends.timeIntervalSince(now) / 60))) min left")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))
                        } else {
                            Text("\(Int(ends.timeIntervalSince(begins) / 60)) min")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
                if let description = entry?.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 225, alignment: .top)
    }

    // MARK: - List

    private var list: some View {
        Group {
            if loadingChannels && channels.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
            } else if channels.isEmpty {
                emptyNote
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(sortedChannels) { channel in
                            Button {
                                play(channel)
                            } label: {
                                ChannelListRow(channel: channel,
                                               number: prefs.showChannelNumbers ? channel.number : nil,
                                               current: prefs.showEPG ? current(channel.id) : nil,
                                               next: prefs.showEPG ? next(channel.id) : nil,
                                               now: now,
                                               favourite: prefs.favouriteChannelIDs.contains(channel.id),
                                               folderName: showsFolderNames ? channel.folderName : nil)
                            }
                            .buttonStyle(PlainPressStyle())
                            .focused($focusedCell, equals: "\(channel.id)")
                            .contextMenu { channelMenu(channel) }
                        }
                    }
                    .padding(.vertical, 10)
                    .padding(.trailing, 10)
                }
            }
        }
    }

    @ViewBuilder
    private var emptyNote: some View {
        if selectedIsLocked {
            VStack(alignment: .leading, spacing: 18) {
                Label("This group is locked", systemImage: "lock.fill")
                    .font(.system(size: 30, weight: .bold))
                Button {
                    if let group = groups.first(where: { $0.id == selectedID }) {
                        pendingGroup = group
                        askingPIN = true
                    }
                } label: {
                    PillLabel(title: String(localized: "Enter PIN"), icon: "key")
                }
                .buttonStyle(PlainPressStyle())
            }
            .padding(.top, 40)
        } else {
            unlockedEmptyNote
        }
    }

    private var unlockedEmptyNote: some View {
        Text(selectedID == Self.favouritesID
             ? "No favourites yet. Long-press a channel to add it."
             : (isFolderSelected ? "This folder is empty. Add channels in Settings → Content → My folders, or long-press a channel."
                                 : "No channels in this group."))
            .foregroundStyle(.white.opacity(0.7))
            .padding(.top, 40)
    }

    @ViewBuilder
    private func channelMenu(_ channel: XtreamChannel) -> some View {
        Button("Add to multiview", systemImage: "rectangle.split.2x1") {
            MultiviewStore.shared.add(channel)
        }
        if prefs.favouriteChannelIDs.contains(channel.id) {
            Button("Remove from Favourites", systemImage: "star.slash") {
                settings.prefs.favouriteChannelIDs.remove(channel.id)
            }
        } else {
            Button("Add to Favourites", systemImage: "star") {
                settings.prefs.favouriteChannelIDs.insert(channel.id)
            }
        }
        ForEach(prefs.folders) { folder in
            if folder.channelIDs.contains(channel.id) {
                Button("Remove from \(folder.name)", systemImage: "minus.circle") {
                    toggle(channel.id, inFolder: folder.id)
                }
            } else {
                Button("Add to \(folder.name)", systemImage: "plus.circle") {
                    toggle(channel.id, inFolder: folder.id)
                }
            }
        }
        Button("Rename…", systemImage: "pencil") {
            renaming = channel
        }
        Button("Hide channel", systemImage: "eye.slash", role: .destructive) {
            settings.prefs.hiddenChannelIDs.insert(channel.id)
        }
    }

    // MARK: - Guide data helpers

    private func current(_ channelID: Int) -> XtreamEPGEntry? {
        epg[channelID]?.first { ($0.start ?? .distantFuture) <= now && now < ($0.end ?? .distantPast) }
    }

    private func next(_ channelID: Int) -> XtreamEPGEntry? {
        guard let ends = current(channelID)?.end else { return nil }
        return epg[channelID]?
            .filter { ($0.start ?? .distantPast) >= ends }
            .min { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
    }

    // MARK: - Actions

    /// The selected group is locked and the PIN hasn't been entered.
    private var selectedIsLocked: Bool {
        guard let selectedID else { return false }
        return isLocked(groupID: selectedID)
    }

    /// A group, or a quality folder: locked when its group or any merged twin is.
    private func isLocked(groupID id: String) -> Bool {
        let lead = QualitySort.baseCategory(of: id)
        let merged = QualitySort.mergedGroups(categories, chosen: prefs.qualitySortCategoryIDs)
        guard merged[lead] != nil else { return parental.isLocked(categoryID: lead, prefs: prefs) }
        return merged.contains { $0.value.lead == lead && parental.isLocked(categoryID: $0.key, prefs: prefs) }
    }

    private func select(_ group: GroupEntry) {
        if isLocked(groupID: group.id) {
            pendingGroup = group
            askingPIN = true
            return
        }
        guard group.id != selectedID else { return }
        infoChannel = nil
        infoEntry = nil
        selectedID = group.id
        if prefs.rememberLastCategory && group.id != Self.searchID { settings.prefs.lastCategoryID = group.id }
    }

    /// Cell ids are "channel|start|n" in the guide and "channel" in the list.
    private func focusChanged(_ id: String?) {
        guard let id else { return }
        let parts = id.split(separator: "|")
        guard let first = parts.first, let channelID = Int(first),
              let channel = channels.first(where: { $0.id == channelID }) else { return }
        infoChannel = channel
        let stamp = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        if stamp == 0 {
            infoEntry = nil
        } else {
            infoEntry = epg[channelID]?.first { Int($0.start?.timeIntervalSince1970 ?? 0) == stamp }
        }
    }

    private func toggle(_ channelID: Int, inFolder folderID: String) {
        guard let index = settings.prefs.folders.firstIndex(where: { $0.id == folderID }) else { return }
        var folder = settings.prefs.folders[index]
        if let position = folder.channelIDs.firstIndex(of: channelID) {
            folder.channelIDs.remove(at: position)
        } else {
            folder.channelIDs.append(channelID)
        }
        settings.prefs.folders[index] = folder
    }

    private func play(_ channel: XtreamChannel) {
        play(channel, in: sortedChannels, groupName: groups.first(where: { $0.id == selectedID })?.name)
    }

    private func play(_ channel: XtreamChannel, in all: [XtreamChannel], groupName: String?) {
        guard let url = client.liveURL(for: channel, format: prefs.liveFormat) else { return }
        let index = all.firstIndex(of: channel) ?? 0
        playback = PlaybackRequest(
            url: url,
            title: channel.name,
            artworkURL: channel.icon.flatMap { URL(string: $0) },
            sourceName: groupName,
            isLive: true,
            httpHeaders: client.requestHeaders,
            live: LiveContext(channels: all, index: index)
        )
    }

    // MARK: - Loading

    private func loadCategories() async {
        guard settings.xtream.isConfigured else { return }
        if loadedAccountID != settings.xtream.id {
            // Another account: its groups and channels are different, so start fresh.
            loadedAccountID = settings.xtream.id
            selectedID = nil
            categories = []
            channels = []
        }
        do {
            categories = try await XtreamCache.shared.liveCategories(client)
            error = nil
            await loadQualityFolders()
            chooseGroupIfNeeded()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Keeps the selection if it still exists, otherwise opens the last or first real group.
    private func chooseGroupIfNeeded() {
        let ids = groups.map(\.id)
        guard !categories.isEmpty else { return }
        if let selectedID, ids.contains(selectedID) { return }
        // Opens on a real group, not Search or Recent.
        let opening = ids.filter { $0 != Self.searchID && $0 != Self.recentID }
        if prefs.rememberLastCategory, let last = prefs.lastCategoryID, ids.contains(last) {
            selectedID = last
        } else {
            selectedID = opening.first ?? ids.first
        }
    }

    /// Which quality folders the sorted groups need (only ones with channels show).
    private func loadQualityFolders() async {
        let chosen = prefs.qualitySortCategoryIDs
        guard !chosen.isEmpty, settings.xtream.isConfigured else {
            qualityFolders = [:]
            return
        }
        let all = (try? await XtreamCache.shared.liveStreams(client)) ?? []
        var found: [String: Set<ChannelQuality>] = [:]
        for channel in all {
            guard let lead = channel.folderGroupID, let quality = channel.quality, settings.isVisible(channel) else { continue }
            found[lead, default: []].insert(quality)
        }
        qualityFolders = found.mapValues { present in ChannelQuality.allCases.filter { present.contains($0) } }
    }

    private func loadChannels() async {
        guard let selectedID, !selectedIsLocked else {
            channels = []
            return
        }
        loadingChannels = true
        defer { loadingChannels = false }

        let client = self.client
        var loaded: [XtreamChannel] = []
        if selectedID == Self.searchID {
            loaded = []
        } else if selectedID == Self.recentID {
            let all = (try? await XtreamCache.shared.liveStreams(client)) ?? []
            let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            loaded = prefs.recentChannelIDs.compactMap { byID[$0] }.filter { channel in
                settings.isVisible(channel) && !parental.isLocked(categoryID: channel.categoryID ?? "", prefs: prefs)
            }
        } else if selectedID == Self.favouritesID {
            let all = (try? await XtreamCache.shared.liveStreams(client)) ?? []
            loaded = all.filter { prefs.favouriteChannelIDs.contains($0.id) && settings.isVisible($0) }
        } else if selectedID.hasPrefix(Self.folderPrefix) {
            let folderID = String(selectedID.dropFirst(Self.folderPrefix.count))
            let ids = prefs.folders.first(where: { $0.id == folderID })?.channelIDs ?? []
            let all = (try? await XtreamCache.shared.liveStreams(client)) ?? []
            let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            loaded = ids.compactMap { byID[$0] }
        } else if let folder = QualitySort.parseFolderID(selectedID) {
            let all = (try? await XtreamCache.shared.liveStreams(client)) ?? []
            loaded = all.filter {
                $0.folderGroupID == folder.category && $0.quality == folder.quality && settings.isVisible($0)
            }
        } else {
            let all = (try? await client.liveStreams(categoryID: selectedID)) ?? []
            loaded = QualitySort.applyCustomNames(all.filter { !prefs.hiddenChannelIDs.contains($0.id) })
        }
        guard !Task.isCancelled else { return }
        channels = loaded
    }

    private nonisolated static func listings(_ client: XtreamClient, channelID: Int,
                                             from: Date, until: Date) async -> (Int, [XtreamEPGEntry]) {
        let all = await XtreamCache.shared.guide(client, streamID: channelID)
        let kept = all.filter { entry in
            guard let begins = entry.start, let ends = entry.end else { return false }
            return ends > from && begins < until
        }
        return (channelID, kept)
    }

    /// Downloads listings a few channels at a time, top of the list first.
    private func loadGuide() async {
        guard prefs.showEPG else { return }
        let client = self.client
        let pending = sortedChannels.prefix(Self.guideLoadLimit).filter { epg[$0.id] == nil }
        guard !pending.isEmpty else { return }

        // Only what the guide can show: from an hour ago to a day ahead.
        let from = Date().addingTimeInterval(-3600)
        let until = Date().addingTimeInterval(24 * 3600)
        var buffer: [Int: [XtreamEPGEntry]] = [:]

        var queue = pending.map(\.id).makeIterator()
        await withTaskGroup(of: (Int, [XtreamEPGEntry]).self) { group in
            for _ in 0..<6 {
                guard let channelID = queue.next() else { break }
                group.addTask { await Self.listings(client, channelID: channelID, from: from, until: until) }
            }
            while let (channelID, entries) = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                buffer[channelID] = entries
                if buffer.count >= 4 {
                    epg.merge(buffer) { _, new in new }
                    buffer.removeAll()
                }
                if let nextID = queue.next() {
                    group.addTask { await Self.listings(client, channelID: nextID, from: from, until: until) }
                }
            }
        }
        if !buffer.isEmpty {
            epg.merge(buffer) { _, new in new }
        }
    }
}

// MARK: - Cells

private struct GuideChannelCell: View {
    let channel: XtreamChannel
    let number: Int?
    let highlighted: Bool
    let favourite: Bool
    var folderName: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            if let number {
                Text("\(number)")
                    .font(.system(size: 18, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.6))
            }
            AsyncImage(url: channel.icon.flatMap { URL(string: $0) }) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                Image(systemName: "tv").foregroundStyle(.white.opacity(0.5))
            }
            .frame(width: 64, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name)
                    .font(.system(size: 20, weight: .bold))
                    .lineLimit(folderName == nil ? 2 : 1)
                if let folderName {
                    Text(folderName)
                        .font(.system(size: 15, weight: .medium))
                        .opacity(0.65)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if favourite {
                Image(systemName: "star.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.yellow)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(highlighted ? Theme.glassStrong : Theme.glass)
        )
    }
}

private struct ProgrammeCell: View {
    let title: String
    let time: String
    let onNow: Bool
    let width: CGFloat
    let height: CGFloat
    var reminded = false
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if reminded {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(isFocused ? Theme.ink : Color(red: 1, green: 0.7, blue: 0.25))
                }
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .lineLimit(1)
            }
            if !time.isEmpty {
                Text(time)
                    .font(.system(size: 18))
                    .opacity(0.7)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, width > 40 ? 14 : 2)
        .frame(width: width, height: height, alignment: .leading)
        .foregroundStyle(isFocused ? Theme.ink : Color.white)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isFocused ? Color.white : (onNow ? Theme.glassStrong : Theme.glass))
        )
        .clipped()
        .animation(.easeOut(duration: 0.1), value: isFocused)
    }
}

private struct ChannelListRow: View {
    let channel: XtreamChannel
    let number: Int?
    let current: XtreamEPGEntry?
    let next: XtreamEPGEntry?
    let now: Date
    let favourite: Bool
    var folderName: String? = nil
    @Environment(\.isFocused) private var isFocused

    private var progress: Double? {
        guard let begins = current?.start, let ends = current?.end, ends > begins else { return nil }
        return now.timeIntervalSince(begins) / ends.timeIntervalSince(begins)
    }

    var body: some View {
        HStack(spacing: 22) {
            if let number {
                Text("\(number)")
                    .font(.system(size: 20, weight: .bold))
                    .monospacedDigit()
                    .opacity(0.6)
                    .frame(width: 60, alignment: .trailing)
            }
            AsyncImage(url: channel.icon.flatMap { URL(string: $0) }) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                Image(systemName: "tv").font(.title2)
            }
            .frame(width: 96, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text([channel.name, folderName].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 20, weight: .bold))
                        .opacity(0.7)
                        .lineLimit(1)
                    if favourite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(isFocused ? Theme.ink : Color.yellow)
                    }
                }
                Text(current?.title ?? channel.name)
                    .font(.system(size: 28, weight: .bold))
                    .lineLimit(1)
                if let next, let begins = next.start {
                    Text("Next \(DayFormat.time(begins)) · \(next.title)")
                        .font(.system(size: 20, weight: .medium))
                        .opacity(0.7)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            if let begins = current?.start, let ends = current?.end, let progress {
                VStack(alignment: .trailing, spacing: 10) {
                    Text("\(DayFormat.time(begins)) – \(DayFormat.time(ends))")
                        .font(.system(size: 22, weight: .semibold))
                        .opacity(0.7)
                    ThinProgress(fraction: progress, tint: isFocused ? Theme.ink : Color.white)
                        .frame(width: 240)
                }
            }
        }
        .foregroundStyle(isFocused ? Theme.ink : Color.white)
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isFocused ? Color.white : Theme.glass)
        )
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

// MARK: - Muted live preview

/// Plays the focused channel, muted, in the guide's top-left box. It shares
/// the app's one player engine, so it steps aside while the full-screen
/// player is open and stops when Live TV is left.
private struct LivePreview: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: PlayerEngineHolder
    let channel: XtreamChannel?
    let active: Bool

    var body: some View {
        ZStack {
            Color.black
            if active, channel != nil, let engine = player.engine {
                AetherPlayerSurface(engine: engine)
            } else {
                Image(systemName: "play.tv")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(width: 400, height: 225)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .task(id: "\(active)|\(channel?.id ?? -1)") {
            guard active, let channel, let engine = player.engine else { return }
            // Wait until focus settles on a channel before tuning in.
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            let client = settings.xtreamClient
            guard let url = client.liveURL(for: channel, format: settings.prefs.liveFormat) else { return }
            engine.volume = 0
            let options = LoadOptions(
                // The preview must never switch the TV's display mode: that blanks the
                // whole screen while you browse the guide.
                suppressDisplayCriteria: true,
                httpHeaders: client.requestHeaders,
                matchContentEnabled: false,
                isLive: true,
                liveJoinProfile: .fastZap,
                // Same pipeline as the full-screen player (see PlayerView).
                nativeRemoteHLS: false,
                preferredAudioLanguages: [settings.prefs.audioLanguage]
            )
            _ = try? await engine.load(url: url, options: options)
        }
        .onDisappear {
            if active { player.engine?.stop() }
        }
        .onChange(of: active) { _, isActive in
            // Leaving the tab stops the preview; the full-screen player loads its own stream.
            if !isActive && !player.isPresentingPlayer { player.engine?.stop() }
        }
    }
}
