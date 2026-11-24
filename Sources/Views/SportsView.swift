import SwiftUI

// MARK: - Sports tab

struct SportsView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var fixtures: [Fixture] = []
    @State private var loading = false
    @ObservedObject private var liveScores = LiveScores.shared

    private var teams: [FavouriteTeam] { settings.prefs.favouriteTeams }
    private var days: Int { settings.prefs.sportsDaysAhead }

    private var loadKey: String {
        teams.map(\.id).joined(separator: ",") + "|\(days)"
    }

    /// On today, or already under way.
    private var today: [Fixture] {
        fixtures.filter { Calendar.current.isDateInToday($0.guideTime) || $0.guideTime <= Date() }
    }

    private var later: [Fixture] {
        let todayIDs = Set(today.map(\.id))
        return fixtures.filter { !todayIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 36) {
                    HStack(spacing: 18) {
                        NavigationLink {
                            TeamsManagerView()
                        } label: {
                            PillLabel(title: String(localized: "My Teams"), icon: "star")
                        }
                        .buttonStyle(PlainPressStyle())

                        Label("Next \(days) days · all competitions", systemImage: "calendar")
                            .font(.system(size: 24, weight: .semibold))
                            .padding(.horizontal, 26)
                            .padding(.vertical, 14)
                            .background(Theme.glass, in: Capsule())
                    }
                    .padding(.horizontal, 90)
                    .padding(.top, 20)

                    if teams.isEmpty {
                        message("Choose your teams with My Teams to see when they next play or race.")
                    } else if loading && fixtures.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    } else if fixtures.isEmpty {
                        message("No fixtures for your teams in the next \(days) days.")
                    }

                    if !today.isEmpty {
                        row("Today") {
                            ForEach(today) { fixture in
                                NavigationLink(value: fixture) {
                                    FixtureTile(fixture: fixture, width: 480)
                                }
                                .buttonStyle(PlainPressStyle())
                            }
                        }
                    }

                    if !later.isEmpty {
                        row("Next \(days) days") {
                            ForEach(later) { fixture in
                                NavigationLink(value: fixture) {
                                    UpcomingCard(fixture: fixture)
                                }
                                .buttonStyle(PlainPressStyle())
                            }
                        }
                    }

                    if !teams.isEmpty {
                        row("My Teams") {
                            ForEach(teams) { team in
                                let next = fixtures.first {
                                    $0.followed.contains(team.name) && liveScores.score(for: $0)?.phase != .finished
                                }
                                if let next {
                                    NavigationLink(value: next) {
                                        TeamTile(team: team, next: next)
                                    }
                                    .buttonStyle(PlainPressStyle())
                                } else {
                                    Button {} label: {
                                        TeamTile(team: team, next: nil)
                                    }
                                    .buttonStyle(PlainPressStyle())
                                }
                            }
                        }

                        LeagueTablesSection(teams: teams)
                    }
                }
                .padding(.bottom, 60)
            }
            .background(AppBackground())
            .task(id: loadKey) { await load() }
            .task { await liveScores.run() }
            .navigationDestination(for: Fixture.self) { fixture in
                FixtureDetailView(fixture: fixture)
            }
        }
    }

    private func row<Content: View>(_ title: LocalizedStringResource, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3).bold()
                .padding(.horizontal, 90)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 40) {
                    content()
                }
                .padding(.horizontal, 90)
                .padding(.vertical, 30)
            }
            .focusRow()
            .scrollClipDisabled()
        }
    }

    private func message(_ text: LocalizedStringResource) -> some View {
        Text(text)
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 90)
            .padding(.top, 20)
    }

    private func load() async {
        guard !teams.isEmpty else {
            fixtures = []
            return
        }
        loading = true
        fixtures = await SportsLoader.upcoming(teams: teams, days: days)
        loading = false
    }
}

// MARK: - Fixture artwork and cards

/// A team crest on a light disc, so dark logos stay visible on any colour.
struct TeamLogo: View {
    let url: String?
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.94))
            AsyncImage(url: url.flatMap { URL(string: $0) }) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                Image(systemName: "shield.fill")
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(Color.gray)
            }
            .padding(size * 0.16)
        }
        .frame(width: size, height: size)
    }
}

private struct DiagonalHalf: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.58, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Two-tone artwork in the teams' colours with both crests (or a flag for a race).
struct FixtureArt: View {
    let fixture: Fixture

    private var homeColor: Color {
        if fixture.isRace { return Color(red: 0.82, green: 0.1, blue: 0.1) }
        return Color(hex: fixture.home?.color) ?? Color(red: 0.24, green: 0.3, blue: 0.42)
    }

