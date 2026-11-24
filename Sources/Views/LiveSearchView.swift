import SwiftUI

/// Live TV › Search: channels by name across every group, and programmes on now or
/// later today whose listings have been loaded. Locked and hidden groups are left out.
struct LiveSearchView: View {
    /// Plays a channel, with the results as the list to zap through.
    let onPlay: (XtreamChannel, [XtreamChannel]) -> Void

    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var parental = ParentalLock.shared
    @State private var query = ""
    @State private var all: [XtreamChannel] = []
    @State private var listings: [Int: [XtreamEPGEntry]] = [:]
    @State private var loading = true

    private struct ProgrammeHit: Identifiable {
        let channel: XtreamChannel
        let entry: XtreamEPGEntry
        var id: String { "\(channel.id)|\(entry.start?.timeIntervalSince1970 ?? 0)|\(entry.title)" }
    }

    private var visible: [XtreamChannel] {
        all.filter { channel in
            settings.isVisible(channel)
                && !parental.isLocked(categoryID: channel.categoryID ?? "", prefs: settings.prefs)
        }
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    private var channelHits: [XtreamChannel] {
        guard trimmed.count >= 2 else { return [] }
        return Array(visible.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }.prefix(40))
    }

    private var programmeHits: [ProgrammeHit] {
        guard trimmed.count >= 3 else { return [] }
        let now = Date()
        let until = now.addingTimeInterval(12 * 3600)
        let byID = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var hits: [ProgrammeHit] = []
        for (id, entries) in listings {
            guard let channel = byID[id] else { continue }
            for entry in entries {
                guard let start = entry.start, let end = entry.end, end > now, start < until,
                      entry.title.localizedCaseInsensitiveContains(trimmed) else { continue }
                hits.append(ProgrammeHit(channel: channel, entry: entry))
            }
        }
        return Array(hits.sorted { ($0.entry.start ?? .distantFuture) < ($1.entry.start ?? .distantFuture) }.prefix(25))
    }

    /// "Now: …" for a channel whose listings are loaded.
    private func onNow(_ channel: XtreamChannel) -> String? {
        let now = Date()
        guard let entry = listings[channel.id]?.first(where: { ($0.start ?? .distantFuture) <= now && ($0.end ?? .distantPast) > now })
        else { return nil }
        return String(localized: "Now: \(entry.title)")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                TextField("Search channels and programmes", text: $query)
                    .font(.system(size: 26, weight: .semibold))

                if trimmed.count < 2 {
                    Text(loading ? "Loading channels…" : "Type at least two letters. Programmes are found on channels whose guide has loaded.")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.6))
                } else {
                    let channels = channelHits
                    let programmes = programmeHits
                    if channels.isEmpty && programmes.isEmpty {
                        Text("Nothing found for \u{201C}\(trimmed)\u{201D}.")
                            .font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    if !channels.isEmpty {
                        section(String(localized: "Channels"))
                        ForEach(channels) { channel in
                            Button {
                                onPlay(channel, channels)
                            } label: {
                                ListRowLabel(title: channel.name,
                                             subtitle: QualitySort.joined([channel.folderName, onNow(channel)]),
                                             icon: "tv",
                                             logoURL: channel.icon.flatMap { URL(string: $0) }, showsLogo: true)
                            }
                            .buttonStyle(PlainPressStyle())
                        }
                    }
                    if !programmes.isEmpty {
                        section(String(localized: "On now & later today"))
                        ForEach(programmes) { hit in
                            Button {
                                onPlay(hit.channel, programmes.map(\.channel))
                            } label: {
                                ListRowLabel(title: hit.entry.title,
                                             subtitle: QualitySort.joined([hit.channel.name, hit.channel.folderName]),
                                             icon: "tv",
                                             logoURL: hit.channel.icon.flatMap { URL(string: $0) }, showsLogo: true,
                                             trailing: hit.entry.start.map { $0 <= Date() ? String(localized: "On now · \(DayFormat.time($0))") : DayFormat.time($0) })
                            }
                            .buttonStyle(PlainPressStyle())
                        }
                    }
                }
            }
            .padding(.trailing, 50)
            .padding(.bottom, 60)
        }
        .task(id: settings.xtream) {
            loading = true
            let client = settings.xtreamClient
            all = (try? await XtreamCache.shared.liveStreams(client)) ?? []
            listings = await XtreamCache.shared.cachedListings(client)
            loading = false
        }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 18, weight: .bold))
            .tracking(1)
            .foregroundStyle(.white.opacity(0.6))
            .padding(.top, 6)
    }
}
