# About Lyrics Sync

Luma uses lyrics from your server and external lyric sources, following the playback position.

## Supported formats

- Standard LRC
- LRC/TTML with word timing
- OpenSubsonic `songLyrics` v2, including translation and pronunciation
- Apple Music–style TTML

## Presentation

- The current line is emphasized at its playback time.
- Word timing highlights words as they are sung.
- Fast passages use a shorter emphasis animation so the next line can arrive cleanly.
- Manual scrolling pauses automatic following until playback catches up.

## Troubleshooting

- If lyrics are missing, check the server's lyric settings and track metadata.
- If translation is missing, check the engine and target language in **Settings → Lyrics & Translation**.
- After a seek, the view moves directly to the line at the new position.
