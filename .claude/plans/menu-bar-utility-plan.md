# Plan: menu bar utility as the MCP workspace manager — macOS only

**Status: not started.** Checklist-style plan; check items off as they land, keep in sync  
if the design changes during implementation (same convention as  
`.claude/plans/recent-vaults-plan.md`, `.claude/plans/welcome-screen-plan.md`).

> **This plan was rewritten on 2026-08-28 after the feature was redefined.** The previous  
> revision described a `MenuBarExtra` *scene inside the main app*, sharing one hoisted  
> `Workspace`, doing quick capture / search / recent notes. That design is **superseded and**  
> **dropped in full** — the utility is now a *separate always-running process* that shares no  
> state with the editor, and its job is configuring MCP access. Nothing from the old  
> Phases A–F survives; in particular the `Workspace` hoist, `AppUI`, the termination-policy  
> flip, quick capture, and menu bar search are all no longer needed. Anything already built  
> against the old plan should be reverted, not adapted.

**Platform scope: macOS only, deliberately.** `MenuBarExtra`, `SMAppService`, launchd  
socket activation, and security-scoped bookmarks have no WinUI 3 equivalents, and the  
Windows app ships no MCP server today. This is an accepted, documented divergence from the  
file-for-file macOS↔Windows mirroring in `CLAUDE.md` — the same category as the existing  
MCP sidecar.

## Goal

Three processes, deliberately independent:


| #   | Process                                   | Lifetime                                                   | Job                                                                                                                                                                    |
| --- | ----------------------------------------- | ---------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | **Markdown.app** (existing editor)        | User-launched                                              | File tree, editor, AI chat pane. Also a **second config surface**: a sidebar-toolbar "Add to MCP" action and an MCP section in Settings. Installs the login item once. |
| 2   | **Markdown MCP Manager** (new helper app) | Login item — runs from login, with or without the editor   | `MenuBarExtra` status item listing the folders MCP may reach. Add/remove workspaces; each add writes a security-scoped bookmark into the App Group container.          |
| 3   | **solomd-mcp** (existing Rust binary)     | launchd agent, socket-activated on first client connection | Serves MCP over the socket, reading its workspace list from the App Group container.                                                                                   |


The helper is the **configuration surface for MCP**, nothing more. It does not open, edit,  
render, or search notes, and it holds no `Workspace`.

## Context — what already exists

Confirmed by reading the sources this session:

- `solomd-mcp` **is already multi-workspace and already speaks HTTP.** `src/main.rs` takes  
repeated `--workspace [alias=]path`, and `--transport stdio|http` with `--bind` and a  
bearer token from `SOLOMD_MCP_TOKEN`, plus `--allow-write` (read-only by default). The  
helper's entire output is therefore *a list of workspaces*, which is exactly the argument  
surface the binary already has. This is a much better fit than it looks at first glance.
- **The binary is already built, bundled, and signed on macOS.** `rust/build-xcode.sh`  
builds it per-arch, `lipo`s it, copies it into `Contents/MacOS/`, and **explicitly**  
**re-signs** it. `build-and-development.md` records the two silent-SIGKILL failure modes  
behind that (Mach-O in `Contents/Resources/`; cargo's ad-hoc linker signature inside an  
already-signed bundle). Both apply again, unchanged, to whichever bundle the binary  
ends up in.
- **Nothing launchd-related exists yet.** A repo-wide search for `SMAppService`,  
`LaunchAgent`, `launchd`, and `LoginItem` returns no hits in Swift, plists, or the Xcode  
project. This is entirely greenfield.
- **The App Group already exists and is already in use.** `Markdown.entitlements` declares  
`group.com.ogay.webviewtest.Markdown`, and `RecentVaultsStore` (`RecentVaults.swift`)  
already writes bookmarks into that suite via  
`UserDefaults(suiteName:) ?? .standard`, using `.withSecurityScope` with a plain-bookmark  
fallback. The bookmark-creation code is already written and can be lifted verbatim.
- **The main app is sandboxed**: `app-sandbox`, `files.user-selected.read-write`,  
`files.bookmarks.app-scope`, `network.client`.
- `solomd-mcp` **still has its own path confinement.** `src/safety.rs` and `src/workspace.rs`  
are independent of `markdown_vault::confine`, and `security.md` §1 calls this  
*"the most consequential open security item found while documenting this codebase."*  
See the hard prerequisite below — this feature is what makes that gap matter.
- `MACOSX_DEPLOYMENT_TARGET = 26.5`, so `SMAppService` (macOS 13+) and every `MenuBarExtra`  
API are available unconditionally.

