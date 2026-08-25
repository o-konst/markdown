//
//  ChatView.swift
//  Markdown
//
//  The assistant sheet: a transcript plus a composer, opened from the sidebar's "Assistant"
//  button. Every tool call it makes goes through the same VaultStore-backed Rust vault the
//  editor writes through, so its edits are saved, undoable, and show up in the file tree.
//

import SwiftUI

struct ChatView: View {
    /// `nil` when no folder is open; the composer disables itself rather than pretending.
    let vaultRoot: URL?

    @State private var viewModel = ChatViewModel()
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            composer
        }
        .frame(width: 420, height: 560)
        .task { isInputFocused = true }
    }

    private var header: some View {
        HStack {
            Label("Assistant", systemImage: "sparkles")
                .font(.headline)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if viewModel.messages.isEmpty {
                        emptyState
                    }
                    ForEach(viewModel.messages) { message in
                        ChatMessageRow(message: message, viewModel: viewModel, vaultRoot: vaultRoot)
                            .id(message.id)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: viewModel.messages.count) {
                guard let last = viewModel.messages.last else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Ask About Your Notes", systemImage: "sparkles")
        } description: {
            Text(
                vaultRoot == nil
                    ? "Open a folder to give the assistant something to work with."
                    : "It can search, read, and edit the notes in this folder. Every change is saved and can be undone."
            )
        }
        .padding(.top, 40)
        .frame(maxWidth: .infinity)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask the assistant…", text: $viewModel.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .focused($isInputFocused)
                    .disabled(vaultRoot == nil)
                    .onSubmit(send)

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .disabled(sendDisabled)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (⌘↩)")
            }
        }
        .padding(12)
    }

    private var sendDisabled: Bool {
        vaultRoot == nil
            || viewModel.isResponding
            || viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard let vaultRoot, !sendDisabled else { return }
        viewModel.send(vaultRoot: vaultRoot)
    }
}

/// One row of the transcript: a chat bubble, or a tool-call line with a status glyph.
private struct ChatMessageRow: View {
    let message: ChatMessage
    let viewModel: ChatViewModel
    let vaultRoot: URL?

    var body: some View {
        switch message.kind {
        case .user(let text):
            bubble(text, alignment: .trailing, tint: .accentColor.opacity(0.15))
        case .assistant(let text):
            bubble(text.isEmpty ? "…" : text, alignment: .leading, tint: .clear)
        case .tool(let name, let ok, let detail, let commit):
            HStack(spacing: 6) {
                statusIcon(for: ok)
                Text(name)
                    .font(.caption.monospaced())
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let commit {
                    Spacer(minLength: 4)
                    undoButton(commit: commit)
                }
            }
        case .notice(let text):
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder
    private func undoButton(commit: String) -> some View {
        if viewModel.undoneCommits.contains(commit) {
            Text("Undone")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let vaultRoot {
            Button("Undo") {
                viewModel.undo(commit: commit, vaultRoot: vaultRoot)
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
    }

    @ViewBuilder
    private func statusIcon(for ok: Bool?) -> some View {
        switch ok {
        case .some(true):
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
        case .some(false):
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case nil:
            ProgressView().controlSize(.small)
        }
    }

    private func bubble(_ text: String, alignment: HorizontalAlignment, tint: Color) -> some View {
        HStack {
            if alignment == .trailing { Spacer(minLength: 32) }
            Text(text)
                .textSelection(.enabled)
                .padding(10)
                .background(tint, in: RoundedRectangle(cornerRadius: 10))
            if alignment == .leading { Spacer(minLength: 32) }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
    }
}

#Preview {
    ChatView(vaultRoot: nil)
}
