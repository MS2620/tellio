import SwiftUI
import AetherEngine

/// The channels in multiview. Adding one opens multiview over the whole app.
@MainActor
final class MultiviewStore: ObservableObject {
    static let shared = MultiviewStore()
    static let maxChannels = 4

    @Published private(set) var channels: [XtreamChannel] = []
    @Published var presented = false

    func add(_ channel: XtreamChannel, openAfter delay: Duration = .zero) {
        if !channels.contains(where: { $0.id == channel.id }), channels.count < Self.maxChannels {
            channels.append(channel)
        }
        Task { @MainActor in
            if delay > .zero { try? await Task.sleep(for: delay) }
            presented = true
        }
    }

    func remove(_ id: Int) {
        channels.removeAll { $0.id == id }
        if channels.isEmpty { presented = false }
    }

    func close() {
        presented = false
        channels = []
    }
}

/// Two (up to four) live channels at once. Each has its own engine; the focused one is heard.
struct MultiviewView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: PlayerEngineHolder
    @ObservedObject private var store = MultiviewStore.shared

    @State private var engines: [Int: AetherEngine] = [:]
    @State private var audibleID: Int?
    @State private var expandedID: Int?
    @State private var picking = false
    @FocusState private var focusedTile: Int?

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 16), count: store.channels.count > 1 ? 2 : 1)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let expandedID, let channel = store.channels.first(where: { $0.id == expandedID }) {
                tile(channel, expanded: true)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 20) {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(store.channels) { channel in
                            tile(channel, expanded: false)
                                .aspectRatio(16 / 9, contentMode: .fit)
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .focusSection()
                    bottomBar
                }
                .padding(40)
            }
        }
        .onChange(of: focusedTile) { _, id in
            if let id { audibleID = id }
        }
        .onChange(of: audibleID) { _, _ in applyVolumes() }
        .task(id: store.channels.map(\.id)) { await syncEngines() }
        .onAppear { player.isPresentingPlayer = true }
        .onDisappear {
            for engine in engines.values { engine.stop() }
            engines = [:]
            player.isPresentingPlayer = false
        }
        .onExitCommand {
            if expandedID != nil {
                expandedID = nil
            } else {
                store.close()
            }
        }
        .sheet(isPresented: $picking) {
            NavigationStack {
                LiveSearchView { channel, _ in
                    picking = false
                    store.add(channel)
                }
                .padding(60)
            }
        }
    }

    private func tile(_ channel: XtreamChannel, expanded: Bool) -> some View {
        Button {
            expandedID = expanded ? nil : channel.id
            audibleID = channel.id
        } label: {
            MultiviewTile(engine: engines[channel.id], name: channel.name,
                          audible: audibleID == channel.id, expanded: expanded)
        }
        .buttonStyle(BareTileStyle())
        .focused($focusedTile, equals: channel.id)
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {
            Text("Left/Right moves the sound with the white frame · Select for full screen · Back leaves multiview")
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                picking = true
            } label: {
                PillLabel(title: String(localized: "Add channel"), icon: "plus")
            }
            .buttonStyle(PlainPressStyle())
            .disabled(store.channels.count >= MultiviewStore.maxChannels)
            Button {
                if let id = audibleID ?? store.channels.last?.id { remove(id) }
            } label: {
                PillLabel(title: String(localized: "Remove"), icon: "rectangle.badge.minus")
            }
            .buttonStyle(PlainPressStyle())
        }
        .focusSection()
    }

    private func remove(_ id: Int) {
        engines[id]?.stop()
        engines[id] = nil
        if audibleID == id { audibleID = store.channels.first(where: { $0.id != id })?.id }
        store.remove(id)
    }

    /// One engine per channel: new channels get one, removed channels lose theirs.
    private func syncEngines() async {
        let wanted = store.channels
        for (id, engine) in engines where !wanted.contains(where: { $0.id == id }) {
            engine.stop()
            engines[id] = nil
        }
        if audibleID == nil || !wanted.contains(where: { $0.id == audibleID }) { audibleID = wanted.first?.id }
        let client = settings.xtreamClient
        for (index, channel) in wanted.enumerated() where engines[channel.id] == nil {
            guard let engine = try? AetherEngine(),
                  let url = client.liveURL(for: channel, format: settings.prefs.liveFormat) else { continue }
            engine.logTag = "multiview-\(index + 1)"
            engine.deactivatesAudioSessionOnStop = true
            engine.volume = channel.id == audibleID ? 1 : 0
            engines[channel.id] = engine
            let options = LoadOptions(
                // Several pictures at once: none of them may switch the TV's display mode.
                suppressDisplayCriteria: true,
                httpHeaders: client.requestHeaders,
                matchContentEnabled: false,
                isLive: true,
                nativeRemoteHLS: false,
                preferredAudioLanguages: [settings.prefs.audioLanguage],
                // The engine shares the audio session and panel between engines by role.
                sharedOutputRole: index == 0 ? .primary : .secondary
            )
            _ = try? await engine.load(url: url, options: options)
        }
        applyVolumes()
    }

    private func applyVolumes() {
        for (id, engine) in engines {
            engine.volume = id == audibleID ? 1 : 0
        }
    }
}

private struct MultiviewTile: View {
    let engine: AetherEngine?
    let name: String
    let audible: Bool
    let expanded: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            if let engine {
                AetherPlayerSurface(engine: engine)
            }
            if !expanded {
                Label(name, systemImage: audible ? "speaker.wave.2.fill" : "speaker.slash")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
                    .padding(18)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: expanded ? 0 : 18, style: .continuous))
        .overlay {
            if !expanded {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white, lineWidth: isFocused ? 6 : 0)
            }
        }
    }
}

/// A tile shows focus with its own white frame, without the system lift.
private struct BareTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