## Phase 0 — two blocking spikes, before any feature work

Both are load-bearing assumptions that the rest of the plan rests on, and **neither is**  
**something to discover halfway through**. Do these first, in a throwaway branch.

### Spike 1 — can the MCP agent resolve the helper's bookmarks? (the big one)

The premise "save a security-scoped bookmark to the App Group container so the newly  
launched Rust process can instantly access the files" is **not a documented Apple**  
**guarantee**, and it is the single riskiest assumption here.

What is solid:

- `.withSecurityScope` bookmarks are **app-scoped**: resolvable by the app that created  
them. Apple documents app-scoped and document-scoped bookmarks; "app-group-scoped" is not  
a thing.
- `com.apple.security.application-groups` shares a *group container directory*. It does  
**not** merge sandbox containers, and bookmark scope is keyed to the container.
- `com.apple.security.inherit` only works for processes the parent spawns directly. A  
launchd agent is launched by **launchd**, so it cannot inherit the helper's sandbox.

Reports of a same-Team-ID, same-App-Group helper successfully resolving the main app's  
app-scoped bookmarks exist, and so do reports of it failing with  
`NSFileReadNoPermissionError`. **Measure it; don't assume it.**

- [ ] Build a throwaway sandboxed GUI app + a nested launchd agent, same Team ID, same App
  ```
  Group. GUI picks a folder, writes a `.withSecurityScope` bookmark to the group
  container. Agent resolves it, calls `startAccessingSecurityScopedResource()`, and
  tries to read a `.md` file. Record the exact result.
  ```
- [ ] Repeat with the folder in `~/Documents` (TCC-protected) and in `~/Notes`
  ```
  (unprotected). These behave differently and the difference decides the fallback.
  ```

**Fallback ladder, in the order to prefer them:**

- **A — agent ships unsandboxed** (no `app-sandbox` entitlement, hardened runtime, same  
Team ID). It then needs no bookmark: the group container carries the **paths**, and  
"configuration for MCP" is literally a path list. Cost: TCC still gates `~/Desktop`,  
`~/Documents`, `~/Downloads`, iCloud Drive, and external volumes, and a background  
launchd agent **cannot meaningfully prompt for TCC consent**. A vault in `~/Documents/Notes`  
— a very common location — would fail with no usable error. Mitigate by detecting the  
denial and surfacing "grant Full Disk Access to the MCP agent" in the helper's menu, with  
a deep link to the right System Settings pane.
- **B — helper hosts MCP in-process** and the launchd agent is dropped. The helper is a  
login item and is therefore already running; it holds the scope legitimately; everything  
stays sandboxed and correct. Cost: loses socket activation and on-demand lifetime.  
**This is the pragmatic winner if Spike 1 fails and TCC makes A unacceptable.**
- **C — helper vends open directory file descriptors to the agent over XPC**, and Rust does  
every path operation `openat`-relative to that fd. Definitively correct under sandbox, and  
a deep, invasive rewrite of `confine.rs`'s whole model. Record it as the known-correct  
option; do not choose it without a strong reason.

Write the outcome into `.claude/docs/security.md` either way — it is a durable fact about  
this codebase that the next person should not have to re-derive.

### Spike 2 — `SMAppService` from a nested helper, and the dev loop

