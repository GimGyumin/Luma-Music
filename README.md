<p align="center">
  <img src="./Luma-Music-README-Hero.png" alt="Luma Music — Your music, beautifully." width="100%">
</p>

<h1 align="center">Luma Music</h1>
<p align="center"><strong>Your music. The experience it deserves.</strong></p>
<p align="center">An immersive, Apple Music-inspired player for the music you own.</p>
<p align="center">
  <a href="#release-and-installation"><strong>Release & installation</strong></a>
  · <a href="#the-luma-experience">Explore the experience</a>
  · <a href="https://github.com/GimGyumin/Luma-Music/issues">Share feedback</a>
</p>
<p align="center"><sub>Navidrome · OpenSubsonic-compatible servers · Supported Jellyfin libraries</sub></p>

---

Luma Music brings the polish of a native Apple music app to **your own self-hosted library**. Discover your albums through expressive artwork, follow beautifully animated lyrics, and listen with the continuity your favorite records deserve.

**No separate Luma account. No built-in analytics or tracking. Your server, your collection.**

## See Luma Music in action

<p align="center">
  <img src="./assets/screenshots/now-playing.jpg" alt="Luma Music immersive Now Playing screen" width="29%" />
  <img src="./assets/screenshots/lyrics-translation.jpg" alt="Synchronized lyrics with Korean translation" width="29%" />
  <img src="./assets/screenshots/lyrics-pronunciation.jpg" alt="Synchronized lyrics with romanized pronunciation" width="29%" />
</p>
<p align="center"><sub>Immersive Now Playing · Synchronized lyrics & translation · Pronunciation when supported</sub></p>

<p align="center">
  <img src="./assets/screenshots/album-page.jpg" alt="Artwork-focused Luma Music album page" width="29%" />
  <img src="./assets/screenshots/lock-screen.jpg" alt="Album-color coordinated Lock Screen music controls" width="29%" />
</p>
<p align="center"><sub>Artwork-focused album pages · Lock Screen playback controls</sub></p>

> Lyrics appear only when the connected server or a supported lyric source can provide them. Word-timed karaoke requires compatible timing data, and pronunciation appears only when compatible pronunciation data is available. Some album covers may not support immersive artwork.

## The Luma experience

### 01 — Your album artwork, brought to life

**Music should look as good as it sounds.**

- Immersive artwork presentations across Now Playing, albums, and supported Lock Screen experiences **when the album artwork and device support them**. Some album covers may not be compatible with the immersive presentation.
- Artwork-driven colors, fluid transitions, and a native interface for Apple platforms.
- Designed to put the album and the listening experience first — not another dashboard.

### 02 — Lyrics that feel alive

**More than a scrolling wall of text.**

- Smooth, synchronized line-by-line lyrics and **TTML word-timed karaoke** when compatible lyrics and timing data are available from the connected server or a supported lyric source.
- Optional **AI-assisted lyric translation** using supported Apple or OpenAI integrations.
- Translation of available lyric text through supported optional integrations.
- Pronunciation/romanization display **only when the supplied lyrics include a supported pronunciation layer**. Luma does not generate pronunciation for every track.
- Lyrics from a connected server when it has supported lyric data or provides them through a compatible feature; optional LRCLIB fallback may supply lyrics where available. Lyrics are not guaranteed for every song.

**What to expect:** Lyrics appear only when the server or a configured compatible source can provide them. Translation requires available lyric text; karaoke-style word animation additionally requires compatible timing data. **Pronunciation appears only for lyrics that provide compatible pronunciation data.** Not every track or language has the same coverage, and optional translation features may require setup or compatible hardware/software.

### 03 — Listen to the album, not the gaps

**Keep the music flowing.**

- Gapless playback for supported tracks, albums, and live recordings.
- Lossless audio where the source, server, and playback route allow it.
- Crossfade, ReplayGain, Up Next controls, shuffle, and repeat.
- Offline downloads, caching, and network recovery for everyday listening.

### 04 — Built to feel effortless

**Polished visuals without ignoring performance.**

Luma is designed with attention to efficient UI updates, adaptive effects, and background work. Performance and power usage remain ongoing priorities, with real-device testing guiding improvements.

- Local indexing and categorized library search.
- Siri and Shortcuts support, Spotlight integration, widgets, and system playback controls where supported.
- VoiceOver, Dynamic Type, Reduce Motion, and English/Korean localization.

> Battery life depends on device, display brightness, media format, network, and audio output. We do not claim an independently verified battery-life advantage over other players.

## Release and installation

