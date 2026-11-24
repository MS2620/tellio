import SwiftUI

// MARK: - PIN entry

/// The 4-digit keypad: checks the PIN, or asks for a new one twice.
struct PINEntryView: View {
    enum Mode { case verify, create }

    let mode: Mode
    let onSuccess: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lock = ParentalLock.shared

    @State private var digits = ""
    @State private var firstEntry: String?
    @State private var message: String?
    @State private var shake: CGFloat = 0
    @State private var confirmingReset = false
    @FocusState private var focusedKey: String?

    private static let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "⌫"]

    private var heading: String {
        switch mode {
        case .verify: return String(localized: "Enter PIN")
        case .create: return firstEntry == nil ? String(localized: "Choose a 4-digit PIN") : String(localized: "Enter it again")
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 24) {
                Text(heading).font(.system(size: 34, weight: .heavy))
                HStack(spacing: 18) {
                    ForEach(0..<4, id: \.self) { index in
                        Circle()
                            .fill(index < digits.count ? Color.white : Color.white.opacity(0.25))
                            .frame(width: 28, height: 28)
                    }
                }
                .offset(x: shake)
                Text(message ?? " ")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.danger)

                LazyVGrid(columns: Array(repeating: GridItem(.fixed(110), spacing: 14), count: 3), spacing: 14) {
                    ForEach(Self.keys, id: \.self) { key in
                        if key.isEmpty {
                            Color.clear.frame(width: 110, height: 84)
                        } else {
                            Button {
                                press(key)
                            } label: {
                                KeypadKey(text: key)
                            }
                            .buttonStyle(PlainPressStyle())
                            .focused($focusedKey, equals: key)
                        }
                    }
                }

                if mode == .verify {
                    Button {
                        confirmingReset = true
                    } label: {
                        Text("Forgot PIN?")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(PlainPressStyle())
                }
            }
            .padding(44)
            .frame(width: 640)
            .background(RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(Color(red: 30 / 255, green: 32 / 255, blue: 38 / 255).opacity(0.97)))
        }
        .onAppear {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                focusedKey = "5"
            }
        }
        .confirmationDialog("Reset parental controls?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Delete all connections and reset", role: .destructive) {
                settings.deleteAllConnections()
                settings.prefs.parentalControlsOn = false
                lock.setPIN(nil)
                dismiss()
                onSuccess()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Without the PIN, the only way back in is to remove your IPTV login, TMDB key and addons. You can add them again afterwards.")
        }
    }

    private func press(_ key: String) {
        message = nil
        if key == "⌫" {
            if !digits.isEmpty { digits.removeLast() }
            return
        }
        guard digits.count < 4 else { return }
        digits += key
        guard digits.count == 4 else { return }

        switch mode {
        case .verify:
            if lock.matches(digits) {
                lock.unlock(minutes: settings.prefs.unlockMinutes)
                dismiss()
                onSuccess()
            } else {
                wrong(String(localized: "Wrong PIN"))
            }
        case .create:
            if let first = firstEntry {
                if first == digits {
                    lock.setPIN(digits)
                    lock.unlock(minutes: settings.prefs.unlockMinutes)
                    dismiss()
                    onSuccess()
                } else {
                    firstEntry = nil
                    wrong(String(localized: "The PINs didn't match. Start again."))
                }
            } else {
                firstEntry = digits
                digits = ""
            }
        }
    }

    private func wrong(_ text: String) {
        message = text
        Task { @MainActor in
            for offset in [-18.0, 18, -12, 12, -6, 0] {
                withAnimation(.linear(duration: 0.05)) { shake = offset }
                try? await Task.sleep(for: .milliseconds(50))
            }
            digits = ""
        }
    }
}

private struct KeypadKey: View {
    let text: String
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Group {
            if text == "⌫" {
                Image(systemName: "delete.left")
            } else {
                Text(text)
            }
        }
        .font(.system(size: 34, weight: .bold))
        .foregroundStyle(isFocused ? Theme.ink : Color.white)
        .frame(width: 110, height: 84)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(isFocused ? Color.white : Color.white.opacity(0.12)))
        .scaleEffect(isFocused ? 1.06 : 1)
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

extension View {
    /// Shows the PIN keypad over the screen while `isPresented` is true.
    func pinPrompt(_ isPresented: Binding<Bool>, mode: PINEntryView.Mode = .verify,
                   onSuccess: @escaping () -> Void) -> some View {
        fullScreenCover(isPresented: isPresented) {
            PINEntryView(mode: mode, onSuccess: onSuccess)
                .presentationBackground(.clear)
        }
    }
}