    private var awayColor: Color {
        if fixture.isRace { return Color(red: 0.12, green: 0.12, blue: 0.15) }
        return Color(hex: fixture.away?.color) ?? Color(red: 0.13, green: 0.14, blue: 0.18)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                awayColor
                Color.black.opacity(0.35)
                DiagonalHalf().fill(homeColor)
                if fixture.isRace {
                    Image(systemName: "flag.checkered")
                        .font(.system(size: geo.size.height * 0.34, weight: .bold))
                        .foregroundStyle(Color.white)
                } else {
                    HStack(spacing: 0) {
                        TeamLogo(url: fixture.home?.logo, size: geo.size.height * 0.46)
                            .frame(maxWidth: .infinity)
                        TeamLogo(url: fixture.away?.logo, size: geo.size.height * 0.46)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}

/// A fixture as artwork with its title and time underneath.
struct FixtureTile: View {
    let fixture: Fixture
    let width: CGFloat
    @ObservedObject private var liveScores = LiveScores.shared

    private var isLive: Bool { fixture.guideTime <= Date() }
    private var score: FixtureScore? { liveScores.score(for: fixture) }

    private var detail: String {
        if let score {
            return [fixture.competition, score.period].compactMap { $0 }.joined(separator: " · ")
        }
        let session = fixture.sessions.first(where: { $0.date == fixture.guideTime })
        if fixture.isRace && isLive {
            return String(localized: "\(session?.name ?? String(localized: "Race")) in progress · \(fixture.competition)")
        }
        var parts = ["\(DayFormat.label(fixture.guideTime)) \(DayFormat.time(fixture.guideTime))"]
        if let session { parts.append(session.name) }
        parts.append(fixture.competition)
        return parts.joined(separator: " · ")
    }

    /// Top-left pill: kick-off time, LIVE, HT or FT.
    private var pill: (text: String, color: Color) {
        switch score?.phase {
        case .finished: return (score?.clock ?? String(localized: "FT"), Color.black.opacity(0.6))
        case .halfTime: return (String(localized: "HT"), Color.black.opacity(0.6))
        case .live: return (String(localized: "LIVE"), Theme.live)
        case nil: return isLive ? (String(localized: "LIVE"), Theme.live) : (DayFormat.time(fixture.guideTime), Color.black.opacity(0.5))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FocusFrame(cornerRadius: 22) {
                FixtureArt(fixture: fixture)
                    .frame(width: width, height: width * 9 / 16)
                    .overlay {
                        if let score { ScoreBadge(score: score, size: width / 440) }
                    }
                    .overlay(alignment: .topLeading) {
                        Text(pill.text)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(pill.color))
                            .padding(16)
                    }
            }
            Text(fixture.title)
                .font(.system(size: 26, weight: .bold))
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
            Text(detail)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
        }
    }
}

/// The score between the two crests, with the minute (red while live) underneath.
struct ScoreBadge: View {
    let score: FixtureScore
    /// 1 at the 440-point Home tile.
    var size: CGFloat = 1

    private var caption: String {
        switch score.phase {
        case .live: return score.clock
        case .halfTime: return String(localized: "Half-time")
        case .finished: return score.clock == "FT" ? String(localized: "Full time") : score.clock
        }
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(score.line)
                .font(.system(size: 46 * size, weight: .heavy))
                .monospacedDigit()
            Text(caption)
                .font(.system(size: 18 * size, weight: .bold))
                .foregroundStyle(score.phase == .live ? Theme.live : Color.white.opacity(0.8))
                .lineLimit(1)
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 18 * size)
        .padding(.vertical, 10 * size)
        .background(RoundedRectangle(cornerRadius: 18 * size, style: .continuous).fill(Color.black.opacity(0.55)))
    }
}

/// A compact card for fixtures later in the window.
private struct UpcomingCard: View {
    let fixture: Fixture
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if fixture.isRace {
                Image(systemName: "flag.checkered")
                    .font(.system(size: 40, weight: .bold))
                    .frame(height: 60)
            } else {
                HStack(spacing: -14) {
                    TeamLogo(url: fixture.home?.logo, size: 60)
                    TeamLogo(url: fixture.away?.logo, size: 60)
                }
            }
            Text(DayFormat.label(fixture.guideTime).uppercased())
                .font(.system(size: 18, weight: .bold))
                .opacity(0.7)
                .padding(.top, 6)
            Text(fixture.title)
                .font(.system(size: 26, weight: .bold))
                .lineLimit(1)
            Text("\(DayFormat.time(fixture.guideTime)) · \(fixture.competition)")
                .font(.system(size: 20, weight: .medium))
                .opacity(0.7)
                .lineLimit(1)
        }
        .foregroundStyle(isFocused ? Theme.ink : Color.white)
        .padding(24)
        .frame(width: 420, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(isFocused ? Color.white : Theme.glass)
        )
        .scaleEffect(isFocused ? 1.04 : 1)
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

/// A followed team with its next fixture.
private struct TeamTile: View {
    let team: FavouriteTeam
    let next: Fixture?

    private var nextLine: String {
        guard let next else { return String(localized: "No fixture soon") }
        return String(localized: "Next: \(DayFormat.label(next.guideTime)) \(DayFormat.time(next.guideTime))")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FocusFrame {
                ZStack {
                    Rectangle().fill(Theme.glass)
                    if team.isF1 {
                        Image(systemName: "flag.checkered").font(.system(size: 60, weight: .bold))
                    } else {
                        AsyncImage(url: team.logo.flatMap { URL(string: $0) }) { image in
                            image.resizable().aspectRatio(contentMode: .fit)
                        } placeholder: {
                            Image(systemName: "shield").font(.largeTitle)
                        }
                        .padding(26)
                    }
                }
                .frame(width: 300, height: 170)
            }
            Text(team.name)
                .font(.system(size: 22, weight: .bold))
                .lineLimit(1)
                .frame(width: 300, alignment: .leading)
            Text(nextLine)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
                .frame(width: 300, alignment: .leading)
        }
    }
}