- [ ] Confirm `SMAppService.agent(plistName:)` called **from the nested helper app** reads
  ```
  the plist from the *helper's* `Contents/Library/LaunchAgents/`, not the outer app's.
  ```
- [ ] Confirm `SMAppService.loginItem(identifier:)` registration from the main app succeeds
  ```
  and that the helper actually launches at the next login.
  ```
- [ ] **Measure the dev-loop cost.** `SMAppService` registration is unreliable for apps run
  ```
  out of `DerivedData` and generally wants the app in `/Applications`, signed. If the
  loop is "copy to /Applications and re-approve in System Settings on every build," say
  so in `build-and-development.md` now — it will otherwise be rediscovered painfully
  once per contributor.
  ```
- [ ] Confirm `SMAppService.Status` reporting (`.enabled` / `.requiresApproval` / `.notFound`)
  ```
  so the helper can tell the user "macOS is waiting for your approval in System Settings"
  instead of silently doing nothing.
  ```

## Hard prerequisite — converge `solomd-mcp` onto `markdown_vault`

This is not optional scope, and it is not padding.

Today the MCP server is a manually-configured, developer-only, single-vault sidecar, so its  
private `safety.rs` confinement is a latent risk. **This feature turns it into a login-item-**  
**managed, multi-workspace, always-reachable surface over a network socket.** That converts  
`security.md` §1 from "known duplication" into "the actual attack surface," and it does so  
for folders the user added through a friendly menu without necessarily thinking of them as  
"exposed to an agent."

- [ ] Repoint `solomd-mcp`'s tool implementations at `markdown_vault::tools::call`, per
  ```
  invariant #1 and the vendoring author's own `PROVENANCE.md` (which already names this
  as the intended, not-yet-done fix).
  ```
- [ ] Delete `vendor/solomd-mcp/src/safety.rs` and the parts of `workspace.rs` that
  ```
  duplicate `markdown_vault` scanning, once nothing references them.
  ```
- [ ] Run `markdown_vault`'s 16 adversarial confinement tests (symlink escape, `%2e%2e`,
  ```
  the `/vault-evil` vs `/vault` prefix case) **through the MCP entry point** so both
  paths are covered by one suite.
  ```
- [ ] `cd rust && cargo test` green.

If this cannot be done first, the honest alternative is to ship the helper with MCP writes  
disabled entirely — `--allow-write` never passed and the decision-6 toggle absent from both  
surfaces, not merely defaulted off — and add  
write support only after convergence. **Do not ship a multi-workspace writable MCP surface**  
**on the unconverged confinement.**

## Key design decisions

1. **The helper is a separate app target, not a scene.** `MarkdownMCPManager.app`, built  
into `Markdown.app/Contents/Library/LoginItems/`, `LSUIElement = YES`, a single  
`MenuBarExtra` scene and no windows other than its panel. A `MenuBarExtra` inside the  
editor cannot run when the editor isn't running, which is the whole requirement.  
It gets its own `.entitlements`: `app-sandbox`, `files.user-selected.read-write`,  
`files.bookmarks.app-scope`, and the **same App Group**.
2. **No shared in-memory state with the editor — by construction.** Separate processes,  
separate `Workspace`s (the helper has none). The only shared thing is the App Group  
container on disk. The editor's `Workspace`, editor pane, chat, and watcher are  
untouched; what it does gain is a config surface (decisions 12–13) writing into that same  
on-disk store — **not** a shared object.
3. **The MCP workspace list is a *new, separate* store — not** `RecentVaultsStore`**, and it is**  
**the only thing MCP can reach.** New `MCPWorkspaceStore`, new file, same App Group  
container. The agent serves exactly the folders in that list and nothing else: not the  
recently-opened list, not the currently-open vault, not `$HOME`. Conflating with  
`RecentVaultsStore` would silently expose every folder the user has ever opened in the  
editor to an external agent. **Granting MCP access is always an explicit act**, performed  
in one of exactly two places — the helper's menu, or the editor (decisions 12–13). This  
is the security core of the feature and must not be "simplified" away later.
4. **Config lives in a JSON *file* in the group container, not** `UserDefaults`**.**  
`…/Library/Group Containers/group.com.ogay.webviewtest.Markdown/mcp-workspaces.json`.  
Reasons: the Rust agent has to read it (parsing a plist from Rust is avoidable work);  
cross-process `UserDefaults` change notification on macOS is unreliable; and a file can  
be watched with `DispatchSource` and written with `NSFileCoordinator`. Schema, versioned  
from day one:
  ```jsonc
   { "version": 1,
     "allowWrite": false,          // global; see decision 6
     "workspaces": [
       { "id": "uuid", "alias": "notes", "path": "/Users/…/Notes",
         "bookmark": "base64…", "addedAt": "2026-08-28T…" }
     ] }
  ```

   Both `path` and `bookmark` are stored: sandboxed readers (helper, editor) use the  
   bookmark, and an unsandboxed agent under fallback A uses the path. Which one the agent  
   uses is decided by Spike 1, and the file format does not have to change either way.  
   **There is deliberately no per-workspace** `writable` **field in v1** — a stored flag that  
   nothing enforces is worse than no flag, because the next reader assumes it is a control.  
   Per-workspace granularity arrives with a `"version": 2` bump if it is ever wanted.
