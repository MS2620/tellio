// Checks for addon listing matching (Sources/Services/SportsMatching.swift): team names in
// listing titles, dates in titles, and how a listing becomes a row's title and channel.
// Run with Scripts/test-matching.sh; GitHub runs it on every pull request.
// Use made-up channel names here, never real providers or addons.

import Foundation

func team(_ name: String, aliases: [String] = [], code: String?) -> ListingMatcher.Team {
    let full = GuideText.phrase(name)
    let others = TeamNames.aliases(name, extra: aliases).filter { $0 != full }
    let names = ([full] + others.sorted { $0.count > $1.count }).filter { $0.count >= 3 }
    return ListingMatcher.Team(names: names, code: code)
}

let wolves = team("Wolverhampton Wanderers", aliases: ["Wolves"], code: "WOL")
let manU = team("Manchester United", aliases: ["Man United"], code: "MUN")
let liverpool = team("Liverpool", code: "LIV")
let brighton = team("Brighton & Hove Albion", aliases: ["Brighton"], code: "BHA")
let arsenal = team("Arsenal", code: "ARS")
let bayern = team("Bayern Munich", aliases: ["Bayern"], code: "BAY")
let psg = team("Paris Saint-Germain", aliases: ["PSG"], code: "PSG")
let stEtienne = team("Saint-Étienne", code: "STE")
let lyon = team("Olympique Lyonnais", aliases: ["Lyon"], code: "LYON")

// (title, home, away, should match)
let cases: [(String, ListingMatcher.Team, ListingMatcher.Team, Bool)] = [
    ("MUN v LIV", manU, liverpool, true),
    ("MUN-LIV", manU, liverpool, false),            // no spaces: not split (kept conservative)
    ("MUN - LIV", manU, liverpool, true),
    ("LIV @ MUN", manU, liverpool, true),           // swapped sides
    ("Wolverhampton Wanderes v Man Utd", wolves, manU, true),   // typo
    ("Wolves vs Manchester Utd", wolves, manU, true),
    ("Premier League: Brighton & Hove v Arsenal | 20:00", brighton, arsenal, true),
    ("EPL - Brighton - Arsenal", brighton, arsenal, true),
    ("Arsenal W v Brighton W", arsenal, brighton, false),   // women's teams
    ("Bayern Munchen v PSG", bayern, psg, true),
    ("Bayern München II v Paris SG", bayern, psg, false),   // reserves
    ("Saint-Etienne vs Lyon (Ligue 1) [HD]", stEtienne, lyon, true),
    ("St Etienne v Lyon", stEtienne, lyon, true),
    ("Brighton and Hove Albion v Arsenal", brighton, arsenal, true),
    ("Bayern v Man Utd", bayern, manU, true),
    ("Man Utd v Bayern Munich 2 Jan 2027 · 20:00", bayern, manU, true),
    ("Manchester v Liverpool", manU, liverpool, false),     // which Manchester?
    ("Man City v Liverpool", manU, liverpool, false),
    ("Liverpool v Everton", manU, liverpool, false),
    ("Arsenal v Liverpool", manU, liverpool, false),
    ("LIVE: Man Utd x Liverpool 25/11 20:00", manU, liverpool, true),
    ("United v Liverpool", manU, liverpool, false),         // too vague
    ("Wolves U21 v Man Utd U21", wolves, manU, false),
    ("Example Sports Main Event", manU, liverpool, false),
    // A channel carrying the game in brackets
    ("US| EXAMPLE TV PPV 055 [Wolves vs. Man Utd]", wolves, manU, true),
    ("UK: Example Sports 2 (Liverpool v Manchester United)", manU, liverpool, true),
    ("EXAMPLE TV 12 [Arsenal v Brighton W]", arsenal, brighton, false),
    ("EXAMPLE TV 12 [Liverpool v Everton]", manU, liverpool, false),
    ("EXAMPLE TV 12 [HD] Bayern v PSG", bayern, psg, false),   // no separator before the game: left to the exact check
    ("EXAMPLE TV 12 [HD]", bayern, psg, false),
]

var failed = 0
for (title, home, away, expected) in cases {
    let got = ListingMatcher.isMatch(title, home: home, away: away)
    if got != expected { failed += 1 }
    print(got == expected ? "ok  " : "FAIL", expected ? "match   " : "no match", "|", title, got != expected ? "→ got \(got)" : "")
}

// Dates: (text, expected UTC "yyyy-MM-dd HH:mm" or nil, precise)
let f = DateFormatter(); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd HH:mm"; f.locale = Locale(identifier: "en_US_POSIX")
let ref = f.date(from: "2026-11-25 20:00")!
let now = f.date(from: "2026-11-24 10:00")!
let dates: [(String, String?, Bool)] = [
    ("Arsenal v Spurs · 25 Nov 2026 · 08:00", "2026-11-25 08:00", true),
    ("2026-11-25T20:00Z Arsenal v Spurs", "2026-11-25 20:00", true),
    ("2026-11-25 20:00 Arsenal v Spurs", "2026-11-25 20:00", false),
    ("Arsenal v Spurs 25/11/2026 19:45", "2026-11-25 19:45", false),
    ("Arsenal v Spurs 25.11. 20:00 UTC", "2026-11-25 20:00", true),
    ("Arsenal v Spurs Nov 25", "2026-11-25 12:00", false),
    ("Wed 25 Nov - Arsenal v Spurs", "2026-11-25 12:00", false),
    ("Arsenal v Spurs 11/25", "2026-11-25 12:00", false),
    ("Arsenal v Spurs 2 Jan", "2027-01-02 12:00", false),
    ("Arsenal v Spurs tomorrow", "2026-11-25 12:00", false),
    ("Arsenal v Spurs", nil, false),
]
for (text, expected, precise) in dates {
    let found = ListingDates.find(in: text, near: ref, now: now)
    let got = found.map { f.string(from: $0.date) }
    let ok = got == expected && (found == nil || found!.precise == precise)
    if !ok { failed += 1 }
    print(ok ? "ok  " : "FAIL", "|", text, "→", got ?? "none", found.map { $0.precise ? "precise" : "day only" } ?? "")
}
// Row titles: (listing, title, channel)
let titles: [(String, String, String?)] = [
    ("US| EXAMPLE TV PPV 055 [Wolves vs. Man Utd]", "Wolves vs. Man Utd", "EXAMPLE TV PPV 055"),
    ("(FHD) : EXAMPLE SPORTS PREMIER", "EXAMPLE SPORTS PREMIER", nil),
    ("UK: Example Sports 2 (Liverpool v Everton)", "Liverpool v Everton", "Example Sports 2"),
    ("Arsenal v Spurs", "Arsenal v Spurs", nil),
    ("[HD] Example Sports 1", "Example Sports 1", nil),
]
for (listing, title, channel) in titles {
    let parts = ListingTitle.parts(listing)
    let ok = parts.title == title && parts.channel == channel
    if !ok { failed += 1 }
    print(ok ? "ok  " : "FAIL", "|", listing, "→", parts.title, "/", parts.channel ?? "-")
}
print(failed == 0 ? "\nAll passed" : "\n\(failed) failed")
if failed > 0 { exit(1) }
