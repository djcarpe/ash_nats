defmodule AshNats.Verifiers.VerifyActions do
  @moduledoc """
  Compile-time checks:

    * `publish` action names reference real actions (unless they're a type
      atom: :create/:update/:destroy)
    * `expose` actions reference real actions
    * `expose` endpoint names are valid NATS service endpoint names
  """

  use Spark.Dsl.Verifier
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @types [:create, :update, :destroy]

  @impl true
  def verify(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)

    action_names =
      dsl_state
      |> Verifier.get_entities([:actions])
      |> MapSet.new(& &1.name)

    entities = Verifier.get_entities(dsl_state, [:nats])

    with :ok <- verify_publications(entities, action_names, module),
         :ok <- verify_exposures(entities, action_names, module) do
      verify_endpoints(entities, module)
    end
  end

  defp verify_publications(entities, action_names, module) do
    entities
    |> Enum.filter(&match?(%AshNats.Publication{}, &1))
    |> Enum.reject(&(&1.action in @types or MapSet.member?(action_names, &1.action)))
    |> case do
      [] ->
        :ok

      [%{action: bad} | _] ->
        {:error,
         DslError.exception(
           module: module,
           path: [:nats, :publish],
           message:
             "publish references action #{inspect(bad)}, which is not an action " <>
               "on this resource (and not one of :create, :update, :destroy)"
         )}
    end
  end

  defp verify_exposures(entities, action_names, module) do
    entities
    |> Enum.filter(&match?(%AshNats.Exposure{}, &1))
    |> Enum.reject(&MapSet.member?(action_names, &1.action))
    |> case do
      [] ->
        :ok

      [%{action: bad} | _] ->
        {:error,
         DslError.exception(
           module: module,
           path: [:nats, :expose],
           message:
             "expose references action #{inspect(bad)}, which is not an action on this resource"
         )}
    end
  end

  defp verify_endpoints(entities, module) do
    entities
    |> Enum.filter(&match?(%AshNats.Exposure{}, &1))
    |> Enum.reject(&(is_nil(&1.endpoint) or &1.endpoint =~ ~r/^[a-zA-Z0-9_-]+$/))
    |> case do
      [] ->
        :ok

      [%{endpoint: bad} | _] ->
        {:error,
         DslError.exception(
           module: module,
           path: [:nats, :expose],
           message:
             "endpoint #{inspect(bad)} is not a valid NATS service endpoint name " <>
               "(must match [a-zA-Z0-9_-]+)"
         )}
    end
  end
end
