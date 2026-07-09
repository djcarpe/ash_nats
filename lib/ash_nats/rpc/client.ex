defmodule AshNats.Rpc.Client do
  @moduledoc """
  Convenience client for calling exposed actions: encodes the input, attaches
  headers, and unwraps the reply envelope.

      AshNats.Rpc.Client.request(:gnat, "myapp.shipping.shipments.create",
        %{"order_id" => id},
        headers: [
          {"authorization", "Bearer " <> token},
          {"x-request-id", request_id}
        ]
      )
      #=> {:ok, %{"id" => ...}, reply_headers}
  """

  @default_timeout 5_000

  @spec request(atom() | pid(), String.t(), map(), keyword()) ::
          {:ok, term(), list()} | {:error, term()}
  def request(conn, subject, input \\ %{}, opts \\ []) do
    headers = Keyword.get(opts, :headers, [])
    timeout = Keyword.get(opts, :receive_timeout, @default_timeout)

    req_opts = [receive_timeout: timeout]
    req_opts = if headers == [], do: req_opts, else: Keyword.put(req_opts, :headers, headers)

    with {:ok, body} <- Jason.encode(input),
         {:ok, %{body: reply} = msg} <- Gnat.request(conn, subject, body, req_opts),
         {:ok, decoded} <- Jason.decode(reply) do
      reply_headers = Map.get(msg, :headers) || []

      case decoded do
        %{"ok" => true, "data" => data} -> {:ok, data, reply_headers}
        %{"ok" => false, "error" => error} -> {:error, error}
        other -> {:error, {:unexpected_reply, other}}
      end
    end
  end
end
