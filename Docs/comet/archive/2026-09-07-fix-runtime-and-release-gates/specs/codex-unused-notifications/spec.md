# Unused Codex JSON-RPC notifications

## Purpose

The production polling Codex path does not leave JSON-RPC notifications
unconsumed until the bounded buffer overflows and closes the client.

## Behavior

The polling integration (`CodexUsageProvider` start / request / shutdown)
owns unused notifications for the client lifetime.

The default notification buffer size stays 100. Overflow remains a typed
failure when a real consumer falls behind.

A drain owner consumes the shared notification stream and drops each event.
Polling `request` calls keep completing after more than 100 valid unused
notifications.

Pulse still updates only from manual refresh and the periodic poll.
`account/rateLimits/updated` does not change the published snapshot by itself.

Shutdown of the usage client also ends notification ownership. No leftover
drain task outlives shutdown. The drain must not cancel the notification
stream in a way that closes in-flight requests before shutdown.

The Pulse UI does not gain a notification inbox, event bus, or new panel.

## Non-behavior

Do not raise `maximumBufferedNotifications` as the fix.

Do not add an application event bus.

Do not remove overflow protection for an active slow consumer.

## Acceptance

- More than 100 valid unused notifications during a provider+client lifetime
  still allow later requests to complete.
- The existing overflow test for a subscribed consumer that falls behind still
  fails closed.
- Shutdown still completes.
