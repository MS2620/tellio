import SwiftUI
import Combine
import AVFoundation
import MediaPlayer
import AetherEngine

/// The channel list a live stream was started from, so the player can zap.
struct LiveContext {
    var channels: [XtreamChannel]
    var index: Int
    var channel: XtreamChannel { channels[index] }
}

struct PlaybackRequest: Identifiable {
    let id = UUID()
    var url: URL
    var title: String?
    /// Episode line for VOD (e.g. "S1E2 · Pilot").
    var subtitle: String? = nil
    var overview: String? = nil
    /// Channel logo for live TV.
    var artworkURL: URL? = nil
    /// Addon name for VOD, category for live; shown as a badge.
    var sourceName: String? = nil
    var isLive: Bool = false
    var httpHeaders: [String: String] = [:]
    var live: LiveContext? = nil
    /// Movie or episode being watched: saves progress, offers to resume, finds addon subtitles.
    var watch: WatchContext? = nil
}

/// Full-screen player for live TV, movies and series, built on AetherEngine.
///
/// Siri Remote, controls hidden:
///   click             → show controls
///   play/pause        → pause / resume
///   left / right      → skip back / forward (when the stream can seek)
///   up / down         → previous / next channel (live) or show controls
///   Back              → close the player
/// Controls shown: swipe between the buttons; Back hides them.
struct PlayerView: View {
    let request: PlaybackRequest
    @EnvironmentObject private var player: PlayerEngineHolder

    var body: some View {
        if let engine = player.engine {
            AetherPlaybackView(engine: engine, request: request)
                .onAppear { player.isPresentingPlayer = true }
                .onDisappear { player.isPresentingPlayer = false }
        } else {
            ZStack {
                Color.black.ignoresSafeArea()
                Text("Player failed to start: \(player.initError ?? String(localized: "unknown error"))")
            }
        }
    }
}

private enum OverlayMode { case hidden, info, controls }

private enum Panel: Identifiable {
    case channels, subtitles, audio, stats, more
    var id: Self { self }

    var title: String {
        switch self {
        case .channels: return String(localized: "Channels")
        case .subtitles: return String(localized: "Subtitles")
        case .audio: return String(localized: "Audio")
        case .stats: return String(localized: "Playback stats")
        case .more: return String(localized: "More")
        }
    }
}

private enum Control: Hashable { case aspect, favourite, channels, lastChannel, subtitles, audio, stats, more, progress }

/// A pill under the title: plain, or the upscaling badge.
private enum Badge: Hashable {
    case plain(String)
    case upscaling(String)
}

private struct PanelOption: Identifiable {
    let id: String
    let title: String
    var detail: String? = nil
    var selected = false
    /// A section heading in the list, not a choice.
    var isHeader = false
    let action: () -> Void
}

