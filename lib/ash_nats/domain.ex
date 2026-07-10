defmodule AshNats.Domain do
  @moduledoc """
  Domain extension providing NATS defaults for every AshNats resource in the
  domain, so `connection`/`subject_prefix`/`encoder` don't have to be repeated
  per resource.

  ## Example

      defmodule MyApp.Shipping do
        use Ash.Domain, extensions: [AshNats.Domain]

        nats do
          connection :gnat
          subject_prefix "myapp.shipping"
        end

        resources do
          resource MyApp.Shipping.Shipment
        end
      end

  Resolution order for each option: the resource's own `nats` section, then
  the domain's, then (for `connection`) `config :ash_nats, :connection`.
  """

  @nats %Spark.Dsl.Section{
    name: :nats,
    describe: "Default NATS configuration for AshNats resources in this domain.",
    examples: [
      """
      nats do
        connection :gnat
        subject_prefix "myapp.shipping"
      end
      """
    ],
    schema: [
      connection: [
        type: :atom,
        doc: "Default Gnat connection name for resources in this domain."
      ],
      subject_prefix: [
        type: :string,
        doc: "Default subject prefix for resources in this domain."
      ],
      encoder: [
        type: {:behaviour, AshNats.Encoder},
        doc: "Default payload encoder for resources in this domain."
      ]
    ]
  }

  use Spark.Dsl.Extension, sections: [@nats]
end

defmodule AshNats.Domain.Info do
  @moduledoc "Introspection for the `nats` section of domains using `AshNats.Domain`."

  use Spark.InfoGenerator, extension: AshNats.Domain, sections: [:nats]
end
