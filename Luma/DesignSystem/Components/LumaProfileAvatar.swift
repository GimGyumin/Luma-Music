// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import Foundation
import SwiftSonic

/// Circular account picture used by the iPad sidebar footer and the Account sheet.
///
/// OpenSubsonic exposes the signed-in user's image through `getAvatar`.
/// `SwiftSonicClient.avatarURL(username:)` returns that URL with the server's
/// authentication parameters already attached, so the image can be fetched
/// directly. Servers that do not implement avatars (Jellyfin, some Subsonic
/// instances) fall back to a stable monogram on a neutral circular background.
struct LumaProfileAvatar: View {
    let username: String
    var size: CGFloat = 28

    @Environment(\.appContainer) private var container
    @State private var loadedImage: PlatformImage?
    @State private var loadedRequestID: String?

    private var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var requestID: String {
        "\(container?.serverState.activeServer?.id.uuidString ?? "-"):\(container?.serverState.accountRevision ?? 0):\(trimmedUsername)"
    }

    /// One or two characters, never a blank circle.
    private var monogram: String {
        let words = trimmedUsername.split { character in
            character.isWhitespace || character == "." || character == "_" || character == "-"
        }
        if words.count >= 2 {
            let initials = words.prefix(2).compactMap(\.first).map(String.init).joined()
            if !initials.isEmpty { return initials.uppercased() }
        }
        guard let first = trimmedUsername.first else { return "?" }
        // Korean and other CJK names read better as two characters; Latin
        // usernames use the first two letters only when there is one word.
        let prefix = trimmedUsername.prefix(2)
        return prefix.count > 1 ? String(prefix).uppercased() : String(first).uppercased()
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.40), Color(white: 0.23)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text(monogram)
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.7)
                .lineLimit(1)

            if let loadedImage, loadedRequestID == requestID {
                platformImage(loadedImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle()
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
        .task(id: requestID) {
            await loadAvatar()
        }
    }

    @MainActor
    private func loadAvatar() async {
        loadedImage = nil
        loadedRequestID = nil
        let expectedRequestID = requestID
        guard !trimmedUsername.isEmpty,
              let container,
              let serverID = container.serverState.activeServer?.id,
              let identity = try? container.serverState.requestIdentity(for: serverID),
              let client = try? await container.serverService.makeSwiftSonicClient(),
              let url = client.avatarURL(username: trimmedUsername) else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let image = PlatformImage(data: data) else { return }
        guard !Task.isCancelled, container.serverState.requestIsCurrent(identity),
              requestID == expectedRequestID else { return }
        loadedRequestID = expectedRequestID
        loadedImage = image
    }

    private func platformImage(_ image: PlatformImage) -> Image {
        #if canImport(UIKit)
        Image(uiImage: image)
        #else
        Image(nsImage: image)
        #endif
    }
}