// MARK: - Fixture detail + TV guide matching

struct FixtureDetailView: View {
    @EnvironmentObject var settings: AppSettings
    let fixture: Fixture

    @ObservedObject private var store = ChannelSearchStore.shared
    @State private var playback: PlaybackRequest?
    @State private var showingSportsChannels = false
    @ObservedObject private var liveScores = LiveScores.shared
    @ObservedObject private var reminders = ReminderStore.shared
    @State private var addonHits: [AddonSportsHit] = []
    @State private var addonSearching = false
    /// Whether any addon lists something other than movies and series; otherwise the panel stays hidden.
    @State private var addonsHaveLive = false

    private var unlockedAddons: [AddonEntry] {
        settings.addons.filter { !ParentalLock.shared.isLocked(addon: $0, prefs: settings.prefs) }
    }

    /// The guide search is done (or there's no IPTV account), so its channels can be looked for in addons too.
    private var guideSearchDone: Bool { !settings.xtream.isConfigured || !searching }

    private var score: FixtureScore? { liveScores.score(for: fixture) }
    private var entry: ChannelSearchStore.Entry? { store.entries[fixture.id] }
    private var result: ChannelSearch { entry?.result ?? ChannelSearch() }
    private var searching: Bool { entry?.searching ?? true }
    private var matches: [ChannelMatch] { result.matches }

