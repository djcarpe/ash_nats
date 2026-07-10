---
name: verify
description: Verify ash_nats changes end-to-end against a real NATS server (request/reply, publications, NATS service registration).
---

# Verifying ash_nats

This is a library — its surface is NATS traffic. Verify by starting a real
NATS server, running a script that defines an Ash resource using the
extension, and observing wire behavior with the `nats` CLI.

## NATS server

`docker compose up -d nats` works if docker is running; on this machine the
faster path is the local binary (already installed):

```bash
nats-server -p 4222 -js   # run in background
```

The `nats` CLI is at /usr/local/bin/nats and defaults to localhost:4222.

## Drive it

Write a scratchpad `.exs` defining a resource (Ets data layer) + domain +
server/service module, start `Gnat.ConnectionSupervisor` and the consumer in
a `Supervisor`, then `mix run` it. Gotchas:

- `Gnat.ConsumerSupervisor` polls for the named connection every 2s —
  requests sent before it subscribes are dropped (core NATS). Retry-loop a
  `$SRV.PING` (or the endpoint subject) with a short `receive_timeout` until
  it answers before asserting anything.
- Keep the script alive (`Process.sleep`) after setup so you can probe from
  outside with the `nats` CLI in a separate Bash call.

## Observe

- Request/reply: `nats req 'subject' '{"json":"body"}' --timeout=2s` or
  `AshNats.Rpc.Client.request/4`; replies are `{"ok":true,"data":...}`
  envelopes.
- Service registration (`AshNats.Rpc.Service`): `nats micro ls`,
  `nats micro info <name>`, `nats micro stats <name>`; raw protocol via
  `nats req '$SRV.PING' ''` (note: single-quote `$SRV` in zsh).
- Publications: `nats sub 'prefix.>'` in a background Bash call, then run
  actions.

## Gotchas

- If `mix format` raises "Spark.Formatter requires sourceror", the spark dep
  was compiled before sourceror existed — `mix deps.compile spark --force`.
- Spark verifier errors (`AshNats.Verifiers.*`) surface as compiler
  diagnostics via `@after_verify`, not exceptions — `assert_raise` around
  `defmodule` won't catch them; call the verifier directly on a modified
  `Resource.spark_dsl_config()` instead.
- Ash-level errors reply as `"ok": false` envelopes and count as *requests*
  (not errors) in `$SRV.STATS`; only crashes increment the error counter.
