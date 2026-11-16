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

## RC3 additions — Lyricify Backgrounds

- Upstream: https://github.com/WXRIW/Lyricify-Backgrounds
- Reference revision: `cbef8a667c02a01707c78c7e76dc67d65cf161ed`
- License: **Apache-2.0**; copyright belongs to the Lyricify Backgrounds contributors. Swift/Metal adaptation © 2026 Luma contributors.
- RC3 adaptation includes `LyricifyBackgroundMesh.swift`, `LyricifyBackgroundGPU.swift`, `LyricifyBackground.metal`, `LyricifyBassAnalyzer.swift`, and updates to `AppleMusicLyricsBackground.swift`.
- Full license: [`licenses/Lyricify-Apache-2.0.txt`](licenses/Lyricify-Apache-2.0.txt).
- These components are part of the RC3 development build and are **not present in the public RC2 source snapshot**.

## RC3 additions — CMU Pronouncing Dictionary (CMUdict)

- Source: Carnegie Mellon University, CMU Pronouncing Dictionary.
- Copyright © 1993–2015 Carnegie Mellon University; all rights reserved.
- License: **BSD-style 2-clause redistribution conditions**, including retention of the copyright, conditions, and disclaimer in source and binary distributions.
- RC3 dictionary: `Luma/Resources/Pronunciation/cmudict.txt`; used for English-to-Korean pronunciation fallback.
- Full copyright notice, conditions, and disclaimer: [`licenses/CMUdict-BSD-2-Clause.txt`](licenses/CMUdict-BSD-2-Clause.txt).
- The dictionary is part of the RC3 development build and is **not present in the public RC2 source snapshot**.

**License scope:** The MPL-2.0 root license does not replace the AMLL AGPL-3.0-only license, Lyricify Apache-2.0 license, or CMUdict redistribution conditions. Review the corresponding-source and notice requirements when publishing RC3 binaries.