    /// The provider's guide doesn't reach the fixture yet. Without the whole
    /// guide, guides rarely go more than about a week ahead.
    private var notListedYet: Bool {
        if let ends = result.guideEnds { return fixture.guideTime > ends }
        return fixture.guideTime > Date().addingTimeInterval(8 * 86_400)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .center, spacing: 30) {
                    FixtureArt(fixture: fixture)
                        .frame(width: 330, height: 186)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: 16, y: 10)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(displayTitle)
                            .font(.system(size: 46, weight: .heavy))
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                        if let score {
                            HStack(spacing: 12) {
                                Text(score.phase == .live ? String(localized: "● LIVE \(score.clock)") : score.clock)
                                    .font(.system(size: 20, weight: .heavy))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(score.phase == .live ? Theme.live : Color.black.opacity(0.45)))
                                if let period = score.period {
                                    Text(period)
                                        .font(.system(size: 22, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.85))
                                }
                            }
                        }
                        if let subtitle = fixture.subtitle, !subtitle.isEmpty {
                            Label(subtitle, systemImage: fixture.isRace ? "flag.checkered" : "mappin.and.ellipse")
                                .font(.system(size: 23, weight: .medium))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        Text(fixture.competition)
                            .font(.system(size: 23, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                        Text(dateLine)
                            .font(.system(size: 24, weight: .bold))
                        if fixture.date > Date() {
                            Button {
                                reminders.toggle(fixture: fixture)
                            } label: {
                                CardButtonLabel(title: reminders.isSet(fixture: fixture)
                                                    ? String(localized: "Cancel reminder") : String(localized: "Remind me"),
                                                icon: reminders.isSet(fixture: fixture) ? "bell.slash" : "bell", compact: true)
                            }
                            .buttonStyle(PlainPressStyle())
                            .frame(width: 340)
                            .padding(.top, 8)
                        }
                    }
                }

                if fixture.isRace {
                    GlassPanel("Weekend schedule") {
                        ForEach(fixture.sessions, id: \.self) { session in
                            HStack {
                                Text(session.name)
                                Spacer()
                                Text(session.date.formatted(.dateTime.weekday(.abbreviated).day().month().hour().minute()))
                            }
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(Color.white.opacity(session.date < Date() ? 0.5 : 1))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                        }
                    }
                }

                watchPanel
                addonPanel
                if !matches.isEmpty && !searching {
                    SettingsNote([result.details, String(localized: "Hidden groups and channels are skipped.")]
                        .compactMap { $0 }.joined(separator: " "))
                }

                if !fixture.broadcasts.isEmpty {
                    Text("Listed broadcasters: \(fixture.broadcasts.joined(separator: ", "))")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 20)
                }
            }
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
        }
        .background(AppBackground())
        .task { search(force: false) }
        .task { await liveScores.run() }
        .task(id: guideSearchDone) { await searchAddons() }
        .fullScreenCover(item: $playback) { request in
            PlayerView(request: request).ignoresSafeArea()
        }
        .sheet(isPresented: $showingSportsChannels) {
            SportsChannelsSheet()
        }
    }

    private var progressText: String {
        guard let entry, entry.total > 0 else { return String(localized: "Searching your TV guide…") }
        return String(localized: "Checking channels… \(entry.checked) of \(entry.total)")
    }

    /// "Portugal – Denmark" (ESPN writes "Portugal v Denmark"), or "Portugal 2 – 1 Denmark" once started.
    private var displayTitle: String {
        if let score, let home = fixture.home?.name, let away = fixture.away?.name {
            return "\(home) \(score.line) \(away)"
        }
        return fixture.title.replacingOccurrences(of: " v ", with: " – ")
    }

    /// "Saturday, 14 November at 19:45".
    private var dateLine: String {
        String(localized: "\(fixture.guideTime.formatted(.dateTime.weekday(.wide).day().month(.wide))) at \(DayFormat.time(fixture.guideTime))")
    }

    /// Every channel showing the match, edge to edge with dividers, like NOWseen.
    private var watchPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("WATCH")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 28)
                .padding(.top, 18)
                .padding(.bottom, 10)
            if matches.isEmpty {
                guideSection
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
                        Button {
                            play(index)
                        } label: {
                            MatchRowLabel(match: match, line: programmeLine(match.programme),
                                          showsDivider: index < matches.count - 1)
                        }
                        .buttonStyle(PlainPressStyle())
                    }
                }
                .padding(.bottom, 6)
                if searching {
                    // More may still turn up while channels are being checked.
                    HStack(spacing: 14) {
                        ProgressView()
                        Text(progressText)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 16)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Theme.glass))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(.white.opacity(0.1), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
    }

    /// The game in the user's addons: listings of the game itself, or the channels showing it.
    @ViewBuilder
    private var addonPanel: some View {
        if addonsHaveLive {
            GlassPanel("From your addons") {
                if addonHits.isEmpty {
                    if addonSearching {
                        ProgressView(String(localized: "Searching your addons…"))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    } else {
                        note("Not found in your addons. Addons that list live games or channels are searched by the team names and the channels showing it.")
                    }
                }
                ForEach(addonHits.filter { $0.kind != .sportChannel }) { hit in
                    addonRow(hit)
                }
                let maybe = addonHits.filter { $0.kind == .sportChannel }
                if !maybe.isEmpty {
                    Text("CHANNELS FOR THIS SPORT · MAY BE SHOWING IT")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 18)
                        .padding(.top, 10)
                    ForEach(maybe) { hit in
                        addonRow(hit)
                    }
                }
            }
        }
    }

    private func addonRow(_ hit: AddonSportsHit) -> some View {
        Button {
            playAddon(hit)
        } label: {
            ListRowLabel(title: hit.title,
                         subtitle: [hit.stream.headline, hit.addonName].joined(separator: " · "),
                         icon: hit.kind == .game ? "sportscourt" : "tv",
                         trailing: String(localized: "Watch"))
        }
        .buttonStyle(PlainPressStyle())
    }

    private func searchAddons() async {
        let addons = unlockedAddons
        guard !addons.isEmpty else { return }
        addonsHaveLive = await AddonSports.hasLiveCatalogues(addons)
        guard addonsHaveLive else { return }
        addonSearching = true
        let done = guideSearchDone
        let channelNames = done ? matches.map(\.channel.providerName) : []
        let hits = await AddonSports.search(fixture, addons: addons, channelNames: channelNames)
        guard !Task.isCancelled else { return }
        addonHits = hits
        // Until the guide search ends, more channels (and so more addon results) may follow.
        addonSearching = !done
    }

    private func playAddon(_ hit: AddonSportsHit) {
        guard let url = hit.stream.playableURL else { return }
        playback = PlaybackRequest(url: url, title: displayTitle, sourceName: hit.addonName,
                                   isLive: true, httpHeaders: hit.stream.requestHeaders)
    }

    private func note(_ text: LocalizedStringResource) -> some View {
        Text(text)
            .font(.system(size: 24, weight: .medium))
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
    }

    @ViewBuilder
    private var guideSection: some View {
        if !settings.xtream.isConfigured {
            note("Add your IPTV login in Settings → Connections to find this in your TV guide.")
        } else if searching {
            ProgressView(progressText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
        } else {
            notFound
        }
    }

    /// Nothing found: either the guide doesn't reach the date yet, or nothing matched.
    private var notFound: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 20) {
                Image(systemName: "clock")
                    .font(.system(size: 36, weight: .semibold))
                    .opacity(0.85)
                VStack(alignment: .leading, spacing: 8) {
                    Text(notListedYet ? "Not in your TV guide yet" : "Not found in your TV guide")
                        .font(.system(size: 30, weight: .bold))
                    Text(notFoundDetail)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 16) {
                Button {
                    search(force: true)
                } label: {
                    PillLabel(title: String(localized: "Check again"), icon: "arrow.clockwise")
                }
                .buttonStyle(PlainPressStyle())
                Button {
                    showingSportsChannels = true
                } label: {
                    PillLabel(title: String(localized: "Open sports channels"), icon: "antenna.radiowaves.left.and.right")
                }
                .buttonStyle(PlainPressStyle())
            }
            .padding(.leading, 56)
            if let details = result.details {
                // What was searched, so a photo of this screen shows where it went wrong.
                Text(details)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 56)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var notFoundDetail: String {
        if notListedYet {
            let later = String(localized: "Channels showing this will appear here once it's listed — usually a day or two before.")
            guard let ends = result.guideEnds else { return later }
            let day = ends.formatted(.dateTime.weekday(.wide).day().month(.wide))
            return String(localized: "Your provider's guide reaches \(day).") + " " + later
        }
        return String(localized: "None of your channels list it at that time. Listings can be added late, so try again closer to the start.")
    }

    /// "Liga das Nações - Portugal x Dinamarca (Direto) · 19:45–21:45 · Olyviax".
    private func programmeLine(_ entry: XtreamEPGEntry) -> String {
        let times = [entry.start, entry.end].compactMap { $0 }.map(DayFormat.time).joined(separator: "–")
        return [entry.title, times, settings.xtream.displayName].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func search(force: Bool) {
        guard settings.xtream.isConfigured else { return }
        store.start(fixture, settings: settings, force: force)
    }

    private func play(_ index: Int) {
        let client = settings.xtreamClient
        let channels = matches.map(\.channel)
        let channel = channels[index]
        guard let url = client.liveURL(for: channel, format: settings.prefs.liveFormat) else { return }
        playback = PlaybackRequest(
            url: url,
            title: channel.name,
            artworkURL: channel.icon.flatMap { URL(string: $0) },
            sourceName: fixture.competition,
            isLive: true,
            httpHeaders: client.requestHeaders,
            live: LiveContext(channels: channels, index: index)
        )
    }
}

/// A channel showing the fixture: logo, name, the listing and "Tune in".
/// Rows run edge to edge inside the Watch panel, with a divider between them.
private struct MatchRowLabel: View {
    let match: ChannelMatch
    let line: String
    var showsDivider = true
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 22) {
            AsyncImage(url: match.channel.icon.flatMap { URL(string: $0) }) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                RoundedRectangle(cornerRadius: 6).fill(Theme.glassStrong)
            }
            .frame(width: 70, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(match.channel.name)
                    .font(.system(size: 27, weight: .semibold))
                    .lineLimit(1)
                Text(line)
                    .font(.system(size: 19, weight: .medium))
                    .opacity(0.75)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Text("Tune in")
                .font(.system(size: 22, weight: .semibold))
                .opacity(0.8)
        }
        .foregroundStyle(isFocused ? Theme.ink : Color.white)
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isFocused ? Color.white : Color.clear)
        .overlay(alignment: .bottom) {
            if showsDivider && !isFocused {
                Rectangle()
                    .fill(Color.white.opacity(0.14))
                    .frame(height: 1)
                    .padding(.horizontal, 28)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

/// Every channel that looks like a sports channel, to pick one by hand.
private struct SportsChannelsSheet: View {
    @EnvironmentObject var settings: AppSettings
    @State private var channels: [XtreamChannel] = []
    @State private var loading = true
    @State private var playback: PlaybackRequest?

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Sports channels")
                        .font(.system(size: 44, weight: .heavy))
                    if loading {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    } else if channels.isEmpty {
                        Text("No sports channels found in your groups.")
                            .foregroundStyle(.white.opacity(0.7))
                    } else {
                        GlassPanel {
                            ForEach(Array(channels.enumerated()), id: \.element.id) { index, channel in
                                Button {
                                    play(index)
                                } label: {
                                    ListRowLabel(title: channel.name,
                                                 logoURL: channel.icon.flatMap { URL(string: $0) },
                                                 showsLogo: true,
                                                 trailing: String(localized: "Tune in"))
                                }
                                .buttonStyle(PlainPressStyle())
                            }
                        }
                    }
                }
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            }
        }
        .task {
            let prefs = settings.prefs
            channels = await ChannelFinder.sportsChannels(client: settings.xtreamClient,
                                                          hiddenCategories: prefs.hiddenCategoryIDs,
                                                          hiddenChannels: prefs.hiddenChannelIDs)
            loading = false
        }
        .fullScreenCover(item: $playback) { request in
            PlayerView(request: request).ignoresSafeArea()
        }
    }

    private func play(_ index: Int) {
        let client = settings.xtreamClient
        let channel = channels[index]
        guard let url = client.liveURL(for: channel, format: settings.prefs.liveFormat) else { return }
        playback = PlaybackRequest(
            url: url,
            title: channel.name,
            artworkURL: channel.icon.flatMap { URL(string: $0) },
            sourceName: String(localized: "Sports"),
            isLive: true,
            httpHeaders: client.requestHeaders,
            live: LiveContext(channels: channels, index: index)
        )
    }
}

