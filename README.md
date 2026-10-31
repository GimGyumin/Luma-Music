Luma Music

Your music, beautifully.

A beautiful, native music player for your personal library on iPhone, iPad, and Mac.

Luma Music is an AI-assisted, open-source music player designed to bring your personal music collection to life.

Built for Navidrome, OpenSubsonic-compatible servers, and supported Jellyfin libraries, Luma Music combines high-quality audio playback, synchronized lyrics, offline listening, and powerful library management with a beautiful, artwork-focused interface inspired by Apple Music.

Your music. Your server. Your listening experience.

⸻

✨ Highlights

* Beautiful Native Interface — An artwork-focused listening experience designed for Apple platforms.
* High-Quality Audio — Lossless streaming, gapless playback, crossfade, and ReplayGain.
* Synchronized Lyrics — Line-by-line and karaoke-style highlighting, with optional translation.
* Offline Listening — Download songs, albums, and playlists for listening anywhere.
* Intelligent Search — Fast local library indexing, categorized search, and Spotlight integration.
* Apple Ecosystem Integration — Siri, Shortcuts, widgets, and native system playback controls.
* Adaptive Streaming — Automatic quality management, intelligent caching, and network recovery.
* Accessibility — VoiceOver, Dynamic Type, Reduce Motion, and localized accessibility support.
* Privacy First — No Luma Music account, analytics, or telemetry.

⸻

📥 Download

Get the latest available version of Luma Music from GitHub Releases.

Download Luma Music

Installation

Luma Music is distributed as an IPA package for compatible Apple devices.

1. Download the IPA from the latest available GitHub release.
2. Install the app using a compatible sideloading solution, such as SideStore or AltStore.
3. Open Luma Music.
4. Connect to your supported music server.
5. Sign in and enjoy your personal music library.

Note

Sideloading requires a compatible signing method. Some system integrations may depend on signing entitlements, hardware, and operating-system capabilities.

⸻

🎵 Music Playback

Enjoy your collection with flexible playback options and high-quality streaming.

* Lossless audio playback when supported by the server, source files, and playback configuration.
* Gapless playback for supported albums and live recordings.
* Crossfade for smooth transitions between songs.
* ReplayGain with clipping protection for consistent perceived loudness.
* Adaptive streaming quality based on network conditions.
* Manual audio quality selection, including Lossless, AAC, and Opus options when supported.
* Playback queue management with shuffle, repeat, and Up Next.
* Reliable playback recovery during eligible network interruptions.
* System Now Playing integration with artwork and playback controls.

Supported audio formats include MP3, AAC, FLAC, Ogg Vorbis, Opus, and WAV through compatible playback routes.

⸻

💿 Music Library

Explore your personal music collection through a unified, artwork-rich interface.

* Browse artists, albums, songs, playlists, and supported radio collections.
* Explore dedicated artist and album pages.
* Create and manage supported playlists.
* Organize music with library sorting options.
* Access recently played and pinned content.
* Enhance available metadata through optional integrations.
* Configure multiple music servers with one active server at a time.
* Keep cached information and downloaded media associated with their respective server accounts.

⸻

🎤 Synchronized Lyrics

Experience lyrics that follow your music.

* Time-synchronized lyrics with automatic line highlighting.
* Karaoke-style word highlighting when compatible timing information is available.
* Smooth scrolling and lyric transitions.
* Server-provided lyrics with optional LRCLIB fallback.
* Optional lyric translation through supported integrations and compatible on-device capabilities.
* Lyric caching for faster loading and reduced network requests.
* Configurable lyric sources for greater control over external services.

⸻

🔎 Search & Discovery

Find the music you want without losing your place.

* Fast local library indexing.
* Search across songs, albums, artists, and playlists.
* Categorized search results.
* Search history.
* Spotlight indexing for supported library content.
* Direct navigation from Spotlight into Luma Music.
* Server-aware indexing to keep results associated with the correct library.

⸻

📶 Offline Listening

Your music should be available even when your connection is not.

* Download songs, albums, and playlists.
* Browse downloaded music without contacting your server.
* Configure download quality and streaming preferences.
* Resume or repair interrupted downloads when supported.
* Use separate Wi-Fi and cellular quality settings.
* Benefit from intelligent caching and network recovery.
* Keep downloads and cached media separated by server account.

⸻

🍎 Apple Ecosystem

Luma Music is designed to feel at home on Apple devices.

