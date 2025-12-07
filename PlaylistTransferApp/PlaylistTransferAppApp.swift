//
//  PlaylistTransferAppApp.swift
//  PlaylistTransferApp
//
//  Created by Evan Ross on 11/24/25.
//

import SwiftUI
import SwiftData

extension Notification.Name {
    static let incomingTXTFileURL = Notification.Name("IncomingTXTFileURL")
    static let incomingImportURL = Notification.Name("IncomingImportURL")
}

@main
struct PlaylistTransferAppApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    let scheme = url.scheme?.lowercased()
                    if scheme == "file" || scheme == "shareddocuments" {
                        // Handle plain text file opened via "Open In..."
                        if url.pathExtension.lowercased() == "txt" {
                            NotificationCenter.default.post(name: .incomingTXTFileURL, object: url)
                            return
                        }
                    }

                    guard scheme == "playlisttransferapp" else { return }

                    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    let host = url.host?.lowercased()
                    let path = url.path
                    let isImport = (host == "import") || (path == "/import")
                    guard isImport,
                          let urlQuery = components?.queryItems?.first(where: { $0.name == "url" })?.value,
                          let sharedURL = URL(string: urlQuery) else { return }

                    #if DEBUG
                    print("[App] Received deep link (host: \(host ?? "nil"), path: \(path)) with shared URL: \(sharedURL)")
                    #endif

                    NotificationCenter.default.post(name: .incomingImportURL, object: sharedURL)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        readIncomingURLFromAppGroup()
                    }
                }
        }
        .modelContainer(sharedModelContainer)
    }
}

private func readIncomingURLFromAppGroup() {
    let appGroupID = "group.com.EvanRoss.playlisttransfer"
    guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
        #if DEBUG
        print("[MainApp] App group container not found for ID: \(appGroupID)")
        #endif
        return
    }
    let fileURL = container.appendingPathComponent("incoming_url.txt")

    guard let s = try? String(contentsOf: fileURL, encoding: .utf8), let url = URL(string: s) else {
        return
    }

    NotificationCenter.default.post(name: .incomingImportURL, object: url)
    try? FileManager.default.removeItem(at: fileURL)
    #if DEBUG
    print("[MainApp] Posted IncomingImportURL with: \(url.absoluteString)")
    #endif
}

