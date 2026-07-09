defmodule AshNats.Info do
  @moduledoc """
  Introspection for the `nats` section of resources using `AshNats`.
  """

  alias Spark.Dsl.Extension

  @doc "Whether the resource uses the AshNats extension."
  def nats?(resource) do
    AshNats in Spark.extensions(resource)
  end

  @doc "The Gnat connection name, falling back to `config :ash_nats, :connection`."
  def connection(resource) do
    Extension.get_opt(
      resource,
      [:nats],
      :connection,
      Application.get_env(:ash_nats, :connection)
    )
  end

  @doc "The subject prefix for the resource, or nil."
  def subject_prefix(resource) do
    Extension.get_opt(resource, [:nats], :subject_prefix, nil)
  end

  @doc "The payload encoder module."
  def encoder(resource) do
    Extension.get_opt(resource, [:nats], :encoder, AshNats.Encoder.Json)
  end

  @doc "Whether publications are enabled for the resource."
  def publish?(resource) do
    Extension.get_opt(resource, [:nats], :publish?, true)
  end

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
end
