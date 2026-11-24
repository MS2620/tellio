import SwiftUI

/// Settings › Content › Sort by quality: choose which provider groups are split into
/// 4K, FHD, HD and SD folders, with tidied channel names.
struct QualitySortSettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var categories: [XtreamCategory] = []
    /// Per group: how many channels, and which quality folders it would get.
    @State private var summary: [String: (count: Int, qualities: [ChannelQuality])] = [:]
    @State private var loading = true
    @State private var error: String?

    /// The provider's groups, without the ones hidden in Groups & channels, with twins
    /// ("UK | Entertainment" and "UK | Entertainment HEVC") as one row.
    private var rows: [(ids: [String], name: String)] {
        QualitySort.twinGroups(categories.filter { !settings.prefs.hiddenCategoryIDs.contains($0.id) })
    }

    var body: some View {
        SettingsPage("Sort by quality") {
            if loading {
                ProgressView().padding(40)
            } else if let error {
                SettingsNote(error)
            } else if rows.isEmpty {
                SettingsNote("Your IPTV account has no channel groups yet.")
            } else {
                GlassPanel {
                    ForEach(rows, id: \.ids) { row in
                        SettingsToggleRow(row.name, icon: "folder", subtitle: subtitle(for: row.ids, name: row.name),
                                          isOn: binding(for: row.ids))
                    }
                }
            }
            SettingsNote("Pick the groups to split. Tellio sorts them again every time the channels load, so new channels land in the right folder. The original group is hidden; turn a group Off to bring it back. Channel names in these groups lose the country tag at the start and HEVC, 4K, UHD, FHD, HD and SD; a name with no quality counts as SD.")
        }
        .task { await load() }
    }

    /// One switch for a group and its twins.
    private func binding(for ids: [String]) -> Binding<Bool> {
        Binding(
            get: { ids.contains { settings.prefs.qualitySortCategoryIDs.contains($0) } },
            set: { on in
                if on {
                    settings.prefs.qualitySortCategoryIDs.formUnion(ids)
                } else {
                    settings.prefs.qualitySortCategoryIDs.subtract(ids)
                }
            })
    }

    /// "With UK | Entertainment HEVC · 186 channels · FHD, HD and SD folders" when on,
    /// "64 channels" when off.
    private func subtitle(for ids: [String], name: String) -> String {
        let names = Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let count = ids.reduce(0) { $0 + (summary[$1]?.count ?? 0) }
        var parts: [String] = []
        let twins = ids.compactMap { names[$0] }.filter { $0.caseInsensitiveCompare(name) != .orderedSame }
        if ids.count > 1, !twins.isEmpty { parts.append(String(localized: "With \(twins.joined(separator: ", "))")) }
        parts.append(count == 0 ? String(localized: "No channels") : String(localized: "\(count) channels"))
        let present = Set(ids.flatMap { summary[$0]?.qualities ?? [] })
        let labels = ChannelQuality.allCases.filter { present.contains($0) }.map(\.label)
        if ids.contains(where: { settings.prefs.qualitySortCategoryIDs.contains($0) }), !labels.isEmpty {
            let list = labels.formatted(.list(type: .and))
            parts.append(labels.count == 1 ? String(localized: "\(list) folder") : String(localized: "\(list) folders"))
        }
        return parts.joined(separator: " · ")
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
            let channels = try await XtreamCache.shared.rawLiveStreams(client)
            let names = Dictionary(groups.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            var tags: [String: String?] = [:]
            var counts: [String: Int] = [:]
            var found: [String: Set<ChannelQuality>] = [:]
            for channel in channels {
                guard let category = channel.categoryID,
                      !settings.prefs.hiddenChannelIDs.contains(channel.id) else { continue }
                counts[category, default: 0] += 1
                if tags[category] == nil { tags[category] = .some(QualitySort.countryTag(ofGroup: names[category] ?? "")) }
                found[category, default: []].insert(QualitySort.tidy(channel.name, groupTag: tags[category] ?? nil).quality)
            }
            categories = groups
            summary = counts.reduce(into: [:]) { result, entry in
                let present = found[entry.key] ?? []
                result[entry.key] = (entry.value, ChannelQuality.allCases.filter { present.contains($0) })
            }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}
