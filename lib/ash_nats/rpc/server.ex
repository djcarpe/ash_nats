defmodule AshNats.Rpc.Server do
  @moduledoc """
  Serves `expose`d actions over NATS request/reply.

  ## Usage

      defmodule MyApp.NatsRpc do
        use AshNats.Rpc.Server,
          domains: [MyApp.Shipping, MyApp.Billing],
          context: {MyApp.NatsAuth, :resolve},
          passthrough_headers: ["x-request-id", "traceparent"]
      end

  Options:

    * `:domains` (required) — Ash domains whose resources may expose actions.
    * `:context` — `{m, f}` or `{m, f, args}` receiving the raw Gnat message
      (which includes `:headers` when the requester sent any) and returning a
      keyword list merged into every Ash call: `:actor`, `:tenant`, `:context`.
      This is where you validate a JWT from a header and produce an actor.
    * `:passthrough_headers` — header keys (case-insensitive) copied from the
      request onto the reply, e.g. correlation/trace headers.

  Incoming headers are always available to your actions regardless of the
  `:context` resolver, under `context.ash_nats`:

      # in a change/preparation
      %{headers: headers, subject: subject} = changeset.context.ash_nats

  ## Supervision

      {Gnat.ConsumerSupervisor,
       %{
         connection_name: :gnat,
         module: MyApp.NatsRpc,
         subscription_topics:
           Enum.map(MyApp.NatsRpc.subscription_topics(), &%{topic: &1})
       }}

  ## Replies

  `%{"ok" => true, "data" => ...}` or
  `%{"ok" => false, "error" => %{"class" => ..., "message" => ...}}`.

  When `passthrough_headers` match, the reply is published manually with those
  headers (Gnat.Server's `{:reply, body}` tuple can't carry headers); otherwise
  the normal reply path is used.
  """

  require Logger

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use Gnat.Server

      @ash_nats_domains Keyword.fetch!(opts, :domains)
      @ash_nats_opts [
        context: Keyword.get(opts, :context),
        passthrough_headers: Keyword.get(opts, :passthrough_headers, [])
      ]

      @doc "All subjects this server should subscribe to."
      def subscription_topics do
        AshNats.Rpc.Server.subscription_topics(@ash_nats_domains)
      end

      @impl true
      def request(message) do
        AshNats.Rpc.Server.handle_request(@ash_nats_domains, @ash_nats_opts, message)
      end

      @impl true
      def error(message, error) do
        AshNats.Rpc.Server.handle_error(message, error)
      end
    end
  end

  ## Runtime

  def subscription_topics(domains) do
    domains |> routes() |> Map.keys()
  end

  def handle_request(domains, server_opts, %{topic: topic, body: body} = message) do
    case Map.fetch(routes(domains), topic) do
      {:ok, {domain, resource, exposure}} ->
        encoder = AshNats.Info.encoder(resource)

        reply =
          case encoder.decode_request(body) do
            {:ok, input} ->
              ash_opts = build_ash_opts(server_opts[:context], message, domain)
              run(resource, exposure, input, ash_opts)

            {:error, reason} ->
              error_reply("invalid_request", inspect(reason))
          end

        respond(encoder, reply, message, server_opts[:passthrough_headers])

      :error ->
        respond(AshNats.Encoder.Json, error_reply("unknown_subject", topic), message, [])
    end
  end

  def handle_error(%{topic: topic} = message, error) do
    Logger.error("AshNats.Rpc: unhandled error on #{topic}: #{inspect(error)}")

    respond(
      AshNats.Encoder.Json,
      error_reply("internal_error", "unhandled server error"),
      message,
      []
    )
  end

  ## Context / actor resolution

  defp build_ash_opts(resolver, message, domain) do
    base = [
      domain: domain,
      context: %{
        ash_nats: %{
          headers: incoming_headers(message),
          subject: message.topic
        }
      }
    ]

    case resolve_context(resolver, message) do
      [] ->
        base

      user_opts when is_list(user_opts) ->
        Keyword.merge(base, user_opts, fn
          :context, base_ctx, user_ctx -> Map.merge(base_ctx, user_ctx)
          _key, _base, user -> user
        end)
    end
  end

  defp resolve_context(nil, _message), do: []

  defp resolve_context({m, f}, message), do: apply(m, f, [message])

  defp resolve_context({m, f, a}, message), do: apply(m, f, [message | a])

  defp incoming_headers(message), do: Map.get(message, :headers) || []

  ## Reply path

  defp respond(encoder, reply, message, passthrough) do
    binary = encode!(encoder, reply)

    case reply_headers(message, passthrough || []) do
      [] ->
        {:reply, binary}

      headers ->
        case message do
          %{gnat: gnat, reply_to: reply_to} when is_binary(reply_to) ->
            Gnat.pub(gnat, reply_to, binary, headers: headers)
            :ok

          _ ->
            {:reply, binary}
        end
    end
  end

  defp reply_headers(message, passthrough) do
    wanted = Enum.map(passthrough, &String.downcase/1)

    message
    |> incoming_headers()
    |> Enum.filter(fn {key, _value} -> String.downcase(key) in wanted end)
  end

  ## Routing

  defp routes(domains) do
    key = {__MODULE__, domains}

    try do
      :persistent_term.get(key)
    rescue
      ArgumentError ->
        routes = build_routes(domains)
        :persistent_term.put(key, routes)
        routes
    end
  end

  defp build_routes(domains) do
    for domain <- domains,
        resource <- Ash.Domain.Info.resources(domain),
        AshNats.Info.nats?(resource),
        exposure <- AshNats.Info.exposures(resource),
        into: %{} do
      {AshNats.Info.exposure_subject(resource, exposure), {domain, resource, exposure}}
    end
  end

  ## Execution

  defp run(resource, exposure, input, ash_opts) do
    action = Ash.Resource.Info.action(resource, exposure.action)
    execute(action.type, resource, action, exposure, input, ash_opts)
  rescue
    error -> error_reply_from(error)
  end

  defp execute(:read, resource, action, exposure, input, ash_opts) do
    query = Ash.Query.for_read(resource, action.name, input, ash_opts)

    result =
      if exposure.get? do
        Ash.read_one(query)
      else
        Ash.read(query)
      end

    case result do
      {:ok, data} -> ok_reply(AshNats.Serializer.serialize(data))
      {:error, error} -> error_reply_from(error)
    end
  end

  defp execute(:create, resource, action, _exposure, input, ash_opts) do
    resource
    |> Ash.Changeset.for_create(action.name, input, ash_opts)
    |> Ash.create()
    |> case do
      {:ok, record} -> ok_reply(AshNats.Serializer.serialize(record))
      {:error, error} -> error_reply_from(error)
    end
  end

  defp execute(:update, resource, action, _exposure, input, ash_opts) do
    with {:ok, record, rest} <- fetch_record(resource, input, ash_opts) do
      record
      |> Ash.Changeset.for_update(action.name, rest, ash_opts)
      |> Ash.update()
      |> case do
        {:ok, updated} -> ok_reply(AshNats.Serializer.serialize(updated))
        {:error, error} -> error_reply_from(error)
      end
    end
  end

  defp execute(:destroy, resource, action, _exposure, input, ash_opts) do
    with {:ok, record, rest} <- fetch_record(resource, input, ash_opts) do
      record
      |> Ash.Changeset.for_destroy(action.name, rest, ash_opts)
      |> Ash.destroy()
      |> case do
        :ok -> ok_reply(nil)
        {:ok, destroyed} -> ok_reply(AshNats.Serializer.serialize(destroyed))
        {:error, error} -> error_reply_from(error)
      end
    end
  end

  defp execute(:action, resource, action, _exposure, input, ash_opts) do
    resource
    |> Ash.ActionInput.for_action(action.name, input, ash_opts)
    |> Ash.run_action()
    |> case do
      :ok -> ok_reply(nil)
      {:ok, result} -> ok_reply(AshNats.Serializer.serialize(result))
      {:error, error} -> error_reply_from(error)
    end
  end

  defp fetch_record(resource, input, ash_opts) do
    pk_fields = Ash.Resource.Info.primary_key(resource)
    pk_keys = Enum.map(pk_fields, &to_string/1)

    pk =
      Map.new(pk_fields, fn field ->
        {field, Map.get(input, to_string(field))}
      end)

    if Enum.any?(pk, fn {_, v} -> is_nil(v) end) do
      error_reply(
        "missing_primary_key",
        "update/destroy requests must include #{inspect(pk_keys)}"
      )
    else
      case Ash.get(resource, pk, ash_opts) do
        {:ok, record} -> {:ok, record, Map.drop(input, pk_keys)}
        {:error, error} -> error_reply_from(error)
      end
    end
  end

  ## Reply envelopes

  defp ok_reply(data), do: %{"ok" => true, "data" => data}

  defp error_reply(class, message) do
    %{"ok" => false, "error" => %{"class" => class, "message" => message}}
  end

  defp error_reply_from(%{class: class} = error) when is_exception(error) do
    error_reply(to_string(class), Exception.message(error))
  end

  defp error_reply_from(error) when is_exception(error) do
    error_reply("error", Exception.message(error))
  end

  defp error_reply_from(error), do: error_reply("error", inspect(error))

  defp encode!(encoder, reply) do
    case encoder.encode_response(reply) do
      {:ok, binary} ->
        binary

      {:error, reason} ->
        Logger.error("AshNats.Rpc: failed to encode reply: #{inspect(reason)}")
        ~s({"ok":false,"error":{"class":"internal_error","message":"encoding failed"}})
    end
  end
end
