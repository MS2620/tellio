import Foundation

/// Whether an addon's listing ("Wolverhampton Wanderes v Man Utd | 20:00") is a given match,
/// when the teams' names don't appear word for word. Each side of the listing is compared with
/// one team: exactly, by the team's code ("MUN"), or closely enough to allow a typo or another
/// spelling. Both sides have to match, in either order, so other games stay out.
enum ListingMatcher {
    /// A team as listings may name it: its names and aliases (already as phrases), and its code.
    struct Team {
        let names: [String]
        let code: String?

        init(names: [String], code: String?) {
            self.names = names
            self.code = code.map(GuideText.phrase).flatMap { $0.count >= 2 ? $0 : nil }
        }
    }

    /// A side counts with at least this score (1 is a perfect match).
    static let threshold = 0.75

    static func isMatch(_ title: String, home: Team, away: Team) -> Bool {
        sidePairs(title).contains { left, right in
            (score(left, home) >= threshold && score(right, away) >= threshold)
                || (score(left, away) >= threshold && score(right, home) >= threshold)
        }
    }

    // MARK: Splitting a listing

    /// "Premier League: Arsenal v Spurs [HD] | 20:00" → ("arsenal", "spurs"). Several splits
    /// may be possible when only dashes separate the parts ("EPL - Arsenal - Spurs").
    static func sidePairs(_ title: String) -> [(String, String)] {
        var text = " " + title + " "
        // Brackets hold extras: "(Premier League)", "[HD]".
        text = text.replacingOccurrences(of: #"\([^)]*\)|\[[^\]]*\]|\{[^}]*\}"#, with: " ", options: .regularExpression)
        text = ListingDates.removingDates(text)
        // A competition before a colon, and a time or channel after a bar, aren't sides.
        let parts = text.components(separatedBy: CharacterSet(charactersIn: "|·•"))
        text = parts.first(where: GuideText.hasVersus) ?? text
        if let colon = text.lastIndex(of: ":"), GuideText.hasVersus(String(text[colon...])) {
            text = String(text[text.index(after: colon)...])
        }
        text = " " + text + " "

        for strong in [" vs. ", " vs ", " v. ", " v ", " x ", " @ "] {
            guard let range = text.range(of: strong, options: .caseInsensitive) else { continue }
            let left = splitAtDashes(String(text[..<range.lowerBound])).last ?? ""
            let right = splitAtDashes(String(text[range.upperBound...])).first ?? ""
            return [(clean(left), clean(right))]
        }
        let pieces = splitAtDashes(text).map(clean).filter { !$0.isEmpty }
        guard pieces.count >= 2 else { return [] }
        return (0..<(pieces.count - 1)).map { (pieces[$0], pieces[$0 + 1]) }
    }

    /// Split at dashes with spaces around them, so "Saint-Etienne" stays whole.
    private static func splitAtDashes(_ text: String) -> [String] {
        text.replacingOccurrences(of: #"\s[-–—]+\s"#, with: "\u{1}", options: .regularExpression)
            .components(separatedBy: "\u{1}")
    }

    /// As a phrase, without words that only describe the stream.
    private static func clean(_ side: String) -> String {
        let noise: Set<String> = ["live", "now", "hd", "fhd", "uhd", "4k", "sd", "en", "vivo", "directo", "today", "tonight"]
        return GuideText.phrase(side).split(separator: " ").map(String.init)
            .filter { !noise.contains($0) }.joined(separator: " ")
    }

    // MARK: Scoring a side

    /// How well one side of a listing names `team`, from 0 to 1.
    static func score(_ side: String, _ team: Team) -> Double {
        guard !side.isEmpty else { return 0 }
        if let code = team.code, side == code { return 1 }
        guard !TeamNames.isTooVague(side) else { return 0 }
        return team.names.map { similarity(side, $0) }.max() ?? 0
    }

    /// Every word of the side has to be in the name (allowing a typo in longer words), and the
    /// side has to cover most of the name: "brighton hove" is "brighton hove albion", but
    /// "arsenal w" (the women's team) or "bayern munich ii" (the reserves) isn't the team.
    static func similarity(_ side: String, _ name: String) -> Double {
        let sideWords = words(side)
        let nameWords = words(name)
        guard !sideWords.isEmpty, !nameWords.isEmpty else { return 0 }
        var unused = nameWords
        for word in sideWords {
            guard let index = unused.firstIndex(where: { close(word, $0) }) else { return 0 }
            unused.remove(at: index)
        }
        let covered = Double(nameWords.count - unused.count) / Double(nameWords.count)
        // A single shared word from a longer name is weaker than the whole name.
        return covered >= 0.5 ? 0.75 + 0.25 * covered : covered
    }

    /// Short forms listings use, written out.
    private static let shortForms = ["utd": "united", "st": "saint", "ste": "sainte", "intl": "international"]
    /// Words that don't tell teams apart ("Brighton and Hove Albion").
    private static let fillers: Set<String> = ["and", "the"]

    private static func words(_ phrase: String) -> [String] {
        TeamNames.coreWords(phrase).filter { !fillers.contains($0) }.map { shortForms[$0] ?? $0 }
    }

    /// The same word, or one letter off in a word of 6 letters or more ("wanderes", "munchen").
    private static func close(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard min(a.count, b.count) >= 6, abs(a.count - b.count) <= 1 else { return false }
        return editDistance(a, b, limit: 1) <= 1
    }

    private static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            if current.min()! > limit { return limit + 1 }
            previous = current
        }
        return previous[b.count]
    }
}

