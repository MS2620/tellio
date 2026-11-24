<p align="center">
  <img src="https://ms2620.github.io/tellio-site/logo.png" width="96" alt="">
</p>

<h1 align="center">Tellio</h1>

<p align="center">
  A free Apple TV player for your own Stremio addons and IPTV account.<br>
  <b>Beta</b> · tvOS 18 or later · <a href="https://ms2620.github.io/tellio-site/">Website</a> · <a href="https://ms2620.github.io/tellio-site/install.html">Install guide</a> · <a href="https://github.com/MS2620/tellio/releases">Download</a>
</p>

<p align="center">
  <img src="https://ms2620.github.io/tellio-site/screens/home.webp" width="720" alt="Tellio's Home screen on an Apple TV">
</p>

Tellio is a native tvOS app that plays what **you** bring: your IPTV provider's Xtream Codes login for live TV, and your Stremio addons for films and series. It adds artwork, a proper TV guide, sports, Trakt sync and more on top.

> **Tellio doesn't include any channels, films or streams.** It only plays what your own IPTV account and addons provide. Use services you're entitled to.

## Features

- **Films & series:** trending, popular and new titles with seasons, episodes and cast. Streams come from your addons, filtered by quality.
- **Live TV with a real guide:** a full programme guide, favourites, folders, recent channels, search and reminders.
- **Sports:** your teams' fixtures, live scores, league tables and F1 standings. Tellio finds the channel showing the match in your guide.
- **Multiview:** up to four live channels at once.
- **Continue Watching:** pick up where you left off, with optional Trakt sync.
- **Top Shelf:** live games, Continue Watching and what's coming up on the Apple TV home screen.
- **Several IPTV accounts:** switch between them from the Live TV sidebar.
- **Parental PIN, eight appearances, and backup & restore** to a server you run yourself.

## Install

Tellio isn't on the App Store. There are two ways to install it:

