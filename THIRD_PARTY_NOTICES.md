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

The port is not relicensed under the root MPL license. Existing Cassette MPL notices remain in place. This notice grants no exception to the AGPL terms for the combined application.

## Lyricify Backgrounds — Apple Music Inspired · iOS

- Upstream: https://github.com/WXRIW/Lyricify-Backgrounds
- Reference commit: `cbef8a667c02a01707c78c7e76dc67d65cf161ed`
- License: **Apache-2.0**
- Copyright: the Lyricify Backgrounds contributors; Swift/Metal adaptation © 2026 Luma contributors.
- Imported/adapted files:
  - `Luma/Views/Main/Player/LyricifyBackgroundMesh.swift`
  - `Luma/Views/Main/Player/LyricifyBackgroundGPU.swift`
  - `Luma/Views/Main/Player/LyricifyBackground.metal`
  - `Luma/Services/Playback/LyricifyBassAnalyzer.swift`
  - `Luma/Views/Main/Player/AppleMusicLyricsBackground.swift`
- Ported algorithms: the 4 portrait/5 landscape Catmull–Clark mesh presets, three opaque
  instances at 1.4×/0.7×/0.7× with 120/70/90 s rotations, and the third instance's parent rotation.
  The normalized separable sigma-42.5 Gaussian uses 77 mirrored tap pairs plus the center
  tap with zero-border sampling. Color treatment uses 1.4 then 0.70 saturation, the reference
  intermediate clamp, dark/light scrims of 0.40 and 1/3, and the dithered 0.07…0.97 output.
  Artwork crossfades for 0.5 s and the pinch mesh uses the reference smoothstep of
  `acos(sin(t*pi/5))/pi`. The bass response retains the transient and dual-window FFT
  analysis and the `1 + 0.33 * power²` image scale.
- Platform adaptation: Swift/Metal and one MTKView per full player instead of Direct3D and
  Windows loopback. ColorSync prepares sRGB artwork, with the upstream resize threshold
  of 100,000 pixels and maximum resized side of 300 px. Playback and lyrics both use the
  reference lyrics-mode passes. A shared Metal encoder draws the backing and the pinch
  mesh into one target. The PCM mailbox consumes the audible engine's decoded audio in
  512-sample hops and schedules the pulse at its presentation time. The port does not
  request the supplementary decoder or synthesize a pulse when native PCM is unavailable.
- WWDC26 sample reviewed: SwiftUI's `layerEffect`, noise texture, domain warping, and
  `TimelineView` demonstrate feeding time and textures to Metal outside transcript layout.
  Luma keeps the explicit MTKView passes for the reference compositing order and
  avoids invalidating SwiftUI on each rendered frame.
- Full license: [`Luma/Resources/Licenses/Lyricify-Apache-2.0.txt`](Luma/Resources/Licenses/Lyricify-Apache-2.0.txt).
