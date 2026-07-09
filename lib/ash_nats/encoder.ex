defmodule AshNats.Encoder do
  @moduledoc """
  Behaviour for encoding/decoding NATS payloads. The default implementation is
  `AshNats.Encoder.Json`. Swap per-resource via the `encoder` DSL option, e.g.
  to use Protobuf or MessagePack.
  """

  @callback encode_event(event :: map()) :: {:ok, binary()} | {:error, term()}
  @callback decode_request(binary()) :: {:ok, map()} | {:error, term()}
  @callback encode_response(map()) :: {:ok, binary()} | {:error, term()}
end

defmodule AshNats.Encoder.Json do
  @moduledoc "Default JSON encoder backed by Jason."
  @behaviour AshNats.Encoder

  @impl true
  def encode_event(event), do: Jason.encode(event)

  @impl true
  def decode_request(""), do: {:ok, %{}}

  def decode_request(binary) do
    case Jason.decode(binary) do
      {:ok, %{} = map} -> {:ok, map}
      {:ok, other} -> {:error, {:invalid_request, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def encode_response(response), do: Jason.encode(response)
end

defmodule AshNats.Serializer do
  @moduledoc """
  Converts Ash records into JSON-safe maps (public attributes only; loaded
  relationships and calculations are intentionally not traversed — handle those
  in a custom encoder or a `transform` if you need them).
  """

  def serialize(%Ash.NotLoaded{}), do: nil
  def serialize(%Ash.ForbiddenField{}), do: nil

  def serialize(%resource{} = record) when is_struct(record) do
    if Ash.Resource.Info.resource?(resource) do
      resource
      |> Ash.Resource.Info.public_attributes()
      |> Map.new(fn %{name: name} ->
        {to_string(name), encode_value(Map.get(record, name))}
      end)
    else
      encode_value(record)
    end
  end

  def serialize(records) when is_list(records), do: Enum.map(records, &serialize/1)
  def serialize(nil), do: nil
  def serialize(other), do: encode_value(other)

  defp encode_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp encode_value(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp encode_value(%Date{} = d), do: Date.to_iso8601(d)
  defp encode_value(%Time{} = t), do: Time.to_iso8601(t)
  defp encode_value(%Decimal{} = d), do: Decimal.to_string(d)
  defp encode_value(%Ash.NotLoaded{}), do: nil
  defp encode_value(%Ash.ForbiddenField{}), do: nil

  defp encode_value(%_{} = struct) do
    if Ash.Resource.Info.resource?(struct.__struct__) do
      serialize(struct)
    else
      struct |> Map.from_struct() |> encode_value()
    end
  end

  defp encode_value(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), encode_value(v)} end)
  end

  defp encode_value(list) when is_list(list), do: Enum.map(list, &encode_value/1)
  defp encode_value(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> encode_value()
  defp encode_value(other), do: other
end
