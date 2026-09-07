---
generated_from_state_version: 7
---

# Verification

## Current result

- Result: **Passed**
- Assurance: **skill-coordinated**
- Goal cycle: 1
- Iteration: 1
- Verifier attempt: 1
- Completed: 2026-09-07T00:07:18.611Z
- Summary: Independent Verify passed. Runtime re-ran swift test, swift build --product UsageIslandPrototype, and ./Scripts/verify-resilience.sh (all exit 0). Spec review of F1-F4 and discard-drain R1 matches the 73 acceptance items. v26 UI files unchanged.

## Acceptance

| ID | Result | Source | Criterion | Reason |
| --- | --- | --- | --- | --- |
| A1 | passed | brief.md | Child `/bin/sh` closes stdout (`exec 1>&-; sleep …`) while still alive: stdout EOF is handled once, the stdout handler is unregistered, shutdown still completes. Repeat independently for stderr (`exec 2>&-; sleep …`). | ManagedProcessTests.testStdoutEOFUnregistersHandlerWhileChildStaysAlive and testStderrEOFUnregistersHandlerWhileChildStaysAlive passed; handlers nil at empty availableData. |
| A2 | passed | brief.md | Count handler invocations with bounded instrumentation, not a CPU-time threshold. | Tests use readabilityProbe call/EOF counts, not CPU-time thresholds; swift test passed. |
| A3 | passed | brief.md | Live composition starts with Codex missing. One refresh fails. The locator then succeeds. The next refresh creates the real provider and does not publish demo snapshots. The app composition is not rebuilt. | LiveCompositionTests.testMissingCodexBecomesAvailableOnLaterRefreshWithoutRebuildingComposition passed; LocatingCodexUsageProvider locates on each fetchUsage. |
| A4 | passed | brief.md | Pending request id 1 receives one chunk `not json\n{"id":1,"result":"accepted"}\n`. The request fails. It does not return `accepted`. The same failure occurs when the malformed line and the later response arrive in separate chunks. | JSONRPCClientTests.testMalformedLineThenValidResponseInSameChunkFailsPendingRequest and ...LaterChunk... passed; request does not return accepted. |
| A5 | passed | brief.md | A final valid JSON-RPC line without a trailing newline at clean EOF still completes the pending request. | JSONRPCClientTests.testValidFinalLineWithoutNewlineIsDecodedAtEndOfStream passed; readerEnded last-line path only on transportClosed. |
| A6 | passed | brief.md | Production polling with more than 100 valid unused notifications still completes later `request` calls. Shutdown still finishes the client. | CodexUsageProviderTests.testUnusedNotificationsAreDrainedSoLaterFetchesStillSucceed passed; drain Task.detached drops notifications. |
| A7 | passed | brief.md | `.github/workflows/release.yml` runs the existing test and resilience commands on the tagged commit before `Scripts/package-app.sh` and `gh release create`. A deliberate test failure must skip package and publish. Do not prove this by publishing a broken GitHub release. | ReleaseWorkflowTests.testReleaseJobRunsTestsAndResilienceBeforePackageAndPublish passed; YAML has no continue-on-error; GitHub Actions fails the job on a failed step. |
| A8 | passed | specs/codex-executable-recovery/spec.md | A missing Codex CLI at application launch is a recoverable condition, not a permanent provider identity for that process lifetime. | makeLiveComposition always installs LocatingCodexUsageProvider; locate runs on fetchUsage, not as a permanent UnavailableCodexUsageProvider. |
| A9 | passed | specs/codex-executable-recovery/spec.md | Live composition still has a single refresh owner and a single shutdown owner. | LiveComposition still owns one model refresh path and AppDelegate still shuts down the single locating provider. |
| A10 | passed | specs/codex-executable-recovery/spec.md | The production Codex adapter locates the `codex` executable at a retryable provider start, not once in `makeLiveComposition` with a substitute that always throws. | LocatingCodexUsageProvider.locate("codex") runs inside fetchUsage; factory is not called until locate succeeds. |
| A11 | passed | specs/codex-executable-recovery/spec.md | If locate fails, `fetchUsage()` fails with the existing executable-unavailable typed error. No usage snapshot is published. Demo data is never substituted. | Locate failure throws CodexUsageError.appServerFailure(.executableUnavailable); tests assert no demo snapshot. |
| A12 | passed | specs/codex-executable-recovery/spec.md | If a later refresh occurs after the executable becomes locatable, that refresh creates or starts the real Codex provider and may publish a real snapshot. | After locator succeeds, inner CodexUsageProvider is created and fetchUsage proceeds; composition object is unchanged. |
| A13 | passed | specs/codex-executable-recovery/spec.md | The application composition object is not rebuilt to recover. | Recovery does not call makeLiveComposition again; same LiveComposition instance is retained. |
| A14 | passed | specs/codex-executable-recovery/spec.md | Startup without Codex still starts with empty live snapshots and no demo agents. | makeLiveComposition uses initialSnapshots: [] and initialAgents: []; live tests assert no demo agents. |
| A15 | passed | specs/codex-executable-recovery/spec.md | Termination still replies once when no Codex provider was created. | testTerminationWithoutInstalledCodexStillRepliesOnce passed. |
| A16 | passed | specs/codex-executable-recovery/spec.md | This capability does not add a provider registry or dependency-injection container. | Only LocatingCodexUsageProvider wrapping a factory closure; no registry or DI container added. |
| A17 | passed | specs/codex-executable-recovery/spec.md | It does not read or copy Codex credentials. | Locator uses ExecutableLocator; no credential-file reads in the change. |
| A18 | passed | specs/codex-executable-recovery/spec.md | It does not change Pulse layout or copy. | git diff shows PulseView.swift and other v26 UI files unchanged. |
| A19 | passed | specs/codex-executable-recovery/spec.md | Locator reports missing, then present, without rebuilding composition: the next refresh can succeed. | testMissingCodexBecomesAvailableOnLaterRefreshWithoutRebuildingComposition passed. |
| A20 | passed | specs/codex-executable-recovery/spec.md | Startup without Codex never publishes demo usage. | testMissingExecutableUsesUnavailableAdapterWithoutCreatingCodexProvider and live startup tests assert no demo usage. |
| A21 | passed | specs/codex-unused-notifications/spec.md | The production polling Codex path does not leave JSON-RPC notifications unconsumed until the bounded buffer overflows and closes the client. | CodexUsageProvider starts a drain after successful client.start(); unused notifications are consumed. |
| A22 | passed | specs/codex-unused-notifications/spec.md | The polling integration (`CodexUsageProvider` start / request / shutdown) owns unused notifications for the client lifetime. | notifications() drain is owned by CodexUsageProvider start/shutdown; join happens after client.shutdown(). |
| A23 | passed | specs/codex-unused-notifications/spec.md | The default notification buffer size stays 100. Overflow remains a typed failure when a real consumer falls behind. | JSONRPCClient default maximumBufferedNotifications remains 100; testNotificationBufferOverflowFailsTransportExplicitly still fails closed. |
| A24 | passed | specs/codex-unused-notifications/spec.md | A drain owner consumes the shared notification stream and drops each event. Polling `request` calls keep completing after more than 100 valid unused notifications. | Drain for-try-await drops events; production fetch still completes after >100 unused notifications. |
| A25 | passed | specs/codex-unused-notifications/spec.md | Pulse still updates only from manual refresh and the periodic poll. `account/rateLimits/updated` does not change the published snapshot by itself. | Drain discards events; fetch still uses account/read and account/rateLimits/read only. No rateLimits/updated snapshot apply. |
| A26 | passed | specs/codex-unused-notifications/spec.md | Shutdown of the usage client also ends notification ownership. No leftover drain task outlives shutdown. The drain must not cancel the notification stream in a way that closes in-flight requests before shutdown. | shutdown joins drain after client.shutdown(); Task.detached avoids actor deadlock; drain is not cancelled mid-request. |
| A27 | passed | specs/codex-unused-notifications/spec.md | The Pulse UI does not gain a notification inbox, event bus, or new panel. | No Pulse or notification UI files changed. |
| A28 | passed | specs/codex-unused-notifications/spec.md | Do not raise `maximumBufferedNotifications` as the fix. | Default buffer remains 100; CodexAppServerConfiguration default unchanged. |
| A29 | passed | specs/codex-unused-notifications/spec.md | Do not add an application event bus. | No event-bus type or module added. |
| A30 | passed | specs/codex-unused-notifications/spec.md | Do not remove overflow protection for an active slow consumer. | testNotificationBufferOverflowFailsTransportExplicitly still present and passing. |
| A31 | passed | specs/codex-unused-notifications/spec.md | More than 100 valid unused notifications during a provider+client lifetime still allow later requests to complete. | Provider drain test with 120 unused notifications then a later request passed. |
| A32 | passed | specs/codex-unused-notifications/spec.md | The existing overflow test for a subscribed consumer that falls behind still fails closed. | JSONRPCClientTests.testNotificationBufferOverflowFailsTransportExplicitly passed. |
| A33 | passed | specs/codex-unused-notifications/spec.md | Shutdown still completes. | Drain join is part of shutdown; provider shutdown tests still pass. |
| A34 | passed | specs/jsonrpc-protocol-failure/spec.md | `JSONRPCClient` separates a malformed or invalid protocol line from clean transport EOF last-line recovery. | consume parse failures throw; readerEnded last-line recovery gated by isCleanTransportEOF(transportClosed). |
| A35 | passed | specs/jsonrpc-protocol-failure/spec.md | When `consume` fails to decode or validate a complete line, the client: | On decode/validate failure, consume clears the buffer and throws; reader loop calls readerEnded with that error. |
| A36 | passed | specs/jsonrpc-protocol-failure/spec.md | discards remaining buffered bytes | consume catch calls receiveBuffer.removeAll before rethrow. |
| A37 | passed | specs/jsonrpc-protocol-failure/spec.md | fails every pending request with a typed protocol error | readerEnded then close(with:) failAllPending with the typed JSONRPCError. |
| A38 | passed | specs/jsonrpc-protocol-failure/spec.md | closes the connection | close sets state closed and beginTransportShutdown runs. |
| A39 | passed | specs/jsonrpc-protocol-failure/spec.md | does not decode further lines from that buffer or later chunks on the same generation | Throwing from consume exits the incomingBytes loop; later chunks of that generation are not decoded. |
| A40 | passed | specs/jsonrpc-protocol-failure/spec.md | Clean transport EOF may still decode one remaining buffer that has no trailing newline, then close. That path is not used after a parse or validation error. | isCleanTransportEOF is true only for transportClosed; parse errors skip last-line recovery. |
| A41 | passed | specs/jsonrpc-protocol-failure/spec.md | A well-formed response that follows a malformed line in the same chunk, or in a later chunk of the same generation, must not complete the pending request. | Same-chunk and later-chunk malformed-then-valid tests pass. |
| A42 | passed | specs/jsonrpc-protocol-failure/spec.md | Existing oversized-line, fragmented-line, and clean-EOF last-line behavior remains. | Existing oversized, fragmented, and EOF last-line tests still passed in swift test. |
| A43 | passed | specs/jsonrpc-protocol-failure/spec.md | This capability does not introduce a new reader abstraction. | Still a single reader Task over incomingBytes; no new reader type. |
| A44 | passed | specs/jsonrpc-protocol-failure/spec.md | It does not treat stderr diagnostics as protocol data. | testStandardErrorIsNeverParsedAsProtocolData passed; stderr remains diagnostics. |
| A45 | passed | specs/jsonrpc-protocol-failure/spec.md | Chunk `not json\n{"id":1,"result":"accepted"}\n` with request 1 pending: the request fails; it does not return `accepted`. | testMalformedLineThenValidResponseInSameChunkFailsPendingRequest passed. |
| A46 | passed | specs/jsonrpc-protocol-failure/spec.md | The same pair in separate chunks also fails the request. | testMalformedLineThenValidResponseInLaterChunkFailsPendingRequest passed. |
| A47 | passed | specs/jsonrpc-protocol-failure/spec.md | A valid last line without newline at clean EOF still completes. | testValidFinalLineWithoutNewlineIsDecodedAtEndOfStream passed. |
| A48 | passed | specs/process-stdio-eof/spec.md | `ManagedProcess` treats stdout EOF and stderr EOF as stream lifecycle events, independent of child-process termination. | stdout and stderr EOF handlers unregister on empty availableData without waiting for process exit. |
| A49 | passed | specs/process-stdio-eof/spec.md | When a readability handler observes empty `availableData` for stdout or stderr, it unregisters that handler immediately after scheduling the existing EOF bookkeeping. | Both handlers set readabilityHandler = nil immediately after scheduling EOF bookkeeping. |
| A50 | passed | specs/process-stdio-eof/spec.md | EOF on one stream does not unregister the other stream. | stdout and stderr handlers are independent; tests close one stream while the other remains. |
| A51 | passed | specs/process-stdio-eof/spec.md | Last-byte delivery that arrived before EOF remains available to readers. | Non-empty availableData is yielded before the empty-EOF path; existing last-byte tests still pass. |
| A52 | passed | specs/process-stdio-eof/spec.md | Process-exit observation, exit-status handling, forced termination, and shutdown cleanup stay responsible for the child process. They still run if the child remains alive after a pipe is closed. | processDidTerminate, exit monitor, and shutdown cleanup are unchanged; child sleep after exec 1>&- still gets shutdown. |
| A53 | passed | specs/process-stdio-eof/spec.md | A handler that has unregistered at EOF must not be invoked again for that stream on the same process instance. | EOF tests assert a single EOF count per stream via readabilityProbe. |
| A54 | passed | specs/process-stdio-eof/spec.md | This capability does not replace `ManagedProcess` with another process subsystem. | ManagedProcess remains the process owner; no replacement subsystem. |
| A55 | passed | specs/process-stdio-eof/spec.md | It does not use CPU-time thresholds as the regression signal. | Regression signal is probe call counts, not CPU time. |
| A56 | passed | specs/process-stdio-eof/spec.md | Close stdout while the child stays alive: stdout EOF is handled once, then shutdown completes. | testStdoutEOFUnregistersHandlerWhileChildStaysAlive passed. |
| A57 | passed | specs/process-stdio-eof/spec.md | Close stderr while the child stays alive: stderr EOF is handled once, then shutdown completes. | testStderrEOFUnregistersHandlerWhileChildStaysAlive passed. |
| A58 | passed | specs/process-stdio-eof/spec.md | Count handler calls with bounded instrumentation. | readabilityProbe records stdout/stderr call and EOF counts. |
| A59 | passed | specs/release-test-gate/spec.md | A GitHub tagged release built from this repository cannot package or publish until the tagged commit passes the same test and resilience commands CI uses. | release.yml Test and Run resilience checks steps precede package and gh release create. |
| A60 | passed | specs/release-test-gate/spec.md | `.github/workflows/release.yml` remains triggered by tags matching `v*.*.*`. | on.push.tags remains ['v*.*.*']. |
| A61 | passed | specs/release-test-gate/spec.md | The `release` job, on the tagged commit, runs in this order: | Release job step order matches the specified sequence. |
| A62 | passed | specs/release-test-gate/spec.md | checkout | First step is actions/checkout@v4. |
| A63 | passed | specs/release-test-gate/spec.md | `swift test` | Second step runs swift test. |
| A64 | passed | specs/release-test-gate/spec.md | `./Scripts/verify-resilience.sh` | Third step runs ./Scripts/verify-resilience.sh. |
| A65 | passed | specs/release-test-gate/spec.md | existing universal package build (`Scripts/package-app.sh`) | Then Scripts/package-app.sh with USAGE_ISLAND_ARCHS. |
| A66 | passed | specs/release-test-gate/spec.md | zip and checksum | Then ditto zip and shasum checksum. |
| A67 | passed | specs/release-test-gate/spec.md | `gh release create` | Last step is gh release create. |
| A68 | passed | specs/release-test-gate/spec.md | If `swift test` or `./Scripts/verify-resilience.sh` fails, later package and publish steps do not run. | No continue-on-error or if: always(); default GitHub Actions skips later steps after a failure. |
| A69 | passed | specs/release-test-gate/spec.md | Commands stay in this job. The workflow does not query another workflow's check status to decide whether to publish. | No workflow_run or needs of another workflow; commands are inline in this job. |
| A70 | passed | specs/release-test-gate/spec.md | This capability does not publish a known-broken release to prove the gate. | Proof is YAML order plus ReleaseWorkflowTests, not a published broken release. |
| A71 | passed | specs/release-test-gate/spec.md | It does not require a reusable workflow until duplicated commands become a real maintenance problem. | Steps remain in this job; no reusable workflow added. |
| A72 | passed | specs/release-test-gate/spec.md | Release YAML lists test and resilience steps before package and publish. | testIndex < resilienceIndex < packageIndex < publishIndex in ReleaseWorkflowTests. |
| A73 | passed | specs/release-test-gate/spec.md | A verification method that does not create a GitHub release shows that a failing test step prevents the publish step from running. | ReleaseWorkflowTests inspects YAML for step order and absence of continue-on-error without creating a GitHub release. |

