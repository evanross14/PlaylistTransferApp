//  ExportSpotify.swift
//  PlaylistTransferApp
//
//  Created by Assistant on 11/26/25.
//
//  This file provides a lightweight Spotify playlist export utility that
//  relies on an existing, signed-in SpotifyAuthManager to obtain an access token.
//
//  Usage:
//  let exporter = SpotifyPlaylistExporter(authManager: yourAuthManager)
//  let url = try await exporter.export(playlist: playlistFile)
//

import Foundation

// MARK: - Errors

enum SpotifyExportError: LocalizedError {
    case unauthorized
    case badResponse
    case invalidData
    case playlistCreationFailed
    case addTracksFailed
    case searchFailed

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Spotify authorization failed."
        case .badResponse: return "Received an unexpected response from Spotify."
        case .invalidData: return "Failed to parse data from Spotify."
        case .playlistCreationFailed: return "Couldn't create playlist on Spotify."
        case .addTracksFailed: return "Couldn't add tracks to the Spotify playlist."
        case .searchFailed: return "Couldn't find one or more tracks on Spotify."
        }
    }
}

// MARK: - Exporter

struct SpotifyPlaylistExporter {
    private let authManager: SpotifyAuthManager

    init(authManager: SpotifyAuthManager) {
        self.authManager = authManager
    }

    // Public entry point: creates a playlist and adds tracks
    @discardableResult
    func export(playlist: PlaylistFile) async throws -> URL {
        let accessToken = try await authManager.provideValidAccessToken()
        let userID = try await getCurrentUserID(accessToken: accessToken)
        let playlistID = try await createPlaylist(name: playlist.name, userID: userID, accessToken: accessToken)

        // Resolve track URIs via ISRC if available, otherwise search by title/artist (+ optional album)
        let uris = try await resolveTrackURIs(for: playlist.songs, accessToken: accessToken)

        // Add in batches of up to 100 per Spotify API
        try await addTracks(uris: uris, to: playlistID, accessToken: accessToken)

        // Return a Spotify URL to the created playlist
        guard let url = URL(string: "https://open.spotify.com/playlist/\(playlistID)") else {
            throw SpotifyExportError.invalidData
        }
        return url
    }
}

// MARK: - Networking helpers

private extension SpotifyPlaylistExporter {
    struct SpotifyErrorPayload: Decodable {
        struct Inner: Decodable { let status: Int; let message: String }
        let error: Inner
    }