private struct AetherPlaybackView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var engine: AetherEngine
    @ObservedObject private var clock: PlaybackClock
    @ObservedObject private var upscaleLog = UpscaleLog.shared
    @State private var current: PlaybackRequest
    /// Whether this load asked the engine to upscale, and with which scaler.
    @State private var upscaleRequested = false
    @State private var requestedScaler: UpscaleScaler = .automatic

    @Environment(\.dismiss) private var dismiss
    @State private var mode: OverlayMode = .controls
    @State private var panel: Panel?
    @State private var hideTask: Task<Void, Never>?
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var loadError: String?
    @State private var epg: [XtreamEPGEntry] = []
    @State private var fillScreen = false
    @State private var rate: Float = 1
    @FocusState private var focusedControl: Control?
    @FocusState private var focusedOption: String?
    @FocusState private var rootFocused: Bool
    @FocusState private var statsFocused: Bool
    @FocusState private var resumeFocused: ResumeChoice?

    // Resume and progress.
    @State private var resumeOffer: Double?
    /// The channel before this one in the list, for "Last channel".
    @State private var previousChannelIndex: Int?
    @State private var loadRequest: LoadRequest?
    // Subtitles from the user's addons; nil until the panel first asks.
    @State private var addonSubtitles: [AddonSubtitle]?
    @State private var activeAddonSubtitle: String?

    // Live retune guard (see AetherEngine's Examples/LiveHost).
    @State private var retuneInFlight = false
    @State private var retuneCount = 0
    @State private var lastRetuneAt: Date?
    private static let retuneSpacing: TimeInterval = 20
    private static let retuneBudget = 3

    init(engine: AetherEngine, request: PlaybackRequest) {
        self.engine = engine
        self._clock = ObservedObject(wrappedValue: engine.clock)
        self._current = State(initialValue: request)
    }

    // MARK: - Derived state

    private var errorMessage: String? {
        if case .error(let message) = engine.state { return message }
        return loadError
    }

    private var isPaused: Bool { engine.state == .paused }
    private var prefs: Preferences { settings.prefs }

    private var epgNow: XtreamEPGEntry? {
        let now = Date()
        return epg.first { ($0.start ?? .distantFuture) <= now && now < ($0.end ?? .distantPast) }
    }

    private var epgNext: XtreamEPGEntry? {
        guard let end = epgNow?.end else { return nil }
        return epg.first { ($0.start ?? .distantPast) >= end }
    }

    private var programmeTitle: String? {
        current.live != nil ? epgNow?.title : current.subtitle
    }

    private var programmeDescription: String? {
        current.live != nil ? epgNow?.description : current.overview
    }

    private var isFavourite: Bool {
        guard let id = current.live?.channel.id else { return false }
        return prefs.favouriteChannelIDs.contains(id)
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            AetherPlayerSurface(engine: engine)
                .ignoresSafeArea()

            SubtitleOverlay(cues: engine.subtitleCues, time: clock.sourceTime,
                            fontSize: prefs.subtitleSize.points)
                .ignoresSafeArea()

            // Catches the remote while the buttons are hidden. It is a sibling of the
            // controls (not their parent), so it never steals focus navigation from them.
            if mode != .controls && panel == nil && resumeOffer == nil {
                Color.clear
                    .contentShape(Rectangle())
                    .focusable()
                    .focused($rootFocused)
                    .focusEffectDisabled()
                    .onTapGesture { showControls() }
                    .onMoveCommand { direction in handleMove(direction) }
                    .onAppear { rootFocused = true }
                    .ignoresSafeArea()
            }

            if resumeOffer == nil && errorMessage == nil && (!engine.hasFirstFrameReadyForDisplay || engine.isBuffering) {
                ProgressView().scaleEffect(1.5)
            }

            if let errorMessage {
                errorBox(errorMessage)
            }

            if mode != .hidden && panel == nil && resumeOffer == nil {
                overlay.transition(.opacity)
            }

            if let resumeOffer {
                resumeCard(resumeOffer)
            }

            if let panel {
                panelView(panel).transition(.move(edge: .trailing))
            }

            ReminderBanner { reminder in
                watchReminder(reminder)
            }

            if let toast {
                VStack {
                    Text(toast)
                        .font(.headline)
                        .padding(.horizontal, 30).padding(.vertical, 16)
                        .background(.black.opacity(0.75), in: Capsule())
                        .padding(.top, 60)
                    Spacer()
                }
                .transition(.opacity)
            }
        }
        .onPlayPauseCommand { togglePause() }
        .onExitCommand { handleExit() }
        .task(id: current.id) { prepare() }
        .task(id: loadRequest) {
            guard let loadRequest else { return }
            await load(start: loadRequest.start)
        }
        .task(id: loadRequest) { await progressLoop() }
        .task(id: current.live?.channel.id) { await epgLoop() }
        .onAppear { showControls() }
        .onDisappear {
            hideTask?.cancel()
            toastTask?.cancel()
            saveProgress()
            scrobble("stop")
            engine.stop()
        }
        .onChange(of: engine.state) { old, state in
            // Trakt's "Watching now": paused and resumed as the player is.
            if state == .paused { scrobble("pause") }
            if state == .playing && (old == .paused || old == .loading || old == .idle) { scrobble("start") }
            if state == .ended {
                if let watch = current.watch { WatchHistory.shared.setWatched(true, context: watch) }
                dismiss()
            }
        }
        .onChange(of: focusedControl) { _, _ in scheduleHide() }
        .onReceive(engine.liveSourceReset.receive(on: DispatchQueue.main)) { _ in
            handleLiveSourceReset()
        }
    }

    // MARK: - Overlay

    private var overlay: some View {
        ZStack {
            VStack {
                LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 220)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.92)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 620)
            }

            VStack {
                HStack {
                    Spacer()
                    TimelineView(.everyMinute) { context in
                        Text(context.date.formatted(date: .omitted, time: .shortened))
                            .font(.title3).bold().monospacedDigit()
                    }
                }
                Spacer()
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .bottom, spacing: 40) {
                        infoColumn
                        Spacer(minLength: 0)
                        if mode == .controls { controlsPill }
                    }
                    progressSection
                }
            }
            .padding(.horizontal, 90)
            .padding(.top, 50)
            .padding(.bottom, 55)
        }
        .ignoresSafeArea()
    }

    private var infoColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 18) {
                if let artwork = current.artworkURL {
                    AsyncImage(url: artwork) { image in
                        image.resizable().aspectRatio(contentMode: .fit)
                    } placeholder: {
                        Color.clear
                    }
                    .frame(width: 110, height: 56)
                }
                Text(current.title ?? "").font(.title2).bold().lineLimit(1)
                if isPaused {
                    Image(systemName: "pause.fill").font(.title3)
                }
            }

            HStack(spacing: 10) {
                ForEach(badges, id: \.self) { badge in
                    switch badge {
                    case .plain(let text):
                        Text(text)
                            .font(.system(size: 18, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(.white.opacity(0.18), in: Capsule())
                    case .upscaling(let text):
                        Label(text, systemImage: "sparkles")
                            .labelStyle(BadgeLabelStyle())
                            .font(.system(size: 18, weight: .bold))
                            .padding(.horizontal, 14).padding(.vertical, 5)
                            .background(Self.upscaleGradient, in: Capsule())
                    }
                }
            }

            if let title = programmeTitle, !title.isEmpty {
                Text(title).font(.headline).lineLimit(1)
            }
            if let description = programmeDescription, !description.isEmpty {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: 1100, alignment: .leading)
    }

    @ViewBuilder
    private var progressSection: some View {
        if current.live != nil {
            if let now = epgNow, let start = now.start, let end = now.end, end > start {
                let playhead = Date().addingTimeInterval(-clock.behindLiveSeconds)
                let fraction = playhead.timeIntervalSince(start) / end.timeIntervalSince(start)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(Self.time(start))
                        Spacer()
                        Text(Self.time(end))
                    }
                    .font(.caption).monospacedDigit()
                    scrubbableBar(fraction: fraction)
                    ZStack(alignment: .trailing) {
                        PositionMarker(fraction: fraction, label: Self.time(playhead), live: clock.behindLiveSeconds < 5)
                        if let next = epgNext, let nextStart = next.start {
                            Text("\(Self.time(nextStart))  \(next.title)")
                                .font(.callout).bold().lineLimit(1)
                                .frame(maxWidth: 520, alignment: .trailing)
                        }
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Circle().fill(.red).frame(width: 14, height: 14)
                    Text("LIVE").font(.caption).bold()
                }
            }
        } else if engine.duration > 0 {
            let fraction = clock.currentTime / engine.duration
            VStack(alignment: .leading, spacing: 8) {
                scrubbableBar(fraction: fraction)
                ZStack(alignment: .trailing) {
                    PositionMarker(fraction: fraction, label: Self.duration(clock.currentTime), live: false)
                    Text("-" + Self.duration(max(engine.duration - clock.currentTime, 0)))
                        .font(.callout).monospacedDigit()
                }
            }
        }
    }

    /// The progress bar. With the buttons shown, press down to focus it, then
    /// left / right to rewind / fast-forward; up returns to the buttons.
    private func scrubbableBar(fraction: Double) -> some View {
        ProgressBar(fraction: fraction, highlighted: focusedControl == .progress)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .focusable(mode == .controls)
            .focused($focusedControl, equals: .progress)
            .focusEffectDisabled()
            .onMoveCommand { direction in
                switch direction {
                case .left: seek(by: -Double(prefs.seekBackSeconds))
                case .right: seek(by: Double(prefs.seekForwardSeconds))
                case .up: focusedControl = .aspect
                default: break
                }
                scheduleHide()
            }
    }

    private var controlsPill: some View {
        HStack(spacing: 12) {
            controlButton(fillScreen ? "arrow.down.right.and.arrow.up.left" : "aspectratio", .aspect) {
                toggleAspect()
            }
            if current.live != nil {
                controlButton(isFavourite ? "heart.fill" : "heart", .favourite) { toggleFavourite() }
                controlButton("square.grid.2x2", .channels) { open(.channels) }
            }
            if current.isLive && previousChannelIndex != nil {
                controlButton("arrow.uturn.backward", .lastChannel) { lastChannel() }
            }
            controlButton("captions.bubble", .subtitles) { open(.subtitles) }
            controlButton("waveform", .audio) { open(.audio) }
            controlButton("chart.bar", .stats) { open(.stats) }
            controlButton("ellipsis", .more) { open(.more) }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func controlButton(_ icon: String, _ control: Control, action: @escaping () -> Void) -> some View {
        Button {
            action()
            scheduleHide()
        } label: {
            PillIcon(systemName: icon)
        }
        .buttonStyle(BareButtonStyle())
        .focused($focusedControl, equals: control)
    }

    private func errorBox(_ message: String) -> some View {
        VStack(spacing: 16) {
            Text("Playback failed").font(.title2).bold()
            Text(message).multilineTextAlignment(.center)
            Text(current.live != nil ? "Press up or down to try another channel, or Back to return"
                                     : "Press Back to return")
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: 1200)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 24))
    }

    // MARK: - Badges

    private var badges: [Badge] {
        var list: [Badge] = [.plain("AetherEngine")]
        if let source = current.sourceName, !source.isEmpty { list.append(.plain(source)) }
        if let resolution = resolutionLabel { list.append(.plain(resolution)) }
        if let upscale = upscaleBadge { list.append(upscale) }
        list.append(.plain(Self.formatLabel(engine.videoFormat)))
        if let fps = frameRateLabel { list.append(.plain(fps)) }
        if let audio = audioLabel { list.append(.plain(audio)) }
        return list
    }

    private var frameRateLabel: String? {
        guard let fps = engine.sourceVideoFrameRate, fps > 0 else { return nil }
        return abs(fps - fps.rounded()) < 0.01 ? String(localized: "\(Int(fps.rounded())) fps") : String(format: "%.2f fps", fps)
    }

    private var resolutionLabel: String? {
        // While upscaling, the picture on screen is the target size; the badge names the source.
        if let upscale = engine.activeUpscale { return Self.sizeLabel(upscale.sourceSize) }
        let size = engine.currentAVPlayerItem?.presentationSize ?? engine.softwareDisplaySize ?? .zero
        return Self.sizeLabel(size)
    }

    /// "Upscaling 720p → 4K" while the stage runs; a plain pill when it was asked for but isn't running.
    private var upscaleBadge: Badge? {
        if let upscale = engine.activeUpscale, upscale.disabledReason == nil {
            let from = Self.sizeLabel(upscale.sourceSize) ?? String(localized: "Video")
            let to = Self.sizeLabel(upscale.targetSize) ?? String(localized: "screen")
            return .upscaling(String(localized: "Upscaling \(from) → \(to)"))
        }
        guard upscaleRequested else { return nil }
        if engine.activeUpscale?.disabledReason != nil { return .plain(String(localized: "Upscaling stopped")) }
        if upscaleLog.skipReason != nil { return .plain(String(localized: "Not upscaled")) }
        return nil
    }

    static func sizeLabel(_ size: CGSize) -> String? {
        let width = max(size.width, size.height * 16 / 9)
        switch width {
        case 3000...: return "4K"
        case 1800..<3000: return "1080p"
        case 1200..<1800: return "720p"
        case 1..<1200: return size.height > 0 ? "\(Int(size.height))p" : "SD"
        default: return nil
        }
    }

    static let upscaleGradient = LinearGradient(
        colors: [Color(red: 0x7b / 255, green: 0x3b / 255, blue: 1), Color(red: 1, green: 0x3d / 255, blue: 0x7f / 255)],
        startPoint: .leading, endPoint: .trailing)

    private var audioLabel: String? {
        let tracks = engine.audioTracks
        guard let track = tracks.first(where: { $0.id == engine.activeAudioTrackIndex }) ?? tracks.first else { return nil }
        return Self.audioDescription(track)
    }

    // MARK: - Panels

    @ViewBuilder
    private func panelView(_ panel: Panel) -> some View {
        if panel == .stats {
            statsPanel
        } else {
            optionsPanel(panel)
        }
    }

    private func optionsPanel(_ panel: Panel) -> some View {
        let options = panelOptions(panel)
        return HStack {
            Spacer()
            VStack(alignment: .leading, spacing: 24) {
                Text(panel.title).font(.title3).bold()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(options) { option in
                                if option.isHeader {
                                    Text(option.title)
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.6))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 8)
                                        .padding(.top, 14)
                                        .id(option.id)
                                } else {
                                    Button {
                                        option.action()
                                    } label: {
                                        PanelRow(option: option)
                                    }
                                    .buttonStyle(BareButtonStyle())
                                    .focused($focusedOption, equals: option.id)
                                    .id(option.id)
                                }
                            }
                        }
                        .padding(.vertical, 10)
                    }
                    .onAppear {
                        let target = options.first(where: \.selected)?.id ?? options.first(where: { !$0.isHeader })?.id
                        if let target {
                            proxy.scrollTo(target, anchor: .center)
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(80))
                                focusedOption = target
                            }
                        }
                    }
                }
            }
            .padding(50)
            .frame(width: 760)
            .frame(maxHeight: .infinity)
            .background(.ultraThinMaterial)
        }
        .ignoresSafeArea()
    }

    private func panelOptions(_ panel: Panel) -> [PanelOption] {
        switch panel {
        case .stats:
            return []
        case .subtitles:
            var options = [PanelOption(id: "off", title: String(localized: "Off"),
                                       selected: engine.activeSubtitleTrackIndex == nil && activeAddonSubtitle == nil) {
                engine.clearSubtitle()
                activeAddonSubtitle = nil
                closePanel()
            }]
            if !engine.subtitleTracks.isEmpty {
                options.append(PanelOption(id: "h-video", title: String(localized: "IN THIS VIDEO"), isHeader: true) {})
            }
            options += engine.subtitleTracks.map { track in
                PanelOption(id: "sub-\(track.id)", title: Self.trackTitle(track),
                            detail: track.isForced ? String(localized: "Forced") : (track.isHearingImpaired ? "SDH" : nil),
                            selected: activeAddonSubtitle == nil && track.id == engine.activeSubtitleTrackIndex) {
                    activeAddonSubtitle = nil
                    engine.selectSubtitleTrack(index: track.id)
                    closePanel()
                }
            }
            if current.watch != nil && !settings.addons.isEmpty {
                let subtitles = addonSubtitles ?? []
                let names = Array(Set(subtitles.map(\.addonName))).sorted()
                let heading = names.isEmpty ? String(localized: "FROM ADDONS") : String(localized: "FROM ADDONS · \(names.joined(separator: ", ").uppercased())")
                options.append(PanelOption(id: "h-addons", title: heading, isHeader: true) {})
                if addonSubtitles == nil {
                    options.append(PanelOption(id: "h-loading", title: String(localized: "Looking for subtitles…"), isHeader: true) {})
                } else if subtitles.isEmpty {
                    options.append(PanelOption(id: "h-none", title: String(localized: "None found. Add a subtitles addon such as OpenSubtitles v3 in Settings › Connections."), isHeader: true) {})
                }
                // Several files per language: number them so they can be told apart.
                var counts: [String: Int] = [:]
                for subtitle in subtitles {
                    counts[subtitle.languageName, default: 0] += 1
                    let number = counts[subtitle.languageName] ?? 1
                    options.append(PanelOption(id: "addon-\(subtitle.id)", title: subtitle.languageName,
                                               detail: "\(subtitle.addonName) · #\(number)",
                                               selected: activeAddonSubtitle == subtitle.id) {
                        activeAddonSubtitle = subtitle.id
                        engine.selectSidecarSubtitle(url: subtitle.url)
                        closePanel()
                    })
                }
            }
            return options

        case .audio:
            return engine.audioTracks.map { track in
                PanelOption(id: "audio-\(track.id)", title: Self.trackTitle(track),
                            detail: Self.audioDescription(track),
                            selected: track.id == engine.activeAudioTrackIndex) {
                    engine.selectAudioTrack(index: track.id)
                    closePanel()
                }
            }

        case .channels:
            guard let live = current.live else { return [] }
            return live.channels.enumerated().map { index, channel in
                PanelOption(id: "ch-\(channel.id)",
                            title: channel.number.map { "\($0)  \(channel.name)" } ?? channel.name,
                            detail: prefs.favouriteChannelIDs.contains(channel.id) ? "★" : nil,
                            selected: index == live.index) {
                    zap(to: index)
                    closePanel()
                }
            }

        case .more:
            if current.live != nil {
                var options: [PanelOption] = []
                if engine.canSeek {
                    options.append(PanelOption(id: "live-edge", title: String(localized: "Jump to live")) {
                        Task { await engine.seekToLiveEdge() }
                        closePanel()
                    })
                }
                options.append(PanelOption(id: "reload", title: String(localized: "Reload channel")) {
                    reload()
                    closePanel()
                })
                if let live = current.live, live.channels.indices.contains(live.index) {
                    let channel = live.channels[live.index]
                    options.append(PanelOption(id: "multiview", title: String(localized: "Watch in multiview")) {
                        closePanel()
                        // Opens once the player has closed.
                        MultiviewStore.shared.add(channel, openAfter: .milliseconds(600))
                        dismiss()
                    })
                }
                return options
            } else {
                var options = [PanelOption(id: "restart", title: String(localized: "Restart from the beginning")) {
                    Task { await engine.seek(to: 0) }
                    closePanel()
                }]
                for speed: Float in [0.75, 1, 1.25, 1.5, 2] {
                    options.append(PanelOption(id: "speed-\(speed)", title: String(localized: "Speed \(Self.speedLabel(speed))"),
                                               selected: speed == rate) {
                        rate = speed
                        engine.setRate(speed)
                        closePanel()
                    })
                }
                return options
            }
        }
    }

    // MARK: - Loading

    /// Before loading a started movie or episode, asks whether to resume.
    private func prepare() {
        rememberChannel()
        addonSubtitles = nil
        activeAddonSubtitle = nil
        if !current.isLive, let watch = current.watch,
           let entry = WatchHistory.shared.entry(for: watch), entry.isResumable {
            resumeOffer = entry.position
            loadRequest = nil
        } else {
            resumeOffer = nil
            loadRequest = LoadRequest(start: nil)
        }
    }

    private func chooseStart(_ start: Double?) {
        resumeOffer = nil
        loadRequest = LoadRequest(start: start)
        showControls()
    }

    /// Saves progress every 15 seconds while a movie or episode plays.
    private func progressLoop() async {
        guard current.watch != nil, !current.isLive else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            saveProgress()
        }
    }

    /// Tells Trakt about a movie or episode (Settings › Connections › Trakt › Scrobble).
    private func scrobble(_ action: String) {
        guard let watch = current.watch, !current.isLive, loadRequest != nil, engine.duration > 0 else { return }
        TraktSync.shared.scrobble(action, context: watch, progress: clock.currentTime / engine.duration * 100)
    }

    private func saveProgress() {
        guard let watch = current.watch, !current.isLive, loadRequest != nil,
              engine.duration > 0, engine.hasFirstFrameReadyForDisplay else { return }
        WatchHistory.shared.record(watch, position: clock.currentTime, duration: engine.duration)
    }

    /// Tells the Apple TV what's playing, so Home Assistant, the Control Centre and the
    /// iPhone remote see Tellio as playing video (with title, pause and play).
    private func publishNowPlaying() {
        engine.ownsVideoNowPlayingSession = true
        engine.ownsVideoNowPlayingCommands = true
        engine.ownsSoftwareNowPlaying = true
        engine.ownsAudioNowPlaying = true
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: current.title ?? "Tellio",
            MPNowPlayingInfoPropertyMediaType: NSNumber(value: MPNowPlayingInfoMediaType.video.rawValue),
            MPNowPlayingInfoPropertyIsLiveStream: NSNumber(value: current.isLive),
        ]
        if let line = current.subtitle ?? current.sourceName, !line.isEmpty {
            info[MPMediaItemPropertyArtist] = line
        }
        engine.setNowPlayingInfo(info)
    }

    private func load(start: Double? = nil) async {
        loadError = nil
        let prefs = settings.prefs
        var shaping = AudioShaping()
        if prefs.dialogueBoost { shaping.dialogueGainDB = 6 }
        if prefs.nightMode { shaping.compressor = .night }
        let subtitleLanguages = prefs.autoSubtitles ? [prefs.subtitleLanguage] : []

        let options: LoadOptions
        if current.isLive {
            let matchLive = prefs.matchContent && prefs.matchContentLive
            options = LoadOptions(
                // Without this the engine still sets the TV's refresh rate itself,
                // which blanks the screen for a moment on every channel.
                suppressDisplayCriteria: !matchLive,
                httpHeaders: current.httpHeaders,
                upscalesLowResolutionVideo: prefs.upscaleLowResolution,
                // Switching the TV's refresh rate blanks the screen for a moment on every
                // channel change, so live TV only does it when asked (Settings → Live TV).
                matchContentEnabled: prefs.matchContent && prefs.matchContentLive,
                isLive: true,
                dvrWindowSeconds: prefs.timeshiftMinutes > 0 ? Double(prefs.timeshiftMinutes * 60) : nil,
                liveJoinProfile: prefs.channelSwitching == .fast ? .fastZap : .standard,
                // The engine's own live pipeline rather than Apple's HLS player: Apple's
                // can play the sound but show no picture for some channels (HEVC or
                // interlaced broadcasts). The engine reads HLS addresses itself.
                nativeRemoteHLS: false,
                preferredAudioLanguages: [prefs.audioLanguage],
                preferredSubtitleLanguages: subtitleLanguages,
                audioShaping: shaping
            )
        } else {
            options = LoadOptions(
                httpHeaders: current.httpHeaders,
                upscalesLowResolutionVideo: prefs.upscaleLowResolution,
                matchContentEnabled: prefs.matchContent,
                preferredAudioLanguages: [prefs.audioLanguage],
                preferredSubtitleLanguages: subtitleLanguages,
                audioShaping: shaping
            )
        }
        upscaleRequested = options.upscalesLowResolutionVideo
        requestedScaler = options.upscaleScaler
        UpscaleLog.shared.reset()
        do {
            // The Live TV guide preview plays muted on the same engine.
            engine.volume = 1
            publishNowPlaying()
            _ = try await engine.load(url: current.url, startPosition: start, options: options)
            engine.videoGravity = fillScreen ? .resizeAspectFill : .resizeAspect
        } catch is CancellationError {
            // A newer load or a stop replaced this one; not a failure.
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func epgLoop() async {
        epg = []
        guard let channel = current.live?.channel, prefs.showEPG else { return }
        while !Task.isCancelled {
            if let entries = try? await settings.xtreamClient.shortEPG(streamID: channel.id, limit: 4) {
                epg = entries
            }
            try? await Task.sleep(for: .seconds(60))
        }
    }

    /// The engine asks for a fresh load when a live session can't be revived.
    private func handleLiveSourceReset() {
        guard current.isLive, !retuneInFlight else { return }
        let tooSoon = lastRetuneAt.map { Date().timeIntervalSince($0) < Self.retuneSpacing } ?? false
        guard retuneCount < Self.retuneBudget, !tooSoon else {
            loadError = String(localized: "This channel keeps failing. Try it again later.")
            return
        }
        retuneInFlight = true
        retuneCount += 1
        lastRetuneAt = Date()
        Task {
            await load()
            retuneInFlight = false
        }
    }

    // MARK: - Remote handling

    private func handleMove(_ direction: MoveCommandDirection) {
        switch direction {
        case .left: seek(by: -Double(prefs.seekBackSeconds))
        case .right: seek(by: Double(prefs.seekForwardSeconds))
        case .up: current.live != nil ? zap(by: -1) : showControls()
        case .down: current.live != nil ? zap(by: 1) : showControls()
        @unknown default: break
        }
    }

    private func handleExit() {
        if resumeOffer != nil {
            dismiss()
        } else if panel != nil {
            closePanel()
        } else if mode != .hidden {
            hide()
        } else {
            dismiss()
        }
    }

    private func showControls() {
        withAnimation(.easeOut(duration: 0.2)) { mode = .controls }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            if focusedControl == nil { focusedControl = .aspect }
        }
        scheduleHide()
    }

    /// Info only (no buttons), e.g. after a seek or channel change.
    private func showInfo() {
        if mode == .hidden { withAnimation(.easeOut(duration: 0.2)) { mode = .info } }
        scheduleHide(after: mode == .controls ? 6 : 4)
    }

    private func hide() {
        hideTask?.cancel()
        focusedControl = nil
        withAnimation(.easeIn(duration: 0.2)) { mode = .hidden }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            rootFocused = true
        }
    }

    private func scheduleHide(after seconds: Double = 6) {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, panel == nil, !isPaused else { return }
            hide()
        }
    }

    private func open(_ newPanel: Panel) {
        if newPanel == .subtitles { loadAddonSubtitles() }
        hideTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { panel = newPanel }
    }

    private func loadAddonSubtitles() {
        guard addonSubtitles == nil, let watch = current.watch, !settings.addons.isEmpty else { return }
        let addons = settings.addons
        let language = prefs.subtitleLanguage
        let requestID = current.id
        Task {
            let found = await StremioAddonClient.subtitles(from: addons, type: watch.stremioType,
                                                          id: watch.stremioID, preferredLanguage: language)
            guard current.id == requestID else { return }
            addonSubtitles = found
        }
    }

    private func closePanel() {
        withAnimation(.easeIn(duration: 0.2)) { panel = nil }
        showControls()
    }

    // MARK: - Actions

    private func togglePause() {
        engine.togglePlayPause()
        if mode == .hidden { showInfo() } else { scheduleHide() }
    }

    private func seek(by seconds: Double) {
        guard engine.canSeek else {
            showToast(engine.isLive ? String(localized: "Turn on timeshift in Settings → Live TV to rewind") : String(localized: "This stream can't seek"))
            return
        }
        let target = max(0, clock.currentTime + seconds)
        Task { await engine.seek(to: target) }
        showInfo()
    }

    /// "Watch now" on a reminder: the channel in the current list if it's there, otherwise on its own.
    private func watchReminder(_ reminder: ProgrammeReminder) {
        if let live = current.live, let index = live.channels.firstIndex(where: { $0.id == reminder.channelID }) {
            zap(to: index)
        } else if let request = PlaybackRequest.liveChannel(reminder.channel, settings: settings) {
            current = request
            showInfo()
        }
    }

    private func zap(by delta: Int) {
        guard let live = current.live, !live.channels.isEmpty else { return }
        let count = live.channels.count
        zap(to: ((live.index + delta) % count + count) % count)
    }

    /// "Last channel": back to the channel before this one, and again to return.
    private func lastChannel() {
        guard let live = current.live, let previous = previousChannelIndex,
              live.channels.indices.contains(previous) else { return }
        zap(to: previous)
    }

    /// Newest first, 20 at most, for Live TV › Recent.
    private func rememberChannel() {
        guard current.isLive, let live = current.live, live.channels.indices.contains(live.index) else { return }
        let id = live.channels[live.index].id
        var recent = settings.prefs.recentChannelIDs.filter { $0 != id }
        recent.insert(id, at: 0)
        settings.prefs.recentChannelIDs = Array(recent.prefix(20))
    }

    private func zap(to index: Int) {
        guard let live = current.live, live.channels.indices.contains(index) else { return }
        if index != live.index { previousChannelIndex = live.index }
        let channel = live.channels[index]
        guard let url = settings.xtreamClient.liveURL(for: channel, format: prefs.liveFormat) else { return }
        retuneCount = 0
        lastRetuneAt = nil
        current = PlaybackRequest(
            url: url,
            title: channel.name,
            artworkURL: channel.icon.flatMap { URL(string: $0) },
            sourceName: current.sourceName,
            isLive: true,
            httpHeaders: current.httpHeaders,
            live: LiveContext(channels: live.channels, index: index)
        )
        showInfo()
    }

    private func reload() {
        var copy = current
        copy = PlaybackRequest(url: copy.url, title: copy.title, subtitle: copy.subtitle, overview: copy.overview,
                               artworkURL: copy.artworkURL, sourceName: copy.sourceName, isLive: copy.isLive,
                               httpHeaders: copy.httpHeaders, live: copy.live, watch: copy.watch)
        retuneCount = 0
        current = copy
    }

    private func toggleAspect() {
        fillScreen.toggle()
        engine.videoGravity = fillScreen ? .resizeAspectFill : .resizeAspect
        showToast(fillScreen ? String(localized: "Fill screen") : String(localized: "Fit to screen"))
    }

    private func toggleFavourite() {
        guard let id = current.live?.channel.id else { return }
        if settings.prefs.favouriteChannelIDs.contains(id) {
            settings.prefs.favouriteChannelIDs.remove(id)
            showToast(String(localized: "Removed from Favourites"))
        } else {
            settings.prefs.favouriteChannelIDs.insert(id)
            showToast(String(localized: "Added to Favourites"))
        }
    }

    private func showToast(_ message: String) {
        withAnimation { toast = message }
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation { toast = nil }
        }
    }

    // MARK: - Formatting

    static func trackTitle(_ track: TrackInfo) -> String {
        if !track.name.isEmpty { return track.name }
        if let language = track.language, !language.isEmpty {
            return LanguageOptions.displayLocale.localizedString(forLanguageCode: language) ?? language.uppercased()
        }
        return String(localized: "Track \(String(describing: track.id))")
    }

    static func audioDescription(_ track: TrackInfo) -> String {
        if track.isAtmos { return "Dolby Atmos" }
        if track.isDTSX { return "DTS:X" }
        let codec: String
        switch track.codec.lowercased() {
        case "eac3": codec = "Dolby Digital+"
        case "ac3": codec = "Dolby Digital"
        case "truehd": codec = "Dolby TrueHD"
        case "dts": codec = "DTS"
        case "aac": codec = "AAC"
        case "flac": codec = "FLAC"
        case "opus": codec = "Opus"
        case "mp3", "mp2": codec = "MP3"
        default: codec = track.codec.uppercased()
        }
        switch track.channels {
        case 8: return "\(codec) 7.1"
        case 6: return "\(codec) 5.1"
        case 2: return String(localized: "\(codec) Stereo")
        case 1: return String(localized: "\(codec) Mono")
        default: return codec
        }
    }

    static func formatLabel(_ format: VideoFormat) -> String {
        switch format {
        case .sdr: return "SDR"
        case .hdr10: return "HDR10"
        case .hdr10Plus: return "HDR10+"
        case .dolbyVision: return "Dolby Vision"
        case .hlg: return "HLG"
        @unknown default: return String(localized: "Video")
        }
    }

    static func speedLabel(_ speed: Float) -> String {
        speed == 1 ? String(localized: "Normal") : "\(speed.formatted())×"
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Resume

private enum ResumeChoice: Hashable { case resume, restart }

private struct LoadRequest: Equatable {
    let id = UUID()
    let start: Double?
}

extension AetherPlaybackView {
    /// "Resume from 21:14" or "Start from the beginning", shown before a started title loads.
    func resumeCard(_ position: Double) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            Text((current.title ?? "") + (current.subtitle.map { " · " + $0 } ?? ""))
                .font(.system(size: 30, weight: .bold))
                .lineLimit(1)
            HStack(spacing: 18) {
                Button {
                    chooseStart(position)
                } label: {
                    ResumeButtonLabel(title: String(localized: "Resume from \(Self.duration(position))"))
                }
                .buttonStyle(BareButtonStyle())
                .focused($resumeFocused, equals: .resume)

                Button {
                    chooseStart(nil)
                } label: {
                    ResumeButtonLabel(title: String(localized: "Start from the beginning"))
                }
                .buttonStyle(BareButtonStyle())
                .focused($resumeFocused, equals: .restart)
            }
        }
        .padding(.horizontal, 44)
        .padding(.vertical, 36)
        .frame(width: 900, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 30, style: .continuous)
            .fill(Color(red: 30 / 255, green: 32 / 255, blue: 38 / 255).opacity(0.94)))
        .onAppear {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                resumeFocused = .resume
            }
        }
    }
}

