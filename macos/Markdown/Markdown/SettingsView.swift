//
//  SettingsView.swift
//  Markdown
//
//  Modal sheet holding the rendering options. Each control writes straight to
//  `UserDefaults`, which `ContentView` reads back to push into the web UI.
//

import SwiftUI

struct SettingsView: View {
    /// False when the open document has no sections, which makes the outline moot.
    let isOutlineAvailable: Bool

    @AppStorage(PreferenceKey.outlineVisible) private var outlineVisible = true
    @AppStorage(PreferenceKey.contentWidth) private var contentWidth = ContentWidth.full
    @AppStorage(PreferenceKey.fontSize) private var fontSize = FontSize.standard
    @AppStorage(PreferenceKey.appearance) private var appearance = AppAppearance.system

    /// Loaded from and written straight back to the Keychain — never `UserDefaults`, and
    /// never sent to the web view.
    @State private var apiKey = Keychain.apiKey() ?? ""

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Assistant") {
                    SecureField("Anthropic API key", text: $apiKey)
                        .onChange(of: apiKey) { _, newValue in
                            Keychain.setApiKey(newValue.trimmingCharacters(in: .whitespacesAndNewlines))
                        }

                    Link("Get an API key from console.anthropic.com",
                         destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                        .font(.caption)
                }

                Section("Contents") {
                    Toggle("Show contents tree", isOn: $outlineVisible)
                        .disabled(!isOutlineAvailable)

                    if !isOutlineAvailable {
                        Text("The open document has no sections to navigate.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Width", selection: $contentWidth) {
                        ForEach(ContentWidth.allCases) { width in
                            Text(width.label).tag(width)
                        }
                    }
                    .pickerStyle(.segmented)

                    Stepper(value: $fontSize, in: FontSize.range, step: 1) {
                        Text("Font size: \(Int(fontSize)) pt")
                    }

                    Button("Reset to defaults") {
                        appearance = .system
                        contentWidth = .full
                        fontSize = FontSize.standard
                    }
                    .disabled(
                        appearance == .system
                            && contentWidth == .full
                            && fontSize == FontSize.standard
                    )
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 400)
    }
}

#Preview {
    SettingsView(isOutlineAvailable: true)
}
