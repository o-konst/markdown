//
//  LoginView.swift
//  Markdown
//
//  Sign-in sheet. Records the account locally; see `Account` for why there is no network
//  call here.
//

import SwiftUI

struct LoginView: View {
    let account: Account

    @State private var fullName = ""
    @State private var email = ""

    @Environment(\.dismiss) private var dismiss

    private var canSubmit: Bool {
        !fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Log In")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 20)

            Form {
                TextField("Full name", text: $fullName)
                TextField("Email", text: $email)
                    #if !os(macOS)
                    .textInputAutocapitalization(.never)
                    #endif
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Log In") {
                    account.logIn(fullName: fullName, email: email)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
            .padding(12)
        }
        .frame(width: 360)
    }
}

#Preview {
    LoginView(account: Account())
}
