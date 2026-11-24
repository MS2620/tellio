import Foundation
import UIKit

/// Sends feedback to the Tellio feedback service, which opens a public GitHub issue for it.
/// The contact field is kept private on the server and never posted.
enum FeedbackService {
    enum Kind: String, CaseIterable, Identifiable {
        case problem, idea, other
        var id: String { rawValue }
        var label: String {
            switch self {
            case .problem: String(localized: "Problem")
            case .idea: String(localized: "Idea")
            case .other: String(localized: "Something else")
            }
        }
    }

    struct Sent {
        let number: Int
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Filled at build time from the FEEDBACK_URL secret; empty in builds without it.
    static var baseURL: URL? {
        let text = (Bundle.main.object(forInfoDictionaryKey: "FeedbackURL") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("https://") else { return nil }
        return URL(string: text)
    }

    static var isAvailable: Bool { baseURL != nil }

    /// "tvOS 26.1 · Apple TV 4K · Tellio build 54", or "iOS 26.1 · iPhone (iPhone17,1) · …" from the
    /// iPhone and iPad app. Nothing about accounts or what's watched.
    static var deviceDetails: String {
        "\(systemName) \(UIDevice.current.systemVersion) · \(modelName) · Tellio build \(UpdateChecker.currentBuild)"
    }

    private static var systemName: String {
        #if os(tvOS)
        return "tvOS"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        #endif
    }

    static func send(kind: Kind, message: String, contact: String, includeDevice: Bool) async throws -> Sent {
        guard let base = baseURL else {
            throw Failure(message: String(localized: "Feedback isn't available in this build."))
        }
        var body: [String: String] = ["kind": kind.rawValue, "message": message,
                                      "build": String(UpdateChecker.currentBuild)]
        if !contact.isEmpty { body["contact"] = contact }
        if includeDevice { body["device"] = deviceDetails }

        var request = URLRequest(url: base.appendingPathComponent("feedback"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure(message: String(localized: "Couldn't reach the feedback service. Check your connection and try again."))
        }
        let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let http = response as? HTTPURLResponse, http.statusCode == 201,
              let number = reply?["number"] as? Int else {
            throw Failure(message: reply?["error"] as? String ?? String(localized: "Couldn't send it right now. Please try again later."))
        }
        return Sent(number: number)
    }

    private static var modelName: String {
        var info = utsname()
        uname(&info)
        let id = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        #if !os(tvOS)
        // "iPhone (iPhone17,1)": the identifier pins down the exact model without a lookup table.
        return "\(UIDevice.current.model) (\(id))"
        #else
        switch id {
        case "AppleTV5,3": return "Apple TV HD"
        case "AppleTV6,2": return "Apple TV 4K"
        case "AppleTV11,1": return "Apple TV 4K (2nd gen)"
        case "AppleTV14,1": return "Apple TV 4K (3rd gen)"
        default: return id.hasPrefix("AppleTV") ? "Apple TV (\(id))" : "Apple TV"
        }
        #endif
    }
}