5. **Adding a workspace is:** `NSOpenPanel` **→ bookmark → write → done.** The helper is  
sandboxed with `files.user-selected.read-write`, so the user's pick *is* the grant. Reuse  
`RecentVaultsStore.makeBookmark(for:)` verbatim — including its plain-bookmark fallback —  
rather than writing a second bookmark path.
6. **Write access is ONE global toggle, default off — decided, not open.** "Allow MCP to  
edit notes" is a single setting stored as `allowWrite` in the config file (decision 4), and  
it maps exactly onto `solomd-mcp`'s existing global `--allow-write`: present when true,  
absent when false. **No Rust change, no per-workspace flag, no partial states.**
  - **The consequence, to state in the UI rather than bury:** turning it on grants write  
  access to **every** configured workspace at once, and adding a workspace afterwards  
  inherits that. The toggle's label and the add flow must both say so — "Allow MCP to  
  edit notes in all workspaces" reads correctly; "Allow editing" does not.
    - Every workspace row therefore shows the *same* mode, derived from the one toggle. Do  
    not render it as a per-row control that happens to move together — that invites the  
    user to believe in granularity that does not exist.
    - Default off, and it must survive the first-run path as off. Read-only is the safe  
    state and the one the vendored binary already defaults to.
    - Per-workspace granularity is a deliberate v2 item: it needs a `solomd-mcp` change  
    (per-workspace write flags, not a single global) plus the `"version": 2` schema bump.