// MARK: - Choosing teams

/// Which sport the team search is narrowed to.
private enum SportFilter: String, CaseIterable, Identifiable {
    case all, football, f1, rugby, cricket, nfl, nba, nhl, mlb

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return String(localized: "All")
        case .football: return String(localized: "Football")
        case .f1: return String(localized: "Formula 1")
        case .rugby: return String(localized: "Rugby")
        case .cricket: return String(localized: "Cricket")
        case .nfl: return "NFL"
        case .nba: return "NBA"
        case .nhl: return "NHL"
        case .mlb: return "MLB"
        }
    }

    func includes(_ result: TeamSearchResult) -> Bool {
        switch self {
        case .all: return true
        case .football: return result.sport == "soccer"
        case .f1: return result.sport == "f1"
        case .rugby: return result.sport == "rugby" || result.sport == SuperLeagueClient.sport
        case .cricket: return result.sport == "cricket"
        case .nfl: return result.league == "nfl"
        case .nba: return result.league == "nba"
        case .nhl: return result.league == "nhl"
        case .mlb: return result.league == "mlb"
        }
    }
}

struct TeamsManagerView: View {
    @EnvironmentObject var settings: AppSettings

    @State private var query = ""
    @State private var results: [TeamSearchResult] = []
    @State private var searching = false
    @State private var filter: SportFilter = .all
    @State private var constructors: [F1Constructor] = []
    @State private var leagueNames: [String: String] = [:]
    @State private var removing: FavouriteTeam?

