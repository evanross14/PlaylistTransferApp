//
//  ContentView.swift
//  PlaylistTransferApp
//
//  Created by Evan Ross on 11/24/25.
//

import SwiftUI
import UIKit
import Combine
import SafariServices
import UniformTypeIdentifiers

// Shared ISO8601 formatter used by history provider
private let iso8601Formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

// Minimal decoded models that match the JSON structure used in history
struct DecodedPlaylistFile: Codable {
    let playlist_name: String
    let generated_at: String
    let tracks: [DecodedTrack]
}

struct DecodedTrack: Codable, Identifiable {
    let id: UUID
    let title: String
    let artist: String?
    let artwork: Artwork?

    struct Artwork: Codable {
        let url: String?
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case artist
        case artwork
    }

    init(id: UUID = UUID(), title: String, artist: String?, artwork: Artwork?) {
        self.id = id
        self.title = title
        self.artist = artist
        self.artwork = artwork
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let title = try container.decode(String.self, forKey: .title)
        let artist = try container.decodeIfPresent(String.self, forKey: .artist)
        let artwork = try container.decodeIfPresent(Artwork.self, forKey: .artwork)
        self.init(id: UUID(), title: title, artist: artist, artwork: artwork)
    }
}

private actor ITunesArtworkCache {
    static let shared = ITunesArtworkCache()
    private var cache: [String: URL] = [:]

    func url(for key: String) -> URL? { cache[key] }
    func set(_ url: URL, for key: String) { cache[key] = url }
}

private struct ITunesSearchResult: Decodable {
    struct Item: Decodable {
        let artworkUrl100: String?
        let artworkUrl60: String?
        let artworkUrl600: String?
    }
    let results: [Item]
}

private struct ITunesArtworkFinder {
    static func searchArtworkURL(title: String, artist: String?) async -> URL? {
        let key = cacheKey(title: title, artist: artist)
        if let cached = await ITunesArtworkCache.shared.url(for: key) {
            return cached
        }

        // Try song first
        if let url = await search(entity: "song", title: title, artist: artist) {
            await ITunesArtworkCache.shared.set(url, for: key)
            return url
        }
        // Then try album
        if let url = await search(entity: "album", title: title, artist: artist) {
            await ITunesArtworkCache.shared.set(url, for: key)
            return url
        }
        return nil
    }

