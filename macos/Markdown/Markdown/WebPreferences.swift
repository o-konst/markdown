//
//  WebPreferences.swift
//  Markdown
//
//  Rendering options the settings window owns, stored in `UserDefaults` and pushed to the
//  web UI, which does the actual rendering.
//

import SwiftUI

enum PreferenceKey {
    static let outlineVisible = "outlineVisible"
    static let contentWidth = "contentWidth"
    static let fontSize = "fontSize"
    static let appearance = "appearance"
    static let accountName = "accountName"
    static let accountEmail = "accountEmail"
}

/// Light, dark, or whatever the system is doing.
///
/// Applied to the window, which the web view reads back through `prefers-color-scheme`,
/// so the native chrome and the rendered document stay in step without a second setting.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var label: String {
        switch self {
        case .system: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// `nil` hands the decision back to the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// How wide the rendered document is allowed to run.
enum ContentWidth: String, CaseIterable, Identifiable {
    /// Fills the pane, the behaviour before this option existed.
    case full
    /// Caps the measure so long lines stay readable.
    case page

    var id: Self { self }

    var label: String {
        switch self {
        case .full: "Full width"
        case .page: "Page width"
        }
    }
}

enum FontSize {
    static let standard = 16.0
    static let range = 11.0...24.0
}

/// The snapshot handed to the web UI.
///
/// `Equatable` so the coordinator can skip pushing when nothing actually changed.
struct WebPreferences: Equatable {
    var outlineVisible: Bool
    var contentWidth: ContentWidth
    var fontSize: Double

    /// Shape the web UI's `normalizePreferences` expects.
    var payload: [String: Any] {
        [
            "outlineVisible": outlineVisible,
            "contentWidth": contentWidth.rawValue,
            "fontSize": fontSize,
        ]
    }
}