private struct ResumeButtonLabel: View {
    let title: String
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Text(title)
            .font(.system(size: 26, weight: .bold))
            .foregroundStyle(isFocused ? Color.black : Color.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isFocused ? Color.white : Color.white.opacity(0.14)))
            .scaleEffect(isFocused ? 1.04 : 1)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

// MARK: - Playback stats

extension AetherPlaybackView {
    /// The side panel from the PlayerStats design: video, upscaling, audio and playback facts.
    var statsPanel: some View {
        HStack {
            Spacer()
            VStack(alignment: .leading, spacing: 26) {
                Text("Playback stats").font(.system(size: 32, weight: .heavy))

                StatsSection("Video") {
                    StatsRow("Source", sourceLine)
                    if let fps = frameRateLabel {
                        StatsRow("Frame rate", engine.sourceVideoScan.isInterlaced ? String(localized: "\(fps) · interlaced") : fps)
                    }
                    StatsRow("Picture", Self.formatLabel(engine.videoFormat))
                    if engine.sourceVideoBitrate > 0 {
                        StatsRow("Bitrate", String(format: "%.1f Mb/s", Double(engine.sourceVideoBitrate) / 1_000_000))
                    }
                }

                upscaleSection

                StatsSection("Audio") {
                    StatsRow("Track", audioTrackLine)
                    StatsRow("Delivery", Self.deliveryLabel(engine.audioDelivery))
                }

                StatsSection("Playback") {
                    StatsRow("Route", Self.routeLabel(engine.videoRoute, live: current.isLive))
                    if let decoder = engine.activeVideoDecoder { StatsRow("Decoder", decoder) }
                    if current.isLive {
                        StatsRow("Behind live", "\(Int(clock.behindLiveSeconds.rounded())) s")
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 50)
            .padding(.vertical, 60)
            .frame(width: 760, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(red: 30 / 255, green: 32 / 255, blue: 38 / 255).opacity(0.82))
            // Nothing in the panel is a button; this keeps focus here so Back closes it.
            .focusable()
            .focused($statsFocused)
            .focusEffectDisabled()
            .onAppear {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(80))
                    statsFocused = true
                }
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var upscaleSection: some View {
        if let upscale = engine.activeUpscale {
            let running = upscale.disabledReason == nil
            StatsSection(running ? "Upscaling · On" : "Upscaling · Stopped", highlighted: running) {
                StatsRow("From → to", "\(Self.pixels(upscale.sourceSize)) → \(Self.pixels(upscale.targetSize))")
                StatsRow("Method", Self.methodLabel(upscale))
                StatsRow("Status", upscaleStatus(upscale))
            }
        } else {
            StatsSection("Upscaling · Off") {
                StatsRow("Reason", upscaleOffReason)
            }
        }
    }

    private var upscaleOffReason: String {
        guard upscaleRequested else { return String(localized: "Turned off in Settings → Player") }
        if let reason = upscaleLog.skipReason { return reason }
        if upscaleLog.lastLine?.contains("taken:") == true { return String(localized: "Starting…") }
        return engine.hasFirstFrameReadyForDisplay ? String(localized: "The player didn't use the upscaler for this video") : String(localized: "Starting…")
    }

    private func upscaleStatus(_ upscale: UpscaleStatus) -> String {
        if let reason = upscale.disabledReason { return String(localized: "Stopped: \(String(describing: reason))") }
        if upscale.degraded { return String(localized: "Reduced to keep up (MetalFX off)") }
        if upscaleLog.fellBackFromLineArt { return String(localized: "Running (line art was too slow here)") }
        return String(localized: "Running at full quality")
    }

    private var sourceLine: String {
        let w = Int(engine.sourceVideoWidth), h = Int(engine.sourceVideoHeight)
        let size = w > 0 && h > 0 ? "\(w) × \(h)" : String(localized: "Unknown size")
        guard let codec = engine.sourceVideoCodecName else { return size }
        return "\(size) · \(Self.codecLabel(codec))"
    }

    private var audioTrackLine: String {
        let tracks = engine.audioTracks
        guard let track = tracks.first(where: { $0.id == engine.activeAudioTrackIndex }) ?? tracks.first else {
            return String(localized: "None")
        }
        let name = Self.trackTitle(track)
        let description = Self.audioDescription(track)
        return name == description ? name : "\(name) · \(description)"
    }

    static func pixels(_ size: CGSize) -> String {
        "\(Int(size.width)) × \(Int(size.height))"
    }

    static func methodLabel(_ upscale: UpscaleStatus) -> String {
        switch upscale.scaler {
        case .lineArt:
            let doubled = upscale.sourceSize.width * 2 == upscale.targetSize.width
                && upscale.sourceSize.height * 2 == upscale.targetSize.height
            return doubled ? String(localized: "Line art ×2 (Anime4K)") : String(localized: "Line art ×2 (Anime4K) + resize")
        case .automatic:
            guard !upscale.degraded, let ml = upscale.mlScale else {
                return upscale.mlScale.map { String(localized: "Super resolution ×\(Self.factor($0))") } ?? "MetalFX"
            }
            let fills = (upscale.sourceSize.width * CGFloat(ml)).rounded(.down) >= upscale.targetSize.width - 1
            return fills ? String(localized: "Super resolution ×\(Self.factor(ml))") : String(localized: "Super resolution ×\(Self.factor(ml)) + MetalFX")
        @unknown default:
            return String(localized: "Upscaler")
        }
    }

    static func factor(_ value: Float) -> String {
        value == value.rounded() ? "\(Int(value))" : String(format: "%g", value)
    }

    static func codecLabel(_ codec: String) -> String {
        switch codec.lowercased() {
        case "h264": return "H.264"
        case "hevc": return "HEVC"
        case "av1": return "AV1"
        case "vp9": return "VP9"
        case "mpeg2video": return "MPEG-2"
        case "vc1": return "VC-1"
        default: return codec.uppercased()
        }
    }

    static func deliveryLabel(_ delivery: AudioDelivery) -> String {
        switch delivery {
        case .none: return "—"
        case .noAudioInSource: return String(localized: "No sound in this video")
        case .streamCopy: return String(localized: "Passed through unchanged")
        case .bridged: return String(localized: "Converted for Apple TV")
        case .decoded: return String(localized: "Decoded on Apple TV")
        case .droppedNoPipeline: return String(localized: "Sound format not supported")
        case .playerManaged: return String(localized: "Apple's player")
        @unknown default: return "—"
        }
    }

    static func routeLabel(_ route: VideoRoute, live: Bool) -> String {
        switch route {
        case .none: return "—"
        case .remoteBypass: return String(localized: "Apple's player (direct)")
        case .loopback: return String(localized: "Apple's player via the engine")
        case .software: return live ? String(localized: "Engine live pipeline") : String(localized: "Engine software pipeline")
        case .audio: return String(localized: "Audio only")
        @unknown default: return "—"
        }
    }
}

private struct StatsSection<Content: View>: View {
    let title: String
    let highlighted: Bool
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringResource, highlighted: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = String(localized: title)
        self.highlighted = highlighted
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 18, weight: .bold))
                .tracking(1)
                .foregroundStyle(.white.opacity(highlighted ? 0.8 : 0.6))
            content
        }
        .padding(.horizontal, highlighted ? 20 : 0)
        .padding(.vertical, highlighted ? 18 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if highlighted {
                RoundedRectangle(cornerRadius: 18).fill(LinearGradient(
                    colors: [Color(red: 0x7b / 255, green: 0x3b / 255, blue: 1).opacity(0.35),
                             Color(red: 1, green: 0x3d / 255, blue: 0x7f / 255).opacity(0.25)],
                    startPoint: .leading, endPoint: .trailing))
            }
        }
    }
}

