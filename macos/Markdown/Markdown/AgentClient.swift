//
//  AgentClient.swift
//  Markdown
//
//  Swift facade over the Rust `markdown_agent` library, which owns the whole conversation
//  with Claude — the HTTP call, the tool loop, and the safety caps. Mirrors VaultStore.swift
//  in shape: a handle, one blocking call pumped on a background thread, JSON in and out.
//
//  There is no callback from Rust into Swift. `md_agent_poll_event` blocks and returns one
//  event at a time; this facade drains it on a plain `Thread` (not a cooperative Task, since
//  the call can block for as long as the model takes to answer) and delivers each event back
//  to whichever queue the caller asks for.
//

import Foundation

/// One thing the chat view might want to show, decoded from the JSON `md_agent_poll_event`
/// returns. Delivered on a background thread — callers hop to the main actor themselves.
nonisolated enum AgentEvent: Equatable {
    case text(String)
    case thinking(String)
    case toolStarted(name: String)
    case toolFinished(name: String, ok: Bool, detail: String, commit: String?)
    case refused(category: String?, explanation: String?)
    case failed(String)
    case done(stopReason: String)
}

/// Lets the FFI handle cross into `Thread.detachNewThread`'s `@Sendable` closure.
///
/// `OpaquePointer` carries no Sendable conformance because the compiler cannot see what it
/// points to. This one is safe to move across threads: Rust's `MdAgent` serialises every
/// call behind its own mutex, and the handle is only ever used to poll the one channel that
/// belongs to it — nothing here reaches back into unsynchronised Swift state.
private struct AgentHandle: @unchecked Sendable {
    let pointer: OpaquePointer
}

nonisolated final class AgentClient {
    private let handle: OpaquePointer

    /// Fails if the vault path cannot be opened; the API key itself is not validated until
    /// the first request.
    init?(vaultRoot: URL, apiKey: String) {
        guard let handle = vaultRoot.path.withCString({ path in
            apiKey.withCString { key in md_agent_open(path, key) }
        }) else {
            return nil
        }
        self.handle = handle
    }

    deinit {
        md_agent_close(handle)
    }

    /// Sends `text` and streams the reply. `onEvent` fires on a background thread for every
    /// event, ending with exactly one `.done`, `.refused`, or `.failed`.
    ///
    /// Returns `false` without sending anything if a turn is already running.
    @discardableResult
    func send(_ text: String, onEvent: @escaping (AgentEvent) -> Void) -> Bool {
        guard text.withCString({ md_agent_send_start(handle, $0) }) else {
            return false
        }

        let session = AgentHandle(pointer: handle)
        Thread.detachNewThread {
            while let raw = md_agent_poll_event(session.pointer) {
                let json = String(cString: raw)
                md_string_free(raw)
                if let event = Self.decode(json) {
                    onEvent(event)
                }
            }
        }
        return true
    }

    private static func decode(_ json: String) -> AgentEvent? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else {
            return nil
        }

        switch type {
        case "text":
            return (object["text"] as? String).map(AgentEvent.text)
        case "thinking":
            return (object["text"] as? String).map(AgentEvent.thinking)
        case "tool_started":
            guard let name = object["name"] as? String else { return nil }
            return .toolStarted(name: name)
        case "tool_finished":
            guard let name = object["name"] as? String,
                  let ok = object["ok"] as? Bool,
                  let detail = object["detail"] as? String
            else {
                return nil
            }
            return .toolFinished(name: name, ok: ok, detail: detail, commit: object["commit"] as? String)
        case "refused":
            return .refused(
                category: object["category"] as? String,
                explanation: object["explanation"] as? String
            )
        case "failed":
            return (object["message"] as? String).map(AgentEvent.failed)
        case "done":
            return (object["stop_reason"] as? String).map(AgentEvent.done)
        default:
            return nil
        }
    }
}
