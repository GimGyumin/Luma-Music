<p align="center">
  <img src="./Luma-Music-README-Hero.png" alt="Luma Music" width="100%">
</p>

<h1 align="center">Luma Music</h1>

<p align="center">
  <strong>Your music. The experience it deserves.</strong><br>
  A beautiful, native listening experience for your own music library.
</p>

<p align="center">
  <a href="#discover-luma">Explore</a> &nbsp; · &nbsp;
  <a href="./docs/ROADMAP.md">Roadmap</a> &nbsp; · &nbsp;
  <a href="#get-luma-music">Get the IPA</a> &nbsp; · &nbsp;
  <a href="https://github.com/GimGyumin/Luma-Music/issues">Give feedback</a>
</p>

<p align="center">
  <sub>iPhone & iPad — IPA preview &nbsp; | &nbsp; macOS — Coming next year (2027)</sub>
</p>

<p align="center"><sub>Navidrome · OpenSubsonic-compatible servers · Supported Jellyfin libraries</sub></p>

<p align="center">
  <sub>We're still polishing Luma Music and this repository. A stable 1.0 release is planned for 2026.</sub><br>
  <sub>If you like the project, consider giving it a ⭐ on GitHub. It really helps!</sub>
</p>

---

## Discover Luma

<p align="center">
  <img src="./assets/screenshots/now-playing.jpg" alt="Immersive Now Playing screen" width="30%" />
  <img src="./assets/screenshots/lyrics-translation.jpg" alt="Synchronized lyrics and translation" width="30%" />
  <img src="./assets/screenshots/lyrics-pronunciation.jpg" alt="Synchronized lyrics with available pronunciation" width="30%" />
</p>
<p align="center"><sub>Now Playing &nbsp; · &nbsp; Lyrics & translation &nbsp; · &nbsp; Pronunciation</sub></p>

<p align="center">
  <img src="./assets/screenshots/album-page-hopeless-romantic.jpg" alt="Luma Music immersive album page — Hopeless Romantic" width="30%" />
  <img src="./assets/screenshots/lock-screen-childhood.jpg" alt="Luma Music Lock Screen playback — Childhood" width="30%" />
</p>
<p align="center"><sub>Album artwork &nbsp; · &nbsp; Lock Screen playback</sub></p>

---

## Your albums, brought to life.

Your music collection deserves more than a list of tracks. Luma brings an **Apple Music-inspired**, artwork-first interface to your personal server — with immersive color, thoughtful transitions, and album pages designed to let the artwork shine.

Immersive presentation is available for **compatible album covers only**. The result can vary with the cover, device, and supported system features.

## Lyrics that move with the music.

Follow each line with fluid animations and **TTML word-timed highlighting** whenever compatible timing data is available.

Translate supported lyric text using optional Apple or OpenAI-powered features. **Pronunciation and romanization appear only if the available lyric data includes a compatible pronunciation layer**; Luma cannot supply pronunciation for every track.

Lyrics are shown when your connected server contains or supplies supported lyric data, or an enabled external source such as LRCLIB can provide them. Not every song has lyrics, translations, or word-level timing.

## Hear every moment.

Keep full albums and live performances flowing with **gapless playback** when supported. Enjoy lossless audio with compatible source files and playback routes, plus crossfade, ReplayGain, Up Next, and offline downloads.

Adaptive streaming, caching, and network recovery help your personal library fit into everyday listening.

## Details you can feel.

Fast local library search, refined artwork handling, and efficient display updates make the experience feel responsive. Supported Apple-platform integrations include Siri, Shortcuts, Spotlight, widgets, and system playback controls.

Accessibility is part of the experience, with VoiceOver, Dynamic Type, Reduce Motion, and English/Korean localization.

> Power use depends on the display brightness, device, network, source format, and playback output. Luma does not claim independently verified battery-life superiority over other players.

---

## Get Luma Music

**Available now:** iPhone and iPad preview builds are distributed as **IPA files only**.

**[Browse GitHub Releases](https://github.com/GimGyumin/Luma-Music/releases)**

The new post-rebrand IPA build has **not been uploaded yet**. The Releases page currently includes the earlier [RC1 preview](https://github.com/GimGyumin/Luma-Music/releases/tag/v1.0.0-rc1). Please check the release tag before installing.

To install a published IPA:

1. Download the IPA from the relevant [GitHub release](https://github.com/GimGyumin/Luma-Music/releases).
2. Sign and install it on an eligible iPhone or iPad using a compatible solution such as SideStore or AltStore.
3. Open Luma Music and connect to **your own** compatible music server.

**No App Store or TestFlight distribution is currently available.** Luma does not provide a music streaming catalog. Signing methods and some system integrations may have entitlement requirements.

### Platform availability

| Platform | Status |
| :--- | :--- |
| **iPhone** | IPA preview · iOS 18.6 or later |
| **iPad** | IPA preview · iPadOS 18.6 or later |
| **macOS** | **Coming next year (2027)** · Not available yet |

The macOS version is in the roadmap for 2027. **No macOS release or macOS installer is currently provided**, and an iPhone/iPad IPA should not be presented as a macOS build.

Supported servers: **Navidrome, OpenSubsonic-compatible servers, and supported Jellyfin libraries**.

Playback formats include MP3, AAC, FLAC, Ogg Vorbis, Opus, and WAV when supported by the server and playback route.

### Building and contributing

Luma is open source. The source project can be explored and built for supported iPhone/iPad development targets using a Mac, Xcode 26 or later, and the appropriate signing configuration. This is **not** an announced macOS app release.

```bash
git clone https://github.com/GimGyumin/Luma-Music.git
cd Luma-Music
open Luma.xcodeproj
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidance. Device testing is recommended for audio and background playback.

---

## Your library stays yours.

Luma connects to the music server you select, keeps credentials in the system Keychain, and has **no built-in advertising, analytics, or tracking SDKs**.

Optional external services may receive relevant data when you enable or use them:

- **Lyrics:** Optional LRCLIB fallback can send track title, artist, album, and duration. Disable it using **Settings → Lyrics → Source → Server only**.
- **Translation:** Optional OpenAI translation sends lyric text to the selected provider. Apple translation depends on device and OS support.
- **Metadata:** Optional lookups through MusicBrainz, Wikidata, Wikipedia, and Cover Art Archive can send artist or album information.

Unencrypted HTTP server connections require explicit confirmation. Use HTTPS where possible.

## Made to grow with your music.

[Report an issue](https://github.com/GimGyumin/Luma-Music/issues) &nbsp; · &nbsp; [Roadmap](docs/ROADMAP.md) &nbsp; · &nbsp; [Contribute](CONTRIBUTING.md) &nbsp; · &nbsp; [Releases](https://github.com/GimGyumin/Luma-Music/releases)

The repository, documentation, and release experience are still being refined. If Luma Music is useful to you, a [⭐ GitHub star](https://github.com/GimGyumin/Luma-Music) is a great way to support its development.

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
