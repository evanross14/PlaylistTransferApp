import Foundation
import AuthenticationServices
import Security
import Combine
import CryptoKit
import UIKit

struct PKCE {
    static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "Failed to generate random bytes")
        return Data(bytes).base64URLEncodedString()
    }

    static func codeChallenge(for verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hashed = SHA256.hash(data: data)
        return Data(hashed).base64URLEncodedString()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        return self.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

final class KeychainStore {
    private let service: String

    init(service: String) {
        self.service = service
    }

    func set(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var newItem = query
        newItem[kSecValueData as String] = data

        let status = SecItemAdd(newItem as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandledError(status: status)
        }
    }

    func get(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            return result as? Data
        }
        return nil
    }

    func remove(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledError(status: status)
        }
    }

    enum KeychainError: Error {
        case unhandledError(status: OSStatus)
    }
}

struct SpotifyTokens: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
}

final class SpotifyAuthManager: NSObject, ObservableObject {
    private let clientID: String = "YourSpotifyDeveloperTokenHere"
    private let redirectScheme: String = "playlisttransferapp"
    private let redirectURI: String = "playlisttransferapp://callback"

    @Published private(set) var isSignedIn: Bool = false
    @Published private(set) var currentAccessToken: String? = nil

    private var tokens: SpotifyTokens? { didSet { Task { await MainActor.run { self.updatePublishedState() } } } }
    private let keychain = KeychainStore(service: "com.example.playlisttransferapp.spotify")
    private let tokensAccount = "spotify.tokens"

    private var authSession: ASWebAuthenticationSession?
    private var pendingCodeVerifier: String?

    override init() {
        super.init()
        if let data = keychain.get(account: tokensAccount),
           let decoded = try? JSONDecoder().decode(SpotifyTokens.self, from: data) {
            self.tokens = decoded
            Task {
                do {
                    try await self.ensureFreshTokenIfNeeded()
                } catch {
                    // Log but don't fail initialization
                    print("[SpotifyAuthManager] Failed to refresh token on init: \(error)")
                }
            }
        }
    }

    func signIn() async throws {
        let verifier = PKCE.randomVerifier()
        let challenge = PKCE.codeChallenge(for: verifier)
        self.pendingCodeVerifier = verifier

        var comps = URLComponents(string: "https://accounts.spotify.com/authorize")!
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: "playlist-modify-private playlist-modify-public user-read-email"),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "show_dialog", value: "true")
        ]
        let authURL = comps.url!

        let callbackURL = try await startAuthSession(authURL: authURL)
        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "code" })?
            .value else {
            throw URLError(.badServerResponse)
        }
        guard let verifierToUse = pendingCodeVerifier else { throw URLError(.cannotDecodeContentData) }
        self.pendingCodeVerifier = nil

        let tokenResponse = try await exchangeCodeForToken(code: code, codeVerifier: verifierToUse)
        let expiresAt = Date().addingTimeInterval(TimeInterval(tokenResponse.expires_in))
        let stored = SpotifyTokens(accessToken: tokenResponse.access_token, refreshToken: tokenResponse.refresh_token, expiresAt: expiresAt)
        try persist(tokens: stored)
        self.tokens = stored
    }

    func signOut() {
        try? keychain.remove(account: tokensAccount)
        tokens = nil
        currentAccessToken = nil
        isSignedIn = false
    }

    func provideValidAccessToken() async throws -> String {
        try await ensureFreshTokenIfNeeded()
        if let t = tokens?.accessToken { return t }
        throw URLError(.userAuthenticationRequired)
    }

    private func startAuthSession(authURL: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: redirectScheme) { url, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let url = url else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                continuation.resume(returning: url)
            }
            session.prefersEphemeralWebBrowserSession = true
            session.presentationContextProvider = self
            self.authSession = session
            let started = session.start()
            if !started {
                continuation.resume(throwing: URLError(.cannotLoadFromNetwork))
            }
        }
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let token_type: String
        let expires_in: Int
        let refresh_token: String?
        let scope: String
    }

    private func exchangeCodeForToken(code: String, codeVerifier: String) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "client_id": clientID,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": codeVerifier
        ]
        req.httpBody = urlEncoded(body).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func refreshAccessToken(refreshToken: String) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]
        req.httpBody = urlEncoded(body).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    @MainActor
    private func updatePublishedState() {
        let token = tokens?.accessToken
        self.currentAccessToken = token
        self.isSignedIn = token != nil
    }

    private func persist(tokens: SpotifyTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        try keychain.set(data, account: tokensAccount)
    }

    private func ensureFreshTokenIfNeeded() async throws {
        guard var stored = tokens else { return }
        if stored.expiresAt.timeIntervalSinceNow < 60 {
            guard let refresh = stored.refreshToken else { return }
            let resp = try await refreshAccessToken(refreshToken: refresh)
            stored.accessToken = resp.access_token
            stored.expiresAt = Date().addingTimeInterval(TimeInterval(resp.expires_in))
            if let newRefresh = resp.refresh_token, !newRefresh.isEmpty { stored.refreshToken = newRefresh }
            try persist(tokens: stored)
            await MainActor.run { self.tokens = stored }
        }
    }

    private func urlEncoded(_ dict: [String: String]) -> String {
        dict.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }
}

extension SpotifyAuthManager: ASWebAuthenticationPresentationContextProviding {
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Prefer a key window if available
        if let keyWindow = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) {
            return keyWindow
        }

        // Fall back to the first window in the first active window scene
        if let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first,
           let existingWindow = windowScene.windows.first {
            return existingWindow
        }

        // If we have any window scene at all, construct a temporary window using init(windowScene:)
        if let anyWindowScene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            return UIWindow(windowScene: anyWindowScene)
        }

        // If no window scenes are available (highly unusual), try to return any existing window from any scene.
        if let anyWindow = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first {
            return anyWindow
        }

        // As a final fallback (should not normally happen), return a dummy ASPresentationAnchor via a new window
        // created with init(windowScene:) if we can obtain a scene at runtime.
        // We avoid using the deprecated frame-based initializer entirely.
        preconditionFailure("No available UIWindowScene or UIWindow to present ASWebAuthenticationSession.")
    }
}
