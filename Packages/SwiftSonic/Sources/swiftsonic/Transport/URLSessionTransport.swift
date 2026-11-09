// URLSessionTransport.swift — SwiftSonic
//
// Default HTTPTransport implementation backed by URLSession.
// Used automatically when no custom transport is injected into SwiftSonicClient.

import Foundation
import os

/// The default ``HTTPTransport`` implementation, backed by `URLSession`.
///
/// Uses `URLSession.shared` by default. Pass a custom `URLSession` to configure
/// timeout intervals, TLS settings, or a custom delegate:
///
/// ```swift
/// let session = URLSession(configuration: .default)
/// let transport = URLSessionTransport(session: session)
/// let client = SwiftSonicClient(configuration: config, transport: transport)
/// ```
///
/// > Note: ``SwiftSonicClient`` automatically creates a `URLSessionTransport`
/// > configured with the ``ServerConfiguration/requestTimeout`` and
/// > ``ServerConfiguration/resourceTimeout`` values when no custom transport is injected.
/// > You do not need to configure timeouts manually in the common case.
public struct URLSessionTransport: HTTPTransport, Sendable {
    private let sameOriginOnly: Bool
    private let session: URLSession

    /// Creates a transport backed by the given session.
    ///
    /// - Parameter session: The `URLSession` to use. Defaults to `.shared`.
    public init(session: URLSession = .shared) {
        self.sameOriginOnly = false
        self.session = session
    }

    /// Creates a transport with a custom `URLSessionConfiguration`.
    ///
    /// Use this initializer when you need fine-grained control over session settings
    /// such as `timeoutIntervalForResource`, TLS configuration, or HTTP headers.
    ///
    /// - Parameter configuration: The session configuration to use.
    public init(configuration: URLSessionConfiguration, sameOriginOnly: Bool = false) {
        self.sameOriginOnly = sameOriginOnly
        self.session = URLSession(configuration: configuration)
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let redirectGuard = RedirectGuard(originalURL: request.url, sameOriginOnly: sameOriginOnly)
        let (data, response) = try await session.data(for: request, delegate: redirectGuard)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        // D3 — If a cross-domain redirect was blocked, surface a typed error now that
        // the async task has completed (happens-after the delegate callback).
        if let blocked = redirectGuard.blockedRedirect {
            throw SwiftSonicError.insecureRedirect(from: blocked.from, to: blocked.to)
        }
        return (data, httpResponse)
    }
}

// MARK: - Redirect guard

/// Intercepts HTTP redirects and refuses those that cross to a different host.
///
/// Subsonic authentication credentials are embedded as query parameters in every
/// request URL. A cross-domain redirect would silently forward those credentials
/// to an untrusted host. `RedirectGuard` blocks such redirects and records the
/// details so `URLSessionTransport` can surface a ``SwiftSonicError/insecureRedirect``
/// error to the caller.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    let originalURL: URL?
    let sameOriginOnly: Bool

    /// Populated (from the delegate thread) when a cross-domain redirect is blocked.
    ///
    /// Accessed only after `session.data(for:delegate:)` returns, so there is a strict
    /// happens-before relationship and no data race despite the `@unchecked Sendable`.
    private let blockedState = OSAllocatedUnfairLock<(from: URL, to: URL)?>(initialState: nil)

    var blockedRedirect: (from: URL, to: URL)? { blockedState.withLock { $0 } }

    init(originalURL: URL?, sameOriginOnly: Bool) {
        self.originalURL = originalURL
        self.sameOriginOnly = sameOriginOnly
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let newHost = newRequest.url?.host
        let sameOrigin = newRequest.url?.scheme == originalURL?.scheme && newRequest.url?.port == originalURL?.port
        guard newHost == originalURL?.host, !sameOriginOnly || sameOrigin else {
            // Cross-domain redirect detected — record it and refuse to follow.
            let fromURL = task.originalRequest?.url ?? newRequest.url!
            let toURL   = newRequest.url!
            blockedState.withLock { $0 = (from: fromURL, to: toURL) }
            completionHandler(nil) // nil = do not follow the redirect
            return
        }
        completionHandler(newRequest) // Same-domain redirect — allow it.
    }
}