7. **Transport: socket-activated loopback HTTP, with a bearer token.** `solomd-mcp` already  
has `--transport http --bind` and `SOLOMD_MCP_TOKEN`, and MCP clients accept an HTTP URL,  
so this needs the least new surface. **But launchd socket activation is not the same as**  
**binding an address**: the agent must call `launch_activate_socket("Listener", …)` and  
build its listener from the handed-down fd. That is a real, new Rust change (`libc`  
extern + `TcpListener::from_raw_fd` into axum), not a config flag. Budget for it.  
*Security note, to write into* `security.md`*:* **a loopback TCP port is reachable by every**  
**process running on the machine.** The bearer token is the only gate. A Unix-domain socket  
inside the group container (0700) is meaningfully stronger and launchd supports it —  
prefer it if a stdio shim for clients that can't speak Unix sockets proves cheap.
8. **The agent reads its workspace list from the config file, not from** `ProgramArguments`**.**  
Baking `--workspace` flags into the plist would mean rewriting and re-registering the  
plist on every add/remove. Add `--workspace-config <path>` to `solomd-mcp` instead; the  
socket-activated process re-reads it at each launch. After a config change the helper  
kicks the running agent (`launchctl kickstart -k`, or the agent watches the file) so the  
next connection sees the new list.
9. **Ownership: registration is single-owner, config is shared.**  
*Registration* keeps one rule — the **main app** registers the helper  
(`SMAppService.loginItem`); the **helper** registers the MCP agent  
(`SMAppService.agent`), so the editor keeps working with MCP entirely absent. Consequence  
to state plainly in the UI: **the main app must be run once** to install the login item;  
after that neither app needs launching again for the helper and MCP to work at every login.  
*Config* is deliberately **two-writer**: the editor and the helper both add/remove  
workspaces, because the editor is where you already have the folder open and the helper is  
what exists when the editor doesn't. Neither is the "primary" — see decision 14 for how  
they stay consistent.
10. **The MCP binary and its LaunchAgent plist move into the helper's bundle** —  
`MarkdownMCPManager.app/Contents/MacOS/solomd-mcp` and  
`…/Contents/Library/LaunchAgents/com.ogay.webviewtest.Markdown.mcp.plist`. Both  
`build-xcode.sh` gotchas (`Contents/MacOS/` not `Resources/`; explicit re-sign) apply  
unchanged to the new destination, and getting either wrong is a **silent SIGKILL with**  
**no diagnostic**.
11. **Removing a workspace revokes access, visibly.** Remove from the JSON, drop the  
bookmark, and kick the agent so a running server stops serving it. A "removed" workspace  
that a live agent still holds an open scope on is the kind of gap that makes a security  
control decorative.
12. **Editor toolbar action: "Add to MCP", on the open folder, with no picker.** A new  
`ToolbarItem` in `SidebarView`'s existing `.toolbar` (`SidebarView.swift:162`), beside the  
"Open" (`folder.badge.plus`) and "New" menus — that toolbar is already the folder-scoped  
one, so this belongs there rather than in the detail pane's editor toolbar.  
**No** `NSOpenPanel` **is needed for the open folder:** the editor already holds live  
security-scoped access to it (`Workspace.scopedResource`), so  
`bookmarkData(options: .withSecurityScope)` succeeds right there. Behavior:
  - Disabled when `workspace.root == nil` — a single opened file has no folder to share,  
  matching how search and the assistant already gate themselves.
  - **Not yet shared** → a one-click button whose label names the grant  
  (`Add "Notes" to MCP`), not a bare icon.
  - **Already shared** → a visibly distinct *filled/active* icon opening a menu showing the  
  current global mode as **read-only information** ("MCP access: read-only" /  
  "MCP access: read and write — all workspaces") plus "Remove from MCP". The write toggle  
  itself lives only in Settings and the helper (decision 6) — putting it on a per-folder  
  menu would read as per-folder, which it is not.
  - That menu also carries "Add Another Folder…" → `NSOpenPanel`, so a folder that isn't  
  the open one can still be added without leaving the editor.
  - Pick two clearly different SF Symbols for the two states (e.g.  
  `folder.badge.gearshape` vs. a filled/`sparkles` variant). A grant whose on/off state  
  isn't obvious at a glance is the failure mode here.
  - **First-time explainer**: the first add shows a one-off popover saying plainly that  
  this lets an external AI agent read (or edit) that folder, with "Don't show again".  
  No modal confirmation after that — the state is visible and one click revokes it.
13. **Editor Settings gets the full list, not a link.** An "MCP" section in `SettingsView`  
showing every configured workspace with the same add/remove controls as the helper, the one  
global write toggle (decision 6), plus agent status and the connection URL/token. This  
**supersedes** the earlier  
"`SettingsView` links to the helper — one editor of that list" note: the redefinition  
reverses it, and there are now two equal editors of one on-disk list.
14. **Two writers means coordinated read-modify-write, not read-then-write.** Every mutation  
re-reads the JSON, applies the change, and writes it back **inside a single**  
`NSFileCoordinator` **coordinated write block**. Mutating an in-memory copy loaded earlier  
and writing the whole array back is the obvious implementation, and it silently drops the  
other process's concurrent add. Both processes also watch the file (`DispatchSource`) so each  
reflects the other's changes live — the toolbar icon's shared/not-shared state has to track a  
change made in the helper while the editor is open.
15. `MCPWorkspaceStore` **is one source file compiled into both targets**, never copied. Two  
copies of a security control's storage logic is exactly the mistake `security.md` §1 already  
documents for path confinement; don't reproduce its shape here. Both app targets use  
`PBXFileSystemSynchronizedRootGroup`, so shared membership needs either a per-file membership  
exception or a small shared framework target. **Start with the membership exception** (two  
files, least machinery); move to a framework only if the shared surface grows.

