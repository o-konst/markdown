//
//  ChatViewModel.swift
//  Markdown
//
//  The chat transcript and the one AgentClient turn in flight at a time.
//

import Foundation
import Observation

struct ChatMessage: Identifiable {
    enum Kind {
        case user(String)
        case assistant(String)
        case tool(name: String, ok: Bool?, detail: String, commit: String?)
        /// A refusal or failure, shown inline rather than as an assistant reply.
        case notice(String)
    }

    let id = UUID()
    var kind: Kind
}

@Observable
final class ChatViewModel {
    private(set) var messages: [ChatMessage] = []
    var draft = ""
    private(set) var isResponding = false
    private(set) var errorMessage: String?

    /// Recreated whenever the vault changes, so a stale session is never reused.
    private var client: AgentClient?
    private var clientVaultRoot: URL?

    /// Commit ids already reverted from this transcript, so a tool row's Undo button can't
    /// be used twice.
    private(set) var undoneCommits: Set<String> = []

    /// Separate from `client`/`clientVaultRoot`: undo is a plain vault call, not an agent turn.
    private var vault: VaultStore?
    private var vaultRoot: URL?

    func send(vaultRoot: URL) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isResponding else { return }

        guard let client = client(for: vaultRoot) else { return }

        draft = ""
        errorMessage = nil
        messages.append(ChatMessage(kind: .user(text)))
        let assistantIndex = messages.count
        messages.append(ChatMessage(kind: .assistant("")))
        isResponding = true

        let started = client.send(text) { [weak self] event in
            Task { @MainActor in
                self?.apply(event, assistantIndex: assistantIndex)
            }
        }
        if !started {
            // Can only happen if a previous turn's background thread has not finished
            // draining yet; `isResponding` normally prevents this from being reachable.
            isResponding = false
            messages.removeLast(2)
            draft = text
            errorMessage = "The assistant is still finishing the last message."
        }
    }

    /// Opens (or reuses) the session for `vaultRoot`. Fails, with a message set, when there
    /// is no API key yet.
    private func client(for vaultRoot: URL) -> AgentClient? {
        if let client, clientVaultRoot == vaultRoot {
            return client
        }
        guard let key = Keychain.apiKey(), !key.isEmpty else {
            errorMessage = "Add an Anthropic API key in Settings to use the assistant."
            return nil
        }
        guard let opened = AgentClient(vaultRoot: vaultRoot, apiKey: key) else {
            errorMessage = "Could not open the assistant for this folder."
            return nil
        }
        client = opened
        clientVaultRoot = vaultRoot
        return opened
    }

    /// Reverts an earlier tool call by the commit id shown on its row. The revert is itself a
    /// new commit (`History::revert`), so this can't lose data — it can only be called once
    /// per commit from here, tracked by `undoneCommits`, to keep the transcript honest about
    /// what's already been undone.
    func undo(commit: String, vaultRoot: URL) {
        guard !undoneCommits.contains(commit) else { return }
        guard let vault = vault(for: vaultRoot) else { return }

        do {
            try vault.undo(commit: commit)
            undoneCommits.insert(commit)
            messages.append(ChatMessage(kind: .notice("Undid that change.")))
        } catch {
            messages.append(ChatMessage(kind: .notice("Could not undo: \(error.localizedDescription)")))
        }
    }

    /// Opens (or reuses) the vault for `vaultRoot`, independent of the agent `client` above.
    private func vault(for vaultRoot: URL) -> VaultStore? {
        if let vault, self.vaultRoot == vaultRoot {
            return vault
        }
        guard let opened = try? VaultStore(root: vaultRoot) else {
            messages.append(ChatMessage(kind: .notice("Could not open the vault to undo that change.")))
            return nil
        }
        vault = opened
        self.vaultRoot = vaultRoot
        return opened
    }

    @MainActor
    private func apply(_ event: AgentEvent, assistantIndex: Int) {
        guard assistantIndex < messages.count else { return }

        switch event {
        case .text(let delta):
            if case .assistant(let existing) = messages[assistantIndex].kind {
                messages[assistantIndex].kind = .assistant(existing + delta)
            }

        case .thinking:
            // Summarised reasoning; not surfaced in this first pass.
            break

        case .toolStarted(let name):
            messages.append(ChatMessage(kind: .tool(name: name, ok: nil, detail: "Running…", commit: nil)))

        case .toolFinished(let name, let ok, let detail, let commit):
            // Matched by name from the end: tools can run more than once in a turn, so this
            // finds the most recent still-running row for that name rather than the first.
            if let index = messages.lastIndex(where: {
                if case .tool(name, nil, _, _) = $0.kind { return true }
                return false
            }) {
                messages[index].kind = .tool(name: name, ok: ok, detail: detail, commit: commit)
            }

        case .refused(let category, let explanation):
            isResponding = false
            let reason = [category, explanation].compactMap { $0 }.joined(separator: ": ")
            messages.append(ChatMessage(
                kind: .notice(reason.isEmpty ? "The assistant declined to continue." : reason)
            ))

        case .failed(let message):
            isResponding = false
            messages.append(ChatMessage(kind: .notice(message)))

        case .done:
            isResponding = false
        }
    }
}
