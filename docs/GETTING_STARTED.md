<h1 align="center">Getting started</h1>
<p align="center"><strong>Your music, a few steps away.</strong></p>
<p align="center"><a href="README.md">All guides</a> &nbsp; · &nbsp; <a href="../README.md">Luma Music</a> &nbsp; · &nbsp; <a href="SUPPORT.md">Need help?</a></p>

---

## Before you begin.

You need an **iPhone with iOS 18.6+** or an **iPad with iPadOS 18.6+**, access to **your own compatible music server**, and a way to sign and sideload an IPA (for example, SideStore or AltStore).

**⚠️ iPad UI compatibility notice (November 2026)**

The current iPad version has known interface issues, and some UI elements may not work correctly. We plan to release an iPad fix **during December 2026**. **Until the updated version is available, please use Luma Music on iPhone.**

**iPad 이용 안내:** 현재 iPad 버전에서 일부 UI가 정상적으로 작동하지 않는 문제가 확인되었습니다. **2026년 12월 중 수정 버전을 배포할 예정**입니다. 수정 버전 배포 전까지는 **iPhone에서 Luma Music을 이용해 주세요.**

Luma is a client app for Navidrome, OpenSubsonic-compatible servers, and supported Jellyfin libraries. It does **not** provide or host a music catalog.

## 1. Choose a release.

Go to **[GitHub Releases](https://github.com/GimGyumin/Luma-Music/releases)** and read the notes for the build you select.

[RC2](https://github.com/GimGyumin/Luma-Music/releases/tag/v1.0.0-rc2) is the latest published preview; [RC1](https://github.com/GimGyumin/Luma-Music/releases/tag/v1.0.0-rc1) is an earlier release. Neither is stable 1.0. The current iPad build has UI issues, so **install and use the iPhone version for now**. The iPad correction is planned for December 2026.

## 2. Install the IPA.

Use a compatible signing/sideloading method, then follow that tool's installation instructions for your device and signing account.

There is **no App Store or TestFlight distribution** at present, and the macOS app is not available yet.

## 3. Connect your music server.

Open Luma and follow the server connection flow. Enter the address and credentials for your **own** supported server.

Prefer HTTPS. If connection fails, check the address, network access, account details, and whether the server supports the appropriate API.

## 4. Enjoy your collection.

Browse albums and playlists, adjust playback settings, and use supported offline downloads.

Some features depend on source data: lyrics require a compatible provider, word-timed animation requires timing, pronunciation needs a pronunciation layer, and immersive artwork is not available for every cover.

---

## Don't have a server yet?

A detailed, Luma-specific **Navidrome setup walkthrough is planned**. For now, use your chosen server project's official documentation to set it up and confirm it is reachable before connecting Luma.

[Feature overview](FEATURES.md) &nbsp; · &nbsp; [Troubleshooting](SUPPORT.md) &nbsp; · &nbsp; [Roadmap](ROADMAP.md)
