defmodule AshNats.Notifier do
  @moduledoc """
  An `Ash.Notifier` that publishes action notifications to NATS subjects, as
  configured by the `publish`/`publish_all` entities in the `nats` section.

  Like all Ash notifiers, this fires *after* the transaction commits — so a
  rolled-back action never publishes, but a crash between commit and publish
  can drop a message. Treat core-mode publications as at-most-once. For
  stronger guarantees, use `mode: :jetstream` (publish-with-ack, still not
  transactional) or pair this with your CDC pipeline as the source of truth.
  """

  use Ash.Notifier
  require Logger

  @jetstream_timeout 5_000

  @impl true
  def notify(%Ash.Notifier.Notification{resource: resource} = notification) do
    if AshNats.Info.nats?(resource) and AshNats.Info.publish?(resource) do
      resource
      |> AshNats.Info.publications()
      |> Enum.filter(&matches?(&1, notification.action))
      |> Enum.each(&publish(resource, &1, notification))
    end

    :ok
  end

  defp matches?(%{action: type}, action) when type in [:create, :update, :destroy] do
    action.type == type or action.name == type
  end

  defp matches?(%{action: name}, action), do: action.name == name

  defp publish(resource, publication, notification) do
    with {:ok, conn} <- fetch_connection(resource),
         {:ok, subject} <- build_subject(resource, publication, notification.data),
         {:ok, payload} <- encode_payload(resource, publication, notification) do
      headers =
        resolve_headers(publication.headers, notification) ++
          msg_id_headers(publication.msg_id, notification)

      do_publish(publication.mode, conn, subject, payload, headers)
    else
      {:error, reason} ->
        Logger.error(
          "AshNats: skipped publication for #{inspect(resource)}.#{notification.action.name}: #{inspect(reason)}"
        )
    end
  end

  defp resolve_headers(headers, _notification) when is_list(headers), do: headers
  defp resolve_headers(fun, notification) when is_function(fun, 1), do: fun.(notification)

  defp resolve_headers({m, f, a}, notification) when is_atom(m) and is_atom(f),
    do: apply(m, f, [notification | a])

  defp msg_id_headers(nil, _notification), do: []

  defp msg_id_headers(segments, notification) when is_list(segments) do
    id =
      segments
      |> Enum.map(&resolve_segment(&1, notification.data))
      |> Enum.join(".")

    [{"Nats-Msg-Id", id}]
  end

  defp msg_id_headers(fun, notification) when is_function(fun, 1),
    do: [{"Nats-Msg-Id", fun.(notification)}]

  defp msg_id_headers({m, f, a}, notification) when is_atom(m) and is_atom(f),
    do: [{"Nats-Msg-Id", apply(m, f, [notification | a])}]

  defp fetch_connection(resource) do
    case AshNats.Info.connection(resource) do
      nil -> {:error, :no_connection_configured}
      conn -> {:ok, conn}
    end
  end

  defp build_subject(resource, %{subject: subject}, record) do
    base =
      case subject do
        binary when is_binary(binary) ->
          binary

        segments when is_list(segments) ->
          segments
          |> Enum.map(&resolve_segment(&1, record))
          |> Enum.join(".")
      end

    case AshNats.Info.subject_prefix(resource) do
      nil -> {:ok, base}
      prefix -> {:ok, prefix <> "." <> base}
    end
  end

  defp resolve_segment(segment, _record) when is_binary(segment), do: segment

  defp resolve_segment(segment, record) when is_atom(segment) do
    case Map.get(record, segment) do
      nil -> "_"
      value -> value |> to_string() |> String.replace(~r/[.\s>*]/, "_")
    end
  end

  defp encode_payload(resource, publication, notification) do
    encoder = AshNats.Info.encoder(resource)

    event =
      publication.event ||
        "#{short_name(resource)}.#{notification.action.name}"

    encoder.encode_event(%{
      "event" => event,
      "resource" => short_name(resource),
      "action" => notification.action.name,
      "type" => notification.action.type,
      "data" => AshNats.Serializer.serialize(notification.data),
      "metadata" => safe_metadata(notification.metadata),
      "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  defp short_name(resource) do
    resource |> Module.split() |> List.last() |> Macro.underscore()
  end

  defp safe_metadata(metadata) when is_map(metadata) do
    case Jason.encode(metadata) do
      {:ok, _} -> metadata
      {:error, _} -> %{}
    end
  end

  defp safe_metadata(_), do: %{}

  defp do_publish(:core, conn, subject, payload, headers) do
    opts = if headers == [], do: [], else: [headers: headers]

    try do
      case Gnat.pub(conn, subject, payload, opts) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error("AshNats: publish to #{subject} failed: #{inspect(reason)}")
      end
    catch
      :exit, reason ->
        Logger.error("AshNats: publish to #{subject} failed (connection down): #{inspect(reason)}")
    end
  end

  defp do_publish(:jetstream, conn, subject, payload, headers) do
    opts = [receive_timeout: @jetstream_timeout]
    opts = if headers == [], do: opts, else: Keyword.put(opts, :headers, headers)

    try do
      case Gnat.request(conn, subject, payload, opts) do
        {:ok, %{body: body}} ->
          case Jason.decode(body) do
            {:ok, %{"error" => error}} ->
              Logger.error("AshNats: JetStream rejected publish to #{subject}: #{inspect(error)}")

            _pub_ack ->
              :ok
          end

        {:error, reason} ->
          Logger.error(
            "AshNats: JetStream publish to #{subject} got no ack: #{inspect(reason)} " <>
              "(is the subject bound to a stream?)"
          )
      end
    catch
      :exit, reason ->
        Logger.error(
          "AshNats: JetStream publish to #{subject} failed (connection down): #{inspect(reason)}"
        )
    end
  end
end
