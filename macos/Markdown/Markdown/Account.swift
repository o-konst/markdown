//
//  Account.swift
//  Markdown
//
//  The signed-in person.
//
//  There is no server behind this yet: signing in records a name and email locally so the
//  sidebar can show an account. Swapping in a real service means replacing `logIn` and the
//  storage, not the views.
//

import SwiftUI

@Observable
final class Account {
    private(set) var fullName: String
    private(set) var email: String

    var isLoggedIn: Bool { !fullName.isEmpty }

    /// Initials for the sidebar's avatar, e.g. "Ada Lovelace" becomes "AL".
    var initials: String {
        let letters = fullName
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    init() {
        let defaults = UserDefaults.standard
        fullName = defaults.string(forKey: PreferenceKey.accountName) ?? ""
        email = defaults.string(forKey: PreferenceKey.accountEmail) ?? ""
    }

    func logIn(fullName: String, email: String) {
        let name = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        self.fullName = name
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines)

        UserDefaults.standard.set(self.fullName, forKey: PreferenceKey.accountName)
        UserDefaults.standard.set(self.email, forKey: PreferenceKey.accountEmail)
    }

    func logOut() {
        fullName = ""
        email = ""
        UserDefaults.standard.removeObject(forKey: PreferenceKey.accountName)
        UserDefaults.standard.removeObject(forKey: PreferenceKey.accountEmail)
    }
}
