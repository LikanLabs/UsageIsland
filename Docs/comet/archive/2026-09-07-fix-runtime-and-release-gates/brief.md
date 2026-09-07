# Outcome

Usage Island keeps the approved v26 Pulse UI and recovers from four confirmed
runtime and release defects without treating demo data as live usage.

After this change:

- A child process that closes stdout or stderr while still running no longer
  busy-loops on that pipe.
- If Codex is missing at launch, installing or restoring the CLI is enough for
  a later refresh to succeed without restarting Usage Island.
- A malformed JSON-RPC line fails pending requests and does not accept a later
  well-formed response from the leftover buffer.
- A tagged release job runs the existing test and resilience commands on that
  commit before packaging or publishing.
- Unused JSON-RPC notifications cannot close the polling Codex client after the
  bounded buffer fills.

# Scope

Correct the next-change items from `Docs/BRANCH_REVIEW.md` on commit
`60c6b4cda952bab0d2713289794129771b156ddb`:

- F1: unregister the matching `ManagedProcess` readability handler at EOF.
- F2: locate `codex` at a retryable provider start, instead of installing a
  permanent `UnavailableCodexUsageProvider`.
- F3: treat parse and validation errors as terminal for remaining bytes; keep
  last-line recovery only for clean transport EOF.
- F4: run `swift test` and `./Scripts/verify-resilience.sh` inside the tagged
  release job before package and publish.
- R1: give unused polling-path notifications an explicit owner and
  consume-or-discard policy, ended with client shutdown.

# Non-goals

- Redesign, resize, or restyle the v26 UI, notch geometry, Pulse panel, or
  active `CodexEdgeWindowController`.
- Remove or rewrite the preserved v26 `IslandWindowController` path.
- Add a provider registry, dependency-injection container, event bus, or new
  third-party dependency.
- Increase the JSON-RPC notification buffer as the R1 fix.
- Infer quota percentages from token totals or local cost logs.
- Present demo data as real usage.
- AppModel demo-composition split, normalized UI failure reasons, or
  `CodexInitializeResponse` storage cleanup. Those are follow-up
  simplifications in the review, postponed until F1–F4 and R1 hold.
- Real Codex authentication, credential access, live quota calls, or schema
  generation from the installed CLI.
- Interactive pixel, lid-closed, sleep/wake, fullscreen, Spaces, or
  out-of-panel click verification.

# Acceptance examples

- Child `/bin/sh` closes stdout (`exec 1>&-; sleep …`) while still alive:
  stdout EOF is handled once, the stdout handler is unregistered, shutdown
  still completes. Repeat independently for stderr (`exec 2>&-; sleep …`).
- Count handler invocations with bounded instrumentation, not a CPU-time
  threshold.
- Live composition starts with Codex missing. One refresh fails. The locator
  then succeeds. The next refresh creates the real provider and does not
  publish demo snapshots. The app composition is not rebuilt.
- Pending request id 1 receives one chunk `not json\n{"id":1,"result":"accepted"}\n`.
  The request fails. It does not return `accepted`. The same failure occurs
  when the malformed line and the later response arrive in separate chunks.
- A final valid JSON-RPC line without a trailing newline at clean EOF still
  completes the pending request.
- Production polling with more than 100 valid unused notifications still
  completes later `request` calls. Shutdown still finishes the client.
- `.github/workflows/release.yml` runs the existing test and resilience
  commands on the tagged commit before `Scripts/package-app.sh` and
  `gh release create`. A deliberate test failure must skip package and
  publish. Do not prove this by publishing a broken GitHub release.

# Constraints and invariants

- Swift 6 strict concurrency, macOS 14+, no backend server, no Usage Island
  account, no telemetry by default, no new third-party dependencies.
- Domain stores `usedPercent`; `remainingPercent` is computed; clamp `0...100`.
- Preserve the last valid snapshot when refresh fails; mark stale rather than
  inventing values.
- UI consumes normalized domain snapshots only.
- JSON-RPC: newline-delimited JSON, `initialize`/`initialized` before other
  Codex requests, stderr is diagnostics, bounded timeouts, graceful shutdown.
- Never log tokens, cookies, authorization headers, full environment, or
  credential-file contents.
- Tests use synthetic fixtures. Do not require Full Disk Access.
- Do not modify v26 visual baseline files unless a compile fix is required:
  `PulseView.swift`, `UnifiedIslandSurfaceView.swift`,
  `UnifiedIslandView.swift`, `VisualTokens.swift`, `WingViews.swift`,
  `IslandWindowController.swift`, `ScreenNotchGeometry.swift`.
- Keep existing process-exit, full-pipe, last-valid-snapshot, and notification
  overflow-with-consumer tests.

# Decisions

- Isolation: Git worktree
  `.worktrees/fix-runtime-and-release-gates`, branch
  `comet/fix-runtime-and-release-gates`, target `main`. Untracked
  `Docs/BRANCH_REVIEW.md` and `.atl/` stay in the original `main` working tree.
- Native artifacts: English, artifact root `docs`.
- Scope follows the review's recommended next change: F1–F4 and R1 only.
- R1 must not grow the default buffer or add an event bus.
- R1 policy: discard. A drain owner on the production polling client
  consumes unused notifications and drops them for the client lifetime.
  Pulse still updates only from manual refresh and the one-minute poll.
  `account/rateLimits/updated` does not refresh the snapshot by itself.
  Overflow still fails closed when a subscribed consumer falls behind.
- F2 must not show demo usage when Codex is missing.
- F4 keeps test and resilience steps inside the release job rather than
  cross-workflow status queries.
- Implementation choices (where to unregister handlers, how to retry locate,
  fail-closed parse versus EOF, and where the drain task lives) belong to
  the Agent.

# Open questions

- None. Q1 resolved: discard unused notifications. Shared understanding
  confirmed.

# Verification expectations

- `swift test`, including new regression tests for F1, F2, F3, and R1.
- `swift build --product UsageIslandPrototype`.
- `./Scripts/verify-resilience.sh`.
- Inspect `.github/workflows/release.yml` so test and resilience steps precede
  package and publish, using a workflow check that does not publish a release.
- No change to v26 visual baseline files listed above.