    private var trimmed: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var shownResults: [TeamSearchResult] {
        results.filter { filter.includes($0) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            ScrollView {
                VStack(spacing: 24) {
                    GlassPanel("Following · \(settings.prefs.favouriteTeams.count)") {
                        if settings.prefs.favouriteTeams.isEmpty {
                            Text("No teams yet. Search on the right to add some.")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))
                                .padding(.horizontal, 18)
                                .padding(.vertical, 12)
                        }
                        ForEach(settings.prefs.favouriteTeams) { team in
                            Button {
                                removing = team
                            } label: {
                                ListRowLabel(title: team.name,
                                             subtitle: team.leagueName,
                                             icon: team.isF1 ? "flag.checkered" : nil,
                                             logoURL: team.logo.flatMap { URL(string: $0) },
                                             showsLogo: !team.isF1)
                            }
                            .buttonStyle(PlainPressStyle())
                        }
                    }

                    GlassPanel("Browse by league") {
                        NavigationLink {
                            FootballLeaguesView()
                        } label: {
                            ListRowLabel(title: String(localized: "Football"), icon: "soccerball", trailingIcon: "chevron.right")
                        }
                        .buttonStyle(PlainPressStyle())
                        NavigationLink {
                            F1TeamsView()
                        } label: {
                            ListRowLabel(title: String(localized: "Formula 1"), icon: "flag.checkered", trailingIcon: "chevron.right")
                        }
                        .buttonStyle(PlainPressStyle())
                        NavigationLink {
                            LeagueListView(title: String(localized: "Rugby"),
                                           leagues: SportsCatalog.rugby + SportsCatalog.rugbyLeague)
                        } label: {
                            ListRowLabel(title: String(localized: "Rugby"), icon: "figure.rugby", trailingIcon: "chevron.right")
                        }
                        .buttonStyle(PlainPressStyle())
                        NavigationLink {
                            CricketLeaguesView()
                        } label: {
                            ListRowLabel(title: String(localized: "Cricket"), icon: "figure.cricket", trailingIcon: "chevron.right")
                        }
                        .buttonStyle(PlainPressStyle())
                        ForEach(SportsCatalog.us) { league in
                            NavigationLink {
                                TeamPickerView(league: league)
                            } label: {
                                ListRowLabel(title: league.name, icon: "sportscourt", trailingIcon: "chevron.right")
                            }
                            .buttonStyle(PlainPressStyle())
                        }
                    }
                }
                .padding(.vertical, 30)
            }
            .frame(width: 600)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    TextField("Search every team — e.g. Porto, McLaren, Bath", text: $query)
                        .autocorrectionDisabled()

                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(SportFilter.allCases) { option in
                                Button {
                                    filter = option
                                } label: {
                                    PillLabel(title: option.label, selected: option == filter)
                                }
                                .buttonStyle(PlainPressStyle())
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .focusRow()
                    .scrollClipDisabled()

                    GlassPanel("Results") {
                        if trimmed.count < 2 {
                            hint("Type at least two letters to search football (every league), Formula 1, rugby, cricket, NFL, NBA, NHL and MLB.")
                        } else if searching && results.isEmpty {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 20)
                        } else if shownResults.isEmpty {
                            hint("No teams found for “\(trimmed)”.")
                        }
                        ForEach(shownResults) { result in
                            let following = isFollowing(result)
                            Button {
                                toggle(result)
                            } label: {
                                ListRowLabel(title: result.name,
                                             subtitle: describe(result),
                                             icon: result.sport == "f1" ? "flag.checkered" : nil,
                                             logoURL: result.logo.flatMap { URL(string: $0) },
                                             showsLogo: result.sport != "f1",
                                             trailing: following ? String(localized: "Following") : nil,
                                             trailingIcon: following ? "checkmark" : "plus")
                            }
                            .buttonStyle(PlainPressStyle())
                        }
                    }
                }
                .padding(.vertical, 30)
            }
        }
        .padding(.horizontal, 90)
        .background(AppBackground())
        .task { await loadNames() }
        .task(id: trimmed) { await search() }
        .confirmationDialog("Stop following \(removing?.name ?? String(localized: "this team"))?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Stop following", role: .destructive) {
                if let removing {
                    settings.prefs.favouriteTeams.removeAll { $0.id == removing.id }
                }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        }
    }

    private func hint(_ text: LocalizedStringResource) -> some View {
        Text(text)
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
    }

    // MARK: Data

    private func loadNames() async {
        if let leagues = try? await ESPNClient().footballLeagues() {
            leagueNames = Dictionary(leagues.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first })
        }
        constructors = (try? await F1Client().constructors()) ?? []
    }

    private func search() async {
        let text = trimmed
        guard text.count >= 2 else {
            results = []
            searching = false
            return
        }
        searching = true
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }

        var found = (try? await ESPNClient().searchTeams(text)) ?? []
        let racing = constructors
            .filter { $0.name.localizedCaseInsensitiveContains(text) }
            .map { TeamSearchResult(sport: "f1", league: "f1", teamID: $0.id, name: $0.name, logo: nil, color: nil) }
        found = racing + found

        guard !Task.isCancelled, text == trimmed else { return }
        results = found
        searching = false
    }

    private func leagueName(_ result: TeamSearchResult) -> String {
        switch result.sport {
        case "f1":
            return String(localized: "Formula 1")
        case "soccer":
            return leagueNames[result.league] ?? String(localized: "Football")
        case "rugby":
            return SportsCatalog.rugby.first { $0.slug == result.league }?.name ?? String(localized: "Rugby")
        case "cricket":
            return String(localized: "Cricket")
        default:
            return result.league.uppercased()
        }
    }

    private func describe(_ result: TeamSearchResult) -> String {
        let sport: String
        switch result.sport {
        case "f1": return String(localized: "Formula 1")
        case "soccer": sport = String(localized: "Football")
        case "rugby": sport = String(localized: "Rugby")
        case "cricket": sport = String(localized: "Cricket")
        case "football": sport = String(localized: "American football")
        case "basketball": sport = String(localized: "Basketball")
        case "hockey": sport = String(localized: "Ice hockey")
        case "baseball": sport = String(localized: "Baseball")
        default: sport = result.sport.capitalized
        }
        let league = leagueName(result)
        return league == sport ? sport : "\(sport) · \(league)"
    }

    private func isFollowing(_ result: TeamSearchResult) -> Bool {
        settings.prefs.favouriteTeams.contains { $0.sport == result.sport && $0.teamID == result.teamID }
    }

    private func toggle(_ result: TeamSearchResult) {
        if isFollowing(result) {
            settings.prefs.favouriteTeams.removeAll { $0.sport == result.sport && $0.teamID == result.teamID }
        } else {
            settings.prefs.favouriteTeams.append(FavouriteTeam(
                sport: result.sport, league: result.league, leagueName: leagueName(result),
                teamID: result.teamID, name: result.name, logo: result.logo, color: result.color
            ))
        }
    }
}