    func getCurrentUserID(accessToken: String) async throws -> String {
        let url = URL(string: "https://api.spotify.com/v1/me")!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SpotifyExportError.badResponse }
        #if DEBUG
        print("[Spotify] GET \(url.absoluteString) -> \(http.statusCode)")
        #endif
        guard (200..<300).contains(http.statusCode) else {
            #if DEBUG
            if let payload = try? JSONDecoder().decode(SpotifyErrorPayload.self, from: data) {
                print("[Spotify] Error \(payload.error.status): \(payload.error.message)")
            } else {
                let snippet = String(data: data.prefix(200), encoding: .utf8) ?? "<non-utf8>"
                print("[Spotify] Error body: \(snippet)")
            }
            #endif
            throw SpotifyExportError.unauthorized
        }
        struct Me: Decodable { let id: String }
        let me = try JSONDecoder().decode(Me.self, from: data)
        return me.id
    }

    func createPlaylist(name: String, userID: String, accessToken: String) async throws -> String {
        let url = URL(string: "https://api.spotify.com/v1/users/\(userID)/playlists")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "name": name,
            "public": false
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SpotifyExportError.badResponse }
        #if DEBUG
        print("[Spotify] POST \(url.absoluteString) -> \(http.statusCode)")
        #endif
        guard (200..<300).contains(http.statusCode) else {
            #if DEBUG
            if let payload = try? JSONDecoder().decode(SpotifyErrorPayload.self, from: data) {
                print("[Spotify] Error \(payload.error.status): \(payload.error.message)")
            } else {
                let snippet = String(data: data.prefix(200), encoding: .utf8) ?? "<non-utf8>"
                print("[Spotify] Error body: \(snippet)")
            }
            #endif
            throw SpotifyExportError.playlistCreationFailed
        }
        struct Created: Decodable { let id: String }
        let created = try JSONDecoder().decode(Created.self, from: data)
        return created.id
    }

    func resolveTrackURIs(for songs: [Song], accessToken: String) async throws -> [String] {
        var uris: [String] = []
        uris.reserveCapacity(songs.count)
        for song in songs {
            if let isrc = song.isrc, let uri = try await searchTrackURI(isrc: isrc, accessToken: accessToken) {
                uris.append(uri)
                continue
            }
            let title = song.title
            let artist = song.artist
            let album = song.album
            if let uri = try await searchTrackURI(title: title, artist: artist, album: album, accessToken: accessToken) {
                uris.append(uri)
                continue
            }
            // Fallback: retry without album qualifier to widen results
            if let uri = try await searchTrackURI(title: title, artist: artist, album: nil, accessToken: accessToken) {
                uris.append(uri)
            }
        }
        #if DEBUG
        print("[Spotify] Resolved \(uris.count)/\(songs.count) track URIs")
        #endif
        return uris
    }

    func searchTrackURI(isrc: String, accessToken: String) async throws -> String? {
        guard let q = "isrc:\(isrc)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        let url = URL(string: "https://api.spotify.com/v1/search?type=track&limit=1&q=\(q)")!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { return nil }
        #if DEBUG
        print("[Spotify] GET \(url.absoluteString) -> \(http.statusCode)")
        #endif
        guard (200..<300).contains(http.statusCode) else {
            #if DEBUG
            if let payload = try? JSONDecoder().decode(SpotifyErrorPayload.self, from: data) {
                print("[Spotify] Error \(payload.error.status): \(payload.error.message)")
            } else {
                let snippet = String(data: data.prefix(200), encoding: .utf8) ?? "<non-utf8>"
                print("[Spotify] Error body: \(snippet)")
            }
            #endif
            return nil
        }
        struct Search: Decodable {
            struct Tracks: Decodable {
                struct Item: Decodable { let uri: String }
                let items: [Item]
            }
            let tracks: Tracks
        }
        let decoded = try JSONDecoder().decode(Search.self, from: data)
        return decoded.tracks.items.first?.uri
    }

    func searchTrackURI(title: String, artist: String?, album: String?, accessToken: String) async throws -> String? {
        var parts: [String] = []
        parts.append("track:\"\(title)\"")
        if let artist, !artist.isEmpty { parts.append("artist:\(artist)") }
        if let album, !album.isEmpty { parts.append("album:\(album)") }
        let joined = parts.joined(separator: " ")
        guard let q = joined.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        let url = URL(string: "https://api.spotify.com/v1/search?type=track&limit=1&q=\(q)")!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { return nil }
        #if DEBUG
        print("[Spotify] GET \(url.absoluteString) -> \(http.statusCode)")
        #endif
        guard (200..<300).contains(http.statusCode) else {
            #if DEBUG
            if let payload = try? JSONDecoder().decode(SpotifyErrorPayload.self, from: data) {
                print("[Spotify] Error \(payload.error.status): \(payload.error.message)")
            } else {
                let snippet = String(data: data.prefix(200), encoding: .utf8) ?? "<non-utf8>"
                print("[Spotify] Error body: \(snippet)")
            }
            #endif
            return nil
        }
        struct Search: Decodable {
            struct Tracks: Decodable {
                struct Item: Decodable { let uri: String }
                let items: [Item]
            }
            let tracks: Tracks
        }
        let decoded = try JSONDecoder().decode(Search.self, from: data)
        return decoded.tracks.items.first?.uri
    }

    func addTracks(uris: [String], to playlistID: String, accessToken: String) async throws {
        guard !uris.isEmpty else { return }

        // Spotify allows up to 100 URIs per request
        let chunkSize = 100
        var index = 0
        while index < uris.count {
            let end = min(index + chunkSize, uris.count)
            let slice = Array(uris[index..<end])

            let url = URL(string: "https://api.spotify.com/v1/playlists/\(playlistID)/tracks")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: Any] = ["uris": slice]
            req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw SpotifyExportError.badResponse }
            #if DEBUG
            print("[Spotify] POST \(url.absoluteString) -> \(http.statusCode) [\(slice.count) URIs]")
            #endif
            guard (200..<300).contains(http.statusCode) else {
                #if DEBUG
                if let payload = try? JSONDecoder().decode(SpotifyErrorPayload.self, from: data) {
                    print("[Spotify] Error \(payload.error.status): \(payload.error.message)")
                } else {
                    let snippet = String(data: data.prefix(200), encoding: .utf8) ?? "<non-utf8>"
                    print("[Spotify] Error body: \(snippet)")
                }
                #endif
                throw SpotifyExportError.addTracksFailed
            }
            index = end
        }
    }
}
