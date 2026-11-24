import SwiftUI

/// Live TV › long-press a channel › Rename…: your own name for a channel, used everywhere
/// and saved per IPTV account.
struct RenameChannelView: View {
    let channel: XtreamChannel
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    private var customName: String? { settings.prefs.channelNames[channel.id] }

    var body: some View {
        SettingsPage("Rename channel") {
            GlassPanel {
                TypingRow(title: String(localized: "Name"), subtitle: String(localized: "Select to type a new name"), icon: "pencil",
                          value: channel.name, initial: channel.name, autocapitalize: true) { name in
                    rename(to: name)
                }
                if customName != nil {
                    Button {
                        settings.prefs.channelNames[channel.id] = nil
                        dismiss()
                    } label: {
                        ListRowLabel(title: String(localized: "Use the provider's name"), subtitle: channel.providerName,
                                     icon: "arrow.counterclockwise")
                    }
                    .buttonStyle(PlainPressStyle())
                }
            }
            SettingsNote("Your name is used everywhere: Live TV, the guide, search, favourites, the player and Top Shelf. Saved per IPTV account, and kept even when Sort by quality is turned off.")
        }
    }

    private func rename(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != channel.name else { return }
        if trimmed == channel.providerName {
            settings.prefs.channelNames[channel.id] = nil
        } else {
            settings.prefs.channelNames[channel.id] = trimmed
        }
        dismiss()
    }
}
