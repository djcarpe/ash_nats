# AshNats

NATS integration for [Ash](https://ash-hq.org) resources, built on [gnat](https://hex.pm/packages/gnat). Two capabilities behind one Spark DSL extension:

1. **Publications** — an `Ash.Notifier` that publishes action notifications to NATS subjects (core publish, or JetStream publish-with-ack).
2. **Exposures** — actions served over NATS request/reply via a `Gnat.Server`.

## Installation

```elixir
def deps do
  [
    {:ash_nats, path: "path/to/ash_nats"},
    {:gnat, "~> 1.8"}
  ]
end
```

## Connection

Start a Gnat connection (or ConnectionSupervisor) in your supervision tree:

```elixir
{Gnat.ConnectionSupervisor,
 %{
   name: :gnat,
   connection_settings: [%{host: "nats.svc.cluster.local", port: 4222}]
 }}
```

Either set the connection per-resource in the DSL, or globally:

```elixir
config :ash_nats, connection: :gnat
```

## Resource DSL

```elixir
defmodule MyApp.Shipping.Shipment do
  use Ash.Resource,
    domain: MyApp.Shipping,
    extensions: [AshNats]

  nats do
    connection :gnat
    subject_prefix "myapp.shipping"

    # All create actions → myapp.shipping.shipments.<id>.created
    publish_all :create, ["shipments", :id, "created"]
    publish_all :update, ["shipments", :id, "updated"]

    # A specific action, with JetStream ack semantics
    publish :deliver, ["shipments", :id, "delivered"], mode: :jetstream

    # Request/reply
    expose :read, subject: "shipments.list"
    expose :create, subject: "shipments.create"
    expose :update, subject: "shipments.update"
  end
end
```

Subject lists join with dots; atom segments resolve from the record at publish time (nil → `_`, and `.`/whitespace/wildcard characters are sanitized). String subjects are used verbatim. `subject_prefix` is prepended to everything, including exposure subjects.

### Event payload

```json
{
  "event": "shipment.deliver",
  "resource": "shipment",
  "action": "deliver",
  "type": "update",
  "data": { "id": "...", "status": "delivered", ... },
  "metadata": {},
  "occurred_at": "2026-06-11T14:00:00Z"
}
```

`data` contains public attributes only. Loaded relationships/calculations are not traversed — implement a custom `AshNats.Encoder` if you need richer payloads (e.g. protobuf).

## Headers

**On publications** — `headers` accepts a static list, or a fun/MFA receiving the notification for per-message values. `msg_id` sets `Nats-Msg-Id` for JetStream dedup:

```elixir
publish :deliver, ["shipments", :id, "delivered"],
  mode: :jetstream,
  msg_id: [:id, "delivered"],
  headers: fn notification ->
    [{"x-carrier", to_string(notification.changeset.context[:carrier_id] || "_")}]
  end
```

**On request/reply** — three pieces:

1. *Receiving*: incoming headers are always available to your actions via `changeset.context.ash_nats.headers` (and `.subject`). For actor/tenant resolution, give the server a `:context` resolver — it receives the raw Gnat message and returns Ash opts:

```elixir
defmodule MyApp.NatsAuth do
  def resolve(message) do
    with {_, "Bearer " <> token} <-
           List.keyfind(Map.get(message, :headers, []), "authorization", 0),
         {:ok, actor} <- MyApp.Auth.verify(token) do
      [actor: actor, tenant: actor.org_id]
    else
      _ -> [actor: nil]
    end
  end
end

defmodule MyApp.NatsRpc do
  use AshNats.Rpc.Server,
    domains: [MyApp.Shipping],
    context: {MyApp.NatsAuth, :resolve},
    passthrough_headers: ["x-request-id", "traceparent"]
end
```

2. *Pass-through*: `passthrough_headers` copies matching request headers (case-insensitive) onto the reply — correlation IDs, trace context. Note: `Gnat.Server`'s `{:reply, body}` can't carry headers, so header-bearing replies are published manually to `reply_to`; that's handled internally.

3. *Sending*: `AshNats.Rpc.Client.request/4` attaches headers and unwraps the envelope:

```elixir
{:ok, shipment, reply_headers} =
  AshNats.Rpc.Client.request(:gnat, "myapp.shipping.shipments.create",
    %{"order_id" => id},
    headers: [{"authorization", "Bearer " <> token}, {"x-request-id", rid}])
```

## Request/reply server

```elixir
defmodule MyApp.NatsRpc do
  use AshNats.Rpc.Server, domains: [MyApp.Shipping, MyApp.Billing]
end
```

Supervision:

```elixir
{Gnat.ConsumerSupervisor,
 %{
   connection_name: :gnat,
   module: MyApp.NatsRpc,
   subscription_topics:
     Enum.map(MyApp.NatsRpc.subscription_topics(), &%{topic: &1})
 }}
```

Calling from anywhere on the mesh:

```elixir
{:ok, %{body: body}} =
  Gnat.request(:gnat, "myapp.shipping.shipments.create",
    Jason.encode!(%{"order_id" => "...", "address" => %{...}}))

%{"ok" => true, "data" => shipment} = Jason.decode!(body)
```

### Registering as a NATS service (micro)

Use `AshNats.Rpc.Service` instead to register with the [NATS service
protocol](https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-32.md):
the service answers `$SRV.PING/INFO/STATS`, so it shows up in `nats micro ls`
with per-endpoint request/error/latency stats. Each `expose` becomes a named
endpoint (default `<resource>_<action>`, override with `endpoint: "..."`)
carrying `resource`/`action` metadata.

```elixir
defmodule MyApp.NatsService do
  use AshNats.Rpc.Service,
    name: "shipping",
    version: "1.0.0",
    description: "Shipping actions over NATS",
    domains: [MyApp.Shipping],
    context: {MyApp.NatsAuth, :resolve},
    passthrough_headers: ["x-request-id"]
end
```

The module is its own child spec — supervision is one line:

```elixir
children = [
  # after your Gnat.ConnectionSupervisor
  {MyApp.NatsService, connection_name: :gnat}
]
```

```console
$ nats micro info shipping
Service Information
  Service: shipping (39Ma3vUig88i7nwB)
  Version: 1.0.0
Endpoints:
  Name: shipment_create
  Subject: myapp.shipping.shipments.create
  Metadata: action: create, resource: shipment
```

Requests and semantics are identical to `AshNats.Rpc.Server`. Note that Ash
errors are replied as JSON envelopes (`"ok": false`), so they count as
requests — not errors — in `$SRV.STATS`; only unhandled crashes increment the
error counter.

Semantics:

- **read** → replies with a list, or a single record/nil with `get?: true`
- **create** → input is changeset input
- **update/destroy** → input must include the primary key field(s); the record is fetched, remaining keys become action input
- **generic actions** → run via `Ash.ActionInput`
- errors → `{"ok": false, "error": {"class": "invalid", "message": "..."}}`

## Delivery semantics (read this)

Notifiers fire after commit, outside the transaction. A crash between commit and publish drops the message — core-mode publications are **at-most-once**. `mode: :jetstream` gets you an ack from the stream but is still not atomic with the database write. If a subject needs guaranteed delivery, use a transactional outbox or CDC pipeline (e.g. logical replication → Broadway → JetStream) as the source of truth; use this extension for subjects where best-effort is acceptable (live dashboards, status feeds, cache invalidation).

## Known integration points / TODOs

- **Actor/tenant**: handled via the `:context` resolver on `use AshNats.Rpc.Server` (see Headers section).
- **Notifier injection**: `AshNats.Transformers.AddNotifier` persists into `:notifiers` the same way ash_paper_trail-style extensions do. If your Ash version changes this internal, fall back to listing the notifier explicitly: `use Ash.Resource, notifiers: [AshNats.Notifier]`.
- **gnat headers on request/4** require a reasonably recent gnat; drop the `headers` option from JetStream mode if you're pinned older.