## Non-goals

- No quick capture, no note search, no recent-notes list in the menu — all dropped with the  
previous revision. The helper configures access; it does not use it.
- No Windows equivalent.
- No editing of MCP client configs (`claude_desktop_config.json` etc.) on the user's behalf.  
Show the URL and token to copy; writing another app's config file is not this app's place.
- No remote/non-loopback MCP exposure.
- **No implicit exposure of any kind.** Opening a folder in the editor, having it in Recent  
Vaults, or being the parent of a shared folder never grants MCP access — only an explicit add  
in the helper or the editor does (decision 3).
- No changes to the editor's `Workspace`, editor pane, chat, or watcher. The editor's only  
new surface is the sidebar toolbar item and the Settings section.

## Checklist

### Phase A — helper app target, no MCP yet

- [ ] New Xcode target `MarkdownMCPManager` (macOS app, `LSUIElement = YES`), embedded via a
  ```
  Copy Files phase into `Markdown.app/Contents/Library/LoginItems/`.
  ```
- [ ] `MarkdownMCPManager.entitlements`: `app-sandbox`, `files.user-selected.read-write`,
  ```
  `files.bookmarks.app-scope`, app group `group.com.ogay.webviewtest.Markdown`.
  ```
- [ ] `MCPManagerApp.swift`: `MenuBarExtra` with `.menuBarExtraStyle(.window)` — the default
  ```
  `.menu` style cannot host a `List`, and the panel needs one. Shell content: a title, an
  empty state, and "Quit".
  ```
- [ ] Verify: helper launches, status item appears, editor unaffected.

### Phase B — the workspace store

- [ ] `MCPWorkspaceStore.swift`, **compiled into both the helper and the editor** (decision

  15 — membership exception, not a copy): `@Observable`, the decision-4 JSON schema,  
  read/write via `NSFileCoordinator` into the group container, `add(url:)` / `remove(_:)` /  
  `contains(url:)`, plus the single global `allowWrite` property. **No per-workspace write**  
  **API** — the store should make v1's granularity impossible to misuse, not merely unused.
- [ ] Every mutation is a **coordinated read-modify-write** in one block (decision 14), not

  a whole-array overwrite of a stale in-memory copy. This is the two-writer correctness  
  requirement, and it is invisible until two surfaces are used at once.
- [ ] `contains(url:)` compares `standardizedFileURL.path`, matching how

  `VaultStore.relativePath(of:in:)` and `Workspace` already compare paths — the toolbar's  
  shared/not-shared state depends on it agreeing with the store.
- [ ] Bookmark creation lifted from `RecentVaultsStore.makeBookmark(for:)`, fallback intact.
- [ ] `DispatchSource` watch on the config file so a second process's edit is reflected live.
- [ ] Handle the group container being unavailable (entitlement not provisioned) with a
  ```
  visible error — **not** `RecentVaultsStore`'s silent `?? .standard` fallback, which
  would write config the agent can never read.
  ```

### Phase C — the menu UI

- [ ] Panel lists workspaces: folder icon, `alias`, abbreviated path, and a remove control.
- [ ] One "Allow MCP to edit notes in all workspaces" toggle in the panel footer — a single

  global control (decision 6), never a per-row one — defaulting to off, with the mode shown  
  once at the top of the list rather than repeated per row.
