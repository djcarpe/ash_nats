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

  alias AshNats.Rpc.ErrorSerializer

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
        metadata = %{resource: resource, action: exposure.action, subject: topic}

        reply =
          :telemetry.span([:ash_nats, :rpc], metadata, fn ->
            reply =
              case encoder.decode_request(body) do
                {:ok, input} ->
                  ash_opts = build_ash_opts(server_opts[:context], message, domain)
                  run(resource, exposure, input, ash_opts)

                {:error, reason} ->
                  ErrorSerializer.protocol_error("invalid_request", inspect(reason))
              end

            {reply, Map.put(metadata, :ok?, match?(%{"ok" => true}, reply))}
          end)

        respond(encoder, reply, message, server_opts[:passthrough_headers])

      :error ->
        respond(
          AshNats.Encoder.Json,
          ErrorSerializer.protocol_error("unknown_subject", topic),
          message,
          []
        )
    end
  end

  def handle_error(%{topic: topic} = message, error) do
    Logger.error("AshNats.Rpc: unhandled error on #{topic}: #{inspect(error)}")

    respond(
      AshNats.Encoder.Json,
      ErrorSerializer.protocol_error("internal_error", "unhandled server error"),
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
        reduce: %{} do
      routes ->
        subject = AshNats.Info.exposure_subject(resource, exposure)

        case routes do
          %{^subject => {_domain, other_resource, other_exposure}} ->
            raise ArgumentError,
                  "NATS subject #{inspect(subject)} is exposed by both " <>
                    "#{inspect(other_resource)} (action #{inspect(other_exposure.action)}) and " <>
                    "#{inspect(resource)} (action #{inspect(exposure.action)}). " <>
                    "Give one of them a distinct `subject:`."

          _ ->
            Map.put(routes, subject, {domain, resource, exposure})
        end
    end
  end

  ## Execution

  defp run(resource, exposure, input, ash_opts) do
    action = Ash.Resource.Info.action(resource, exposure.action)
    execute(action.type, resource, action, exposure, input, ash_opts)
  rescue
    error -> ErrorSerializer.serialize(error)
  end

  defp execute(:read, resource, action, exposure, input, ash_opts) do
    with {:ok, filter, input} <- get_lookup(resource, exposure, input) do
      query =
        resource
        |> Ash.Query.for_read(action.name, input, ash_opts)
        |> Ash.Query.do_filter(filter)

      result =
        if exposure.get? do
          Ash.read_one(query)
        else
          Ash.read(query)
        end

      reply_with(result, exposure, ash_opts)
    end
  end

  defp execute(:create, resource, action, exposure, input, ash_opts) do
    resource
    |> Ash.Changeset.for_create(action.name, input, ash_opts)
    |> Ash.create()
    |> reply_with(exposure, ash_opts)
  end

  defp execute(:update, resource, action, exposure, input, ash_opts) do
    with {:ok, record, rest} <- fetch_record(resource, exposure, input, ash_opts) do
      record
      |> Ash.Changeset.for_update(action.name, rest, ash_opts)
      |> Ash.update()
      |> reply_with(exposure, ash_opts)
    end
  end

  defp execute(:destroy, resource, action, exposure, input, ash_opts) do
    with {:ok, record, rest} <- fetch_record(resource, exposure, input, ash_opts) do
      record
      |> Ash.Changeset.for_destroy(action.name, rest, ash_opts)
      |> Ash.destroy()
      |> case do
        :ok -> ok_reply(nil)
        {:ok, destroyed} -> ok_reply(AshNats.Serializer.serialize(destroyed))
        {:error, error} -> ErrorSerializer.serialize(error)
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
      {:error, error} -> ErrorSerializer.serialize(error)
    end
  end

  defp reply_with({:ok, data}, exposure, ash_opts) do
    case maybe_load(data, exposure, ash_opts) do
      {:ok, data} -> ok_reply(AshNats.Serializer.serialize(data))
      {:error, error} -> ErrorSerializer.serialize(error)
    end
  end

  defp reply_with({:error, error}, _exposure, _ash_opts) do
    ErrorSerializer.serialize(error)
  end

  defp maybe_load(data, %{load: load}, ash_opts) when not is_nil(load) and data != nil do
    Ash.load(data, load, ash_opts)
  end

  defp maybe_load(data, _exposure, _ash_opts), do: {:ok, data}

  ## Record lookup (primary key or identity)

  # For `get?: true` reads: when all lookup keys are present in the input they
  # become a filter and are dropped from the action input; when none are
  # present the input passes through untouched (argument-based get actions).
  defp get_lookup(_resource, %{get?: false}, input), do: {:ok, nil, input}

  defp get_lookup(resource, exposure, input) do
    case split_lookup(resource, exposure, input) do
      {:all, filter, rest} -> {:ok, filter, rest}
      {:none, _keys} -> {:ok, nil, input}
      {:partial, keys} -> missing_lookup_error(keys)
    end
  end

  defp fetch_record(resource, exposure, input, ash_opts) do
    case split_lookup(resource, exposure, input) do
      {:all, lookup, rest} ->
        case Ash.get(resource, lookup, ash_opts) do
          {:ok, record} -> {:ok, record, rest}
          {:error, error} -> ErrorSerializer.serialize(error)
        end

      {_, keys} ->
        missing_lookup_error(keys)
    end
  end

  defp split_lookup(resource, exposure, input) do
    fields = lookup_fields(resource, exposure)
    keys = Enum.map(fields, &to_string/1)
    present = Enum.count(keys, &Map.has_key?(input, &1))

    cond do
      present == 0 ->
        {:none, keys}

      present == length(keys) ->
        lookup = Map.new(fields, fn field -> {field, Map.get(input, to_string(field))} end)
        {:all, lookup, Map.drop(input, keys)}

      true ->
        {:partial, keys}
    end
  end

  defp lookup_fields(resource, %{identity: nil}), do: Ash.Resource.Info.primary_key(resource)

  defp lookup_fields(resource, %{identity: identity}) do
    Ash.Resource.Info.identity(resource, identity).keys
  end

  defp missing_lookup_error(keys) do
    ErrorSerializer.protocol_error(
      "missing_lookup",
      "request must include all of #{inspect(keys)} to identify the record"
    )
  end

  ## Reply envelopes

  defp ok_reply(data), do: %{"ok" => true, "data" => data}

  defp encode!(encoder, reply) do
    case encoder.encode_response(reply) do
      {:ok, binary} ->
        binary

      {:error, reason} ->
        Logger.error("AshNats.Rpc: failed to encode reply: #{inspect(reason)}")

        ~s({"ok":false,"error":{"class":"internal_error","message":"encoding failed","errors":[]}})
    end
  end
end
