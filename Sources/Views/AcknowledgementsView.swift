import SwiftUI

/// Open-source software built into Tellio, with each one's licence text.
/// AetherEngine's licence asks apps that ship it to show these.
struct Acknowledgement: Identifiable {
    let name: String
    let detail: String
    let licence: String
    /// The file in Resources/Licenses, without "License-" and ".txt".
    let file: String
    /// Its key in the build's library versions (see LibraryVersions), if it has its own package.
    var versionKey: String? = nil
    var source: String? = nil

    var id: String { file }

    var version: String? {
        versionKey.flatMap { Acknowledgement.versions[$0] }
    }

    var text: String {
        guard let url = Bundle.main.url(forResource: "License-\(file)", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return String(localized: "The licence text is missing from this build.")
        }
        return text
    }

    /// "aetherengine=7.67.1,ffmpegbuild=3.15.0,…", filled in by the build from Package.resolved.
    static let versions: [String: String] = {
        let raw = Bundle.main.object(forInfoDictionaryKey: "LibraryVersions") as? String ?? ""
        var result: [String: String] = [:]
        for pair in raw.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, !parts[1].isEmpty { result[parts[0]] = parts[1] }
        }
        return result
    }()

    static let all: [Acknowledgement] = [
        Acknowledgement(name: "AetherEngine", detail: String(localized: "Video player engine"),
                        licence: "LGPL-3.0 + App Store exception", file: "AetherEngine",
                        versionKey: "aetherengine", source: "github.com/superuser404notfound/AetherEngine"),
        Acknowledgement(name: "FFmpeg", detail: String(localized: "Video and audio decoding"), licence: "LGPL-2.1+",
                        file: "FFmpeg", versionKey: "ffmpegbuild",
                        source: "github.com/superuser404notfound/FFmpegBuild"),
        Acknowledgement(name: "dav1d", detail: String(localized: "AV1 decoding"), licence: "BSD-2-Clause", file: "dav1d",
                        versionKey: "ffmpegbuild", source: "github.com/superuser404notfound/FFmpegBuild"),
        Acknowledgement(name: "zimg", detail: String(localized: "Scaling"), licence: "WTFPL", file: "zimg",
                        versionKey: "ffmpegbuild", source: "github.com/superuser404notfound/FFmpegBuild"),
        Acknowledgement(name: "libzvbi", detail: String(localized: "Teletext subtitles"), licence: "LGPL-2.1 · MIT", file: "libzvbi",
                        versionKey: "ffmpegbuild", source: "github.com/superuser404notfound/FFmpegBuild"),
        Acknowledgement(name: "libdovi", detail: "© quietvoid and contributors", licence: "MIT", file: "libdovi",
                        versionKey: "libdovi", source: "github.com/quietvoid/dovi_tool"),
        Acknowledgement(name: "Anime4K", detail: "© 2019-2021 bloc97", licence: "MIT", file: "Anime4K",
                        source: "github.com/bloc97/Anime4K"),
        Acknowledgement(name: "Sentry", detail: String(localized: "Crash reports · © 2015 Sentry"), licence: "MIT", file: "Sentry",
                        versionKey: "sentry-cocoa", source: "github.com/getsentry/sentry-cocoa"),
    ]
}

/// Settings › About › Acknowledgements.
struct AcknowledgementsView: View {
    var body: some View {
        SettingsPage("Acknowledgements") {
            Text("Tellio is built with this software and data. Select one to read its licence.")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 30)

            GlassPanel {
                // TMDB asks for this credit; a selectable row so the remote can reach it.
                Button {} label: {
                    ListRowLabel(title: "TMDB",
                                 subtitle: String(localized: "Film & TV information and artwork. This product uses the TMDB API but is not endorsed or certified by TMDB."),
                                 trailing: String(localized: "Data"))
                }
                .buttonStyle(PlainPressStyle())
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 1)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
                ForEach(Acknowledgement.all) { item in
                    NavigationLink {
                        LicenceTextView(item: item)
                    } label: {
                        ListRowLabel(title: item.version.map { "\(item.name) \($0)" } ?? item.name,
                                     subtitle: item.detail, trailing: item.licence,
                                     trailingIcon: "chevron.right")
                    }
                    .buttonStyle(PlainPressStyle())
                }
            }

            SettingsNote(sourceNote)
                .padding(.top, 14)
        }
    }

    private var sourceNote: String {
        let engine = Acknowledgement.versions["aetherengine"].map { " (\($0))" } ?? ""
        let ffmpeg = Acknowledgement.versions["ffmpegbuild"].map { " (\($0))" } ?? ""
        return String(localized: "Source code: github.com/superuser404notfound/AetherEngine\(engine) and /FFmpegBuild\(ffmpeg).")
    }
}

/// One licence, read a paragraph at a time with the remote.
struct LicenceTextView: View {
    let item: Acknowledgement

    private var paragraphs: [String] {
        item.text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        SettingsPage(item.name) {
            VStack(alignment: .leading, spacing: 6) {
                Text([item.licence, item.version.map { String(localized: "version \($0)") }].compactMap { $0 }.joined(separator: " · "))
                if let source = item.source {
                    Text("Source: \(source)")
                }
            }
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(.white.opacity(0.7))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 30)

            GlassPanel {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Button {} label: { LicenceParagraph(text: paragraph) }
                            .buttonStyle(PlainPressStyle())
                    }
                }
            }
        }
    }
}

private struct LicenceParagraph: View {
    let text: String
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Text(text)
            .font(.system(size: 19, weight: .regular, design: .monospaced))
            .foregroundStyle(.white.opacity(0.88))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isFocused ? Color.white.opacity(0.16) : Color.clear)
            )
            .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}
