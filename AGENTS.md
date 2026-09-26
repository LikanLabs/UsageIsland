# Usage Island — Repository Instructions

## Product

Usage Island is a native macOS application that shows AI coding usage at the
edge of the screen: beside the MacBook notch, or on the left or right edge.

The approved visual baseline is the black CodexEdge interface: an attached
pill with the Codex mark inside a usage ring, and a details panel that holds
both usage and settings. The user explicitly approved it on 2026-09-05 as the
replacement for the earlier v26 prototype, which was removed on 2026-09-26.

The product supports Codex and Claude Code. The pill shows the provider in
use most recently; the details panel shows every provider.

## Non-negotiable visual baseline

Do not redesign, resize, restyle, simplify, or reinterpret the approved
CodexEdge UI.

Preserve:

- the pill attached to the screen edge or the base of the notch;
- left, right and top (notch) positions and the auto-hide behavior;
- the usage ring, its remaining-quota colors and the dashed stale state;
- details panel dimensions, corner radii, spacing and typography;
- usage rows, footer controls and the in-panel settings page;
- opening, closing and page-transition animations, including Reduce Motion;
- the geometry in `EdgeWindowGeometry` and `ScreenNotchGeometry`.

Do not modify these files unless the user explicitly requests a visual change
or a compile fix:

- Sources/UsageIslandPrototype/UI/CodexEdgeView.swift
- Sources/UsageIslandPrototype/UI/CodexMark.swift
- Sources/UsageIslandPrototype/UI/AppearanceSettingsView.swift
- Sources/UsageIslandPrototype/Window/CodexEdgeWindowController.swift
- Sources/UsageIslandPrototype/Window/EdgeWindowGeometry.swift
- Sources/UsageIslandPrototype/Window/EdgePanelNavigation.swift
- Sources/UsageIslandPrototype/Window/DockVisibilityState.swift
- Sources/UsageIslandPrototype/Window/ScreenNotchGeometry.swift

Backend work must adapt to the existing frontend, not the opposite.

## Technical baseline

- Swift 6 strict concurrency.
- macOS 14 or later.
- SwiftUI for content.
- AppKit and Core Animation for notch windows and surfaces.
- No backend server.
- No Usage Island account system.
- No telemetry by default.
- No third-party dependencies without explicit approval.

## Architecture boundaries

New backend code must be separated into these responsibilities:

- Domain: provider-independent models and errors.
- Providers: Codex and Claude adapters.
- Infrastructure: processes, JSON-RPC, caching, clocks and filesystem access.
- Store: observable application state consumed by the existing UI.
- AgentMonitoring: agent discovery and normalized activity.

The UI must consume normalized domain snapshots. It must never parse provider
responses, launch subprocesses, read credentials or calculate provider rules.

## Provider scope

Usage Island supports Codex through `codex app-server` and Claude Code through
its status line bridge. Other usage providers and synthetic demo providers are
outside the product scope.

## Data rules

- Store usage as `usedPercent` in the domain layer.
- Expose `remainingPercent` as a computed value.
- Clamp percentages to `0...100`.
- Use absolute reset dates internally.
- Never infer official quota percentages from token totals or local cost logs.
- Preserve the last valid snapshot when refresh fails.
- Mark old values as stale instead of replacing them with fake values.
- Never present demo data as real data.

## Codex integration rules

- Reuse the installed Codex CLI and its existing authentication.
- Do not read or copy Codex credentials.
- Use stdio JSON-RPC with newline-delimited JSON.
- Complete `initialize` and `initialized` before other requests.
- Generate or inspect schemas from the installed Codex version.
- Treat stderr as diagnostics, never as protocol data.
- Use bounded timeouts and graceful process shutdown.
- Redact secrets and personal information from logs.

## Claude integration rules

- Read plan limits only from the `rate_limits` field that Claude Code passes to
  its status line command; the app's own executable is that command
  (`--claude-statusline`).
- Store only the rate-limit percentages, reset times and capture time.
- Never read Claude credentials, the Keychain, OAuth tokens or private
  endpoints such as `api/oauth/usage`.
- Change only the `statusLine` key of `~/.claude/settings.json`, only on the
  user's request, and never replace a status line the user already has.

## Security

- Never log tokens, cookies, authorization headers, complete environment
  variables or credential-file contents.
- Never commit real provider responses containing personal information.
- Tests must use synthetic fixtures.
- Browser cookie access is out of scope until explicitly approved.
- Full Disk Access must not be required for the initial Codex integration.

## Development workflow

Before modifying code:

1. Inspect the relevant implementation and tests.
2. State which files will change.
3. Explain how the CodexEdge visual baseline will remain unchanged.
4. Prefer the smallest coherent change.

After modifying code:

1. Run `swift test` and `./Scripts/verify-resilience.sh`.
2. Build the macOS executable when AppKit is available.
3. Inspect `git diff`.
4. Report tests, failures, limitations and changed files.
5. Do not claim a provider works without real or fixture-backed verification.

Do not create commits unless the user explicitly requests one.
