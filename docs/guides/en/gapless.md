# About Gapless Playback

Gapless playback removes unnecessary silence between tracks in live albums, classical works, and other continuous recordings.

## How it works

- Luma prepares the next track's source ahead of time.
- At the boundary it hands over inside the same audio graph.
- It works best when the server reports exact track boundaries and the files contain no silence.

## Relationship with Crossfade

Gapless and Crossfade are not used together. When Crossfade is on, the overlapping fade wins; turn it off for Gapless.

## Notes

- Gapless does not remove silence that is part of the recording.
- Seeking prepares a new gapless handoff from the requested position.
