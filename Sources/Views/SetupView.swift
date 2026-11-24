import SwiftUI

/// First-run setup: welcome, then IPTV, addons and teams (each skippable), then a summary.
/// Shown once; existing setups are marked done on launch, so they never see it.
struct SetupView: View {
    @EnvironmentObject private var settings: AppSettings

    private enum Step: Int, CaseIterable {
        case welcome, live, addons, teams, done
    }

    @State private var step: Step = .welcome
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                AppBackground()
                switch step {
                case .welcome: welcome
                case .live: SetupLiveStep(next: { go(.addons) }, progress: progress)
                case .addons: addonsStep
                case .teams: teamsStep
                case .done: done
                }
            }
            .onExitCommand {
                // Back goes to the previous step; on the welcome screen it does nothing.
                if let previous = Step(rawValue: step.rawValue - 1) { go(previous) }
            }
        }
        // Pages opened from setup (teams, leagues, add addon, restore) borrow their background
        // from the screen behind them; here that would be the app, so give them Tellio's own.
        .background { AppBackground() }
    }

    private func go(_ next: Step) {
        withAnimation(.easeInOut(duration: 0.25)) { step = next }
    }

    private func finish() {
        settings.prefs.setupDone = true
    }

    // MARK: Welcome

    private var welcome: some View {
        VStack(spacing: 34) {
            RoundedRectangle(cornerRadius: 40, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.35, green: 0.5, blue: 0.71),
                                              Color(red: 0.56, green: 0.44, blue: 0.6)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 150, height: 150)
                .overlay(Image(systemName: "play.fill").font(.system(size: 64, weight: .bold)))
                .shadow(color: .black.opacity(0.35), radius: 30, y: 20)
            Text("Welcome to Tellio")
                .font(.system(size: 72, weight: .heavy))
            Text("A player for your own Stremio addons and IPTV account. Tellio doesn't come with any channels or streams of its own.")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 1100)
            HStack(spacing: 28) {
                featureCard("film", String(localized: "Films & series"), String(localized: "Browse everything; play from your addons"))
                featureCard("tv", String(localized: "Live TV"), String(localized: "Your IPTV channels with a full guide"))
                featureCard("sportscourt", String(localized: "Sports"), String(localized: "Your teams' games, scores and channels"))
            }
            .padding(.top, 10)
            HStack(spacing: 24) {
                Button { go(.live) } label: { SetupPill(title: String(localized: "Get started")) }
                    .buttonStyle(PlainPressStyle())
                NavigationLink {
                    BackupView()
                        .onDisappear {
                            // A restore brings back a finished setup.
                            if settings.prefs.setupDone || settings.xtream.isConfigured || !settings.addons.isEmpty {
                                finish()
                            }
                        }
                } label: {
                    SetupPill(title: String(localized: "Restore from backup"), icon: "clock.arrow.circlepath")
                }
                .buttonStyle(PlainPressStyle())
            }
            .padding(.top, 20)
            .focusSection()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func featureCard(_ icon: String, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon).font(.system(size: 38, weight: .semibold))
            Text(title).font(.system(size: 26, weight: .bold))
            Text(text)
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(width: 330, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Theme.glass))
    }

    // MARK: Steps

    private func progress(_ active: Int) -> some View {
        HStack(spacing: 12) {
            ForEach(Array([String(localized: "Live TV"), String(localized: "Addons"), String(localized: "Your teams")].enumerated()), id: \.offset) { index, name in
                Text("\(index + 1) · \(name)")
                    .font(.system(size: 20, weight: .bold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(index == active ? Color.white
                                               : (index < active ? Color.white.opacity(0.5) : Theme.glass)))
                    .foregroundStyle(index == active ? Theme.ink : Color.white)
            }
        }
    }

    private var addonsStep: some View {
        SetupStepLayout(progress: progress(1), icon: "puzzlepiece.extension",
                        title: String(localized: "Add a Stremio addon"),
                        text: String(localized: "Films and series play from your addons. Use the manifest link from the addon's own configuration page."),
                        hint: String(localized: "You can add more, or change their order, later in Settings › Connections.")) {
            GlassPanel {
                ForEach(settings.addons) { addon in
                    ListRowLabel(title: addon.name, icon: "checkmark", trailing: URL(string: addon.manifestURL)?.host)
                }
                NavigationLink {
                    AddAddonView()
                } label: {
                    ListRowLabel(title: settings.addons.isEmpty ? String(localized: "Add addon") : String(localized: "Add another addon"), icon: "plus")
                }
                .buttonStyle(PlainPressStyle())
            }
        } buttons: {
            stepButtons(next: { go(.teams) }, canContinue: !settings.addons.isEmpty)
        }
    }

    private var teamsStep: some View {
        SetupStepLayout(progress: progress(2), icon: "sportscourt",
                        title: String(localized: "Follow your teams"),
                        text: String(localized: "Their games show on Home and in Sports with live scores, and Tellio finds the channels showing them."),
                        hint: String(localized: "Not into sports? Skip this.")) {
            GlassPanel {
                ForEach(settings.prefs.favouriteTeams, id: \.id) { team in
                    ListRowLabel(title: team.name, icon: "star.fill")
                }
                NavigationLink {
                    TeamsManagerView()
                } label: {
                    ListRowLabel(title: settings.prefs.favouriteTeams.isEmpty ? String(localized: "Choose teams") : String(localized: "Add or remove teams"),
                                 icon: "plus")
                }
                .buttonStyle(PlainPressStyle())
            }
        } buttons: {
            stepButtons(next: { go(.done) }, canContinue: !settings.prefs.favouriteTeams.isEmpty)
        }
    }

    /// Continue once something's been added; Skip for now always.
    private func stepButtons(next: @escaping () -> Void, canContinue: Bool) -> some View {
        HStack(spacing: 24) {
            if canContinue {
                Button(action: next) { SetupPill(title: String(localized: "Continue")) }
                    .buttonStyle(PlainPressStyle())
            }
            Button(action: next) { SetupPill(title: String(localized: "Skip for now")) }
                .buttonStyle(PlainPressStyle())
        }
    }

    // MARK: Done

    private var done: some View {
        VStack(spacing: 34) {
            Circle()
                .fill(Theme.good)
                .frame(width: 130, height: 130)
                .overlay(Image(systemName: "checkmark").font(.system(size: 60, weight: .heavy)).foregroundStyle(Theme.ink))
            Text("You're all set")
                .font(.system(size: 68, weight: .heavy))
            GlassPanel {
                summaryRow("film", String(localized: "Films & series"), String(localized: "Ready"), ok: true)
                summaryRow("tv", String(localized: "Live TV"),
                           settings.xtream.isConfigured ? settings.xtream.displayName : String(localized: "Not set · add in Settings"),
                           ok: settings.xtream.isConfigured)
                summaryRow("puzzlepiece.extension", String(localized: "Addons"),
                           settings.addons.isEmpty ? String(localized: "None · add in Settings")
                               : String(localized: "\(settings.addons.count) added"),
                           ok: !settings.addons.isEmpty)
                summaryRow("sportscourt", String(localized: "Your teams"),
                           settings.prefs.favouriteTeams.isEmpty ? String(localized: "Not set · add in Sports")
                               : String(localized: "\(settings.prefs.favouriteTeams.count) followed"),
                           ok: !settings.prefs.favouriteTeams.isEmpty)
            }
            .frame(width: 860)
            Text("Everything here can be changed later in Settings.")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.6))
            Button { finish() } label: { SetupPill(title: String(localized: "Start watching")) }
                .buttonStyle(PlainPressStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func summaryRow(_ icon: String, _ title: String, _ value: String, ok: Bool) -> some View {
        HStack(spacing: 18) {
            Image(systemName: icon).font(.system(size: 28, weight: .semibold)).frame(width: 40)
            Text(title).font(.system(size: 26, weight: .semibold))
            Spacer()
            Text(value)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(ok ? Theme.good : Color.white.opacity(0.55))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }
}

/// Step 1: the IPTV account, name first. Saved as soon as server, username and password are in.
private struct SetupLiveStep<Progress: View>: View {
    @EnvironmentObject private var settings: AppSettings
    let next: () -> Void
    let progress: (Int) -> Progress

    @State private var account = XtreamAccount()
    @State private var status: ConnectionState?

    var body: some View {
        SetupStepLayout(progress: progress(0), icon: "tv",
                        title: String(localized: "Add your IPTV account"),
                        text: String(localized: "For Live TV, the guide and finding matches on your channels. Use the Xtream Codes details from your provider."),
                        hint: String(localized: "No IPTV, or an M3U playlist instead of a login? Skip this. Films and series still work, and you can add either later in Settings › Connections.")) {
            GlassPanel {
                TypingRow(title: String(localized: "Name"), subtitle: String(localized: "So you can tell your IPTV accounts apart"), icon: "textformat",
                          value: account.name.isEmpty ? String(localized: "e.g. Home IPTV") : account.name,
                          initial: account.name, autocapitalize: true, allowsEmpty: true) { account.name = $0 }
                TypingRow(title: String(localized: "Server"), icon: "globe", value: account.server.isEmpty ? String(localized: "Not set") : account.host,
                          initial: account.server) { account.server = $0 }
                TypingRow(title: String(localized: "Username"), icon: "person",
                          value: account.username.isEmpty ? String(localized: "Not set") : account.username,
                          initial: account.username) { account.username = $0 }
                TypingRow(title: String(localized: "Password"), icon: "lock", value: account.password.isEmpty ? String(localized: "Not set") : "••••••••",
                          initial: account.password, secure: true) { account.password = $0 }
            }
            if let status {
                HStack(spacing: 12) {
                    Circle().fill(status.dot).frame(width: 12, height: 12)
                    Text(status.text).font(.system(size: 22, weight: .semibold))
                }
                .padding(.horizontal, 20)
            }
        } buttons: {
            HStack(spacing: 24) {
                if account.isConfigured {
                    Button {
                        settings.addAccount(account, use: true)
                        next()
                    } label: {
                        SetupPill(title: String(localized: "Continue"))
                    }
                    .buttonStyle(PlainPressStyle())
                }
                Button(action: next) { SetupPill(title: String(localized: "Skip for now")) }
                    .buttonStyle(PlainPressStyle())
            }
        }
        .onAppear {
            // Coming back to this step shows the account already added.
            if settings.xtream.isConfigured { account = settings.xtream }
        }
        .task(id: account) {
            guard account.isConfigured else { status = nil; return }
            status = .checking(String(localized: "Checking…"))
            let (state, info) = await ConnectionCheck.iptv(account, userAgent: settings.prefs.iptvUserAgent)
            guard info?.signedIn == true else { status = state; return }
            let client = XtreamClient(account: account, userAgent: settings.prefs.iptvUserAgent)
            if let count = (try? await XtreamCache.shared.liveStreams(client))?.count {
                status = .good(String(localized: "Connected · \(count) channels"))
            } else {
                status = state
            }
        }
    }
}

/// The shared step layout: progress pills, explanation on the left, the form and buttons on the right.
private struct SetupStepLayout<Progress: View, Form: View, Buttons: View>: View {
    let progress: Progress
    let icon: String
    let title: String
    let text: String
    let hint: String
    @ViewBuilder let form: () -> Form
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 50) {
            progress
            HStack(alignment: .top, spacing: 150) {
                VStack(alignment: .leading, spacing: 26) {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Theme.glass)
                        .frame(width: 96, height: 96)
                        .overlay(Image(systemName: icon).font(.system(size: 44, weight: .semibold)))
                    Text(title).font(.system(size: 60, weight: .heavy))
                    Text(text)
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(hint)
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 640, alignment: .leading)
                VStack(alignment: .leading, spacing: 26) {
                    form()
                    buttons()
                        .padding(.top, 20)
                        .focusSection()
                }
                .frame(width: 910, alignment: .leading)
                .focusSection()
            }
        }
        .padding(.horizontal, 110)
        .padding(.top, 90)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The big round buttons of the setup screens: glass at rest, white when focused.
private struct SetupPill: View {
    let title: String
    var icon: String? = nil
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 14) {
            if let icon { Image(systemName: icon).font(.system(size: 28, weight: .bold)) }
            Text(title).font(.system(size: 30, weight: .heavy))
        }
        .padding(.horizontal, 64)
        .padding(.vertical, 24)
        .foregroundStyle(isFocused ? Theme.ink : Color.white)
        .background(Capsule().fill(isFocused ? Color.white : Theme.glassStrong))
        .scaleEffect(isFocused ? 1.05 : 1)
        .shadow(color: .black.opacity(isFocused ? 0.35 : 0), radius: 20, y: 14)
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}
