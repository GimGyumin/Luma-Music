// NavidromeNativeAPI.swift — SwiftSonic
//
// Concrete implementation of NavidromePlaylistCoverUploading.
// Uses URLSession via the HTTPTransport seam — zero additional dependencies.
// No coupling to SwiftSonicClient or the Subsonic protocol layer.

import Foundation
import os

private let logger = Logger(subsystem: "swiftsonic", category: "NavidromeNativeAPI")

/// Navidrome-native REST API client for playlist cover management.
///
/// Uses the same ``HTTPTransport`` seam as the rest of SwiftSonic, making it
/// straightforward to inject mock transports in tests.
///
/// > Important: This type implements Navidrome-specific endpoints that are **not**
/// > part of the Subsonic or OpenSubsonic specifications. It requires separate
/// > JWT authentication via ``authenticate(baseURL:username:password:)``.
public struct NavidromeNativeAPI: NavidromePlaylistCoverUploading {

    private let transport: any HTTPTransport

    /// Creates an instance backed by the given transport.
    ///
    /// - Parameter transport: The HTTP transport to use. Defaults to ``URLSessionTransport``.
    public init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    public func scrobbles(baseURL: URL, token: String, offset: Int, limit: Int) async throws -> [NavidromeScrobble] {
        guard offset >= 0, (1...501).contains(limit), offset <= Int.max - limit,
              var url = URLComponents(url: baseURL.appendingPathComponent("api/scrobble"), resolvingAgainstBaseURL: false) else {
            throw NavidromeNativeAPIError.invalidResponse
        }
        url.queryItems = [URLQueryItem(name: "_start", value: String(offset)), URLQueryItem(name: "_end", value: String(offset+limit)),
                          URLQueryItem(name: "_sort", value: "id"), URLQueryItem(name: "_order", value: "ASC")]
        guard let endpoint = url.url else { throw NavidromeNativeAPIError.invalidResponse }
        var request = URLRequest(url: endpoint)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "x-nd-authorization")
        let (data, response) = try await transport.data(for: request)
        guard response.statusCode == 200 else { throw NavidromeNativeAPIError.metadataRequestFailed(statusCode: response.statusCode) }
        guard data.count <= 2_000_000, let rows = try? JSONDecoder().decode([NavidromeScrobble].self, from: data),
              rows.count <= limit else { throw NavidromeNativeAPIError.invalidResponse }
        return rows
    }

    // MARK: - NavidromePlaylistCoverUploading

    /// Reads imported tags, or (when authorized by the server) the file inspection
    /// response used by Navidrome's Get Info screen. This never changes server data.
    public func songCopyright(baseURL: URL, token: String, songID: String, inspect: Bool = false) async throws -> String? {
        var components = URLComponents(url: baseURL.appendingPathComponent(inspect ? "api/inspect" : "api/song"), resolvingAgainstBaseURL: false)!
        if inspect {
            components.queryItems = [URLQueryItem(name: "id", value: songID)]
        } else {
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove(charactersIn: "/%?#")
            guard let encoded = songID.addingPercentEncoding(withAllowedCharacters: allowed) else {
                throw NavidromeNativeAPIError.invalidResponse
            }
            components.percentEncodedPath += "/" + encoded
        }
        guard let url = components.url else { throw NavidromeNativeAPIError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "x-nd-authorization")
        let (data, response) = try await transport.data(for: request)
        guard response.statusCode == 200 else {
            throw NavidromeNativeAPIError.metadataRequestFailed(statusCode: response.statusCode)
        }
        guard data.count <= 2_000_000,
              let metadata = try? JSONDecoder().decode(NavidromeCopyrightMetadata.self, from: data) else {
            throw NavidromeNativeAPIError.invalidResponse
        }
        return metadata.copyright
    }

    public func authenticate(
        baseURL: URL,
        username: String,
        password: String
    ) async throws -> String {
        try await login(baseURL: baseURL, username: username, password: password).token
    }

    public func login(baseURL: URL, username: String, password: String) async throws -> NavidromeLogin {
        let url = baseURL.appendingPathComponent("auth/login")
        logger.debug("NavidromeNativeAPI: authenticate → \(url.absoluteString, privacy: .public)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = LoginRequestBody(username: username, password: password)
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw NavidromeNativeAPIError.networkError(underlying: error)
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            throw NavidromeNativeAPIError.networkError(underlying: error)
        }

        logger.debug("NavidromeNativeAPI: authenticate status=\(response.statusCode, privacy: .public)")
        guard response.statusCode == 200 else {
            throw NavidromeNativeAPIError.authenticationFailed
        }

        guard let loginResponse = try? JSONDecoder().decode(NavidromeLogin.self, from: data) else {
            throw NavidromeNativeAPIError.invalidResponse
        }
        logger.debug("NavidromeNativeAPI: JWT obtained")
        return loginResponse
    }

    public func uploadPlaylistCover(
        baseURL: URL,
        token: String,
        playlistId: String,
        imageData: Data,
        mimeType: String
    ) async throws {
        let url = baseURL.appendingPathComponent("api/playlist/\(playlistId)/image")
        let boundary = "SwiftSonic-\(UUID().uuidString)"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Navidrome native /api/ endpoints require x-nd-authorization, not the standard
        // Authorization header. Using Authorization results in a silent 401.
        request.setValue("Bearer \(token)", forHTTPHeaderField: "x-nd-authorization")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = multipartBody(imageData: imageData, mimeType: mimeType, boundary: boundary)

        logger.debug("NavidromeNativeAPI: uploadPlaylistCover → \(url.absoluteString, privacy: .public)")

        let responseData: Data
        let response: HTTPURLResponse
        do {
            (responseData, response) = try await transport.data(for: request)
        } catch {
            throw NavidromeNativeAPIError.networkError(underlying: error)
        }

        logger.debug("NavidromeNativeAPI: upload status=\(response.statusCode, privacy: .public)")
        guard (200...299).contains(response.statusCode) else {
            let body = String(data: responseData, encoding: .utf8) ?? "<binary>"
            logger.error("NavidromeNativeAPI: upload failed status=\(response.statusCode, privacy: .public) body=\(body, privacy: .public)")
            throw NavidromeNativeAPIError.uploadFailed(statusCode: response.statusCode)
        }
    }

    // MARK: - Private helpers

    private func multipartBody(imageData: Data, mimeType: String, boundary: String) -> Data {
        var body = Data()
        let crlf = "\r\n"

        let filename: String
        switch mimeType {
        case "image/png":        filename = "cover.png"
        case "image/jpeg", "image/jpg": filename = "cover.jpg"
        default:                 filename = "cover"
        }

        func append(_ string: String) {
            if let d = string.data(using: .utf8) { body.append(d) }
        }

        append("--\(boundary)\(crlf)")
        // Navidrome reads the file via r.FormFile("image") — field must be "image".
        append("Content-Disposition: form-data; name=\"image\"; filename=\"\(filename)\"\(crlf)")
        append("Content-Type: \(mimeType)\(crlf)")
        append(crlf)
        body.append(imageData)
        append(crlf)
        append("--\(boundary)--\(crlf)")

        return body
    }
}

// MARK: - Private Codable helpers

private struct LoginRequestBody: Encodable {
    let username: String
    let password: String
}

public struct NavidromeScrobble: Decodable, Sendable {
    public let id: Int64
    public let mediaFileId: String
    public let submissionTime: Int64
}

public struct NavidromeLogin: Decodable, Sendable {
    public let id: String?
    public let username: String?
    public let token: String
}
