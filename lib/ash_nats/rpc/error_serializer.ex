defmodule AshNats.Rpc.ErrorSerializer do
  @moduledoc """
  Converts errors raised or returned by Ash actions into the wire-safe error
  envelope used by `AshNats.Rpc.Server`:

      %{
        "ok" => false,
        "error" => %{
          "class" => "invalid" | "forbidden" | "framework" | "unknown",
          "message" => "summary of the first error",
          "errors" => [
            %{"message" => ..., "field" => ..., "fields" => [...], "path" => [...]}
          ]
        }
      }

  User-facing error classes (`:invalid`, `:forbidden`) include per-error
  messages and the fields they concern. Internal classes (`:framework`,
  `:unknown`) are logged in full and replied with a generic message so
  implementation details never cross the wire.
  """

  require Logger

  @internal_classes [:framework, :unknown]
  @internal_message "something went wrong"

  def serialize(error) do
    class = Ash.Error.to_error_class(error)

    if class.class in @internal_classes do
      Logger.error("AshNats.Rpc: #{class.class} error: " <> Exception.message(class))
      envelope(class.class, @internal_message, [])
    else
      errors = Enum.map(class.errors, &serialize_error/1)
      message = errors |> List.first(%{}) |> Map.get("message", @internal_message)
      envelope(class.class, message, errors)
    end
  end

  @doc "Envelope for protocol-level errors (bad payload, unknown subject, ...)."
  def protocol_error(class, message) do
    envelope(class, message, [%{"message" => message}])
  end

  defp envelope(class, message, errors) do
    %{
      "ok" => false,
      "error" => %{
        "class" => to_string(class),
        "message" => message,
        "errors" => errors
      }
    }
  end

  defp serialize_error(error) do
    %{"message" => safe_message(error)}
    |> put_present("field", Map.get(error, :field))
    |> put_present("fields", presence(Map.get(error, :fields)))
    |> put_present("path", presence(Map.get(error, :path)))
  end

  # Leaf messages are safe, but splode prepends bread crumbs ("Error returned
  # from: MyApp.Order.create") — strip them before rendering.
  defp safe_message(%{bread_crumbs: _} = error),
    do: Exception.message(%{error | bread_crumbs: []})

  defp safe_message(error) when is_exception(error), do: Exception.message(error)
  defp safe_message(error), do: inspect(error)

  defp put_present(map, _key, nil), do: map

  defp put_present(map, key, value) do
    Map.put(map, key, encode_value(value))
  end

  defp presence([]), do: nil
  defp presence(value), do: value

  defp encode_value(list) when is_list(list), do: Enum.map(list, &encode_value/1)
  defp encode_value(value) when is_atom(value) or is_binary(value), do: to_string(value)
  defp encode_value(value) when is_integer(value), do: value
  defp encode_value(value), do: inspect(value)
end
