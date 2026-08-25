//
//  Keychain.swift
//  Markdown
//
//  Stores the Anthropic API key in the login keychain. Kept out of UserDefaults and out of
//  the web view: a note can contain arbitrary HTML, so anything reachable from JavaScript is
//  exfiltratable by a crafted note. The key lives here and is only ever handed to Rust.
//

import Foundation
import Security

nonisolated enum Keychain {
    private static let service = "com.ogay.webviewtest.Markdown.anthropic-api-key"

    static func apiKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// An empty key clears the stored one, so the settings field's own emptiness is the
    /// only state that needs tracking.
    static func setApiKey(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)

        guard !key.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(key.utf8)
        // Available once the user has unlocked the Mac once after boot; not synced to iCloud.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
