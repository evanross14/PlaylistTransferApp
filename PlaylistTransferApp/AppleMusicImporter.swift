import Foundation
import MusicKit

public final class AppleMusicImporter {
    public init() {}

    public enum ImportError: LocalizedError {
        case invalidURL
        case notAPlaylistURL
        case networkFailed
        case decodingFailed
        case authFailed

        public var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid Apple Music URL."
            case .notAPlaylistURL: return "This does not appear to be a valid Apple Music playlist."
            case .networkFailed: return "Failed to fetch playlist from Apple Music."
            case .decodingFailed: return "Failed to decode Apple Music response."
            case .authFailed: return "Apple Music authentication failed."
            }
        }
    }

    // Import a playlist given an Apple Music playlist URL string.
    public func importPlaylist(from urlString: String) async throws -> URL {
        guard let url = URL(string: urlString), url.host?.contains("music.apple.com") == true else {
            throw ImportError.invalidURL
        }
        guard let id = Self.extractPlaylistID(from: url) else {
            throw ImportError.notAPlaylistURL
        }
        // Ensure we are authorized to access Apple Music
        let authStatus = await MusicAuthorization.request()
        guard authStatus == .authorized else {
            throw ImportError.authFailed
        }
        // Fetch the playlist using MusicCatalogResourceRequest
        let request = MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: MusicItemID(id))
        let response = try await request.response()
        let playlist = response.items.first
        guard let playlist = playlist else {
            throw ImportError.notAPlaylistURL
        }
        // Gather metadata
        let playlistName = playlist.name
        let generatedAt = ISO8601DateFormatter().string(from: Date())
        var tracks: [[String: Any]] = []
        if let tracksCollection = playlist.tracks {
            for track in tracksCollection {
                var trackDict: [String: Any] = [:]

                // Title
                trackDict["title"] = track.title

                // Artist name (best effort from Track)
                trackDict["artist"] = track.artistName

                // Album title if available
                trackDict["album"] = track.albumTitle

                // ISRC if available
                if let isrc = track.isrc, !isrc.isEmpty {
                    trackDict["isrc"] = isrc
                }

                // Artwork placeholder; leave as null for Playlist History View to resolve later
                trackDict["artwork"] = ["url": NSNull()]

                tracks.append(trackDict)
            }
        }
        let payload: [String: Any] = [
            "version": 1,
            "source": "applemusic",
            "generated_at": generatedAt,
            "playlist_name": playlistName,
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
        let safeName = playlistName.replacingOccurrences(of: "/", with: "-")
        let dest = dir.appendingPathComponent("\(safeName).xplaylist")
        try jsonData.write(to: dest, options: .atomic)
        return dest
    }

    // Helper: extract the Apple Music playlist ID from the URL
    private static func extractPlaylistID(from url: URL) -> String? {
        // Example: https://music.apple.com/us/playlist/playlist-name/pl.u-xxxxxxx
        // Grab the last path component
        let components = url.pathComponents.reversed()
        for comp in components {
            if comp.hasPrefix("pl.") { return comp }
        }
        return nil
    }
}

