# Releasing Luma

> **RC1 release note:** GitHub Actions release workflows are not currently installed. The v1.0.0-rc1 release must be created manually as a source-only pre-release. Pushing a tag will not automatically build or upload binaries.


Luma ships through two independent channels, both triggered by pushing a
`v*` git tag (e.g. `v1.0.0-rc1` for the first public release candidate).

| Channel | Target | Driver | Artifact |
| --- | --- | --- | --- |
| iOS | TestFlight → App Store | **Xcode Cloud** (configured in App Store Connect) | `.ipa` uploaded to TestFlight |
| macOS | Direct download / Homebrew | **GitHub Actions** (`.github/workflows/release.yml`) | notarized `.dmg` on the GitHub Release, cask bumped in the tap |

The two channels do not depend on each other; a tag push fans out to both.

## Release flow

1. Bump the version locally if you want a specific marketing version, or let the
   pipelines derive it from the tag (both read `v<version>`).
2. Tag and push:
   ```sh
   git tag v1.0.0-rc1
   git push origin v1.0.0-rc1
   ```
3. **macOS (GitHub Actions):** archives the `Luma` scheme for macOS with
   manual Developer ID signing, exports via `ExportOptions-DeveloperID.plist`,
   notarizes + staples the `.app` and `.dmg`, publishes a GitHub Release with the
   `.dmg`, then bumps `Casks/luma.rb` in the tap repo.
4. **iOS (Xcode Cloud):** runs `ci_scripts/ci_pre_xcodebuild.sh` (syncs the
   marketing version from `$CI_TAG` via `agvtool`), builds, and uploads to
   TestFlight.

The version is derived from the tag name with the leading `v` stripped. On a
manual `workflow_dispatch` run (no tag), the macOS job builds `0.0.0-dev` and
**does not** publish a Release or bump the cask — both steps are guarded by
`if: github.ref_type == 'tag'`.

## Required GitHub secrets

Set these in the repo settings (Settings → Secrets and variables → Actions):

| Secret | Purpose |
| --- | --- |
| `DEVELOPER_ID_CERT_P12_BASE64` | Base64 of the Developer ID Application cert exported as `.p12` (with private key) |
| `DEVELOPER_ID_CERT_PASSWORD` | Password protecting that `.p12` |
| `KEYCHAIN_PASSWORD` | Arbitrary password for the temporary CI keychain |
| `PROVISION_PROFILE_APP_BASE64` | Base64 of the Developer ID provisioning profile for `com.kyumin.Music.Luma` |
| `PROVISION_PROFILE_WIDGET_BASE64` | Base64 of the Developer ID provisioning profile for the widget extension |
| `AC_API_KEY_P8_BASE64` | Base64 of the App Store Connect API key (`.p8`), used for notarization |
| `AC_API_KEY_ID` | App Store Connect API key ID |
| `AC_API_ISSUER_ID` | App Store Connect API issuer ID |
| `HOMEBREW_TAP_TOKEN` | PAT with write access to your fork's Homebrew tap (optional) |

Set the required repository variable `APPLE_TEAM_ID` to your Apple Developer
team ID. Set the optional repository variable `HOMEBREW_TAP_REPOSITORY` (for
example, `owner/homebrew-luma`) to enable the cask update job. It is skipped
when the variable is empty so a fork never attempts to push to the upstream tap.

`ExportOptions-DeveloperID.plist` is committed without a hard-coded Team ID;
Xcode signing and the release workflow use your own team. No certificate, key,
or password is stored in this repo.

## One-time human setup

1. **Developer ID cert:** create a *Developer ID Application* certificate on the
   developer portal, then export it **with its private key** as `.p12` from
   Keychain Access. Base64-encode it (`base64 -i cert.p12 | pbcopy`) into
   `DEVELOPER_ID_CERT_P12_BASE64`.
2. **App Store Connect API key:** create an API key, download the `.p8`, and
   base64-encode it into `AC_API_KEY_P8_BASE64`; record its key ID and issuer ID.
3. **Add the GitHub secrets** listed above.
4. **Homebrew tap (optional):** add `Casks/luma.rb` to your own tap repository,
   set `HOMEBREW_TAP_REPOSITORY`, and add a token with write access. The workflow
   rewrites its `version` and `sha256` on each tag.
5. **Xcode Cloud:** create a tag-triggered (`v*`) iOS → TestFlight workflow in
   App Store Connect. It picks up `ci_scripts/ci_pre_xcodebuild.sh` automatically.
6. **Validate end-to-end** with a throwaway tag (e.g. `v0.0.1-rc1`), then delete
   it (`git push --delete origin v0.0.1-rc1`).

## Project facts the pipeline relies on

- **Bundle ID:** `com.kyumin.Music.Luma` · **Team ID:** set in Xcode signing / `APPLE_TEAM_ID` repository variable
- **Widget Bundle ID:** `com.kyumin.Music.Luma.LumaWidgetsExtension`
- **macOS minimum:** 15.6 (Sequoia) — the cask should declare
  `depends_on macos: ">= :sequoia"`.
- **Toolchain:** the workflow runs on `macos-26` and selects the newest stable
  Xcode via `maxim-lobanov/setup-xcode@v1` (`latest-stable`). The project is
  authored with Xcode 27, a 2026 beta not yet on hosted runners. If it fails to
  compile on the runner's GA Xcode because of a beta-only API, move to a
  self-hosted runner with Xcode 27 — App Store submission requires a GA Xcode
  anyway, so a beta-only dependency is a launch blocker to resolve regardless.
- **Versioning:** the `Luma` target uses `apple-generic` versioning, which
  `agvtool` (the Xcode Cloud script) requires. The macOS job sets the version via
  `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` build-setting overrides, which
  flow into the generated `Info.plist`.
- **Product build identifier:** the About screen shows `26A1001rc1` next to the
  marketing version. `26` is the 2026 development year, `A` is the 1.x release
  family, `1001` is the first build in that series, and `rc1` identifies the
  first public release candidate. The App Store-facing `CFBundleVersion` remains
  numeric (`1029` locally) for Apple tooling compatibility.

## Known things to check on the first run

- The Widgets extension builds for **iOS and macOS** (`SUPPORTED_PLATFORMS`
  includes `macosx`). Confirm the macOS archive embeds the appex under
  `PlugIns/` and that App Groups match across app + extension entitlements.
- `create-dmg` cosmetics (icon coordinates, window size) assume a standard
  drag-to-Applications layout; adjust in `release.yml` if the volume looks off.