private struct TeamRow: View {
    let name: String
    let detail: String?
    let logo: String?
    let isFavourite: Bool

    var body: some View {
        HStack(spacing: 20) {
            AsyncImage(url: logo.flatMap { URL(string: $0) }) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                Image(systemName: "shield").foregroundStyle(.secondary)
            }
            .frame(width: 50, height: 50)
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: isFavourite ? "star.fill" : "star")
                .foregroundStyle(isFavourite ? Color.yellow : Color.secondary)
        }
    }
}

private struct FootballLeaguesView: View {
    @State private var leagues: [SportLeague] = []
    @State private var error: String?

    var body: some View {
        Group {
            if let error {
                Text(error).foregroundStyle(.secondary)
            } else if leagues.isEmpty {
                ProgressView()
            } else {
                LeagueListView(title: String(localized: "Football"), leagues: leagues)
            }
        }
        .task {
            do {
                leagues = try await ESPNClient().footballLeagues()
                if leagues.isEmpty { error = String(localized: "No leagues found.") }
            } catch {
                self.error = String(localized: "Couldn't load leagues: \(error.localizedDescription)")
            }
        }
    }
}

/// International sides, then the competitions with cricket in the next 30 days.
private struct CricketLeaguesView: View {
    @State private var leagues: [SportLeague] = []

    var body: some View {
        Group {
            if leagues.isEmpty {
                ProgressView()
            } else {
                LeagueListView(title: String(localized: "Cricket"), leagues: leagues)
            }
        }
        .task { leagues = await CricketClient().leagues() }
    }
}

private struct LeagueListView: View {
    let title: String
    let leagues: [SportLeague]

    var body: some View {
        List(leagues) { league in
            NavigationLink(league.name) {
                TeamPickerView(league: league)
            }
        }
        .navigationTitle(title)
    }
}

private struct TeamPickerView: View {
    @EnvironmentObject var settings: AppSettings
    let league: SportLeague
    @State private var teams: [ESPNTeam] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            if loading {
                ProgressView()
            } else if let error {
                Text(error).foregroundStyle(.secondary)
            } else if teams.isEmpty {
                Text("No teams listed for this competition right now.").foregroundStyle(.secondary)
            }
            ForEach(teams, id: \.id) { team in
                let favourite = isFavourite(team)
                Button {
                    toggle(team)
                } label: {
                    TeamRow(name: team.displayName, detail: nil, logo: team.logoURL, isFavourite: favourite)
                }
            }
        }
        .navigationTitle(league.name)
        .task {
            do {
                teams = try await ESPNClient().teams(in: league)
            } catch {
                self.error = String(localized: "Couldn't load teams: \(error.localizedDescription)")
            }
            loading = false
        }
    }

    private func favouriteID(_ team: ESPNTeam) -> String {
        "\(league.sport)/\(league.slug)/\(team.id)"
    }

    private func isFavourite(_ team: ESPNTeam) -> Bool {
        settings.prefs.favouriteTeams.contains { $0.id == favouriteID(team) }
    }

    private func toggle(_ team: ESPNTeam) {
        if isFavourite(team) {
            settings.prefs.favouriteTeams.removeAll { $0.id == favouriteID(team) }
        } else {
            settings.prefs.favouriteTeams.append(FavouriteTeam(
                sport: league.sport, league: league.slug, leagueName: league.name,
                teamID: team.id, name: team.displayName, logo: team.logoURL, color: team.color
            ))
        }
    }
}

