import Foundation
import ActivityKit
import Combine

public struct ExportActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var progress: Double    // 0.0 ... 1.0
        public var message: String
        public var didSucceed: Bool
        public init(progress: Double, message: String, didSucceed: Bool) {
            self.progress = progress
            self.message = message
            self.didSucceed = didSucceed
        }
    }

    public var playlistName: String
    public init(playlistName: String) { self.playlistName = playlistName }
}

public enum ExportMilestone {
    case authorizing
    case preparing
    case creating
    case finalizing
    case success
    case failure
}

@MainActor
public final class ExportActivityController: ObservableObject {

    private(set) public var activity: Activity<ExportActivityAttributes>?

    public init() {}

    public func start(playlistName: String) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            let attributes = ExportActivityAttributes(playlistName: playlistName)
            let state = ExportActivityAttributes.ContentState(progress: 0.0, message: "Starting…", didSucceed: false)
            activity = try Activity<ExportActivityAttributes>.request(attributes: attributes, content: .init(state: state, staleDate: nil), pushType: nil)
        } catch {
            #if DEBUG
            print("Live Activity start failed: \(error)")
            #endif
        }
    }

    public func update(for milestone: ExportMilestone) async {
        guard let activity else { return }
        let (progress, message, didSucceed): (Double, String, Bool) = {
            switch milestone {
            case .authorizing: return (0.15, "Authorizing…", false)
            case .preparing:   return (0.35, "Preparing playlist…", false)
            case .creating:    return (0.75, "Creating playlist…", false)
            case .finalizing:  return (0.95, "Finalizing…", false)
            case .success:     return (1.00, "Success", true)
            case .failure:     return (1.00, "Failed", false)
            }
        }()
        let newState = ExportActivityAttributes.ContentState(progress: progress, message: message, didSucceed: didSucceed)
        if #available(iOS 16.2, *) {
            await activity.update(using: newState)
        } else {
            await activity.update(using: newState)
        }
    }

    public func end(success: Bool) async {
        guard let activity else { return }
        let final = ExportActivityAttributes.ContentState(progress: 1.0, message: success ? "Success" : "Failed", didSucceed: success)
        if #available(iOS 16.2, *) {
            await activity.end(.init(state: final, staleDate: nil), dismissalPolicy: success ? .immediate : .default)
        } else {
            await activity.end(using: final, dismissalPolicy: success ? .immediate : .default)
        }
        self.activity = nil
    }
}

