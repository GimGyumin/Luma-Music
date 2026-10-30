# Luma-Music

Luma Music is an AI-assisted, open-source iOS music player inspired by Apple Music. It brings a beautiful, native listening experience to Navidrome and OpenSubsonic, featuring synchronized lyrics, lossless audio, gapless playback, smooth animations, and seamless iOS integration.

## Build from source

**Requirements:** macOS with Xcode 26 or later. The app targets **iOS 18.6+** and **macOS 15.6+**.

```sh
git clone https://github.com/GimGyumin/Luma-Music.git
cd Luma-Music
open Luma.xcodeproj
```

Select the `Luma` scheme, set your team under **Signing & Capabilities**, then build and run.
Swift Package Manager resolves SwiftSonic and AudioStreaming automatically — no extra setup.

**Audio note:** FLAC/AAC playback, gapless transitions and audio-session behaviour differ in the
Simulator. Verify playback changes on a device.

## Privacy

No analytics, no telemetry, no Luma account. Luma talks to the music server you configure.

Optional integrations are contacted only after you enable them, with one default exception: when
the server has no synced lyrics, Luma falls back to **LRCLIB**, sending only the track title,
artist, album and duration. Set **Settings → Lyrics → Source → Server only** to prevent that.
Artist and release gaps may also be filled from MusicBrainz, Wikidata, Wikipedia and Cover Art
Archive using the artist or album name.

## Credits and Licensing

Luma Music is an AI-assisted, open-source music player
developed from the Cassette project.

- [Cassette](https://github.com/CassetteLab/cassette) — Mozilla Public License 2.0
- [Apple Music Like Lyrics (AMLL)](https://github.com/amll-dev/applemusic-like-lyrics) — AGPL-3.0-only

The repository includes components under different licenses.
The root MPL-2.0 license does not relicense the AMLL-derived code.

See [NOTICE](NOTICE), [COPYRIGHT](COPYRIGHT), and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for
copyright attribution and third-party licensing details.

Distribution of combined application binaries requires
compliance with all applicable license terms. Because the app links the
AMLL-derived code, a distributed binary of the combined work must also
satisfy AGPL-3.0, including the corresponding-source obligation.
