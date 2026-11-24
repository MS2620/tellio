import SwiftUI

/// Settings › About › Send feedback.
struct FeedbackView: View {
    @State private var kind: FeedbackService.Kind = .problem
    @State private var message = ""
    @State private var contact = ""
    @State private var includeDevice = true
    @State private var sending = false
    @State private var sent: FeedbackService.Sent?
    @State private var error: String?

    private var canSend: Bool {
        !sending && message.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3
    }

    var body: some View {
        SettingsPage("Send feedback") {
            if let sent {
                confirmation(sent)
            } else {
                form
            }
        }
    }

    private var form: some View {
        VStack(spacing: 30) {
            HStack(spacing: 14) {
                ForEach(FeedbackService.Kind.allCases) { option in
                    Button { kind = option } label: {
                        PillLabel(title: option.label, selected: kind == option)
                    }
                    .buttonStyle(PlainPressStyle())
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .focusSection()

            GlassPanel {
                TypingRow(title: String(localized: "Message"), subtitle: String(localized: "What happened, or what you'd like"),
                          icon: "text.alignleft",
                          value: message.isEmpty ? String(localized: "Type your message") : message,
                          initial: message, autocapitalize: true, allowsEmpty: true) { message = $0 }
                TypingRow(title: String(localized: "Email or GitHub name"),
                          subtitle: String(localized: "Only if you'd like a reply. Kept private, never posted"),
                          icon: "at", value: contact.isEmpty ? String(localized: "Optional") : contact,
                          initial: contact, allowsEmpty: true) { contact = $0 }
                SettingsToggleRow("Include device details", icon: "tv",
                                  subtitle: FeedbackService.deviceDetails, isOn: $includeDevice)
            }

            HStack(spacing: 20) {
                Button(action: send) {
                    PillLabel(title: sending ? String(localized: "Sending…") : String(localized: "Send"), icon: sending ? nil : "paperplane")
                        .opacity(canSend || sending ? 1 : 0.5)
                }
                .buttonStyle(PlainPressStyle())
                .disabled(!canSend)
                Text(error ?? String(localized: "Never includes your logins, server or channel names."))
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(error == nil ? Color.white.opacity(0.65) : Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .focusSection()
        }
    }

    private func confirmation(_ sent: FeedbackService.Sent) -> some View {
        Button {} label: {
            HStack(spacing: 18) {
                Image(systemName: "checkmark")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Theme.good))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Thanks, it's been sent").font(.system(size: 26, weight: .bold))
                    Text("Reference #\(sent.number). Follow it at github.com/MS2620/tellio/issues")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Theme.glass))
        }
        .buttonStyle(PlainPressStyle())
    }

    private func send() {
        guard canSend else { return }
        sending = true
        error = nil
        Task {
            do {
                sent = try await FeedbackService.send(
                    kind: kind, message: message.trimmingCharacters(in: .whitespacesAndNewlines),
                    contact: contact, includeDevice: includeDevice)
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }
}
