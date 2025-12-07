import Foundation

private struct SpotifyPlaylistResponse: Decodable {
    let name: String
    let tracks: SpotifyTrackItems
}
private struct SpotifyTrackItems: Decodable {
    let items: [SpotifyTrackItem]
}
private struct SpotifyTrackItem: Decodable {
    let track: SpotifyTrack?
}
private struct SpotifyTrack: Decodable {
    let name: String
    let artists: [SpotifyArtist]
    let album: SpotifyAlbum
    let external_ids: [String: String]?
}
private struct SpotifyArtist: Decodable {
    let name: String
}
private struct SpotifyAlbum: Decodable {
    let name: String
    let images: [SpotifyImage]
}
private struct SpotifyImage: Decodable {
    let url: String
}

public final class SpotifyImporter {
    // A closure that returns the bearer token string. Optional.
    public var accessTokenProvider: (() -> String)?

    public init() {}

    // Errors that can be thrown by the importer
    public enum ImportError: LocalizedError {
        case invalidURL
        case missingAccessToken
        case networkFailed
        case decodingFailed

        public var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid Spotify URL."
            case .missingAccessToken: return "Missing Spotify access token."
            case .networkFailed: return "Failed to fetch playlist from Spotify."
            case .decodingFailed: return "Failed to decode Spotify response."
            }
        }
    }

    // Import a playlist given a Spotify URL string.
    public func importPlaylist(from urlString: String) async throws -> URL {
        guard let url = URL(string: urlString), urlString.contains("spotify.com/playlist/") else {
            throw ImportError.invalidURL
        }
        guard let token = accessTokenProvider?(), !token.isEmpty else {
            throw ImportError.missingAccessToken
        }
        // Extract playlist ID
        guard let playlistID = url.pathComponents.last, !playlistID.isEmpty else {
            throw ImportError.invalidURL
        }
        // Fetch playlist data from Spotify
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/playlists/\(playlistID)")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ImportError.networkFailed
        }
        // Decode response
        guard let playlist = try? JSONDecoder().decode(SpotifyPlaylistResponse.self, from: data) else {
            throw ImportError.decodingFailed
        }
        // Build tracks array
        let tracks: [[String: Any]] = playlist.tracks.items.compactMap { (item) -> [String: Any]? in
            guard let t = item.track else { return nil }
            let isrc = t.external_ids?["isrc"]
            let artworkURL = t.album.images.first?.url
            let isrcValue: Any = (isrc != nil) ? isrc! : NSNull()
            let artworkURLValue: Any = (artworkURL != nil) ? artworkURL! : NSNull()
            return [
                "title": t.name,
                "artist": t.artists.first?.name ?? "",
                "album": t.album.name,
                "isrc": isrcValue,
                "artwork": ["url": artworkURLValue]
            ]
        }
        let now = ISO8601DateFormatter()
        now.formatOptions = [.withInternetDateTime]
        let generatedAt = now.string(from: Date())
        let payload: [String: Any] = [
            "version": 1,
            "source": "spotify",
            "generated_at": generatedAt,
            "playlist_name": playlist.name,
            "tracks": tracks
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted)
        // Write to Documents/PlaylistHistory
        let fm = FileManager.default
        let docs = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = docs.appendingPathComponent("PlaylistHistory", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let safeName = playlist.name.replacingOccurrences(of: "/", with: "-")
        let dest = dir.appendingPathComponent("\(safeName).xplaylist")
        try jsonData.write(to: dest, options: .atomic)
        return dest
    }

    // MARK: - Deep Link Handling
    /// Default app URL scheme used by the share extension deep link. Update if you change the scheme in Info.plist.
    public static let defaultScheme = "playlisttransferapp"
    /// Host or path component used for import action (supports both playlisttransferapp://import?... and playlisttransferapp:///import?...)
    public static let importHost = "import"

    /// Parses a custom app URL of the form:
    ///   playlisttransferapp://import?url=<encoded playlist URL>
    /// or:
    ///   playlisttransferapp:///import?url=<encoded playlist URL>
    /// and returns the decoded playlist URL string if present.
    public static func playlistURLString(from appURL: URL) -> String? {
        guard var comps = URLComponents(url: appURL, resolvingAgainstBaseURL: false) else { return nil }

        // Be tolerant of uppercase schemes or host
        comps.scheme = comps.scheme?.lowercased()
        let host = comps.host?.lowercased()
        let path = comps.path

        let isImport = (host == importHost) || (path == "/\(importHost)")
        guard isImport else { return nil }

        guard let value = comps.queryItems?.first(where: { $0.name == "url" })?.value, !value.isEmpty else {
            return nil
        }
        return value.removingPercentEncoding ?? value
    }

    /// Convenience helper to handle a deep link by parsing the playlist URL and invoking the importer.
    /// Call this from your SwiftUI App .onOpenURL or SceneDelegate's scene(_:openURLContexts:).
    /// - Parameters:
    ///   - appURL: The incoming app URL (e.g., playlisttransferapp://import?url=...)
    ///   - importer: A configured SpotifyImporter (ensure accessTokenProvider is set)
    ///   - completion: Called with the resulting file URL or an error.
    public static func handleAppDeepLink(_ appURL: URL, using importer: SpotifyImporter, completion: @escaping (Result<URL, Error>) -> Void) {
        guard let playlistURLString = playlistURLString(from: appURL) else {
            completion(.failure(ImportError.invalidURL))
            return
        }

        Task {
            do {
                let fileURL = try await importer.importPlaylist(from: playlistURLString)
                completion(.success(fileURL))
            } catch {
                completion(.failure(error))
            }
        }
    }
}