**The next Luma Music IPA build will be uploaded after the GitHub page rebrand is completed.** The upcoming build is not available to download yet.

**[Check GitHub Releases for available builds](https://github.com/GimGyumin/Luma-Music/releases)**

Luma Music is distributed **as an IPA only**, using a compatible signing and sideloading method; there is currently **no App Store or TestFlight distribution**. An earlier preview release may still appear on the Releases page, but it is not the upcoming rebranded build.

**Once the new IPA is published:**

1. Open [Releases](https://github.com/GimGyumin/Luma-Music/releases) and select the newly published build.
2. Download the IPA and install it on a compatible iPhone or iPad using SideStore, AltStore, or another suitable signing/sideloading solution.
3. Launch Luma Music and connect to your own Navidrome, OpenSubsonic-compatible, or supported Jellyfin server.

**You need your own music server and library.** Luma does not provide a streaming music catalog. macOS source code can be built with Xcode; an iOS/iPadOS IPA is not a standalone macOS installer.

> Some features depend on OS version, device capabilities, source files, server responses, and signing entitlements. If installation fails, please [report the device, OS version, signing method, and error](https://github.com/GimGyumin/Luma-Music/issues).

## Compatibility & capabilities

| | Supported configuration |
| --- | --- |
| **iPhone** | iOS 18.6 or later |
| **iPad** | iPadOS 18.6 or later |
| **Mac** | macOS 15.6 or later (build from source) |
| **Servers** | Navidrome, OpenSubsonic-compatible servers, and supported Jellyfin libraries |
| **Playback** | MP3, AAC, FLAC, Ogg Vorbis, Opus, WAV via compatible playback routes |
| **Languages** | English, Korean |

Some codecs, transcoding paths, lyric formats, audio enhancements, and integrations depend on server and device support. Immersive artwork is not available for every album cover.

## Built for your library, with your privacy in mind

Luma Music connects to the music server you choose, uses the system Keychain for server credentials, and does **not** include built-in analytics or telemetry.

Optional external features can send data to their respective providers:

- **Lyrics:** An enabled LRCLIB fallback sends track metadata (title, artist, album, and duration). To disable it, choose **Settings → Lyrics → Source → Server only**.
- **Translation:** When optional OpenAI translation is selected and configured, lyric text is sent to that service for translation. Apple translation capabilities depend on the device and OS.
- **Metadata:** Services such as MusicBrainz, Wikidata, Wikipedia, and Cover Art Archive may receive artist or album metadata used for lookups.

Unencrypted HTTP server connections require explicit confirmation; use a secure connection when possible.

## Build from source

**Requirements:** macOS, Xcode 26 or later, and a suitable Apple signing configuration.

    git clone https://github.com/GimGyumin/Luma-Music.git
    cd Luma-Music
    open Luma.xcodeproj

Choose the **Luma** scheme in Xcode and configure **Signing & Capabilities**. Swift Package Manager resolves project dependencies. Test audio changes on a physical device: Simulator behavior can differ for playback and audio sessions.

## Contribute & stay in touch

Luma Music is open source and welcomes bug reports, improvement ideas, and pull requests.

- [Releases — check for the upcoming IPA](https://github.com/GimGyumin/Luma-Music/releases)
- [Report an issue or request a feature](https://github.com/GimGyumin/Luma-Music/issues)
- [Contributing guide](CONTRIBUTING.md)

---

## 📜 Credits & Licensing

Luma Music is an **AI-assisted, open-source music player developed from the Cassette project**.

### Acknowledgements

- **Cassette** — Mozilla Public License 2.0 (MPL-2.0).
- **Apple Music Like Lyrics (AMLL)** — GNU Affero General Public License v3.0 only (AGPL-3.0-only).

The repository's root license is **Mozilla Public License 2.0 (MPL-2.0)**. The repository also contains components governed by different licenses; the root license **does not relicense AMLL-derived code**.

Distribution of combined application binaries requires compliance with all applicable license terms. Because the application links AMLL-derived code, distributing the combined work must also satisfy applicable AGPL-3.0 requirements, including corresponding-source obligations.

For copyright attribution and third-party licensing details, see:

- [LICENSE](LICENSE)
- [NOTICE](NOTICE)
- [COPYRIGHT](COPYRIGHT)
- [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)

> **Licensing note:** The exact obligations for a distributed binary depend on the components and their manner of combination. Review the applicable licenses before redistribution.

---

<p align="center"><strong>Luma Music</strong><br><em>Your music. The experience it deserves.</em></p>
