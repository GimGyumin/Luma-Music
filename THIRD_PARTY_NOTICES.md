# Third-party code incorporated in this working tree

## AudioStreaming

- Upstream: https://github.com/dimitris-c/AudioStreaming
- Resolved version: 1.4.5, revision `e28a74b7b8632fc14312b7a79dcd82fa302779af`.
- Local package: `Packages/AudioStreaming/`; MIT license retained in that directory.
- Luma repairs byte-range continuity and render-buffer lifetime. See
  [`LUMA_PATCHES.md`](Packages/AudioStreaming/LUMA_PATCHES.md) for provenance and regression tests.

## Apple Music Like Lyrics (AMLL)

- Upstream: https://github.com/amll-dev/applemusic-like-lyrics
- Revision: `5fee356362353dbb24ce9bea3a62536478040de7`
- License: **AGPL-3.0-only**
- Copyright: the AMLL contributors; Swift adaptation © 2026 Cassette contributors.
- Swift port: `Luma/Utilities/AMLL/`.
- Derived conformance tests/vectors: `LumaTests/AMLLPortTests.swift` and `LumaTests/Fixtures/amll-reference.json`.
- Full license: [`Luma/Resources/Licenses/AMLL-AGPL-3.0.txt`](Luma/Resources/Licenses/AMLL-AGPL-3.0.txt).
- Source-to-port mapping and platform adaptations: [`docs/fixes/2026-10-26-amll-swift-port.md`](docs/fixes/2026-10-26-amll-swift-port.md).
- Dynamic artwork: `bg-render/pixi-renderer.ts` sprite motion is adapted in `AMLLArtworkMotion.swift`, with native layer compositing in `LyricsArtwork.metal`. Native GPU blur, color management and lifecycle integration are described in `docs/fixes/2026-10-26-amll-background.md`.

The port is not relicensed under the root MPL license. Existing Cassette MPL notices remain in place. This notice grants no exception to the AGPL terms for the combined application.
