defmodule AshNats.Verifiers.VerifyActions do
  @moduledoc """
  Compile-time checks:

    * `publish` references a real action (or a type atom: :create/:update/
      :destroy); `publish_all` uses an action type
    * `publish`/`msg_id` subject segments given as atoms reference fields on
      the resource
    * `expose` actions reference real actions
    * `expose` subjects are unique on the resource
    * `expose` endpoint names are valid NATS service endpoint names
    * `get?: true` is only used on read actions
    * `identity:` references a real identity
  """

  use Spark.Dsl.Verifier
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @types [:create, :update, :destroy]
  @special_subject_segments [:_resource, :_action, :_pkey]

  @impl true
  def verify(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)

    actions = Verifier.get_entities(dsl_state, [:actions])
    action_names = MapSet.new(actions, & &1.name)
    entities = Verifier.get_entities(dsl_state, [:nats])
    publications = Enum.filter(entities, &match?(%AshNats.Publication{}, &1))
    exposures = Enum.filter(entities, &match?(%AshNats.Exposure{}, &1))

    with :ok <- verify_publications(publications, action_names, module),
         :ok <- verify_segments(publications, dsl_state, module),
         :ok <- verify_exposures(exposures, action_names, module),
         :ok <- verify_subjects(exposures, module),
         :ok <- verify_endpoints(exposures, module),
         :ok <- verify_get(exposures, actions, module) do
      verify_identities(exposures, dsl_state, module)
    end
  end

  defp verify_publications(publications, action_names, module) do
    Enum.find_value(publications, :ok, fn
      %{all?: true, action: type} = publication when type not in @types ->
        error(
          module,
          :publish_all,
          "publish_all references #{inspect(type)}, which is not an action type " <>
            "(:create, :update, :destroy). Use `publish` for a specific action.",
          publication
        )

      %{all?: false, action: name} = publication when name not in @types ->
        unless MapSet.member?(action_names, name) do
          error(
            module,
            :publish,
            "publish references action #{inspect(name)}, which is not an action " <>
              "on this resource (and not one of :create, :update, :destroy)",
            publication
          )
        end

      _ ->
        nil
    end)
  end

  defp verify_segments(publications, dsl_state, module) do
    fields = field_names(dsl_state)

    Enum.find_value(publications, :ok, fn publication ->
      bad =
        ((atom_segments(publication.subject) -- @special_subject_segments) ++
           atom_segments(publication.msg_id))
        |> Enum.reject(&MapSet.member?(fields, &1))

      case bad do
        [] ->
          nil

        [segment | _] ->
          error(
            module,
            :publish,
            "subject/msg_id segment #{inspect(segment)} is not a field on this " <>
              "resource (attributes, relationships, calculations, aggregates)",
            publication
          )
      end
    end)
  end

  defp atom_segments(segments) when is_list(segments), do: Enum.filter(segments, &is_atom/1)
  defp atom_segments(_), do: []

  defp field_names(dsl_state) do
    [[:attributes], [:relationships], [:calculations], [:aggregates]]
    |> Enum.flat_map(&Verifier.get_entities(dsl_state, &1))
    |> MapSet.new(& &1.name)
  end

  defp verify_exposures(exposures, action_names, module) do
    Enum.find_value(exposures, :ok, fn exposure ->
      unless MapSet.member?(action_names, exposure.action) do
        error(
          module,
          :expose,
          "expose references action #{inspect(exposure.action)}, which is not an " <>
            "action on this resource",
          exposure
        )
      end
    end)
  end

  defp verify_subjects(exposures, module) do
    exposures
    |> Enum.group_by(&(&1.subject || to_string(&1.action)))
    |> Enum.find_value(:ok, fn
      {_subject, [_]} ->
        nil

      {subject, [%{action: a}, %{action: b} = duplicate | _]} ->
        error(
          module,
          :expose,
          "subject #{inspect(subject)} is exposed by both #{inspect(a)} and " <>
            "#{inspect(b)}. Give one of them a distinct `subject:`.",
          duplicate
        )
    end)
  end

  defp verify_endpoints(exposures, module) do
    Enum.find_value(exposures, :ok, fn exposure ->
      unless is_nil(exposure.endpoint) or exposure.endpoint =~ ~r/^[a-zA-Z0-9_-]+$/ do
        error(
          module,
          :expose,
          "endpoint #{inspect(exposure.endpoint)} is not a valid NATS service " <>
            "endpoint name (must match [a-zA-Z0-9_-]+)",
          exposure
        )
      end
    end)
  end

  defp verify_get(exposures, actions, module) do
    actions_by_name = Map.new(actions, &{&1.name, &1})

    Enum.find_value(exposures, :ok, fn exposure ->
      action = Map.get(actions_by_name, exposure.action)

      if (exposure.get? and action) && action.type != :read do
        error(
          module,
          :expose,
          "get?: true is only supported on read actions, and " <>
            "#{inspect(exposure.action)} is a #{action.type} action",
          exposure
        )
      end
    end)
  end

  defp verify_identities(exposures, dsl_state, module) do
    identity_names =
      dsl_state
      |> Verifier.get_entities([:identities])
      |> MapSet.new(& &1.name)

    Enum.find_value(exposures, :ok, fn exposure ->
      unless is_nil(exposure.identity) or MapSet.member?(identity_names, exposure.identity) do
        error(
          module,
          :expose,
          "identity #{inspect(exposure.identity)} is not an identity on this resource",
          exposure
        )
      end
    end)
  end

  defp error(module, entity, message, offender) do
    {:error,
     DslError.exception(
       module: module,
       path: [:nats, entity],
       message: message,
       location: Spark.Dsl.Entity.anno(offender)
     )}
  end
end
