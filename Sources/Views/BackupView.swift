import SwiftUI

/// Settings › Backup & restore: back up to a code on your own server, or restore from one.
struct BackupView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var backup = BackupService.shared

    @State private var pendingCode: String?
    @State private var serverOK: Bool?
    @State private var working = false
    @State private var newCode: String?
    @State private var message: String?

    var body: some View {
        SettingsPage("Backup & restore") {
            GlassPanel("Your backup server") {
                TypingRow(title: String(localized: "Server"), icon: "server.rack",
                          value: backup.serverURL.isEmpty ? String(localized: "Not set") : backup.serverURL,
                          initial: backup.serverURL) {
                    backup.serverURL = $0
                    serverOK = nil
                }
                TypingRow(title: String(localized: "Password"), icon: "lock", value: backup.password.isEmpty ? String(localized: "Not set") : "••••••",
                          initial: backup.password, secure: true) {
                    backup.password = $0
                    serverOK = nil
                }
                if backup.isConfigured {
                    Button {
                        Task { serverOK = await backup.checkServer() }
                    } label: {
                        ListRowLabel(title: String(localized: "Check connection"), icon: "checkmark.circle",
                                     trailing: serverOK.map { $0 ? String(localized: "Working") : String(localized: "Not reachable") })
                    }
                    .buttonStyle(PlainPressStyle())
                }
            }
            SettingsNote("The Tellio backup service on your VPS (e.g. https://backup.mauroks.co.uk) and the password you set in its .env file.")

            GlassPanel("Backup & restore") {
                Button {
                    Task { await runBackup() }
                } label: {
                    ListRowLabel(title: working ? String(localized: "Working…") : String(localized: "Back up to a code"),
                                 subtitle: String(localized: "Logins, addons, My List, teams, watch history, reminders, Trakt and settings"),
                                 icon: "square.and.arrow.up")
                }
                .buttonStyle(PlainPressStyle())
                .disabled(!backup.isConfigured || working)

                TypingRow(title: String(localized: "Restore from a code"), icon: "square.and.arrow.down", value: "",
                          initial: "") { pendingCode = $0 }
                    .disabled(!backup.isConfigured || working)

                if let code = backup.lastCode, let date = backup.lastDate {
                    ListRowLabel(title: String(localized: "Last backup"), icon: "clock",
                                 trailing: "\(code) · \(date.formatted(.relative(presentation: .named)))", dimmed: true)
                }
            }

            if let newCode {
                codeCard(newCode)
            }
            if let message {
                SettingsNote(message)
            }
        }
        .confirmationDialog("Restore this backup?", isPresented: Binding(
            get: { pendingCode != nil }, set: { if !$0 { pendingCode = nil } }
        ), titleVisibility: .visible) {
            Button("Replace this Apple TV's settings", role: .destructive) {
                let code = pendingCode ?? ""
                pendingCode = nil
                Task { await runRestore(code) }
            }
            Button("Cancel", role: .cancel) { pendingCode = nil }
        } message: {
            Text("Your logins, addons, lists, history and settings here are replaced by the backup's.")
        }
    }

    private func codeCard(_ code: String) -> some View {
        VStack(spacing: 16) {
            Text("BACKUP READY · KEPT FOR 30 DAYS")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white.opacity(0.6))
            HStack(spacing: 10) {
                ForEach(Array(code.enumerated()), id: \.offset) { index, character in
                    if index == 4 {
                        Text("·").font(.system(size: 40, weight: .heavy)).foregroundStyle(.white.opacity(0.5))
                    }
                    Text(String(character))
                        .font(.system(size: 40, weight: .heavy))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 62, height: 80)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
                }
            }
            Text("On another Apple TV, or after reinstalling: Settings › Backup & restore › Restore from a code, and type this in.")
                .font(.system(size: 20))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.75))
        }
        .padding(34)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Theme.glass))
    }

    private func runBackup() async {
        working = true
        defer { working = false }
        message = nil
        do {
            newCode = try await backup.backUp(settings: settings)
        } catch {
            message = String(localized: "Backup failed: \(error.localizedDescription)")
        }
    }

    private func runRestore(_ code: String) async {
        working = true
        defer { working = false }
        message = nil
        do {
            try await backup.restore(code: code, settings: settings)
            newCode = nil
            message = String(localized: "Restored. Everything from the backup is in place.")
        } catch {
            message = String(localized: "Restore failed: \(error.localizedDescription)")
        }
    }
}