- [ ] "Add Workspace…" → `NSOpenPanel` (`canChooseDirectories`) → `store.add(url:)`.
  ```
  `NSApp.activate()` first, or the panel opens behind everything.
  ```
- [ ] Per-row "Reveal in Finder" and "Copy path".
- [ ] Empty state explaining what an MCP workspace *is* — the user is granting an external
  ```
  AI agent read (or write) access to a folder, and the UI should say so rather than
  presenting it as a bookmark list.
  ```
- [ ] Footer: MCP server status, the connection URL + "Copy token", "Open Markdown", "Quit".

### Phase D — the launchd agent

- [ ] `com.ogay.webviewtest.Markdown.mcp.plist` in the helper bundle's
  ```
  `Contents/Library/LaunchAgents/`, with a `Sockets` entry (`Listener`) and
  `ProgramArguments` pointing at the bundled `solomd-mcp` with `--transport http`,
  `--workspace-config <group container path>`.
  ```
- [ ] `rust/build-xcode.sh`: build/lipo/copy `solomd-mcp` into the **helper's**
  ```
  `Contents/MacOS/`, and **re-sign it explicitly**. Re-read
  `build-and-development.md`'s MCP section before touching this — both gotchas are live.
  ```
- [ ] `solomd-mcp`: add `--workspace-config <path>` reading the decision-4 JSON.
- [ ] The launcher passes `--allow-write` **only** when the config's `allowWrite` is true —

  the flag's presence is the entire mechanism (decision 6). Absent by default; no new Rust  
  flag, no per-workspace variant.
- [ ] Toggling `allowWrite` kicks the agent like any other config change (decision 11), so a

  running server never keeps write access the user just revoked. **Test the revoke direction**  
  **specifically** — write→read-only is the one that matters, and it is the easy one to miss.
- [ ] `solomd-mcp`: adopt the launchd socket via `launch_activate_socket` instead of binding
  ```
  `--bind`, keeping `--bind` for manual/CLI use.
  ```
- [ ] Token generation + storage (Keychain, or the group container with 0600) and injection
  ```
  into the agent's environment.
  ```
- [ ] Helper registers/unregisters via `SMAppService.agent`, surfacing
  ```
  `.requiresApproval` as a real message with a System Settings deep link.
  ```
- [ ] Helper kicks the agent after any config change (decision 11).

### Phase E — the editor as the second config surface

- [ ] Add `MCPWorkspaceStore.swift` to the editor target (decision 15) and hold one instance

  at app scope — `@State` in `MarkdownApp`, passed to `ContentView`/`SidebarView`. This is  
  the *only* new shared object in the editor; `Workspace` stays exactly where it is.
- [ ] `SidebarView`: new `ToolbarItem` implementing decision 12 in full — disabled state,

  unshared one-click add, shared menu (global mode shown read-only, "Remove from MCP",  
  "Add Another Folder…"), and two visually distinct symbols.
- [ ] The add path uses `Workspace.root!.url` directly and creates the bookmark under the

  editor's live scoped access — no `NSOpenPanel` for the already-open folder.
- [ ] First-time explainer popover + its "Don't show again" `@AppStorage` key.
- [ ] `SettingsView`: "MCP" section per decision 13 — full list with add/remove, the one

  global "Allow MCP to edit notes in all workspaces" toggle (default off), agent status,  
  connection URL, "Copy token", and the helper's enable/disable toggle.
- [ ] Verify the global toggle round-trips between the two surfaces: flip it in Settings →

  the helper's footer reflects it live, and vice versa (decision 14's file watch).
- [ ] Main app registers the helper via `SMAppService.loginItem` on first run.
- [ ] File-watch wiring so a change made in the helper updates the toolbar state and the

  Settings list live while the editor is open (decision 14).
- [ ] Verify: add from the editor → appears in the helper's menu; remove in the helper →

  the editor's toolbar icon returns to unshared without a relaunch.
- [ ] Verify: the editor still launches, opens vaults, and quits normally with the helper

  absent, disabled, and running. Three states, all tested.