// MARK: - Settings

/// Settings › Parental controls. Needs the PIN to open while controls are on.
struct ParentalControlsView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var lock = ParentalLock.shared

    @State private var categories: [XtreamCategory] = []
    @State private var askingPIN = false
    @State private var creatingPIN = false
    @State private var unlockedHere = false

    private var locked: Bool { lock.settingsNeedPIN(prefs: settings.prefs) && !unlockedHere }

    var body: some View {
        SettingsPage("Parental controls") {
            if locked {
                GlassPanel {
                    SettingsActionRow("Enter PIN to change these settings", icon: "lock.fill") {
                        askingPIN = true
                    }
                }
            } else {
                pinPanel
                SettingsNote("Locked groups and addons need the PIN. Once entered, everything stays unlocked for the time you choose, then locks again.")
                groupsPanel
                addonsPanel
            }
        }
        .onAppear {
            unlockedHere = lock.isUnlocked
            if locked { askingPIN = true }
        }
        .task(id: settings.xtream) {
            guard settings.xtream.isConfigured else { return }
            categories = (try? await XtreamCache.shared.liveCategories(settings.xtreamClient)) ?? []
        }
        .pinPrompt($askingPIN) { unlockedHere = true }
    }

    private var pinPanel: some View {
        pinRows
            .pinPrompt($creatingPIN, mode: .create) {
                settings.prefs.parentalControlsOn = true
                unlockedHere = true
            }
    }

    private var pinRows: some View {
        GlassPanel("PIN") {
            Button {
                if settings.prefs.parentalControlsOn {
                    settings.prefs.parentalControlsOn = false
                    lock.setPIN(nil)
                } else {
                    creatingPIN = true
                }
            } label: {
                ListRowLabel(title: String(localized: "Parental PIN"), subtitle: String(localized: "Asks for the PIN to open locked items"), icon: "key",
                             trailing: settings.prefs.parentalControlsOn ? String(localized: "On") : String(localized: "Off"),
                             trailingIcon: settings.prefs.parentalControlsOn ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(PlainPressStyle())

            if settings.prefs.parentalControlsOn {
                SettingsActionRow("Change PIN", icon: "pencil") { creatingPIN = true }
                SettingsToggleRow("Hide locked groups", icon: "eye.slash", isOn: $settings.prefs.hideLockedGroups)
                SettingsOptionRow("Stay unlocked for", icon: "timer", selection: $settings.prefs.unlockMinutes,
                                  options: [(5, "5 minutes"), (15, "15 minutes"), (30, "30 minutes"),
                                            (60, "1 hour"), (240, "4 hours")])
                SettingsActionRow("Lock now", icon: "lock") {
                    lock.lockNow()
                    unlockedHere = false
                }
            }
        }
    }

    private var groupsPanel: some View {
        GlassPanel("Locked Live TV groups") {
            if categories.isEmpty {
                ListRowLabel(title: settings.xtream.isConfigured ? String(localized: "Loading groups…") : String(localized: "Add your IPTV login first"),
                             icon: "folder", dimmed: true)
            }
            ForEach(categories, id: \.id) { category in
                let isLocked = settings.prefs.lockedCategoryIDs.contains(category.id)
                Button {
                    if isLocked {
                        settings.prefs.lockedCategoryIDs.remove(category.id)
                    } else {
                        settings.prefs.lockedCategoryIDs.insert(category.id)
                    }
                } label: {
                    ListRowLabel(title: category.name, icon: isLocked ? "lock.fill" : "folder",
                                 trailing: isLocked ? String(localized: "Locked") : nil,
                                 trailingIcon: isLocked ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(PlainPressStyle())
            }
        }
    }

    private var addonsPanel: some View {
        GlassPanel("Addons") {
            if settings.addons.isEmpty {
                ListRowLabel(title: String(localized: "No addons"), icon: "puzzlepiece", dimmed: true)
            }
            ForEach(settings.addons) { addon in
                let isLocked = settings.prefs.lockedAddonIDs.contains(addon.id)
                Button {
                    if isLocked {
                        settings.prefs.lockedAddonIDs.remove(addon.id)
                    } else {
                        settings.prefs.lockedAddonIDs.insert(addon.id)
                    }
                } label: {
                    ListRowLabel(title: String(localized: "Lock \(addon.name)"), subtitle: String(localized: "Its streams need the PIN"),
                                 icon: isLocked ? "lock.fill" : "puzzlepiece",
                                 trailing: isLocked ? String(localized: "Locked") : nil,
                                 trailingIcon: isLocked ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(PlainPressStyle())
            }
        }
    }
}