## Checks

| Check | Command | Working directory | Status | Exit | Duration |
| --- | --- | --- | --- | ---: | ---: |
| swift test | test | . | passed | 0 | 4962 ms |
| swift build --product UsageIslandPrototype | build --product UsageIslandPrototype | . | passed | 0 | 639 ms |
| ./Scripts/verify-resilience.sh | — | . | passed | 0 | 3005 ms |

## Blockers

_None._

## Risks and skipped work

- No real Codex authentication, credential access, or live quota calls.
- No interactive pixel, lid-closed, sleep/wake, fullscreen, or Spaces verification.
- Release fail-fast is proven by YAML step order and GitHub Actions default (no continue-on-error), not by publishing a broken GitHub release.

## Previous iterations

| Goal cycle | Iteration | Attempt | Outcome | Unresolved | Summary | Completed |
| ---: | ---: | ---: | --- | --- | --- | --- |
| 1 | 1 | 1 | pass | — | Independent Verify passed. Runtime re-ran swift test, swift build --product UsageIslandPrototype, and ./Scripts/verify-resilience.sh (all exit 0). Spec review of F1-F4 and discard-drain R1 matches the 73 acceptance items. v26 UI files unchanged. | 2026-09-07T00:07:18.611Z |

## Conclusion

Independent Verify passed. Runtime re-ran swift test, swift build --product UsageIslandPrototype, and ./Scripts/verify-resilience.sh (all exit 0). Spec review of F1-F4 and discard-drain R1 matches the 73 acceptance items. v26 UI files unchanged.
