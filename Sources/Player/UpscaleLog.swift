import Foundation
import AetherEngine

/// AetherEngine doesn't publish why a load skipped the upscaler, only logs it
/// ("[Upscale] not taken (…)"). This keeps the latest such line for the stats panel.
@MainActor
final class UpscaleLog: ObservableObject {
    static let shared = UpscaleLog()

    /// The newest "[Upscale] …" line since the last `reset()`.
    @Published private(set) var lastLine: String?
    /// Set when line art overran on this Apple TV before and the engine used the automatic scaler instead.
    @Published private(set) var fellBackFromLineArt = false

    private init() {
        EngineLog.handler = { line in
            guard line.hasPrefix("[Upscale]") else { return }
            Task { @MainActor in UpscaleLog.shared.record(line) }
        }
    }

    /// Call before each load, so the panel only shows this video's decision.
    func reset() {
        lastLine = nil
        fellBackFromLineArt = false
    }

    private func record(_ line: String) {
        if line.contains("line art overran") {
            fellBackFromLineArt = line.contains("automatic scaler")
        } else {
            lastLine = line
        }
    }

    /// The engine's reason in plain words, when the last decision was "not taken".
    var skipReason: String? {
        guard let line = lastLine, let open = line.range(of: "not taken (") else { return nil }
        let reason = String(line[open.upperBound...].dropLast())
        switch reason {
        case let r where r.contains("needs OS 26"): return String(localized: "Needs tvOS 26 or later")
        case let r where r.contains("MetalFX"): return String(localized: "This Apple TV can't run the upscaler")
        case let r where r.contains("HDR or Dolby Vision"): return String(localized: "HDR and Dolby Vision video isn't upscaled")
        case let r where r.contains("not 8 or 10-bit"): return String(localized: "The video's colour format isn't supported")
        case let r where r.contains("not 8-bit"): return String(localized: "10-bit video isn't upscaled")
        case let r where r.contains("size unknown"): return String(localized: "The video's size isn't known")
        case let r where r.contains("not below 1080p"): return String(localized: "Already 1080p or higher")
        case let r where r.contains("larger than 1920x1080"): return String(localized: "The video is above 1080p")
        case let r where r.contains("display is not larger"): return String(localized: "Your TV's resolution isn't higher than the video's")
        case let r where r.contains("AirPlay"): return String(localized: "Sound is playing on an AirPlay speaker")
        case let r where r.contains("demuxed audio"): return String(localized: "This channel sends its sound separately, so it can't be upscaled")
        case let r where r.contains("disabled itself"): return String(localized: "The upscaler couldn't keep up with this video earlier")
        default: return reason.prefix(1).uppercased() + reason.dropFirst()
        }
    }
}