* Native interfaces for iPhone, iPad, and Mac.
* Lock Screen and Control Center playback controls.
* Siri and Shortcuts integration.
* Spotlight search integration.
* Widgets and supported Live Activities.
* Background audio playback.
* System Now Playing integration.
* English and Korean localization.

Some features require compatible operating-system versions, devices, or signing capabilities.

⸻

♿ Accessibility

Accessibility is part of the Luma Music experience.

* VoiceOver labels, hints, and accessibility traits.
* Dynamic Type support for compatible interface elements.
* Reduce Motion support.
* Low Power Mode-aware visual effects.
* English and Korean accessibility labels.

⸻

🔐 Privacy & Security

Your music library remains under your control.

Luma Music does not require a separate account and does not include built-in analytics or telemetry.

Your music library remains on the server you configure. Downloaded music and cached information are stored locally as needed.

* Server credentials are stored in the system Keychain.
* Server-specific caches and downloads remain separated.
* Unencrypted HTTP connections require explicit confirmation.
* Optional integrations can be controlled through the app’s settings.

External Services

Luma Music can contact external services for lyrics and additional music metadata.

Lyrics: When the server does not provide synchronized lyrics, Luma Music may automatically fall back to LRCLIB. This sends the track title, artist, album, and duration.

To disable this fallback, select:

Settings → Lyrics → Source → Server only

Metadata: Missing artist or release information may be retrieved from MusicBrainz, Wikidata, Wikipedia, or Cover Art Archive using artist or album names.

These integrations may involve sharing relevant music metadata with their respective services.

⸻

📱 Compatibility

Platform	Minimum OS version
iPhone	iOS 18.6 or later
iPad	iPadOS 18.6 or later
Mac	macOS 15.6 or later

Supported Servers

* Navidrome
* OpenSubsonic-compatible servers
* Supported Jellyfin libraries

Available features, audio formats, transcoding options, lyrics, and metadata depend on the connected server and source files.

⸻

🛠️ Build from Source

Luma Music is open source and can be built using Xcode.

Requirements

* macOS with Xcode 26 or later
* A compatible Apple development environment
* A supported iPhone, iPad, Mac, or simulator
* A configured development signing team when required

Clone the Repository

git clone https://github.com/GimGyumin/Luma-Music.git
cd Luma-Music

Open the Project

open Luma.xcodeproj

Build and Run

1. Open the project in Xcode.
2. Select the Luma scheme.
3. Select your target device or simulator.
4. Configure your development team under Signing & Capabilities.
5. Build and run the application.

Swift Package Manager resolves dependencies such as SwiftSonic and AudioStreaming automatically.

Audio Testing

FLAC/AAC playback, gapless transitions, and audio-session behavior may differ in the Simulator. Verify audio playback and related changes on a physical device.

⸻

🤝 Contributing

Contributions, bug reports, and suggestions are welcome.

If you encounter an issue or have an idea for improving Luma Music, you can open an issue or submit a pull request.

Please read CONTRIBUTING.md before contributing.

* Report a Bug
* View Pull Requests
* Browse Releases

⸻

📜 Credits & Licensing

Luma Music is an AI-assisted, open-source music player developed from the Cassette project.

The project builds upon existing open-source work and includes components governed by different licenses.

Acknowledgements

* Cassette — Mozilla Public License 2.0 (MPL-2.0)
* Apple Music Like Lyrics (AMLL) — GNU Affero General Public License v3.0 only (AGPL-3.0-only)

Licensing

The repository’s root license is Mozilla Public License 2.0 (MPL-2.0).

However, some components are subject to additional license requirements.

The root MPL-2.0 license does not relicense AMLL-derived code.

Because the application links AMLL-derived code, distribution of a combined application binary must comply with all applicable license terms, including the AGPL-3.0 corresponding-source obligations.

For detailed copyright attribution and third-party licensing information, see:

* LICENSE
* NOTICE
* COPYRIGHT
* THIRD_PARTY_NOTICES.md

Distributors and contributors are responsible for complying with the licenses applicable to the components they use or redistribute.

⸻

❤️ About Luma Music

Luma Music was created to make listening to a personal music library feel beautiful, intuitive, and deeply integrated with Apple devices.

It brings together the freedom of self-hosted music with the experience of a modern native music player.

Your music. Your library. Your experience.

⸻

Luma Music

Your music, beautifully.

Made for your music. Designed for Apple platforms.