private struct StatsRow: View {
    let label: String
    let value: String

    init(_ label: LocalizedStringResource, _ value: String) {
        self.label = String(localized: label)
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(label).foregroundStyle(.white.opacity(0.75))
            Spacer(minLength: 0)
            Text(value).fontWeight(.semibold).multilineTextAlignment(.trailing)
        }
        .font(.system(size: 22))
    }
}

/// Icon and text a little closer than the default label spacing.
private struct BadgeLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            configuration.title
        }
    }
}

// MARK: - Small views

/// A button style with no system chrome; the label draws its own focus state.
private struct BareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct PillIcon: View {
    let systemName: String
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 28, weight: .semibold))
            .foregroundStyle(isFocused ? Color.black : Color.white)
            .frame(width: 76, height: 76)
            .background(Circle().fill(isFocused ? Color.white : Color.clear))
            .scaleEffect(isFocused ? 1.08 : 1)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

private struct PanelRow: View {
    let option: PanelOption
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(option.title).lineLimit(1)
                if let detail = option.detail {
                    Text(detail).font(.caption).opacity(0.7).lineLimit(1)
                }
            }
            Spacer()
            if option.selected {
                Image(systemName: "checkmark").font(.headline)
            }
        }
        .foregroundStyle(isFocused ? Color.black : Color.white)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(isFocused ? Color.white : Color.white.opacity(0.06)))
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

private struct ProgressBar: View {
    let fraction: Double
    var highlighted = false

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white)
                    .frame(width: geo.size.width * clamped)
                if highlighted {
                    Circle()
                        .fill(.white)
                        .frame(width: 26, height: 26)
                        .shadow(radius: 4)
                        .offset(x: geo.size.width * clamped - 13)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: highlighted ? 14 : 8)
        .animation(.easeOut(duration: 0.15), value: highlighted)
    }
}

/// "● 01:20" under the bar, at the playhead's position.
private struct PositionMarker: View {
    let fraction: Double
    let label: String
    let live: Bool

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 8) {
                if live { Circle().fill(.red).frame(width: 12, height: 12) }
                Text(label).font(.callout).bold().monospacedDigit()
            }
            .fixedSize()
            .position(x: min(max(geo.size.width * min(max(fraction, 0), 1), 70), geo.size.width - 70),
                      y: geo.size.height / 2)
        }
        .frame(height: 34)
    }
}
