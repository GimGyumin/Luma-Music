# About Streaming Cache

The streaming cache keeps recently played data on the device so the next playback can start faster.

## Difference from downloads

- **Cache**: temporary playback assistance; may be evicted when storage is low.
- **Download**: explicitly saved by you and kept independently of cache cleanup.

## Automatic cache

Luma starts a cache transfer only after playback is established. If the live stream underruns, it cancels the optional transfer so the stream gets the bandwidth first.

## Manage it

See current usage and clear it in **Settings → Downloads → Cache**. Clearing cache does not delete downloads or playlists.
