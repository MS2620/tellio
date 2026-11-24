import Foundation
import CryptoKit

/// Everything Tellio keeps on this Apple TV, for Settings › Backup & restore.
struct BackupPayload: Codable {
    var version = 1
    var created = Date()
    var tmdbToken: String
    var xtream: XtreamAccount
    var addons: [AddonEntry]
    /// Preferences as saved (decoded with defaults for anything newer).
    var preferences: Data
    var watchHistory: WatchHistory.Snapshot
    var reminders: [ProgrammeReminder]
    var trakt: TraktSync.Backup?
    var parentalPIN: String?
    /// Every IPTV account (backups from before multiple accounts only have `xtream`).
    var xtreamAccounts: [XtreamAccount]? = nil
}

enum BackupError: LocalizedError {
    case noServer
    case wrongPassword
    case notFound
    case cantDecrypt
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .noServer: return String(localized: "Add your backup server and password first.")
        case .wrongPassword: return String(localized: "The server rejected the password.")
        case .notFound: return String(localized: "No backup with that code (they're kept for 30 days).")
        case .cantDecrypt: return String(localized: "That code doesn't open this backup. Check the code and the server password.")
        case .server(let code): return String(localized: "The backup server answered \(code).")
        }
    }
}

/// Backs up to (and restores from) the user's own server. The backup is encrypted here with a
/// key made from the 8-character code and the server password, so the server only holds noise.
@MainActor
final class BackupService: ObservableObject {
    static let shared = BackupService()

    @Published var serverURL: String { didSet { Keychain.set(serverURL, for: "backupServer") } }
    @Published var password: String { didSet { Keychain.set(password, for: "backupPassword") } }
    @Published private(set) var lastCode: String?
    @Published private(set) var lastDate: Date?

    /// No 0/O or 1/I, so the code is easy to type with the remote.
    private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    private init() {
        serverURL = Keychain.string(for: "backupServer") ?? ""
        password = Keychain.string(for: "backupPassword") ?? ""
        lastCode = UserDefaults.standard.string(forKey: "backupLastCode")
        lastDate = UserDefaults.standard.object(forKey: "backupLastDate") as? Date
    }

    var isConfigured: Bool { base != nil && !password.isEmpty }

    private var base: URL? {
        var text = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text)
    }

    /// True when /health answers "ok".
    func checkServer() async -> Bool {
        guard let base else { return false }
        var request = URLRequest(url: base.appendingPathComponent("health"))
        request.timeoutInterval = 10
        guard let data = try? await URLSession.shared.fetch(request) else { return false }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
    }

    // MARK: Backing up

    func backUp(settings: AppSettings) async throws -> String {
        guard let base, !password.isEmpty else { throw BackupError.noServer }
        let payload = BackupPayload(
            tmdbToken: settings.ownTmdbToken,
            xtream: settings.xtream,
            addons: settings.addons,
            preferences: try JSONEncoder().encode(settings.prefs),
            watchHistory: WatchHistory.shared.snapshot,
            reminders: ReminderStore.shared.allReminders,
            trakt: TraktSync.shared.hasApp ? TraktSync.shared.backup : nil,
            parentalPIN: ParentalLock.shared.storedPIN,
            xtreamAccounts: settings.xtreamAccounts
        )
        let code = String((0..<8).map { _ in Self.alphabet.randomElement()! })
        let sealed = try AES.GCM.seal(try JSONEncoder().encode(payload), using: key(code: code))
        guard let body = sealed.combined else { throw BackupError.cantDecrypt }

        var request = URLRequest(url: base.appendingPathComponent("backups/\(code)"))
        request.httpMethod = "PUT"
        request.timeoutInterval = 30
        request.setValue("Bearer \(password)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        try await send(request)

        lastCode = code
        lastDate = Date()
        UserDefaults.standard.set(code, forKey: "backupLastCode")
        UserDefaults.standard.set(lastDate, forKey: "backupLastDate")
        return code
    }

    // MARK: Restoring

    func restore(code rawCode: String, settings: AppSettings) async throws {
        guard let base, !password.isEmpty else { throw BackupError.noServer }
        let code = rawCode.uppercased().filter { Self.alphabet.contains($0) || $0.isNumber || $0.isLetter }
        var request = URLRequest(url: base.appendingPathComponent("backups/\(code)"))
        request.timeoutInterval = 30
        request.setValue("Bearer \(password)", forHTTPHeaderField: "Authorization")
        let data = try await send(request)

        guard let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key(code: code)),
              let payload = try? JSONDecoder().decode(BackupPayload.self, from: plain) else {
            throw BackupError.cantDecrypt
        }

        settings.tmdbToken = payload.tmdbToken
        settings.xtreamAccounts = payload.xtreamAccounts
            ?? (payload.xtream.isConfigured ? [payload.xtream] : [])
        settings.xtream = payload.xtream
        ReminderStore.activeAccountID = payload.xtream.isConfigured ? payload.xtream.id : nil
        settings.addons = payload.addons
        if var prefs = Preferences.decode(payload.preferences) {
            prefs.setupDone = true
            settings.prefs = prefs
        }
        WatchHistory.shared.restore(payload.watchHistory)
        ReminderStore.shared.restore(payload.reminders)
        if let trakt = payload.trakt { TraktSync.shared.restore(trakt) }
        ParentalLock.shared.setPIN(payload.parentalPIN)
    }

    // MARK: Helpers

    /// The code plus the server password, stretched into an AES-256 key.
    private func key(code: String) -> SymmetricKey {
        let material = SymmetricKey(data: Data("\(code):\(password)".utf8))
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: material, salt: Data("Tellio backup v1".utf8),
                                      info: Data("tellio".utf8), outputByteCount: 32)
    }

    @discardableResult
    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 401: throw BackupError.wrongPassword
        case 404: throw BackupError.notFound
        default: throw BackupError.server(status)
        }
    }
}