private struct F1TeamsView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var constructors: [F1Constructor] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            Section {
                if loading {
                    ProgressView()
                } else if let error {
                    Text(error).foregroundStyle(.secondary)
                }
                ForEach(constructors) { constructor in
                    let favourite = isFavourite(constructor)
                    Button {
                        toggle(constructor)
                    } label: {
                        TeamRow(name: constructor.name, detail: nil, logo: nil, isFavourite: favourite)
                    }
                }
            } footer: {
                Text("Following any team shows each race weekend in Sports.")
            }
        }
        .navigationTitle("Formula 1")
        .task {
            do {
                constructors = try await F1Client().constructors()
            } catch {
                self.error = String(localized: "Couldn't load teams: \(error.localizedDescription)")
            }
            loading = false
        }
    }

    private func isFavourite(_ constructor: F1Constructor) -> Bool {
        settings.prefs.favouriteTeams.contains { $0.isF1 && $0.teamID == constructor.id }
    }

    private func toggle(_ constructor: F1Constructor) {
        if isFavourite(constructor) {
            settings.prefs.favouriteTeams.removeAll { $0.isF1 && $0.teamID == constructor.id }
        } else {
            settings.prefs.favouriteTeams.append(FavouriteTeam(
                sport: "f1", league: "f1", leagueName: "Formula 1",
                teamID: constructor.id, name: constructor.name, logo: nil
            ))
        }
    }
}


// MARK: - Tables

/// League tables for the user's teams, one tab per league, plus F1 championships.
struct LeagueTablesSection: View {
    let teams: [FavouriteTeam]
    @State private var tabs: [StandingTab] = []
    @State private var selectedID: String?
    @State private var loading = true

    private var selected: StandingTab? { tabs.first { $0.id == selectedID } ?? tabs.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Tables")
                .font(.title3).bold()
                .padding(.horizontal, 90)

            if tabs.isEmpty {
                Text(loading ? "Loading tables…" : "No tables for your teams' leagues.")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 90)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 16) {
                        ForEach(tabs) { tab in
                            Button {
                                selectedID = tab.id
                            } label: {
                                PillLabel(title: tab.title, selected: tab.id == (selected?.id))
                            }
                            .buttonStyle(PlainPressStyle())
                        }
                    }
                    .padding(.horizontal, 90)
                    .padding(.vertical, 16)
                }
                .scrollClipDisabled()
                .focusSection()

                if let selected {
                    VStack(alignment: .leading, spacing: 30) {
                        ForEach(selected.tables) { table in
                            StandingTableView(table: table, showsTitle: selected.tables.count > 1)
                        }
                    }
                    .padding(.horizontal, 90)
                    .focusSection()
                }
            }
        }
        .padding(.top, 10)
        .task(id: teams.map(\.id)) {
            loading = true
            tabs = await StandingsClient().tabs(for: teams)
            loading = false
        }
    }
}

private struct StandingTableView: View {
    let table: StandingTable
    let showsTitle: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsTitle {
                Text(table.title.uppercased())
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 4)
            }
            header
            ForEach(table.rows) { row in
                // Rows take focus so the remote can scroll through the whole table.
                Button {} label: {
                    StandingRowLabel(row: row, football: table.showsPlayedAndDifference)
                }
                .buttonStyle(RowFocusStyle())
            }
        }
        .padding(20)
        .frame(maxWidth: 1200, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Theme.glass))
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("#").frame(width: 60, alignment: .leading)
            Text(table.showsPlayedAndDifference ? "TEAM" : "NAME").frame(maxWidth: .infinity, alignment: .leading)
            if table.showsPlayedAndDifference {
                Text("P").frame(width: 90, alignment: .trailing)
                Text("GD").frame(width: 100, alignment: .trailing)
            } else {
                Text("WINS").frame(width: 120, alignment: .trailing)
            }
            Text("PTS").frame(width: 100, alignment: .trailing)
        }
        .font(.system(size: 18, weight: .bold))
        .foregroundStyle(.white.opacity(0.55))
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }
}

private struct StandingRowLabel: View {
    let row: StandingRow
    let football: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 0) {
            Text("\(row.rank)").frame(width: 60, alignment: .leading)
            HStack(spacing: 14) {
                if let logo = row.logo, let url = URL(string: logo) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Color.clear
                    }
                    .frame(width: 34, height: 34)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name).lineLimit(1)
                    if let detail = row.detail {
                        Text(detail).font(.system(size: 17)).opacity(0.65).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if football {
                Text(row.played ?? "—").opacity(0.75).frame(width: 90, alignment: .trailing)
                Text(row.difference ?? "—").opacity(0.75).frame(width: 100, alignment: .trailing)
            } else {
                Text((row.played ?? "—").replacingOccurrences(of: " wins", with: ""))
                    .opacity(0.75).frame(width: 120, alignment: .trailing)
            }
            Text(row.points).frame(width: 100, alignment: .trailing)
        }
        .font(.system(size: 23, weight: row.isFollowed ? .heavy : .semibold))
        .foregroundStyle(isFocused ? Theme.ink : Color.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(isFocused ? Color.white : (row.isFollowed ? Color.white.opacity(0.22) : Color.clear)))
    }
}

/// Focus shows on the row itself (white), without the system lift.
private struct RowFocusStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
