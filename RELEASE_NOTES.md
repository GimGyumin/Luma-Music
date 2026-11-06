# Luma Music 1.0 RC1

> **Archived RC1 notes.** RC1 is an iPhone/iPad IPA preview, **not** the final stable release. No TestFlight/App Store distribution or dedicated macOS app is currently offered. Refer to the [README](README.md) and [Roadmap](docs/ROADMAP.md) for current availability.

Luma Music 1.0 RC1 is the first public release candidate of Luma Music, a native music player for personal libraries hosted on Navidrome, OpenSubsonic, and supported Jellyfin servers. It brings streaming, downloads, synchronized lyrics, and library browsing together in an interface designed for iPhone and iPad. Your library remains on the server you configure, while Luma provides the playback controls, artwork, and navigation needed to make that library feel at home on Apple platforms.

This release focuses on a complete listening experience: browse a large library with local indexing, start playback from an album or playlist, continue with gapless transitions or crossfade, and return to downloaded music when a network connection is unavailable. System playback controls, Siri actions, Spotlight indexing, widgets, and Live Activities extend the experience beyond the app. The release candidate also includes safeguards for changing network conditions, playback recovery, cache isolation between servers, and the long-running tasks involved in preparing a library.

## Music Playback

- **Streaming playback** supports music served by Navidrome and OpenSubsonic-compatible servers, with a separate Jellyfin transport for supported Jellyfin libraries.
- **Lossless playback** can use the server's original file when the server and selected source provide it.
- **Adaptive delivery quality** chooses a stream according to the active network and can temporarily lower automatic quality after a stall, then re-evaluate the connection instead of keeping the lower quality indefinitely.
- **Quality choices** include Automatic, Lossless, AAC 256 kbps, AAC 128 kbps, and Opus 128 kbps for supported server-side delivery and downloads.
- **Gapless playback** prepares the next queue entry before the current track ends so supported consecutive tracks can transition without an intentional pause.
- **Crossfade** fades between consecutive tracks when enabled, while respecting the gapless setting and track conditions.
- **ReplayGain** can apply track or album gain with clipping protection and can be changed without rebuilding the playback session.
- **Queue and repeat controls** support queue editing, shuffle, repeat modes, next and previous track actions, and resuming a selected song from its saved position when available.
- **Seeking** provides position updates, duration-aware progress, and recovery handling when a seek or stream response takes longer than expected.
- **Audio sessions and Now Playing** keep playback controls, track information, artwork, and playback state synchronized with the operating system.
- **Supported audio delivery** depends on the server and playback route; the audio pipeline includes native handling for common formats such as MP3, AAC/M4A, FLAC, Ogg Vorbis, Opus, and WAV where available.

## Music Library

- **Library browsing** organizes artists, albums, songs, playlists, and radio-style collections for quick access to a personal catalog.
- **Album and artist views** present artwork, track lists, related information, sorting options, and available metadata from the connected server.
- **Playlist editing** lets you add tracks, remove tracks, reorder contents, and manage playlist artwork without leaving the playlist context.
- **Artwork and metadata** can use server data and optional external sources for album, artist, and release information when those integrations are enabled.
- **Library preparation** builds local metadata and artwork state so browsing and playback can continue to use information already prepared on the device.
- **Pinned and recent content** provides quicker access to frequently used library areas and playback history where the corresponding feature is enabled.
- **Multiple server configurations** can be stored securely, with one active server selected at a time and server-specific cached media kept separate.

## Lyrics

- **Synchronized lyrics** follow the current playback position and keep the active line visible as a song progresses.
- **Karaoke-style presentation** supports timed line and word highlighting where the source provides the required timing information.
- **Lyric sources** can use server-provided lyrics and optional LRCLIB lookup when server lyrics are unavailable; the lyrics source can be limited to the server in Settings.
- **Lyric translation** can translate supported lyrics through the available translation integrations, including on-device or Apple language-model capabilities when the device and system support them.
- **Lyrics caching** keeps previously retrieved lyrics available for later presentation and avoids repeating the same request unnecessarily.
- **Lyrics and player presentation** can be opened from the full player while preserving playback position and the surrounding player controls.

## Search

- **In-app search** searches the connected library for songs, albums, artists, and playlists with debounced input and categorized results.
- **Local library indexing** keeps searchable metadata on the device so repeated searches can respond without treating every keystroke as a server request.
- **Search history** remembers recent searches and provides a way to return to commonly used queries.
- **Spotlight indexing** publishes supported library entities to the system search index, including the metadata needed to open a matching song, album, artist, or playlist in Luma.
- **Search isolation** associates indexed records with the relevant server account so switching servers does not expose results from another library.
- **Optional intelligent discovery** is available only on supported system versions and hardware, and is limited to indexed library content rather than invented results.

## Offline Listening & Connectivity

