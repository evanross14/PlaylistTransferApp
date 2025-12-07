//
//  ShareViewController.swift
//  Playlist Transfer
//
//  Created by Evan Ross on 11/25/25.
//

import UIKit
import UniformTypeIdentifiers

class ShareViewController: UIViewController {

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // Log available provider types for diagnostics
        if let item = self.extensionContext?.inputItems.first as? NSExtensionItem, let attachments = item.attachments {
            for provider in attachments {
                #if DEBUG
                print("[ShareExt] Provider types: \(provider.registeredTypeIdentifiers)")
                #endif
            }
        }

        extractSharedURL { [weak self] sharedURL in
            guard let self = self else { return }

            guard let finalURL = sharedURL else {
                #if DEBUG
                print("[ShareExt] Unable to resolve a URL from attachments")
                #endif
                self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
                return
            }

            // Persist to App Group as a fallback so the main app can pick it up later
            self.persistURLToAppGroup(finalURL)

            // Build deep link to the main app with safer encoding (exclude reserved characters)
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "&+=?#")
            let encoded = finalURL.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            let deepLinkString = "playlisttransferapp://import?source=spotify&url=\(encoded)"
            guard URL(string: deepLinkString) != nil else {
                #if DEBUG
                print("[ShareExt] Failed to build deep link from: \(deepLinkString)")
                #endif
                self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
                return
            }

            DispatchQueue.main.async {
                let alert = UIAlertController(title: nil, message: "Open transfer playlist app to continue", preferredStyle: .alert)

                alert.addAction(UIAlertAction(title: "Close", style: .cancel, handler: { _ in
                    self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
                }))

                self.present(alert, animated: true)
            }
        }
    }
}

// MARK: - Extraction helpers
private extension ShareViewController {
    func extractSharedURL(completion: @escaping (URL?) -> Void) {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = item.attachments else {
            completion(nil)
            return
        }

        #if DEBUG
        for provider in attachments {
            print("[ShareExt] Attachment registered types: \(provider.registeredTypeIdentifiers)")
        }
        #endif

        // Prefer a direct URL attachment
        if let provider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                DispatchQueue.main.async {
                    let url = item as? URL
                    completion(url)
                }
            }
            return
        }

        // Fallback: a text attachment that might contain a URL string
        if let provider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.text.identifier) }) {
            provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { item, _ in
                DispatchQueue.main.async {
                    if let text = item as? String { completion(self.extractURLFromText(text)) } else { completion(nil) }
                }
            }
            return
        }

        completion(nil)
    }

    func extractURLFromText(_ text: String?) -> URL? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        // A very simple parse: try the whole string first; otherwise, find a URL inside
        if let direct = URL(string: text) { return direct }

        // Try to detect a URL within the text using NSDataDetector
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(location: 0, length: (text as NSString).length)
            if let match = detector.firstMatch(in: text, options: [], range: range), let url = match.url {
                return url
            }
        }
        return nil
    }

    func persistURLToAppGroup(_ url: URL) {
        let appGroupID = "group.com.EvanRoss.playlisttransfer"
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            let fileURL = container.appendingPathComponent("incoming_url.txt")
            do {
                try url.absoluteString.write(to: fileURL, atomically: true, encoding: .utf8)
                #if DEBUG
                print("[ShareExt] Wrote incoming URL to app group: \(fileURL.path)")
                #endif
            } catch {
                #if DEBUG
                print("[ShareExt] Failed writing incoming URL to app group: \(error)")
                #endif
            }
        } else {
            #if DEBUG
            print("[ShareExt] App group container not found for ID: \(appGroupID)")
            #endif
        }
    }
}

