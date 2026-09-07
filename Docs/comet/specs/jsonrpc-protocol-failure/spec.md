# JSON-RPC protocol failure versus EOF

## Purpose

`JSONRPCClient` separates a malformed or invalid protocol line from clean
transport EOF last-line recovery.

## Behavior

When `consume` fails to decode or validate a complete line, the client:

1. discards remaining buffered bytes
2. fails every pending request with a typed protocol error
3. closes the connection
4. does not decode further lines from that buffer or later chunks on the same
   generation

Clean transport EOF may still decode one remaining buffer that has no trailing
newline, then close. That path is not used after a parse or validation error.

A well-formed response that follows a malformed line in the same chunk, or in
a later chunk of the same generation, must not complete the pending request.

Existing oversized-line, fragmented-line, and clean-EOF last-line behavior
remains.

## Non-behavior

This capability does not introduce a new reader abstraction.

It does not treat stderr diagnostics as protocol data.

## Acceptance

- Chunk `not json\n{"id":1,"result":"accepted"}\n` with request 1 pending:
  the request fails; it does not return `accepted`.
- The same pair in separate chunks also fails the request.
- A valid last line without newline at clean EOF still completes.
