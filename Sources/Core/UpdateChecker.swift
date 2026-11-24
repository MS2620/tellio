import Foundation

/// Looks at the GitHub pre-releases ("Tellio build N") and says when a newer build exists.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    struct Release: Equatable {
        let build: Int
        let title: String
        let notes: String
        let url: URL?
    }

    @Published private(set) var latest: Release?
    /// The launch card: shown once per new build.
    @Published var showCard = false

    private static let releasesURL = URL(string: "https://api.github.com/repos/MS2620/tellio/releases?per_page=10")!
    private static let dismissedKey = "updateCardDismissedBuild"

    /// This app's build number (the GitHub Actions run that built it).
    nonisolated static var currentBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    var updateAvailable: Bool { (latest?.build ?? 0) > Self.currentBuild }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let htmlUrl: String?
        let draft: Bool?
    }

    func check() async {
        var request = URLRequest(url: Self.releasesURL)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let data = try? await URLSession.shared.fetch(request),
              let releases = try? JSONDecoder.snake.decode([GitHubRelease].self, from: data) else { return }
        let builds = releases.compactMap { release -> Release? in
            guard release.draft != true, release.tagName.hasPrefix("build-"),
                  let number = Int(release.tagName.dropFirst("build-".count)) else { return nil }
            return Release(build: number, title: release.name ?? String(localized: "Tellio build \(number)"),
                           notes: release.body ?? "", url: release.htmlUrl.flatMap(URL.init(string:)))
        }
        guard let newest = builds.max(by: { $0.build < $1.build }) else { return }
        latest = newest
        // A build of 0 means this copy wasn't built by GitHub Actions; don't nag.
        if Self.currentBuild > 0, newest.build > Self.currentBuild,
           UserDefaults.standard.integer(forKey: Self.dismissedKey) != newest.build {
            showCard = true
        }
    }

    func dismissCard() {
        showCard = false
        if let latest { UserDefaults.standard.set(latest.build, forKey: Self.dismissedKey) }
    }
}
