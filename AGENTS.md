# Usage Island — Repository Instructions

## Product

Usage Island is a native macOS application that shows AI coding usage at the
edge of the screen: beside the MacBook notch, or on the left or right edge.

The approved visual baseline is the Liquid Glass interface the user approved
on 2026-09-26 (it replaced the earlier black CodexEdge look, which in turn
replaced the v26 prototype): a glass pill attached to a screen edge, or a
black pill at the base of the notch, with the active provider's mark inside a
usage ring, and a glass details panel with one card of ring gauges per
provider plus an in-panel settings page. On macOS 14–25 the glass falls back
to a system material.

The product supports Codex and Claude Code. The pill shows one limit of the
provider in use most recently (its 5-hour window when the plan has one,
otherwise the weekly limit) and names it; the details panel shows every
provider and every limit.

## Non-negotiable visual baseline

Do not redesign, resize, restyle, simplify, or reinterpret the approved
Liquid Glass UI.

Preserve:

- the pill attached to the screen edge (glass) or the base of the notch
  (black), and its single labelled limit ("5 hours" or "weekly");
- left, right and top (notch) positions and the auto-hide behavior;
- the usage rings, their remaining-quota colors, the dashed stale state and
  the reset countdown when a limit is used up;
- the glass panel's dimensions, corner radii, spacing and typography;
- provider cards, gauge rows, header controls and the in-panel settings page;
- opening, closing and page-transition animations, including Reduce Motion;
- the geometry in `EdgeWindowGeometry` and `ScreenNotchGeometry`;
- the app icon (the glass pill), rendered by `Scripts/render-app-icon.swift`.

Do not modify these files unless the user explicitly requests a visual change
or a compile fix:

- Sources/UsageIslandPrototype/UI/CodexEdgeView.swift
- Sources/UsageIslandPrototype/UI/IslandGlass.swift
- Sources/UsageIslandPrototype/UI/AppearanceSettingsView.swift
- Sources/UsageIslandPrototype/UI/CodexMark.swift
- Sources/UsageIslandPrototype/UI/ClaudeMark.swift
- Sources/UsageIslandPrototype/UI/ProviderMark.swift
- Sources/UsageIslandPrototype/Window/CodexEdgeWindowController.swift
- Sources/UsageIslandPrototype/Window/EdgeWindowGeometry.swift
- Sources/UsageIslandPrototype/Window/EdgePanelNavigation.swift
- Sources/UsageIslandPrototype/Window/DockVisibilityState.swift
- Sources/UsageIslandPrototype/Window/ScreenNotchGeometry.swift
- Scripts/render-app-icon.swift and Assets/AppIcon/

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
its CLI's `get_usage` request. Both are detected automatically and need no
setup; avoid adding per-provider connect steps. Other usage providers and
synthetic demo providers are outside the product scope.

## Data rules

- Store usage as `usedPercent` in the domain layer.
- Expose `remainingPercent` as a computed value.
- Clamp percentages to `0...100`.
- Use absolute reset dates internally.
- Never infer official quota percentages from token totals or local cost logs.
- Forecasts ("runs out ~16:40 at this pace") extrapolate only official
  readings from the last half hour, appear only during recent use, and are
  always worded as estimates, never as quota figures.
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

- Show every window Codex reports: the `codex` bucket first, then other
  buckets of `rateLimitsByLimitId` that carry a `limitName`, labelled with it.

## Claude integration rules

- Read plan limits only from Claude Code itself: the CLI's `get_usage` control
  request, run isolated with `--restricted`, `--strict-mcp-config`,
  `--tools ""` and `--no-session-persistence`, no prompt, at most every two
  minutes, with `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` and
  `DISABLE_AUTOUPDATER=1`.
- The `get_usage` shape is experimental; parse strictly and fall back to the
  last valid reading. Read limits from its ordered `limits` rows, classified
  only by `kind` (`session`, `weekly_all`, `weekly_scoped` with its scope
  name); skip unknown kinds instead of guessing.
- Store only the rate-limit percentages, reset times and capture time.
- Never read Claude credentials, the Keychain, OAuth tokens or private
  endpoints such as `api/oauth/usage`.
- Do not write to `~/.claude/settings.json`. The only exception is removing
  the status line that versions 0.1.3–0.1.7 added (`--claude-statusline`),
  never a status line the user wrote. The executable must keep exiting
  quietly when called with `--claude-statusline`.

## System integration rules

- The first launch opens the panel once on the welcome page; people upgrading
  from a version without it never see it. macOS is asked for notification
  permission only when the user finishes it, or turns alerts on later.
- New installs show the available percentage by default.
- Notifications are local only (`UNUserNotificationCenter`), alert only on a
  change observed from fresh official readings (never on the first reading
  or stale data), and respect the "Alert when running low" preference.
- Opening at login uses `SMAppService.mainApp` and is off until the user turns
  it on.
- Relaunch after an update only when the bundle on disk reports a different,
  complete version and the panel is closed.
- Pause polling while the screen is locked or the displays sleep; stretch the
  interval in Low Power Mode.

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
3. Explain how the Liquid Glass visual baseline will remain unchanged.
4. Prefer the smallest coherent change.

After modifying code:

1. Run `swift test` and `./Scripts/verify-resilience.sh`.
2. Build the macOS executable when AppKit is available.
3. Inspect `git diff`.
4. Report tests, failures, limitations and changed files.
5. Do not claim a provider works without real or fixture-backed verification.

Do not create commits unless the user explicitly requests one.