/// The start dates sports addons write in their listings, in the formats they use.
enum ListingDates {
    /// A date found in a listing. `precise` when it has a time and a time zone (or is UTC);
    /// otherwise it's only good to the day.
    struct Found {
        let date: Date
        let precise: Bool
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let monthPattern = "(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\\.?"
    private static let time = #"(?:\s*(?:·|,|at|-|–)?\s*(\d{1,2})[:.h](\d{2}))?"#
    private static let zone = #"(?:\s*(utc|gmt|z\b))?"#

    /// The patterns, each with which capture group holds the day, month and year (0 = none).
    private static let patterns: [(regex: NSRegularExpression, day: Int, month: Int, year: Int, monthName: Bool)] = {
        func make(_ pattern: String, _ day: Int, _ month: Int, _ year: Int, _ named: Bool) -> (NSRegularExpression, Int, Int, Int, Bool) {
            (try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive]), day, month, year, named)
        }
        return [
            // 2026-11-25T20:00, 2026-11-25 20:00
            make(#"\b(\d{4})-(\d{1,2})-(\d{1,2})(?:[t\s]+(\d{1,2}):(\d{2}))?"# + zone, 3, 2, 1, false),
            // 25 Nov 2026 · 08:00, Wed 25 Nov, 25 November 20:00
            make(#"\b(?:[a-z]{3,9},?\s+)?(\d{1,2})(?:st|nd|rd|th)?\s+("# + monthPattern + #")(?:\s+(\d{4}))?"# + time + zone, 1, 2, 3, true),
            // Nov 25, November 25th 2026
            make(#"\b("# + monthPattern + #")\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?"# + time + zone, 2, 1, 3, true),
            // 25/11/2026, 25.11.2026, 25/11, 25.11.
            make(#"\b(\d{1,2})[/.](\d{1,2})(?:[/.](\d{2,4}))?\.?(?!\d)"# + time + zone, 1, 2, 3, false),
        ]
    }()

    /// The first date in `text`, read near `reference` (for the year when none is given).
    static func find(in text: String, near reference: Date, now: Date = Date()) -> Found? {
        let utc = utcCalendar
        let range = NSRange(text.startIndex..., in: text)
        for pattern in patterns {
            guard let match = pattern.regex.firstMatch(in: text, range: range) else { continue }
            func group(_ index: Int) -> String? {
                guard index > 0, index < match.numberOfRanges, let r = Range(match.range(at: index), in: text) else { return nil }
                return String(text[r])
            }
            var day = group(pattern.day).flatMap { Int($0) }
            var month: Int?
            if pattern.monthName {
                let name = group(pattern.month)?.lowercased().prefix(3) ?? ""
                month = months.firstIndex(of: String(name)).map { $0 + 1 }
            } else {
                month = group(pattern.month).flatMap { Int($0) }
            }
            // Day-first, unless that can't be (11/25 is November 25th).
            if !pattern.monthName, pattern.year != 1, let d = day, let m = month, m > 12, d <= 12 {
                (day, month) = (m, d)
            }
            guard let day, let month, (1...31).contains(day), (1...12).contains(month) else { continue }
            // The time and zone groups come after the date's own.
            let extra = match.numberOfRanges
            let hour = group(extra - 3).flatMap { Int($0) }
            let minute = group(extra - 2).flatMap { Int($0) }
            let zoned = group(extra - 1) != nil
            var year = group(pattern.year).flatMap { Int($0) }
            if let y = year, y < 100 { year = 2000 + y }
            if year == nil {
                // The year nearest the match: "2 Jan" for a match on 31 Dec is next year's.
                let referenceYear = utc.component(.year, from: reference)
                year = [referenceYear - 1, referenceYear, referenceYear + 1].min { a, b in
                    abs(date(a, month, day, 12, 0)?.timeIntervalSince(reference) ?? .infinity)
                        < abs(date(b, month, day, 12, 0)?.timeIntervalSince(reference) ?? .infinity)
                }
            }
            guard let year, let found = date(year, month, day, hour ?? 12, minute ?? 0) else { continue }
            // "25 Nov 2026 · 08:00", the commonest form, is written in UTC even without saying so.
            let writtenInUTC = pattern.monthName && group(pattern.year) != nil
            return Found(date: found, precise: hour != nil && (zoned || writtenInUTC))
        }
        // "Today 20:00", "Tomorrow".
        let lower = text.lowercased()
        for (word, offset) in [("today", 0), ("tonight", 0), ("tomorrow", 1)] where lower.contains(word) {
            let day = utc.date(byAdding: .day, value: offset, to: utc.startOfDay(for: now)) ?? now
            return Found(date: day.addingTimeInterval(12 * 3600), precise: false)
        }
        return nil
    }

    /// The text without any dates or times, so they aren't read as part of a team's name.
    static func removingDates(_ text: String) -> String {
        var result = text
        for pattern in patterns {
            result = pattern.regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                            withTemplate: " ")
        }
        return result.replacingOccurrences(of: #"\b\d{1,2}[:.h]\d{2}\b\s*(?:utc|gmt|[ap]m)?"#, with: " ",
                                           options: [.regularExpression, .caseInsensitive])
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date? {
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        guard let date = utcCalendar.date(from: components),
              utcCalendar.component(.day, from: date) == day else { return nil }
        return date
    }
}
