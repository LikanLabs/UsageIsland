# Managed process stdio EOF

## Purpose

`ManagedProcess` treats stdout EOF and stderr EOF as stream lifecycle events,
independent of child-process termination.

## Behavior

When a readability handler observes empty `availableData` for stdout or
stderr, it unregisters that handler immediately after scheduling the existing
EOF bookkeeping.

EOF on one stream does not unregister the other stream.

Last-byte delivery that arrived before EOF remains available to readers.

Process-exit observation, exit-status handling, forced termination, and
shutdown cleanup stay responsible for the child process. They still run if the
child remains alive after a pipe is closed.

A handler that has unregistered at EOF must not be invoked again for that
stream on the same process instance.

## Non-behavior

This capability does not replace `ManagedProcess` with another process
subsystem.

It does not use CPU-time thresholds as the regression signal.

## Acceptance

- Close stdout while the child stays alive: stdout EOF is handled once, then
  shutdown completes.
- Close stderr while the child stays alive: stderr EOF is handled once, then
  shutdown completes.
- Count handler calls with bounded instrumentation.
