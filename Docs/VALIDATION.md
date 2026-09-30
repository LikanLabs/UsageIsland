# Validation — 2026-09-30 (alerts, login, update relaunch, battery)

- `swift test`: 277 tests pass; the timing-sensitive suites (refresh power,
  alert monitor, resilience) passed six consecutive runs. Resilience runner
  passes.
- Update relaunch, end to end: a packaged 0.1.90 build was running when its
  bundle was replaced by 0.1.91 (as `brew upgrade` does). 57 s later the old
  process had exited and 0.1.91 was running from the same path; one Codex
  app-server remained. The installed app and `~/.claude/settings.json` were
  untouched by the test copy.
- Claude `get_usage` still returns every limit with
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` and `DISABLE_AUTOUPDATER=1`.
- The guarded status line command exits 0 with no output when the app is gone.
- Flat renders checked: settings with the new system section, and the reset
  countdown pill in edge and notch positions.
- Not verified live: registering the login item and posting a notification
  (both need the user's approval in the real app).

# Validation — 2026-09-26 (Liquid Glass redesign, plan coverage)

- Redesign with Liquid Glass (macOS 26+; system material fallback on 14–25):
  glass side pill, black notch pill, glass panel with a card and ring gauges
  per provider, native settings controls. Official Claude mark from Simple
  Icons 16.32.0. Layout checked with flat renders; the user reviewed the real
  glass on their Mac.
- Live data: Codex (Pro Lite) reports only a weekly window, shown next to a
  "No limit" session slot. Claude reports session, weekly and a Fable weekly
  limit through `limits` rows; all three are shown.
- Codex named buckets become scoped windows; missing-data cards now say
  whether the CLI is missing, not signed in, or the account has no plan limits.
- `swift test`: 256 tests pass; resilience checks pass.
- Not covered: credits and dollar spend caps (not shown), unknown future
  limit kinds (skipped).

# Validation — 2026-09-26 (Claude provider)

- `swift test`: all tests pass, including new bridge, provider, settings
  installer and active-provider tests with synthetic status line input.
- The compiled executable in `--claude-statusline` mode stored only rate limits
  and printed `5h 13% · 7d 40%`; about 10 ms per run once warm (240 ms cold).
- Rendered pill, usage panel with both providers and settings with synthetic
  data at 2x; the Claude row and sections fit the panel.
- The Claude desktop app does not run status line commands: with the bridge
  installed, no record was written during desktop sessions. Added the CLI
  `get_usage` query, which covers every surface: against the real account it
  returned 28 % session and 5 % week in about 2 s, used no tokens, printed
  nothing to stderr and created no session files.
- Not verified yet: automatic switching during real use.

# Validation — 2026-09-26 (review fixes)

Toolchain: Xcode with Apple Swift 6.4. Earlier entries below are historical;
their XCTest limitation no longer applies.

## Passed

- `swift test`: 231 tests, 0 failures, no compiler warnings. The process and
  JSON-RPC suites passed five consecutive runs.
- `./Scripts/verify-resilience.sh`: every scenario passes, including 768 geometry
  cases and 30 adaptive-notch cases. The script now selects the native build
  system on toolchains that default to swiftbuild.
- `./Scripts/package-app.sh`: release build, Info.plist lint and ad hoc signature.
- Regression tests added for each fix:
  - stdin backpressure resumes after `EAGAIN` (aborted with "Incorrect actor
    executor assumption" before the fix);
  - server-initiated JSON-RPC requests get a `-32601` reply and the session stays up;
  - a child exit is reported when a descendant keeps stdout open;
  - the Codex provider is replaced when the executable moves, and never relaunches
    after shutdown;
  - usage between 99 and 100 % rounds to 99 so quota is never shown as exhausted early;
  - reset labels, window titles, date locale and past-reset detection.

## Not verified

- The release workflow's signing and notarization steps have not run: they need
  Developer ID and App Store Connect secrets.
- Pausing the auto-hide timer (pinned details, open menus, sleeping displays) and
  skipping redundant tab animations were not exercised in a physical UI session.

# Validation — 2026-09-05

## Passed

- Debug and release builds with Swift 6; local app signature and Info.plist verification.
- Shared standalone regression scenarios (`./Scripts/verify-resilience.sh`):
  failed startup, transport/timeout/remote errors, stale-data preservation,
  cleanup failure, shutdown during recovery, and no authentication restart loops.
- Cancellation regression: a synthetic in-flight request closes its transport;
  the next refresh now retires the client and succeeds immediately. The new test
  failed with a transport error before the fix and passes afterward. Cancelling
  a queued fetch also passes without retiring the healthy client.
- Synthetic `NSWorkspace` sleep/wake notifications: polling pauses, old data becomes
  stale, wake refreshes usage, polling resumes, and stopping removes observers.
- 768 geometry combinations: left/right/top positions, four panel heights, notch/no-notch,
  positive/negative display origins, small displays, 75–150% sizes, and 1x/2x pixel scales.
  Checks include flush side attachment, inset notch width and background overlap,
  content below the camera, and equal visible gaps.
- Real installed Codex CLI: a dedicated verification subprocess was terminated;
  the last valid snapshot stayed stale and a new app-server recovered live usage.
  The replacement process shut down normally. No account payloads were saved.
- Packaged app opened live Codex details during a temporary native fullscreen-window
  check. The temporary app was closed afterward. This is not an exhaustive check
  of every application's fullscreen behavior.
- Notarization preflight rejects an ad-hoc build before submitting anything to Apple.
- Native UI session: opened details, refreshed live usage, opened settings,
  selected all three positions, exercised size limits (75% and 150%), switched
  English/Automatic, toggled auto-hide, closed details with Escape, and used the
  context menu to quit. Rebuilt the local release app and reopened it; live usage
  returned and original preferences persisted (right, 85%, Automatic, auto-hide off).
  These actions do not establish pixel-perfect placement across all configurations.

## Blocked or not physically verified

- `swift test`: `no such module 'XCTest'`. Only Command Line Tools are installed.
  The standalone scenarios pass, but the full existing XCTest suite has not run.
- No valid code-signing identities are installed. Developer ID signing and actual
  notarization have not run. The current `.app` is signed for local use only.
- Monitor hot-plug/clamshell transitions are handled in code; geometry is verified
  synthetically, not by physically attaching or disconnecting displays.
- Sleep/wake is simulated through the notification center; the Mac was not put to sleep.
- Continuous pointer-only hover/reveal transitions, reduced-motion animations,
  and Space changes were not exhaustively tested in the native UI session.
- Two existing no-op-cast warnings remain in the unused v26 surface renderer.

## Black edge UI revision

- User explicitly authorized this visual revision. The old v26 views are unchanged.
- Removed branding inside the panel, blue surfaces, segmented pill meter, hover
  opening, and the separate settings window. Settings and usage share one
  status-level NSPanel. Clicking the pill toggles usage; close/back are explicit.
- Native checks with VS Code raised: opened usage, switched to settings in the
  same panel, changed all positions without dismissing settings, changed language,
  toggled auto-hide, and exercised 75%/150% sizing. Cancelling the context menu
  with the pointer on the pill left details closed; clicking opened them.
- Surface and window bounds now match. Top position directly meets the notch,
  spans its width, and uses the same scaled 8-point gap as the sides.
- Visual iteration enlarged the percentage/ring, added session/week context,
  differentiated stale data with a dashed ring, and reduced settings height from
  344 to 304 points to remove excess bottom space.
- Synthetic ImageRenderer review found no text clipping in two-quota/stale and
  unavailable states. Native AppKit settings controls do not render through
  ImageRenderer; those were inspected in the running app instead.
- Final release rebuild, local signature and live quota passed. Original settings
  persisted: right, 85%, Automatic, auto-hide off. A real Cmd-Tab application switch
  closed the panel. Global outside-click handling now closes directly, and key-loss
  / workspace activation notifications also dismiss it. Background clicks targeted
  at VS Code through the automation tool did not reliably produce that focus loss;
  physical outside-click dismissal is still a manual verification item.

## Notch-specific investigation

Apple's AppKit documentation says `auxiliaryTopLeftArea` and
`auxiliaryTopRightArea` are the unobscured top corners in global screen
coordinates, while `safeAreaInsets.top` describes the obscured top distance.
The implementation derives the bridge from those values at runtime instead of
assuming one MacBook size. Source: [Apple's `auxiliaryTopRightArea` documentation](https://developer.apple.com/documentation/appkit/nsscreen/auxiliarytoprightarea-gr2n).

The bridge uses the complete detected notch rectangle, including its X origin
and bottom edge. A direct AppKit read on this Mac returned screen 1512×982pt,
backing scale 2, and notch (x:663, y:950, width:185, height:32). Its
black background overlaps the camera area by 8 physical points and its lower
corners remain rounded. Apple does not expose the hardware corner radius, so the
runtime AppKit rectangles remain the source of truth. The overlap does not grow
with the content scale.
The visible content remains 36pt high before scaling, entirely below the camera;
the detail retains its 8pt scaled gap. Side geometry is unchanged.

The preceding revision incorrectly placed most of the content above y:950,
inside the camera. Its tests repeated that mistake. A new regression assertion
failed against that revision before the fix. The corrected content occupies
y:923...950 at 75% scale; only black padding occupies y:950...958. AppKit's Y axis
points up: [Apple's coordinate-system documentation](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CocoaDrawingGuide/Transforms/Transforms.html).
The incorrect scale cap based on camera height has been removed. Screen changes,
wake and Space changes already trigger runtime geometry refresh.

Native checks: quit the previous process, launched the packaged executable, opened
details/settings, toggled the percentage preference, inspected settings without
footer clipping, and exercised 75% and 100% sizes. Restored Notch/Arriba, 75%,
Automatic, auto-hide off and available percentage. Both switches now use the same
matte panel style with accessible toggle semantics. Ring and bar fill follow the
selected percentage; color still represents remaining-quota urgency.
App-window captures do not establish the full physical corner contour; other
MacBook geometries are covered by synthetic tests, not physical-device tests.

Validation: debug and release builds passed; the independent resilience runner
passed, including 768 geometry combinations and 30 additional cases checking
content/camera separation, varying cutout sizes, offset centers and 75–150% scale.
`swift test` was attempted but cannot compile because this toolchain lacks XCTest.
The two pre-existing Core Animation cast warnings remain in the untouched v26 view.

Changed files in this revision:

- `Sources/UsageIslandPrototype/UI/CodexEdgeView.swift`
- `Sources/UsageIslandPrototype/UI/AppearanceSettingsView.swift`
- `Sources/UsageIslandPrototype/Window/CodexEdgeWindowController.swift`
- `Sources/UsageIslandPrototype/Window/EdgeWindowGeometry.swift`
- `Sources/UsageIslandPrototype/App/UsageIslandApp.swift`
- `Tests/UsageIslandPrototypeTests/ResilienceScenarios.swift`
- `Scripts/verify-resilience.swift`
- `README.md`, `Docs/VALIDATION.md`, `Docs/HANDOFF.md`

### Design critique and remaining checks

The hierarchy is clearer and settings no longer leave the usage surface. The
period label gives the ring useful context. At 75%, secondary text remains small;
100% is more comfortable for reading. A black attached pill intentionally has less
contrast against dark content; the detail retains a faint outline. Physical display
changes, reduced-motion behavior, and a full multi-app/fullscreen matrix still need
hardware checks. Geometry assertions establish spacing; isolated window screenshots
do not prove the whole desktop composition is perfect.

## Logo pill and navigation refinement

- Codex logo now sits inside the usage ring, with the used percentage below it in
  both side and notch positions. Ring color uses remaining-quota thresholds:
  >50% green, >25% yellow, >10% orange, <=10% red. Stale rings remain dashed.
- Opening the pill requests a refresh unless already connecting. Minute polling
  continues independently of visibility. Edge hover reveals the hidden pill only.
- SwiftUI animates page opacity/offset and surface height over 240 ms, inside a
  stable host. Top alignment preserves the visible notch gap. Reduce Motion uses
  immediate transitions. Back and close now have larger targets; Back has a label.
- Closing preserves the settings page until fade-out and orderOut finish. A
  generation token rejects old close completions after rapid reopening. Synthetic
  regressions cover that lifecycle and all remaining-quota color boundaries.
- Native testing caught and fixed settings clicks classified as outside clicks:
  local events now use their receiving window instead of a later cursor location.
- Native checks: live quota/ring color, opening starts refresh (refresh control
  disabled while connecting), settings, Back, close from settings, reopening,
  and logo/percentage layout in the notch. Screenshots inspect settled frames;
  lifecycle tests verify reset timing, not frame-by-frame animation smoothness.
- Debug/release and local signature pass; resilience runner passes including 768
  geometry cases, now also checking visible surfaces within the stable host.
  Full XCTest remains unavailable because the Mac lacks XCTest.
- Files for this refinement: `UI/CodexEdgeView.swift`,
  `Window/CodexEdgeWindowController.swift`, `Window/EdgeWindowGeometry.swift`,
  new `Window/EdgePanelNavigation.swift` (under `Sources/UsageIslandPrototype`),
  `Tests/UsageIslandPrototypeTests/ResilienceScenarios.swift`, `ResilienceTests.swift`
  in the same test directory, `Scripts/verify-resilience.swift`, and these docs/README.

## Complete public-release verification

1. Physically check sleep/wake, screen unplug/replug, clamshell, and fullscreen on
   target hardware, preserving the current design.
2. Configure the signing and notarization secrets listed in README.md.
3. Follow the public-distribution commands in README.md. Distribute only after
   notarization acceptance, staple validation, and Gatekeeper assessment succeed.
