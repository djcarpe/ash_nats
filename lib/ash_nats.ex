defmodule AshNats do
  @moduledoc """
  An Ash extension that integrates resources with NATS.

  Provides two capabilities:

    * **Publications** — publish notifications to NATS subjects when actions
      run, via an `Ash.Notifier` (core NATS or JetStream publish-with-ack).
    * **Exposures** — expose resource actions over NATS request/reply,
      served by a `Gnat.Server` (see `AshNats.Rpc.Server`) or registered as
      a discoverable NATS service (see `AshNats.Rpc.Service`).

  ## Example

      defmodule MyApp.Shipping.Shipment do
        use Ash.Resource,
          domain: MyApp.Shipping,
          extensions: [AshNats]

        nats do
          connection :gnat
          subject_prefix "myapp.shipping"

          # publish to myapp.shipping.shipments.<id>.created on any create action
          publish_all :create, ["shipments", :id, "created"]
          publish :deliver, ["shipments", :id, "delivered"], mode: :jetstream

          # request/reply on myapp.shipping.shipments.get
          expose :read, subject: "shipments.get", get?: true
          expose :create, subject: "shipments.create"
        end
      end
  """

  @publish %Spark.Dsl.Entity{
    name: :publish,
    describe: """
    Publish a message to a NATS subject when a specific action runs.

    The first argument is an action name (or an action type atom — :create,
    :update, :destroy — to match every action of that type; `publish_all` is
    the explicit form of that). The second is the subject: a string, or a list
    of segments where atoms are resolved from the record (e.g.
    `["shipments", :id, "created"]`).
    """,
    examples: [
      ~S{publish :create, ["shipments", :id, "created"]},
      ~S{publish :cancel, "shipments.cancelled", mode: :jetstream}
    ],
    target: AshNats.Publication,
    args: [:action, :subject],
    schema: AshNats.Publication.schema()
  }

  @publish_all %Spark.Dsl.Entity{
    name: :publish_all,
    describe: """
    Publish a message for every action of the given type (:create, :update,
    :destroy).
    """,
    examples: [
      ~S{publish_all :update, ["shipments", :id, "updated"]}
    ],
    target: AshNats.Publication,
    args: [:action, :subject],
    auto_set_fields: [all?: true],
    schema: AshNats.Publication.schema()
  }

  @expose %Spark.Dsl.Entity{
    name: :expose,
    describe: """
    Expose an action over NATS request/reply. Requests are JSON-decoded into
    action input; replies are JSON envelopes (`{"ok": true, "data": ...}`).

    Served by a module that does `use AshNats.Rpc.Server, domains: [...]`, or
    `use AshNats.Rpc.Service, ...` to also register as a NATS service — there
    each exposure becomes a named endpoint (`endpoint:` overrides the name).
    """,
    examples: [
      ~S{expose :read, subject: "shipments.list"},
      ~S{expose :get_by_tracking_number, subject: "shipments.get", get?: true},
      ~S{expose :create, subject: "shipments.create", endpoint: "shipment_create"}
    ],
    target: AshNats.Exposure,
    args: [:action],
    schema: AshNats.Exposure.schema()
  }

  @nats %Spark.Dsl.Section{
    name: :nats,
    describe: "Configuration for NATS integration.",
    examples: [
      """
      nats do
        connection :gnat
        subject_prefix "myapp.shipping"

        publish_all :create, ["shipments", :id, "created"]
        expose :read, subject: "shipments.list"
      end
      """
    ],
    schema: [
      connection: [
        type: :atom,
        doc: """
        Registered name of the `Gnat` connection (or `Gnat.ConnectionSupervisor`
        name). Falls back to `config :ash_nats, :connection`.
        """
      ],
      subject_prefix: [
        type: :string,
        doc: "Prefix prepended (dot-separated) to every subject on this resource."
      ],
      encoder: [
        type: {:behaviour, AshNats.Encoder},
        doc: """
        Module implementing `AshNats.Encoder` for payload encoding/decoding.
        Defaults to the domain's `encoder` (see `AshNats.Domain`), then
        `AshNats.Encoder.Json`.
        """
      ],
      publish?: [
        type: :boolean,
        default: true,
        doc: "Kill-switch for all publications on this resource."
      ]
    ],
    entities: [@publish, @publish_all, @expose]
  }

  use Spark.Dsl.Extension,
    sections: [@nats],
    transformers: [AshNats.Transformers.AddNotifier],
    verifiers: [AshNats.Verifiers.VerifyActions]
end
