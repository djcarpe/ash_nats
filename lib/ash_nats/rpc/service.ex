defmodule AshNats.Rpc.Service do
  @moduledoc """
  Serves `expose`d actions as a NATS service (micro), per the
  [NATS service protocol](https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-32.md).

  Same request/reply semantics as `AshNats.Rpc.Server`, plus the service
  registers itself with NATS: it answers `$SRV.PING`, `$SRV.INFO`, and
  `$SRV.STATS`, so it appears in `nats micro ls` with per-endpoint request,
  error, and processing-time stats. Each exposed action becomes a named
  endpoint whose subject is the exposure's request subject.

  ## Usage

      defmodule MyApp.NatsService do
        use AshNats.Rpc.Service,
          name: "shipping",
          version: "1.0.0",
          description: "Shipping actions over NATS",
          domains: [MyApp.Shipping, MyApp.Billing],
          context: {MyApp.NatsAuth, :resolve},
          passthrough_headers: ["x-request-id", "traceparent"]
      end

  Options:

    * `:name` (required) — service name (`[a-zA-Z0-9_-]+`).
    * `:version` (required) — semver version, without a "v" prefix.
    * `:description` — optional service description.
    * `:metadata` — optional string→string map of service metadata.
    * `:domains`, `:context`, `:passthrough_headers` — as on
      `AshNats.Rpc.Server`.

  Endpoint names default to `<resource short_name>_<action>`; override
  per-exposure with `expose ..., endpoint: "my_name"`. Each endpoint carries
  `resource` and `action` metadata, visible via `nats micro info`.

  ## Supervision

  The generated module is a ready-made child spec that starts a
  `Gnat.ConsumerSupervisor` with the service definition:

      children = [
        {MyApp.NatsService, connection_name: :gnat}
      ]

  Or wire it manually:

      {Gnat.ConsumerSupervisor,
       %{
         connection_name: :gnat,
         module: MyApp.NatsService,
         service_definition: MyApp.NatsService.service_definition()
       }}
  """

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use Gnat.Services.Server

      @ash_nats_domains Keyword.fetch!(opts, :domains)
      @ash_nats_service [
        name: Keyword.fetch!(opts, :name),
        version: Keyword.fetch!(opts, :version),
        description: Keyword.get(opts, :description),
        metadata: Keyword.get(opts, :metadata, %{})
      ]
      @ash_nats_opts [
        context: Keyword.get(opts, :context),
        passthrough_headers: Keyword.get(opts, :passthrough_headers, [])
      ]

      @doc """
      The `Gnat.Services.Server.service_configuration/0` for this service,
      with one endpoint per exposed action.
      """
      def service_definition do
        AshNats.Rpc.Service.service_definition(@ash_nats_service, @ash_nats_domains)
      end

      @doc """
      Starts a `Gnat.ConsumerSupervisor` hosting this service.

      Options: `:connection_name` (required) — the Gnat connection name —
      and optionally `:name` to register the consumer process.
      """
      def child_spec(opts) do
        AshNats.Rpc.Service.child_spec(__MODULE__, opts)
      end

      @impl true
      def request(message, _endpoint, _group) do
        AshNats.Rpc.Server.handle_request(@ash_nats_domains, @ash_nats_opts, message)
      end

      @impl true
      def error(message, error) do
        AshNats.Rpc.Server.handle_error(message, error)
      end
    end
  end

  ## Runtime

  @doc false
  def service_definition(service, domains) do
    %{
      name: Keyword.fetch!(service, :name),
      version: Keyword.fetch!(service, :version),
      description: Keyword.get(service, :description),
      metadata: Keyword.get(service, :metadata, %{}),
      endpoints: endpoints(domains)
    }
  end

  @doc false
  def child_spec(module, opts) do
    settings = %{
      connection_name: Keyword.fetch!(opts, :connection_name),
      module: module,
      service_definition: module.service_definition()
    }

    %{
      id: module,
      start: {Gnat.ConsumerSupervisor, :start_link, [settings, Keyword.take(opts, [:name])]},
      shutdown: 30_000
    }
  end

  defp endpoints(domains) do
    endpoints =
      for domain <- domains,
          resource <- Ash.Domain.Info.resources(domain),
          AshNats.Info.nats?(resource),
          exposure <- AshNats.Info.exposures(resource) do
        %{
          name: AshNats.Info.exposure_endpoint(resource, exposure),
          subject: AshNats.Info.exposure_subject(resource, exposure),
          metadata: %{
            "resource" => to_string(Ash.Resource.Info.short_name(resource)),
            "action" => to_string(exposure.action)
          }
        }
      end

    case endpoints -- Enum.uniq_by(endpoints, & &1.name) do
      [] ->
        endpoints

      dupes ->
        raise ArgumentError,
              "duplicate NATS service endpoint names: " <>
                "#{dupes |> Enum.map(& &1.name) |> Enum.uniq() |> Enum.join(", ")}. " <>
                "Disambiguate with `expose ..., endpoint: \"...\"`."
    end
  end
end