### Phase F — docs and verification

- [ ] `.claude/docs/security.md`: new section on the MCP surface — Spike 1's measured
  ```
  outcome, the loopback-port exposure and token gate, the global-write-toggle policy and its
  all-workspaces blast radius, and the §1 convergence status. Update §1 itself if the
  prerequisite landed.
  ```
- [ ] `.claude/docs/architecture.md`: three-process diagram and a parity-matrix row marked
  ```
  macOS-only by design.
  ```
- [ ] `.claude/docs/build-and-development.md`: helper target, the LoginItems copy phase, the
  ```
  re-signing step for the relocated binary, and Spike 2's dev-loop findings.
  ```
- [ ] `CLAUDE.md`: note that a *second* menu bar process exists, that MCP reaches **only**

  explicitly-added workspaces, and that the list has exactly two editors (helper menu,  
  editor toolbar/Settings) over one coordinated on-disk file — so nobody adds a third.
- [ ] `cd rust && cargo test` green.
- [ ] End-to-end: add a workspace in the helper → point Claude Code at the MCP URL →

  `list_notes` returns that vault → remove it → the next call cannot see it.
- [ ] End-to-end, the other direction: add from the **editor toolbar** → the helper's menu

  shows it → MCP serves it → remove from the helper → the editor's toolbar updates live.
- [ ] Negative test: a folder that is open in the editor but never added is **not** reachable

  over MCP, and neither is anything in Recent Vaults. This is decision 3's guarantee and it  
  deserves an explicit test, not an assumption.

## Risks and things likely to bite

1. **Spike 1 failing is a design change, not a bug fix.** If the agent cannot resolve the  
bookmarks, the fallback ladder is real work with real trade-offs. Do not start Phase D  
before Spike 1 has an answer written down.
2. **Two writers to one list is the quiet correctness bug in this feature.** An uncoordinated  
read-modify-write loses the other process's add with no error and no visible symptom until  
someone notices a workspace "unshared itself." Decision 14 is not boilerplate — treat a  
whole-array overwrite in review as a defect.
3. **A one-click toolbar grant is easy to make too quiet.** The action hands an external agent  
standing access to the open folder. The state must be unmistakable at a glance, the label  
must name what it does, and revoke must be one click — otherwise the convenience is the  
vulnerability.
4. **TCC, not the sandbox, is the likely real blocker.** `~/Documents/Notes` is exactly  
where people keep notes, and it is exactly the case where an unsandboxed background agent  
fails silently. Spike 1's second bullet is the one that matters most.
5. **The two** `build-xcode.sh` **gotchas will re-fire in the new bundle** and both present as a  
silent SIGKILL with no diagnostic. Budget debugging time proportional to how mysterious  
that failure looks.
6. `SMAppService` **in the dev loop** may force copy-to-`/Applications` and re-approval on  
every build. Find out in Spike 2, not in Phase D.
7. **This widens the security surface more than the UI suggests.** A friendly "+ Add  
Workspace" button grants an external agent standing access to a folder over a local  
socket. The unconverged `safety.rs` prerequisite, the default-read-only policy, and the  
revoke-on-remove behavior are the three things keeping that honest — none of them are  
polish, and none should be deferred to "v2."
8. **The global write toggle is blunt on purpose, and that has to be visible.** One flip  
grants write access to every configured workspace at once, including ones added later. The  
simplification is the right v1 call — it matches `solomd-mcp`'s existing flag exactly and  
needs no Rust change — but it means the label must name the blast radius and the control  
must not appear per-folder. A user who believes they enabled writes for one vault has been  
misled by the UI, not by the design.
9. **Two processes writing one App Group container.** Use `NSFileCoordinator` on both sides  
and assume neither is running when the other writes.
10. **This cannot be verified from the machine this plan was written on** (Windows). Every  
spike and verify item needs a Mac with Xcode; `cargo test` is the only check runnable  
here, and the Rust changes in the prerequisite and Phase D do need it.

