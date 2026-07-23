defmodule AshNats.Info do
  @moduledoc """
  Introspection for the `nats` section of resources using `AshNats`.

  Alongside the helpers below, `Spark.InfoGenerator` provides the raw option
  accessors (`nats_connection/1`, `nats_subject_prefix/1`, `nats_encoder/1`,
  `nats_publish?/1`). Prefer `connection/1`, `subject_prefix/1`, and
  `encoder/1`, which also apply the domain-level defaults from
  `AshNats.Domain` and the application environment.
  """

  use Spark.InfoGenerator, extension: AshNats, sections: [:nats]

  alias Spark.Dsl.Extension

  @doc "Whether the resource uses the AshNats extension."
  def nats?(resource) do
    AshNats in Spark.extensions(resource)
  end

  @doc """
  The Gnat connection name: the resource's `connection`, the domain's (see
  `AshNats.Domain`), or `config :ash_nats, :connection`.
  """
  def connection(resource) do
    with :error <- nats_connection(resource),
         :error <- domain_opt(resource, &AshNats.Domain.Info.nats_connection/1) do
      Application.get_env(:ash_nats, :connection)
    else
      {:ok, connection} -> connection
    end
  end

  @doc """
  Whether the resource's configured connection process is currently
  registered and alive. `false` when no connection is configured, when an
  atom connection name isn't registered to a live process, when a `pid` is
  dead, or when a `{:via, _, _}` tuple doesn't resolve. Used to silently skip
  publishing when NATS isn't wired up (e.g. in environments where no Gnat
  connection is started).
  """
  def connection_registered?(resource) do
    case connection(resource) do
      nil ->
        false

      name when is_atom(name) ->
        is_pid(Process.whereis(name))

      pid when is_pid(pid) ->
        Process.alive?(pid)

      {:via, _, _} = via ->
        is_pid(GenServer.whereis(via))

      _other ->
        true
    end
  end

  @doc "The subject prefix: the resource's `subject_prefix` or the domain's, or nil."
  def subject_prefix(resource) do
    with :error <- nats_subject_prefix(resource),
         :error <- domain_opt(resource, &AshNats.Domain.Info.nats_subject_prefix/1) do
      nil
    else
      {:ok, prefix} -> prefix
    end
  end

  @doc "The payload encoder: the resource's `encoder` or the domain's, defaulting to JSON."
  def encoder(resource) do
    with :error <- nats_encoder(resource),
         :error <- domain_opt(resource, &AshNats.Domain.Info.nats_encoder/1) do
      AshNats.Encoder.Json
    else
      {:ok, encoder} -> encoder
    end
  end

  @doc "Whether publications are enabled for the resource."
  def publish?(resource), do: nats_publish?(resource)

  @doc "All configured publications."
  def publications(resource) do
    resource
    |> Extension.get_entities([:nats])
    |> Enum.filter(&match?(%AshNats.Publication{}, &1))
  end

  @doc "All configured request/reply exposures."
  def exposures(resource) do
    resource
    |> Extension.get_entities([:nats])
    |> Enum.filter(&match?(%AshNats.Exposure{}, &1))
  end

  @doc """
  The fully-qualified request subject for an exposure (prefix + subject,
  defaulting the subject to the action name).
  """
  def exposure_subject(resource, %AshNats.Exposure{} = exposure) do
    base = exposure.subject || to_string(exposure.action)

    case subject_prefix(resource) do
      nil -> base
      prefix -> prefix <> "." <> base
    end
  end

  @doc """
  The NATS service endpoint name for an exposure (see `AshNats.Rpc.Service`):
  the `endpoint` option if set, otherwise `<resource short_name>_<action>`
  sanitized to the characters the service protocol allows.
  """
  def exposure_endpoint(resource, %AshNats.Exposure{} = exposure) do
    exposure.endpoint ||
      "#{Ash.Resource.Info.short_name(resource)}_#{exposure.action}"
      |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")
  end

  defp domain_opt(resource, fetcher) when is_atom(resource) do
    with domain when not is_nil(domain) <- Ash.Resource.Info.domain(resource),
         true <- AshNats.Domain in Spark.extensions(domain) do
      fetcher.(domain)
    else
      _ -> :error
    end
  end

  defp domain_opt(_resource, _fetcher), do: :error
end
