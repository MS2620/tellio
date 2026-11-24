import SwiftUI

/// "New build available", top right, once per build after launch.
struct UpdateCard: View {
    @ObservedObject private var checker = UpdateChecker.shared
    @State private var showingNotes = false
    @FocusState private var focused: Int?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
            if checker.showCard, let latest = checker.latest {
                VStack(alignment: .leading, spacing: 12) {
                    Label("NEW BUILD AVAILABLE", systemImage: "arrow.up.circle.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Theme.good)
                    Text(latest.title)
                        .font(.system(size: 28, weight: .heavy))
                    Text(UpdateNotes.firstLine(latest.notes))
                        .font(.system(size: 19))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(2)
                    Text("Install it with atvloadly. You're on build \(UpdateChecker.currentBuild).")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.55))
                    HStack(spacing: 12) {
                        Button {
                            showingNotes = true
                        } label: {
                            CardButtonLabel(title: String(localized: "What's new"), compact: true)
                        }
                        .buttonStyle(PlainPressStyle())
                        .focused($focused, equals: 0)
                        Button {
                            checker.dismissCard()
                        } label: {
                            CardButtonLabel(title: String(localized: "Later"), compact: true)
                        }
                        .buttonStyle(PlainPressStyle())
                        .focused($focused, equals: 1)
                    }
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 26)
                .frame(width: 640, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color(red: 30 / 255, green: 32 / 255, blue: 38 / 255).opacity(0.97)))
                .shadow(color: .black.opacity(0.5), radius: 25, y: 12)
                .focusSection()
                .onExitCommand { checker.dismissCard() }
                .padding(.top, 60)
                .padding(.trailing, 60)
                .task {
                    try? await Task.sleep(for: .milliseconds(150))
                    focused = 0
                }
                .sheet(isPresented: $showingNotes, onDismiss: { checker.dismissCard() }) {
                    UpdateNotes(release: latest)
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// The release notes of a build, from its GitHub release.
struct UpdateNotes: View {
    let release: UpdateChecker.Release

    static func firstLine(_ notes: String) -> String {
        notes.split(separator: "\n").map(String.init).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(release.title).font(.system(size: 40, weight: .heavy))
                Text(release.notes.isEmpty ? String(localized: "No notes for this build.") : release.notes)
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.85))
                Text("Install it with atvloadly from the release on GitHub (MS2620/tellio, Releases).")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .frame(maxWidth: 1200, alignment: .leading)
            .padding(60)
            // Lets the remote scroll long notes.
            .focusable()
        }
    }
}
