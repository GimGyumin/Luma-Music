# Luma dependency repair

Vendored from the resolved AudioStreaming 1.4.5 revision
`e28a74b7b8632fc14312b7a79dcd82fa302779af` (MIT, see LICENSE).
Source, codec bridge and upstream tests are retained. No generated binaries are checked in.

RemoteAudioSource: reject a nonmatching response to a nonzero byte
range before decoding, never retry an unseekable response from byte zero after
delivering bytes, bound reconnect attempts, cancel the probe on close and fence
late response callbacks. Retry/network callbacks execute on the source queue.
Luma handles the propagated error with its bounded seek-before-play recovery.

AudioPlayer / AudioRendererContext: stop the hardware output before stopping/resetting
its manual render graph, and also on deinitialization; disconnect the output callback.
The context now frees its own buffers when its last render owner releases it instead
of AudioPlayer freeing them while a retained processor can still render. An existing
Luma GaplessContinuityTests engine replacement test crashed on iPhone and macOS
before this fix (garbage mNumberBuffers / audio IO thread). It passes after the fix.
Gapless remains enabled; both native and AudioStreaming transition tests are retained.

RemoteContinuityTests reproduces duplicate prefix delivery in the original source
(three failing tests / seven assertions) and verifies a valid range still works.
Run `swift test --package-path Packages/AudioStreaming --filter RemoteContinuityTests`.

Keep these checks when updating upstream; remove the local patch only after the
upstream implementation passes them. This local package makes the repair survive
clean checkouts and package cache resets.
