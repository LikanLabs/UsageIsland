# Codex executable recovery

## Purpose

A missing Codex CLI at application launch is a recoverable condition, not a
permanent provider identity for that process lifetime.

## Behavior

Live composition still has a single refresh owner and a single shutdown owner.

The production Codex adapter locates the `codex` executable at a retryable
provider start, not once in `makeLiveComposition` with a substitute that
always throws.

If locate fails, `fetchUsage()` fails with the existing executable-unavailable
typed error. No usage snapshot is published. Demo data is never substituted.

If a later refresh occurs after the executable becomes locatable, that refresh
creates or starts the real Codex provider and may publish a real snapshot.

The application composition object is not rebuilt to recover.

Startup without Codex still starts with empty live snapshots and no demo
agents.

Termination still replies once when no Codex provider was created.

## Non-behavior

This capability does not add a provider registry or dependency-injection
container.

It does not read or copy Codex credentials.

It does not change Pulse layout or copy.

## Acceptance

- Locator reports missing, then present, without rebuilding composition: the
  next refresh can succeed.
- Startup without Codex never publishes demo usage.
