# SSE/Hub — test notes (phase 1: investigation + TDD, no implementation yet)

Context: orbitx needs to resolve `condominium_id` server-side for
`/events/condo` instead of trusting a fragile client cookie — while
investigating that, we mapped bigger robustness gaps in `Sse`/`Hub` (no
heartbeat, no replay, no header/cookie access). This document is the
*before* of touching any implementation: current coverage, new tests already
written, and what's left to decide before tests for the new features can
actually be written.

## 1. Coverage before this session

- `hub.zig`: 15 tests — init/deinit, add/remove/count, `broadcast` (WS
  framing + dead-connection removal), `broadcastToChannel` (channel scoping +
  dead-connection removal), `emit`/`emitTo` (JSON, channel scoping),
  `notifyUser`, `add` with duplicate id.
- `sse.zig`: **zero tests.** `Sse.send/join/joinUser/param/wait` and
  `buildHandler` were never exercised directly.

## 2. New tests written this session (cover CURRENT behavior)

In `sse.zig`:
- `send` writes the exact `event: X\ndata: Y\n\n` wire format.
- `join` actually updates the connection's channel on the Hub (not just the
  local `sse.channel` field) — confirmed indirectly via `emitTo` reaching the
  connection after joining.
- `join`-ing a new channel makes the connection **stop** receiving on the old
  one.
- `joinUser` builds the `user:{id}` channel correctly.
- `param` returns the right value for an existing key, `null` for a missing
  one.

In `hub.zig` (filling gaps — only `broadcast`/`broadcastToChannel` had a
"removes dead connection" test, not `emit`/`emitTo`):
- `emitTo` removes a dead connection on write failure.
- `emit` (global) removes a dead connection on write failure.
- `emit` (global) reaches any SSE connection regardless of its channel
  (documents that `emit` ≠ `emitTo`: not channel-scoped, only `.sse`-typed).

All of these pass (`zig build test`) against the current implementation —
baseline, not red TDD.

## 3. One real "red" TDD test (needs no new API)

`sse.zig`: `"Sse (SPEC, currently failing): emitTo includes an incrementing
id: line"` — asserts every emitted event gets an incrementing `id: N` line
before `event:`. This is expressible with the **current** public API (just
`Hub.emitTo` + reading the wire), so it's a real test that fails today
(`sendSse` never writes `id:`) and should start passing once implemented.
Runs via `zig build test`, confirmed failing right now.

## 4. Features that can't be tested without deciding the API first

The other 5 requested features need new surface just for the test to
**compile** — it's not missing code, there's literally nowhere to put the
config or the data yet. Each one below lists what would need to exist, as a
proposal — none of this has been implemented, just sketched out for you to
decide the shape before I write real tests or code.

### 4.1 Periodic heartbeat
Needs: some way to configure an interval (`Hub.init(alloc, io, .{
.heartbeat_ms = 15000 })`?) and a mechanism that runs alongside each
connection while it sits in `Sse.wait()`, writing `: heartbeat\n\n` (an SSE
comment line, ignored by the client's `EventSource`, just keeps the
connection warm). Open question: is heartbeat per-Hub (every connection in
the process) or per-connection (configurable at `sse.join()` time)?

### 4.2 `Last-Event-ID` + replay
Two problems bundled together:
- `Sse`/`buildHandler` doesn't receive `ctx._headers` today (only
  `.params`) — needs either copying that over or exposing a way to read the
  raw header on reconnect.
- For replay to actually work, `Hub` would need to keep a recent event
  history per channel (ring buffer? TTL?) — today `Hub` only knows about
  *live* connections, it has zero memory of past events.
  Open question: how many events / how much time to retain per channel?

### 4.3 `retry:` field
Needs a way to configure the value (global in `Hub.init`? per-route, passed
into `buildHandler`?) and writing it once at handshake time (a `retry:
NNNN\n` line before the first event, or on every message — the RFC allows
either, but it's typically just at the start).

### 4.4 Access to the original request's headers/cookies
Simpler than the others: just needs `ctx._headers` (or a subset) copied into
`Sse` inside `buildHandler` (`sse.zig:88-95`), plus a method like
`Sse.header(name)` (mirroring `Ctx.header()`) and optionally
`Sse.cookie(name)` (mirroring `Ctx.cookie()`, which already exists in
`context.zig` — just reuse the same parsing logic).

### 4.5 Proactive dead-connection sweep
Today it only cleans up on the next `broadcast`/`emitTo` that fails to write
— an idle channel never prunes zombies. Would need a method like
`Hub.sweep()` (walks every connection, attempts an empty write/probe, removes
the ones that fail) and somewhere to call it periodically — the app already
has the `interval_threads`/`sseInterval` pattern in `core/app.zig`, which
could drive `hub.sweep()` on the same infra every N seconds.

## 5. Next step

Waiting on your call on the open questions above (heartbeat per-Hub vs.
per-connection, replay buffer size, `retry:` scope) before sketching the API
and, only then, writing real red tests for these 5.
