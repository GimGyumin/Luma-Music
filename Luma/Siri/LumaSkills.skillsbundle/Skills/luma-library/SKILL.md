---
name: luma-library
description: Use Luma's library and playback tools to find music, inspect or edit the playback queue, manage playlists or favorites, check lyrics, and change supported Luma settings. Use this whenever the user asks about their own Navidrome/OpenSubsonic library or wants several music actions combined.
---

# LUMA MUSIC LIBRARY

Luma is a client for the user's own Navidrome/OpenSubsonic server. Never invent
library items, listening history, play counts, lyrics, or settings. Only report
what a Luma tool returns.

## Workflow

1. For a library question, call `LumaLibrarySearchToolIntent` with the user's
   terms and the requested kind. For requests such as "FLAC only", "released in
   1987", or "Pop songs", fill `File Format`, `Year`, or `Genre` instead of
   treating them as title text. Use `Play First Match` only when the user asked
   to start the first matching item, not when they asked for a count.
2. To start a specific item, use the audio schema's `LumaPlayAudioIntent` with
   the resolved entity. To control the current transport, use
   `LumaPlaybackControlToolIntent`.
3. To inspect or edit the queue, use `LumaQueueToolIntent`. It can show the real
   queue, add next or last, remove, move, clear up next, clear history, or clear
   the whole queue. Bulk and destructive actions require confirmation.
4. To create a playlist, add the current or a named song, list, rename, delete,
   or play a playlist, use `LumaPlaylistToolIntent`. To remove one track, move
   tracks, duplicate a playlist, or append an album, use
   `LumaPlaylistEditToolIntent`. Removal, duplication, and deletion require
   explicit confirmation.
5. To like, unlike, or check a song, use `LumaFavoriteToolIntent`. The same tool
   can list or play favorite songs, albums, and artists.
6. For recent or most-played music, use `LumaListeningHistoryToolIntent`; do not
   compute statistics outside the recorded events it returns.
7. To show lyrics, use `LumaOpenLyricsToolIntent` with the requested view
   (original, translation, or pronunciation). To check availability or seek to
   a line by its text, use `LumaLyricsToolIntent`. Never quote or read lyrics
   aloud.
8. To report or change supported preferences, use `LumaSettingsToolIntent`.
   Turning automatic downloads off also turns automatic streaming cache off;
   say that explicitly. Clearing the streaming cache requires confirmation.
9. Do not change credentials, sign out, or delete account data through a tool.

## Compound requests

For a request such as "find five Michael Jackson songs, make a playlist, and
play it", use `LumaBuildPlaylistToolIntent`: it searches the real library,
creates the playlist, adds the tracks, and starts playback in one step. For
workflows that need an intermediate choice (for example, asking which version
of a song), ask the user before mutating data. Do not invent entity identifiers
or claim that a tool returned tracks it did not return.

For a history-based request, call `LumaListeningHistoryToolIntent` and report
only its returned entries. If the user then asks to act on those tracks, use the
same artist/title terms to resolve them through the library tools and ask for
confirmation when the match is ambiguous.

Never expose passwords, tokens, server addresses, or raw artwork data. Read-only
questions can run without opening the app; playlist deletion and other
destructive edits require confirmation.