- **[Signulous](https://www.signulous.com)** (paid, about $16 a year for an Apple TV): register your Apple TV with *tvOS Code Signing*, upload **Tellio.ipa** from the latest [release](https://github.com/MS2620/tellio/releases) with every option left unticked, and install. No computer needed at home.
- **[atvloadly](https://github.com/bitxeno/atvloadly)** (free): runs in Docker on a Linux computer, Raspberry Pi or NAS at home, signs Tellio with a spare Apple ID and keeps it signed.

**Sideloaders that read AltStore sources** (such as ATVLoadly and FlareStore) can add this one to install Tellio and get each new build as an update:

```
https://raw.githubusercontent.com/MS2620/tellio/altstore/altstore-tvos.json
```

It lists the 10 newest builds and is updated after each one is published. For iPhone and iPad, see [Tellio for iPhone and iPad](https://github.com/MS2620/tellio-iOS#install).

The [install guide](https://ms2620.github.io/tellio-site/install.html) walks through Signulous and atvloadly, with troubleshooting. Tellio tells you when a newer build is out; install it over the old one and your settings are kept.

## Known limitations

- IPTV must use Xtream Codes logins; M3U playlist links aren't supported yet.
- Only addon results with a direct link play; torrent-only results are hidden.
- Installing needs Signulous or atvloadly; there's no App Store or TestFlight version yet.
- Backup & restore needs a backup server you run yourself (see [`server/`](server)).
- The Top Shelf can stay blank after an install; reinstalling usually fixes it.
- Tested with a small number of providers and addons so far. Expect rough edges.

## Privacy

- Your logins, addons and watch history stay on your Apple TV, in its Keychain. There's no Tellio account.
- Crash reports go to Sentry. They contain no logins, stream links, server or channel names, IP address or watch history. Turn them off in **Settings › About**.
- Feedback sent from the app becomes a public issue here. A contact you leave for a reply is kept private and never posted.
- Tellio asks TMDB, ESPN and Jolpica for film and sports information, and Trakt only if you sign in.

## Feedback and problems

There are two ways to report a problem or suggest an idea:

- **From the Apple TV:** Settings › About › Send feedback. It becomes an issue here for you.
- **Directly on GitHub:** [open an issue](https://github.com/MS2620/tellio/issues/new). You need a GitHub account, and you can add screenshots.
- **Fix it yourself:** pull requests are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md).

Either way, say what you did, what happened, and your Tellio build number (in Settings › About). Please don't post logins, server addresses or addon links.

## Licence

Tellio is **not open source**, but contributions are welcome. You can download the official builds and use them on your own devices, read the code, and fork it to fix bugs or add features and send them back as a pull request. You may not publish your own copies or versions of Tellio, or reuse its code elsewhere. See [LICENSE](LICENSE) and [CONTRIBUTING.md](CONTRIBUTING.md).

## Third-party software

Tellio builds include these components, each under its own licence. The exact versions in each build are listed in its release notes.

- [AetherEngine](https://github.com/superuser404notfound/AetherEngine): LGPL-3.0 with an App Store exception. Tellio uses it unmodified.
- [FFmpegBuild](https://github.com/superuser404notfound/FFmpegBuild) (FFmpeg and related libraries), linked dynamically: LGPL; licence texts are in that repository's `LICENSES` folder.
- [libdovi](https://github.com/quietvoid/dovi_tool) (Dolby Vision metadata), Copyright (c) quietvoid and contributors: MIT.
- [Anime4K](https://github.com/bloc97/Anime4K) (line-art upscaling, inside AetherEngine), Copyright (c) 2019-2021 bloc97: MIT.
- [Sentry Cocoa SDK](https://github.com/getsentry/sentry-cocoa): MIT.

The full licence texts are in the app under Settings › About › Acknowledgements, and in [`Resources/Licenses`](Resources/Licenses).

## Credits

Film and TV information and artwork from [TMDB](https://www.themoviedb.org). This product uses the TMDB API but is not endorsed or certified by TMDB. Playback by [AetherEngine](https://github.com/superuser404notfound/AetherEngine).

Tellio isn't affiliated with Apple, Stremio, TMDB, Trakt or ESPN. Apple TV and tvOS are trademarks of Apple Inc.

---

## For developers

Tellio is SwiftUI, built without a Mac: GitHub Actions generates the Xcode project with XcodeGen, builds an unsigned IPA on every push to `main`, and publishes it as a pre-release.

```
project.yml                  XcodeGen spec (the .xcodeproj is generated on CI)
Sources/
  TellioApp.swift            App entry and tab bar
  Core/                      Settings, Keychain, backup, crash reports, feedback
  Services/                  TMDB, Stremio addons, Xtream, sports, Trakt
  Player/                    AetherEngine player
  Views/                     All screens
TopShelf/, Shared/           Top Shelf extension and what it shares with the app
server/                      Backup and feedback service (Docker)
.github/workflows/build.yml  CI: unsigned build and pre-release, optional TestFlight
```

Needs Xcode 27 (for AetherEngine); CI uses the `xcode-27` runner.

**Build settings from GitHub (Settings › Secrets and variables › Actions).** All optional; a build without one simply leaves that feature for the user to set up, or off.

| Name | Kind | What it's for |
|---|---|---|
| `TMDB_TOKEN` | secret | Built-in TMDB read access token |
| `TRAKT_CLIENT_ID` | secret | Built-in Trakt app (PKCE device sign-in) |
| `SENTRY_DSN` | secret | Crash reports |
| `SENTRY_AUTH_TOKEN` | secret | Uploads debug symbols to Sentry |
| `SENTRY_ORG` | variable | Sentry organisation slug for the symbol upload |
| `FEEDBACK_URL` | secret | Address of the backup and feedback service |

**TestFlight** (paid Apple Developer account): register the bundle ID `com.mauro.tellio`, create a tvOS app in App Store Connect, add an Admin API key as the secrets `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8_BASE64` (`base64 -w0 AuthKey_XXXX.p8`) and `APPLE_TEAM_ID`, then set the variable `ENABLE_TESTFLIGHT` to `true`.

**Codemagic** works too: `codemagic.yaml` has a *tvOS unsigned IPA* workflow.
