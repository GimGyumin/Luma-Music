// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic
import OSLog
#if canImport(UIKit)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

struct ContextMenuShareAction: View {
    let itemID: String
    let text: String
    @Environment(\.appContainer) private var container

    var body: some View {
        Button {
            guard let container else { return }
            let options = ShareSettings.shared.makeOptions(trackTitle: text)
            Task {
                do {
                    let client = try await container.serverService.makeSwiftSonicClient()
                    let url = try await client.createShareURL(id: itemID, options: options)
                    #if os(iOS)
                    presentContextMenuShare(url)
                    #else
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    #endif
                } catch {
                    container.toastService.showError(error.localizedDescription)
                }
            }
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }
}

#if os(iOS)
/// A ShareLink hosted inside UIContextMenu can be dismissed with the menu that created it.
/// Wait for that transient controller to leave, then present from the stable app hierarchy.
private func presentContextMenuShare(_ url: URL) {
    Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.keyWindow?.rootViewController else { return }

        var presenter = root
        while let presented = presenter.presentedViewController,
              !presented.isBeingDismissed {
            presenter = presented
        }
        let controller = UIActivityViewController(
            activityItems: [url],
            applicationActivities: nil
        )
        controller.popoverPresentationController?.sourceView = presenter.view
        controller.popoverPresentationController?.sourceRect = CGRect(
            x: presenter.view.bounds.midX,
            y: presenter.view.bounds.midY,
            width: 1,
            height: 1
        )
        presenter.present(controller, animated: true)
    }
}
#endif

// MARK: - Context menu preview views
// Internal (not private) so SongRow can reference SongContextPreview directly.

struct CollectionContextPreview: View {
    let coverImage: PlatformImage?
    let displayName: String
    let displaySubtitle: String
    /// Artists use a circular avatar; albums/playlists stay square.
    var isArtist: Bool = false

    var body: some View {
        HStack(spacing: LumaSpacing.m) {
            artwork
                .frame(width: 112, height: 112)

            HStack(spacing: LumaSpacing.s) {
                VStack(alignment: .leading, spacing: LumaSpacing.xs) {
                    Text(displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if !displaySubtitle.isEmpty {
                        Text(displaySubtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(LumaSpacing.m)
        .frame(width: 360)
        .frame(minHeight: 136)
    }

    @ViewBuilder
    private var artwork: some View {
        let content = Group {
            if let coverImage {
                Image(platformImage: coverImage)
                    .resizable()
                    .aspectRatio(1, contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.secondary.opacity(0.15))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        Image(systemName: isArtist ? "person.fill" : "music.note")
                            .font(.system(size: 60))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        if isArtist {
            content.clipShape(Circle())
        } else {
            content.clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct SongContextPreview: View {
    let coverImage: PlatformImage?
    let song: DisplayableSong

    var body: some View {
        HStack(spacing: LumaSpacing.m) {
            Group {
                if let coverImage {
                    Image(platformImage: coverImage)
                        .resizable()
                        .aspectRatio(1, contentMode: .fit)
                } else {
                    Rectangle()
                        .fill(.secondary.opacity(0.15))
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            Image(systemName: "music.note")
                                .font(.system(size: 60))
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: 112, height: 112)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: LumaSpacing.xs) {
                Text(song.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if let artist = song.artist {
                    Text(artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let albumName = song.albumName {
                    Text(albumName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(LumaSpacing.m)
        .frame(width: 360)
        .frame(minHeight: 136)
    }
}

// MARK: - Song context menu

/// Adds Play / Play Next / Add to Queue / Pin / Favorite actions for a single song.