- **Downloads** save selected songs, albums, and playlists for playback without an active server connection.
- **Download quality** can follow the stream or use a selected lossless, AAC, or Opus format when the server supports the requested delivery.
- **Download recovery** continues or repairs interrupted transfers and validates local files before they are presented as playable offline media.
- **Offline library views** show downloaded albums, playlists, artwork, and cached metadata so available content can be found without a network request.
- **Automatic quality by network** keeps separate Wi-Fi and cellular preferences and applies a constrained-network policy when a connection is metered or limited.
- **Network recovery** monitors reachability and retries eligible playback or preparation work without allowing an old request to take over a newer playback session.
- **Server switching** clears or isolates cached data belonging to inactive servers to prevent media and metadata from being mixed between accounts.
- **Secure credentials** are stored in the system Keychain; custom request headers are validated before they are saved with a server configuration.
- **Local network discovery** can find compatible servers on the local network when the user enables discovery during sign-in.

## Design & Experience

- **Native navigation** adapts the library, player, settings, and onboarding flows to iPhone, iPad, and Mac layouts.
- **Artwork-focused player** uses album and playlist artwork as part of the player presentation while keeping queue, lyrics, output, volume, and playback actions accessible.
- **Dynamic artwork styling** derives colors and backgrounds from artwork to keep album and playlist surfaces visually connected to the music.
- **Smooth transitions** coordinate navigation, player presentation, artwork loading, and list updates so content changes do not unnecessarily interrupt playback.
- **Responsive loading states** show preparation and loading progress for library, artwork, lyrics, and downloads instead of presenting incomplete content as ready.
- **Multiple display languages** include English and Korean localized interface resources.
- **Settings** provide controls for server accounts, streaming quality, lossless audio, downloads, gapless playback, crossfade, ReplayGain, lyrics sources, translation, and privacy-related integrations.

## System Integration

- **Lock Screen and Control Center** provide play, pause, skip, seek, favorite, and artwork-aware playback controls through the system media session.
- **Siri and App Intents** expose supported actions for opening library content, playing songs and playlists, searching the library, managing queue behavior, and updating supported music attributes.
- **Shortcuts integration** makes supported Luma actions available to system automation.
- **Spotlight** makes indexed Luma content available from system search and routes a selected result back to the corresponding library destination.
- **Widgets** provide supported library and playback surfaces outside the main app.
- **Live Activities** show the progress of long-running library preparation work when the system and device support the activity.
- **Background work** coordinates audio playback, downloads, library preparation, artwork work, and permitted processing within the operating system's background execution rules.
- **App Groups and shared storage** allow the app and widget extension to share the data required for supported widget and preparation states.

## Accessibility

- **VoiceOver labels and hints** identify primary navigation, playback, lyrics, queue, volume, server sign-in, and playlist actions.
- **Selected and header traits** communicate navigation hierarchy and selection state for key library and onboarding controls.
- **Dynamic Type** is used by the typography system so supported text can scale with the user's preferred reading size.
- **Reduce Motion and Low Power Mode** are respected by artwork and background animation paths where animation is not required for playback or navigation.
- **Localized accessibility text** follows the selected application language for supported controls.

## Performance & Reliability

- **Playback session identity** prevents callbacks, retries, and data from an older track or server session from being applied to the current track.
- **End-of-track handling** distinguishes a real end of media from a temporary stall or progress reset before advancing the queue.
- **Preloading and cache budgets** limit artwork and next-track preparation according to memory, thermal, power, and network conditions.
- **Concurrent server work** reuses active clients and joins duplicate setup requests to reduce repeated credential, connection, and library initialization work.
- **Cache validation** checks downloaded media and keeps cache records associated with their server and delivery format.
- **Background task cancellation** stops obsolete downloads, library preparation, artwork work, and playback preparation when the user changes context.
- **Playback diagnostics and user-facing errors** report connection, decoding, download, and server failures instead of presenting incomplete work as successful.
- **Library indexing and metadata preparation** are paced to avoid treating every change as a full rebuild and to keep the app responsive during large-library work.

## Compatibility and limitations

- Luma Music requires iOS 18.6 or later on iPhone and iPad, and macOS 15.6 or later on Mac.
- Available audio formats, lossless delivery, transcoding choices, lyrics, artwork, and metadata depend on the connected server and its media files.
- Offline playback is available only for media that has completed a valid download or cache operation on the device.
- Optional integrations contact their respective services only when enabled; server lyric fallback can be disabled in Settings.
- Some system integrations and intelligent discovery features require a compatible operating-system version, device capability, and indexed library.
- Playback behavior, audio decoding, and audio-session behavior can differ in the simulator; a physical device is recommended for final audio verification.
- HTTP connections are supported only with an explicit user confirmation because credentials and music traffic can be observed on an untrusted network.

## Privacy

Luma Music does not require a Luma account and does not include analytics or telemetry. Server credentials are stored in the system Keychain. Luma communicates with the server configured by the user; optional services are contacted only when their corresponding integration is enabled.

