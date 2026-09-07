# Usage Island — Repository Instructions

## Product

Usage Island is a native macOS application that extends both sides of the
MacBook notch to show AI coding usage and agent activity.

The approved visual baseline is the v26 prototype.

The current implementation phase is to replace demo data with real provider
data without redesigning the interface.

## Non-negotiable visual baseline

Do not redesign, resize, restyle, simplify, or reinterpret the approved v26 UI.

Preserve:

- notch geometry;
- left and right wings;
- Pulse panel dimensions;
- Core Animation surface renderer;
- opening and closing animations;
- provider expansion animation;
- typography;
- spacing;
- colors;
- corner radii;
- provider row layout;
- active-agent section;
- footer layout.

Do not modify these files unless the user explicitly requests a visual change
or a compile fix:

- Sources/UsageIslandPrototype/UI/PulseView.swift
- Sources/UsageIslandPrototype/UI/UnifiedIslandSurfaceView.swift
- Sources/UsageIslandPrototype/UI/UnifiedIslandView.swift
- Sources/UsageIslandPrototype/UI/VisualTokens.swift
- Sources/UsageIslandPrototype/UI/WingViews.swift
- Sources/UsageIslandPrototype/Window/IslandWindowController.swift
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
- Providers: Codex adapters.
- Infrastructure: processes, JSON-RPC, caching, clocks and filesystem access.
- Store: observable application state consumed by the existing UI.
- AgentMonitoring: agent discovery and normalized activity.

The UI must consume normalized domain snapshots. It must never parse provider
responses, launch subprocesses, read credentials or calculate provider rules.

## Provider scope

Usage Island supports Codex through `codex app-server`. Other usage providers
and synthetic demo providers are outside the product scope.

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
3. Explain how the v26 visual baseline will remain unchanged.
4. Prefer the smallest coherent change.

After modifying code:

1. Run `swift test`.
2. Build the macOS executable when AppKit is available.
3. Inspect `git diff`.
4. Report tests, failures, limitations and changed files.
5. Do not claim a provider works without real or fixture-backed verification.

Do not create commits unless the user explicitly requests one.
