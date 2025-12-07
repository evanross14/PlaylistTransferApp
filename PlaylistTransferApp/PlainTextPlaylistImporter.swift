import Foundation

enum PlainTextPlaylistImporter {
    struct ParsedTrack {
        let title: String
        let artist: String
    }

    // Parses lines like "Artist - Title" with tolerant separators and spacing
    static func parseLines(_ text: String) -> [ParsedTrack] {
        // Assumes lines are in the form: "Artist - Title" with optional spaces and dash-like separators.
        // Skips empty lines and lines starting with '#'.
        func splitArtistTitle(_ line: String) -> (String, String)? {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            if trimmed.hasPrefix("#") { return nil }

            let chars = Array(trimmed)
            let dashSet: Set<Character> = ["-", "–", "—"]

            // Find the first dash-like separator
            var i = 0
            while i < chars.count, !dashSet.contains(chars[i]) { i += 1 }
            guard i < chars.count else { return nil }

            // Left end (trim spaces before the dash)
            var leftEnd = i
            while leftEnd > 0 && chars[leftEnd - 1].isWhitespace { leftEnd -= 1 }

            // Right start: skip contiguous dash-like chars and spaces after
            var j = i
            while j < chars.count, dashSet.contains(chars[j]) { j += 1 }
            while j < chars.count, chars[j].isWhitespace { j += 1 }

            let left = String(chars[0..<leftEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            var rEnd = chars.count
            while rEnd > j && chars[rEnd - 1].isWhitespace { rEnd -= 1 }
            let right = String(chars[j..<rEnd]).trimmingCharacters(in: .whitespacesAndNewlines)

            if left.isEmpty || right.isEmpty { return nil }
            return (left, right)
        }

        return text
            .components(separatedBy: .newlines)
            .compactMap { line -> ParsedTrack? in
                guard let (artist, title) = splitArtistTitle(line) else { return nil }
                return ParsedTrack(title: title, artist: artist)
            }
    }

    // Builds .xplaylist JSON data
    static func makeXPlaylistData(playlistName: String, tracks: [ParsedTrack]) throws -> Data {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let trackObjects: [[String: Any]] = tracks.map { t in
            return [
                "title": t.title,
                "artist": t.artist,
                "album": NSNull(),
                "isrc": NSNull(),
                "artwork": ["url": NSNull()]
            ]
        }

        let payload: [String: Any] = [
            "version": 1,
            "source": "txt",
            "generated_at": iso.string(from: Date()),
            "playlist_name": playlistName,
            "tracks": trackObjects
        ]

        return try JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted)
    }

    // Saves to Documents/PlaylistHistory/<playlistName>.xplaylist
    static func saveToHistory(playlistName: String, data: Data) throws -> URL {
        let fm = FileManager.default
        let docs = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = docs.appendingPathComponent("PlaylistHistory", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let safeName = playlistName.replacingOccurrences(of: "/", with: "-")
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = df.string(from: Date())
        let dest = dir.appendingPathComponent("\(safeName)-\(stamp).xplaylist")
        try data.write(to: dest, options: .atomic)
        #if DEBUG
        print("Saved TXT import to: \(dest.path)")
        #endif
        return dest
    }
}