    private static func search(entity: String, title: String, artist: String?) async -> URL? {
        var term = title
        if let artist, !artist.isEmpty { term += " " + artist }
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        let urlString = "https://itunes.apple.com/search?media=music&entity=\(entity)&limit=1&term=\(encoded)"
        guard let url = URL(string: urlString) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            let decoded = try JSONDecoder().decode(ITunesSearchResult.self, from: data)
            guard let item = decoded.results.first else { return nil }
            // Prefer highest resolution available, then upscale if needed
            if let s = item.artworkUrl600, let u = URL(string: s) { return u }
            if let s = item.artworkUrl100, let u = URL(string: upscaleArtworkURLString(s)) { return u }
            if let s = item.artworkUrl60, let u = URL(string: upscaleArtworkURLString(s)) { return u }
        } catch {
            #if DEBUG
            print("iTunes search failed (entity=\(entity)): \(error)")
            #endif
        }
        return nil
    }

    private static func upscaleArtworkURLString(_ s: String) -> String {
        // Common pattern: .../100x100bb.jpg -> .../600x600bb.jpg
        // Replace first occurrence of "100x100" or "60x60" with "600x600"
        if s.contains("600x600") { return s }
        return s
            .replacingOccurrences(of: "100x100", with: "600x600")
            .replacingOccurrences(of: "60x60", with: "600x600")
    }

    private static func cacheKey(title: String, artist: String?) -> String {
        (title.lowercased() + "|" + (artist?.lowercased() ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct TrackArtworkView: View {
    let urlString: String?
    let fallbackTitle: String
    let fallbackArtist: String?

    @State private var resolvedURL: URL? = nil
    @State private var attemptedLookup = false

    private let size: CGFloat = 48

    var body: some View {
        content
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
            .accessibilityLabel(accessibilityLabel)
            .task(id: lookupID) {
                await maybeLookupArtwork()
            }
    }

    private var content: some View {
        Group {
            if let url = initialOrResolvedURL {
                AsyncImage(url: url, transaction: Transaction(animation: .default)) { phase in
                    switch phase {
                    case .empty:
                        placeholder
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        placeholder
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
    }

    private var initialOrResolvedURL: URL? {
        if let s = urlString, let u = URL(string: s) { return u }
        return resolvedURL
    }

    private var lookupID: String {
        (urlString ?? "nil") + "|" + fallbackTitle + "|" + (fallbackArtist ?? "")
    }

    private func maybeLookupArtwork() async {
        // Only look up if we don't already have a URL
        guard initialOrResolvedURL == nil else { return }
        guard !attemptedLookup else { return }
        attemptedLookup = true
        let url = await ITunesArtworkFinder.searchArtworkURL(title: fallbackTitle, artist: fallbackArtist)
        await MainActor.run {
            self.resolvedURL = url
        }
    }

    private var accessibilityLabel: String {
        if let fallbackArtist, !fallbackArtist.isEmpty {
            return "Artwork for \(fallbackTitle) by \(fallbackArtist)"
        }
        return "Artwork for \(fallbackTitle)"
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Color.secondary.opacity(0.15), Color.secondary.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note")
                .foregroundStyle(.secondary)
        }
    }
}

struct PlaylistArtworkHeaderView: View {
    let tracks: [DecodedTrack]

    @State private var resolvedURL: URL? = nil
    @State private var attemptedLookup = false

    private let size: CGFloat = 240

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.secondary.opacity(0.12))

            if let url = firstOrResolvedArtworkURL {
                AsyncImage(url: url, transaction: Transaction(animation: .default)) { phase in
                    switch phase {
                    case .empty:
                        placeholder
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        placeholder
                    @unknown default:
                        placeholder
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                placeholder
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
        .frame(width: size, height: size)
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .task(id: artworkLookupID) {
            await maybeResolveArtwork()
        }
    }

    private var firstOrResolvedArtworkURL: URL? {
        if let firstURLString = tracks.first?.artwork?.url, let u = URL(string: firstURLString) {
            return u
        }
        return resolvedURL
    }

    private var artworkLookupID: String {
        // Use first track's title/artist to drive lookup task identity
        let t = tracks.first
        return (t?.title ?? "") + "|" + (t?.artist ?? "")
    }

    private func maybeResolveArtwork() async {
        guard firstOrResolvedArtworkURL == nil else { return }
        guard !attemptedLookup else { return }
        attemptedLookup = true
        guard let first = tracks.first else { return }
        let url = await ITunesArtworkFinder.searchArtworkURL(title: first.title, artist: first.artist)
        await MainActor.run {
            self.resolvedURL = url
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Color.secondary.opacity(0.15), Color.secondary.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note.list")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}

extension Notification.Name {
    static let playlistHistorySeeded = Notification.Name("playlistHistorySeeded")
    static let incomingTextFileURL = Notification.Name("IncomingTXTFileURL")
    static let incomingShareImportURL = Notification.Name("IncomingImportURL")
}

struct Song: Identifiable, Codable {
    var id = UUID()
    let title: String
    let artist: String?
    let album: String?
    let isrc: String?
    let artworkURL: String?
}

struct PlaylistFile: Identifiable, Codable {
    let id: UUID
    let name: String
    let date: Date
    let songs: [Song]
    // Not persisted in JSON; used only to manage on-disk file operations
    var fileURL: URL?

    enum CodingKeys: String, CodingKey {
        case id, name, date, songs
        // Note: fileURL intentionally omitted from CodingKeys
    }
}

struct PlaylistHistoryItem: Identifiable {
    let id = UUID()
    let name: String
    let generatedAt: Date?
    let fileURL: URL
}

protocol PlaylistHistoryProviding {
    var items: [PlaylistHistoryItem] { get }
}

struct FileSystemHistoryProvider: PlaylistHistoryProviding {
    var items: [PlaylistHistoryItem] {
        let fm = FileManager.default
        var items: [PlaylistHistoryItem] = []
        if let docs = try? fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            let destDir = docs.appendingPathComponent("PlaylistHistory", isDirectory: true)
            if let urls = try? fm.contentsOfDirectory(at: destDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                let playlistURLs = urls.filter { $0.pathExtension.lowercased() == "xplaylist" }
                items = playlistURLs.compactMap { url in
                    guard let data = try? Data(contentsOf: url),
                          let decoded = try? JSONDecoder().decode(DecodedPlaylistFile.self, from: data) else {
                        return nil
                    }
                    let date = iso8601Formatter.date(from: decoded.generated_at)
                    return PlaylistHistoryItem(name: decoded.playlist_name, generatedAt: date, fileURL: url)
                }
            }
        }
        return items.sorted { lhs, rhs in
            switch (lhs.generatedAt, rhs.generatedAt) {
            case let (l?, r?):
                if l != r { return l > r }
            default: break
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}

private func copyBundledPlaylistsToDocumentsIfNeeded() {
    let fm = FileManager.default
    // Find all example playlists in the bundle root
    let bundlePlaylists = Bundle.main.urls(forResourcesWithExtension: "xplaylist", subdirectory: nil) ?? []
    guard !bundlePlaylists.isEmpty else { return }

    do {
        let docs = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let destDir = docs.appendingPathComponent("PlaylistHistory", isDirectory: true)
        if !fm.fileExists(atPath: destDir.path) {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true, attributes: nil)
        }
        for src in bundlePlaylists {
            let dest = destDir.appendingPathComponent(src.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                try? fm.removeItem(at: dest)
            }
            do {
                try fm.copyItem(at: src, to: dest)
            } catch {
                #if DEBUG
                print("Failed to copy \(src.lastPathComponent): \(error)")
                #endif
            }
        }
        NotificationCenter.default.post(name: .playlistHistorySeeded, object: nil)
    } catch {
        #if DEBUG
        print("Failed to resolve Documents directory: \(error)")
        #endif
    }
}

private func loadDecodedPlaylist(from url: URL) -> DecodedPlaylistFile? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(DecodedPlaylistFile.self, from: data)
}

struct LoadedPlaylist: Identifiable {
    let id = UUID()
    let name: String
    let tracks: [DecodedTrack]
}

private func buildPlaylistFile(from selection: LoadedPlaylist) -> PlaylistFile {
    let songs: [Song] = selection.tracks.map { t in
        Song(title: t.title, artist: t.artist, album: nil, isrc: nil, artworkURL: t.artwork?.url)
    }
    return PlaylistFile(id: UUID(), name: selection.name, date: Date(), songs: songs, fileURL: nil)
}

private func buildTXT(from selection: LoadedPlaylist) -> String {
    selection.tracks.map { t in
        let artist = (t.artist?.isEmpty == false) ? t.artist! : "Unknown Artist"
        return "\(artist) - \(t.title)"
    }.joined(separator: "\n")
}

struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var showMenu = false
    @State private var isPressed = false
    @State private var isAccountPressed = false
    @State private var showAccount = false
    @AppStorage("didSeedPlaylistHistory") private var didSeedPlaylistHistory: Bool = false
    @StateObject private var authManager = SpotifyAuthManager()
    @StateObject private var appleMusicAuth = AppleMusicAuthManager()
    
    @State private var spotifyURLString: String = ""
    @State private var importError: String? = nil
    
    @State private var showSafari = false
    @State private var safariURL: URL? = nil

    @State private var showingTXTImporter = false
    @State private var pendingTXTURL: URL? = nil
    @State private var showingNamePrompt = false
    @State private var tempPlaylistName: String = ""

    var body: some View {
        ZStack {
            // Main content
            VStack(alignment: .leading, spacing: 16) {
                Text("How to Transfer a Playlist")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("1. Open Spotify or Apple Music.")
                Text("2. Share a playlist using the share button.")
                Text("3. Select this app from the share sheet.")
                Text("4. The playlist will import and be ready to transfer.")

                Divider().padding(.vertical)

                Text("How to Receive a Playlist")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("1. Open the shared playlist file sent to you.")
                Text("2. It will automatically open in this app.")
                Text("3. Choose the service you want to transfer to.")

                Divider().padding(.vertical)
                
                Button {
                    showingTXTImporter = true
                } label: {
                    Label("Import .txt Playlist", systemImage: "doc.text")
                }
                .padding(.top, 8)

                Spacer()
            }
            .padding()

            // Hamburger menu button
            VStack {
                Spacer()
                HStack {
                    Button(action: {
                        withAnimation { showMenu.toggle() }
                    }) {
                        Image(systemName: "line.horizontal.3")
                            .resizable()
                            .frame(width: 28, height: 20)
                            .foregroundColor(colorScheme == .dark ? .white : .black)
                            .padding(20)
                            .background(Circle().fill(Color.clear).glassEffect())
                            .scaleEffect(isPressed ? 0.85 : 1.0)
                            .offset(x: 20)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Circle())
                    .onLongPressGesture(minimumDuration: 0.0, pressing: { isPressing in
                        withAnimation(.easeInOut(duration: 0.13)) {
                            isPressed = isPressing
                        }
                    }, perform: {})
                    Spacer()
                }
            }
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button(action: {
                        withAnimation { showAccount.toggle() }
                    }) {
                        Image(systemName: "person.crop.circle")
                            .resizable()
                            .frame(width: 24, height: 24)
                            .foregroundColor(colorScheme == .dark ? .white : .black)
                            .padding(20)
                            .background(Circle().fill(Color.clear).glassEffect())
                            .scaleEffect(isAccountPressed ? 0.85 : 1.0)
                            .offset(x: -20)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Circle())
                    .onLongPressGesture(minimumDuration: 0.0, pressing: { isPressing in
                        withAnimation(.easeInOut(duration: 0.13)) {
                            isAccountPressed = isPressing
                        }
                    }, perform: {})
                }
            }
        }
        .fileImporter(isPresented: $showingTXTImporter, allowedContentTypes: [UTType.plainText], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { beginImportingTXT(from: url) }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .alert("Name Your Playlist", isPresented: $showingNamePrompt) {
            TextField("Playlist name", text: $tempPlaylistName)
            Button("Cancel", role: .cancel) {
                pendingTXTURL = nil
            }
            Button("Save") {
                let name = tempPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { completeTXTImport(with: name) }
            }
        } message: {
            Text("Enter a name for this playlist.")
        }
        .alert("Import Failed", isPresented: .constant(importError != nil)) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .onAppear {
            if !didSeedPlaylistHistory {
                copyBundledPlaylistsToDocumentsIfNeeded()
                didSeedPlaylistHistory = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .playlistHistorySeeded)) { _ in
            // Open the history view so the user sees the freshly seeded items
            withAnimation {
                showMenu = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .incomingTextFileURL)) { notification in
            guard let url = notification.object as? URL else { return }
            beginImportingTXT(from: url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .incomingShareImportURL)) { notification in
            guard let sharedURL = notification.object as? URL else { return }
            handleIncomingImportURL(sharedURL)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("IncomingImportURL"))) { notification in
            guard let sharedURL = notification.object as? URL else { return }
            handleIncomingImportURL(sharedURL)
        }
        .fullScreenCover(isPresented: $showMenu) {
            PlaylistHistoryView(showMenu: $showMenu, provider: FileSystemHistoryProvider())
                .environmentObject(authManager)
        }
        .sheet(isPresented: $showAccount) {
            AccountManagementView().environmentObject(authManager).environmentObject(appleMusicAuth)
        }
        .sheet(isPresented: $showSafari) {
            if let safariURL {
                SafariView(url: safariURL)
                    .ignoresSafeArea()
            }
        }
    }
    
    private func startSpotifyImport() async {
        importError = nil
        let importer = SpotifyImporter()
        do {
            let token = try await authManager.provideValidAccessToken()
            importer.accessTokenProvider = { token }
            let fileURL = try await importer.importPlaylist(from: spotifyURLString)
            // Notify history to refresh and open the menu
            NotificationCenter.default.post(name: .playlistHistorySeeded, object: nil)
            await MainActor.run {
                showMenu = true
            }
            #if DEBUG
            print("Imported playlist to: \(fileURL.path)")
            #endif
        } catch {
            await MainActor.run {
                importError = error.localizedDescription
            }
        }
    }
    
    private func handleIncomingImportURL(_ sharedURL: URL) {
        if let host = sharedURL.host?.lowercased() {
            if host.contains("spotify.com") {
                // Spotify import logic
                spotifyURLString = sharedURL.absoluteString
                Task {
                    do {
                        // First, attempt silent token retrieval
                        _ = try await authManager.provideValidAccessToken()
                        await startSpotifyImport()
                    } catch {
                        // If silent retrieval fails, attempt interactive sign-in
                        do {
                            try await authManager.signIn()
                            // After successful sign-in, retry import
                            await startSpotifyImport()
                        } catch {
                            await MainActor.run {
                                importError = error.localizedDescription
                            }
                        }
                    }
                }
            } else if host.contains("music.apple.com") {
                // Copy the shared Apple Music link to clipboard for convenience
                UIPasteboard.general.string = sharedURL.absoluteString
                #if DEBUG
                print("[Import] Copied Apple Music link to clipboard: \(sharedURL.absoluteString)")
                #endif

                // Apple Music import via external website flow
                let base = "https://www.tunemymusic.com/transfer/apple-music-to-file"
                var urlComponents = URLComponents(string: base)
                let encoded = sharedURL.absoluteString
                var items = urlComponents?.queryItems ?? []
                items.append(URLQueryItem(name: "url", value: encoded))
                urlComponents?.queryItems = items
                let finalURL = urlComponents?.url ?? URL(string: base)!
                Task {
                    await MainActor.run {
                        safariURL = finalURL
                        showSafari = true
                    }
                }
            } else {
                // Unknown host
                importError = "Unsupported URL host: \(host)"
            }
        } else {
            importError = "Invalid URL host."
        }
    }

    private func beginImportingTXT(from url: URL) {
        pendingTXTURL = url
        tempPlaylistName = ""
        showingNamePrompt = true
        #if DEBUG
        print("[TXT Import] Selected URL: \(url.path)")
        #endif
    }

    private func completeTXTImport(with name: String) {
        guard let url = pendingTXTURL else { return }
        // Dismiss the naming prompt immediately for better UX
        showingNamePrompt = false
        Task {
            #if DEBUG
            print("[TXT Import] Starting import for name=\(name), url=\(url)")
            #endif
            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                #if DEBUG
                print("[TXT Import] Read \(text.count) characters from file")
                #endif
                let parsed = PlainTextPlaylistImporter.parseLines(text)
                guard !parsed.isEmpty else {
                    throw NSError(domain: "TXTImport", code: 1, userInfo: [NSLocalizedDescriptionKey: "No valid tracks found in file."])
                }
                let data = try PlainTextPlaylistImporter.makeXPlaylistData(playlistName: name, tracks: parsed)
                let savedURL = try PlainTextPlaylistImporter.saveToHistory(playlistName: name, data: data)
                #if DEBUG
                print("[TXT Import] Saved to history at: \(savedURL.path)")
                #endif
                NotificationCenter.default.post(name: .playlistHistorySeeded, object: nil)
                await MainActor.run { showMenu = true }
            } catch {
                #if DEBUG
                print("[TXT Import] Failed: \(error)")
                #endif
                await MainActor.run { importError = error.localizedDescription }
            }
            await MainActor.run {
                pendingTXTURL = nil
            }
        }
    }

}

struct PlaylistHistoryView: View {
    enum SortOption: String, CaseIterable, Identifiable {
        case nameAsc = "Name ↑"
        case nameDesc = "Name ↓"
        var id: String { rawValue }
    }
    
    @Binding var showMenu: Bool
    let provider: PlaylistHistoryProviding

    @State private var items: [PlaylistHistoryItem] = []
    @State private var sort: SortOption = .nameDesc
    @State private var searchText: String = ""
    
    @State private var selectedPlaylist: LoadedPlaylist?
    
    @EnvironmentObject private var authManager: SpotifyAuthManager
    @State private var isExporting = false
    @State private var exportError: String? = nil
    @State private var exportSuccessMessage: String? = nil

    @State private var showSafari = false
    @State private var safariURL: URL? = nil

    @Environment(\.colorScheme) private var colorScheme

    init(showMenu: Binding<Bool>, provider: PlaylistHistoryProviding) {
        self._showMenu = showMenu
        self.provider = provider
    }
    
    @ViewBuilder
    private func historyRow(for item: PlaylistHistoryItem) -> some View {
        HStack {
            Text(item.name)
                .lineLimit(1)
            Spacer()
            // Trailing export menu button
            Menu {
                Button {
                    exportItemToSpotify(item)
                } label: {
                    Label("Spotify", systemImage: "music.note.list")
                }
                Button {
                    exportItemToAppleMusic(item)
                } label: {
                    Label("Apple Music", systemImage: "apple.logo")
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .imageScale(.medium)
                    .foregroundColor(colorScheme == .dark ? .white : .black)
                    .padding(.trailing, 4)
            }
        }
        .contentShape(Rectangle())
    }
    
    private var searchBarOverlay: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search playlists", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.clear)
                .glassEffect()
        )
        .padding(.horizontal)
        .padding(.bottom, 12)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 8) {
                let filteredItems = searchText.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
                
                List {
                    ForEach(filteredItems) { item in
                        historyRow(for: item)
                            .onTapGesture {
                                // Preload decoded content before presenting the sheet to avoid an empty first render
                                guard let decoded = loadDecodedPlaylist(from: item.fileURL) else { return }
                                selectedPlaylist = LoadedPlaylist(name: decoded.playlist_name, tracks: decoded.tracks)
                            }
                    }
                    .onDelete(perform: deleteItems)
                }
                .listStyle(.insetGrouped)
                .overlay(alignment: .bottom) {
                    HStack(spacing: 8) {
                        Menu {
                            ForEach([SortOption.nameDesc, SortOption.nameAsc]) { option in
                                Button(option.rawValue) { sort = option }
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                                .imageScale(.medium)
                                .foregroundColor(colorScheme == .dark ? .white : .black)
                                .padding(10)
                                .background(
                                    Circle()
                                        .fill(Color.clear)
                                        .glassEffect()
                                )
                        }
                        .offset(x: 10, y: -5)
                        searchBarOverlay
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("Playlist History")
            .overlay(alignment: .center) {
                if isExporting {
                    ProgressView("Exporting…")
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .alert("Export Failed", isPresented: .constant(exportError != nil)) {
                Button("OK", role: .cancel) { exportError = nil }
            } message: {
                Text(exportError ?? "Unknown error")
            }
            .alert("Export Successful", isPresented: .constant(exportSuccessMessage != nil)) {
                Button("OK", role: .cancel) { exportSuccessMessage = nil }
            } message: {
                Text(exportSuccessMessage ?? "")
            }
            .onChange(of: sort) { _, _ in
                applySort()
            }
            .onAppear {
                items = provider.items
                applySort()
            }
            .onReceive(NotificationCenter.default.publisher(for: .playlistHistorySeeded)) { _ in
                items = provider.items
                applySort()
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showMenu = false
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundColor(.primary)
                    }
                }
            }
            .sheet(isPresented: $showSafari) {
                if let safariURL {
                    SafariView(url: safariURL)
                        .ignoresSafeArea()
                }
            }
            .sheet(item: $selectedPlaylist) { selection in
                NavigationStack {
                    List {
                        // Header section with large square artwork
                        Section {
                            VStack(alignment: .center, spacing: 12) {
                                // Large 1:1 square playlist artwork
                                PlaylistArtworkHeaderView(tracks: selection.tracks)
                                    .frame(maxWidth: .infinity)
                                    .listRowInsets(EdgeInsets())

                                VStack(spacing: 4) {
                                    Text(selection.name)
                                        .font(.title2.bold())
                                        .multilineTextAlignment(.center)
                                    Text("\(selection.tracks.count) songs")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal)
                                .padding(.bottom, 8)
                            }
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                        }

                        // Tracks
                        Section {
                            ForEach(selection.tracks) { t in
                                HStack(alignment: .center, spacing: 12) {
                                    TrackArtworkView(urlString: t.artwork?.url, fallbackTitle: t.title, fallbackArtist: t.artist)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(t.title)
                                            .font(.body)
                                            .lineLimit(1)
                                        if let artist = t.artist {
                                            Text(artist)
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                }
                                .contentShape(Rectangle())
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                    .overlay(alignment: .center) {
                        if isExporting {
                            ProgressView("Exporting…")
                                .padding()
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .alert("Export Failed", isPresented: .constant(exportError != nil)) {
                        Button("OK", role: .cancel) { exportError = nil }
                    } message: {
                        Text(exportError ?? "Unknown error")
                    }
                    .alert("Export Successful", isPresented: .constant(exportSuccessMessage != nil)) {
                        Button("OK", role: .cancel) { exportSuccessMessage = nil }
                    } message: {
                        Text(exportSuccessMessage ?? "")
                    }
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Close") { selectedPlaylist = nil }
                        }
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Menu {
                                Button {
                                    exportToSpotify(selection)
                                } label: {
                                    Label("Spotify", systemImage: "music.note.list")
                                }
                                Button {
                                    exportToAppleMusic(selection)
                                } label: {
                                    Label("Apple Music", systemImage: "apple.logo")
                                }
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                                    .foregroundColor(colorScheme == .dark ? .white : .black)
                            }
                        }
                    }
                }
            }
        }
    }

    private func deleteItems(at offsets: IndexSet) {
        let fm = FileManager.default
        for index in offsets {
            let item = items[index]
            do {
                try fm.removeItem(at: item.fileURL)
            } catch {
                #if DEBUG
                print("Failed to delete file: \(error)")
                #endif
            }
        }
        // Refresh list from provider after deletion
        items = provider.items
        applySort()
    }
    
    private func applySort() {
        switch sort {
        case .nameDesc:
            // Now interpret "↓" as A → Z per request
            items.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .nameAsc:
            // Now interpret "↑" as Z → A per request
            items.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        }
    }
    
    private func exportItemToSpotify(_ item: PlaylistHistoryItem) {
        guard let decoded = loadDecodedPlaylist(from: item.fileURL) else { return }
        let loaded = LoadedPlaylist(name: decoded.playlist_name, tracks: decoded.tracks)
        exportToSpotify(loaded)
    }
    
    private func exportItemToAppleMusic(_ item: PlaylistHistoryItem) {
        guard let decoded = loadDecodedPlaylist(from: item.fileURL) else { return }
        let loaded = LoadedPlaylist(name: decoded.playlist_name, tracks: decoded.tracks)
        exportToAppleMusic(loaded)
    }

    private func exportToAppleMusic(_ selection: LoadedPlaylist) {
        isExporting = true
        Task {
            let txt = buildTXT(from: selection)
            UIPasteboard.general.string = txt
            await MainActor.run {
                self.safariURL = URL(string: "https://www.tunemymusic.com/transfer")
                self.showSafari = true
            }
            await MainActor.run { isExporting = false }
        }
    }

    private func exportToSpotify(_ selection: LoadedPlaylist) {
        let exporter = SpotifyPlaylistExporter(authManager: authManager)
        isExporting = true
        Task {
            do {
                let playlist = buildPlaylistFile(from: selection)
                let url = try await exporter.export(playlist: playlist)

                #if DEBUG
                print("Created Spotify playlist: \(url.absoluteString)")
                #endif
                await MainActor.run {
                    exportSuccessMessage = "Your playlist was created successfully in Spotify."
                }
            } catch {
                #if DEBUG
                print("Export failed: \(error)")
                #endif
                await MainActor.run {
                    let friendly = (error as? LocalizedError)?.errorDescription ?? "Export failed."
                    exportError = friendly + "\n\nDetails: " + error.localizedDescription
                }
            }
            await MainActor.run { isExporting = false }
        }
    }
}

struct AccountManagementView: View {
    @EnvironmentObject private var authManager: SpotifyAuthManager
    @EnvironmentObject private var appleMusicAuth: AppleMusicAuthManager
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Spotify")) {
                    HStack(spacing: 8) {
                        if authManager.isSignedIn {
                            Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                            Text("Signed in").foregroundColor(.secondary)
                        } else {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                            Text("Not signed in").foregroundColor(.secondary)
                        }
                    }
                    Button(authManager.isSignedIn ? "Reauthorize Spotify" : "Sign in with Spotify") {
                        Task {
                            do { try await authManager.signIn() } catch { errorMessage = error.localizedDescription }
                        }
                    }
                }

                Section(header: Text("Apple Music")) {
                    HStack(spacing: 8) {
                        if appleMusicAuth.isSignedIn {
                            Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                            Text("Signed in").foregroundColor(.secondary)
                        } else {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                            Text("Not signed in").foregroundColor(.secondary)
                        }
                    }
                    Button(appleMusicAuth.isSignedIn ? "Reauthorize Apple Music" : "Sign in with Apple Music") {
                        Task {
                            do { try await appleMusicAuth.signIn() } catch { errorMessage = error.localizedDescription }
                        }
                    }
                }
            }
            .navigationTitle("Accounts")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }
}

#Preview {
    ContentView()
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        vc.dismissButtonStyle = .close
        return vc
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

