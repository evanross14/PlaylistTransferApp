import Foundation
import MusicKit
import Combine

@MainActor
final class AppleMusicAuthManager: ObservableObject {
    @Published private(set) var isSignedIn: Bool = false

    init() {
        Task { await refreshState() }
    }

    func signIn() async throws {
        let status = await MusicAuthorization.request()
        switch status {
        case .authorized:
            isSignedIn = true
        case .restricted, .denied:
            isSignedIn = false
            throw NSError(domain: "AppleMusicAuth", code: 1, userInfo: [NSLocalizedDescriptionKey: "Apple Music access denied."])
        case .notDetermined:
            isSignedIn = false
            throw NSError(domain: "AppleMusicAuth", code: 2, userInfo: [NSLocalizedDescriptionKey: "Authorization not determined."])
        @unknown default:
            isSignedIn = false
            throw NSError(domain: "AppleMusicAuth", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unknown authorization state."])
        }
    }

    func refreshState() async {
        let status = MusicAuthorization.currentStatus
        isSignedIn = (status == .authorized)
    }
}

