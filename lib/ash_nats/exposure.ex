defmodule AshNats.Exposure do
  @moduledoc """
  Target struct for the `expose` DSL entity — an action served over NATS
  request/reply.
  """

  defstruct [:action, :subject, :endpoint, :identity, :load, :__spark_metadata__, get?: false]

  @type t :: %__MODULE__{
          action: atom(),
          subject: String.t() | nil,
          endpoint: String.t() | nil,
          identity: atom() | nil,
          load: term() | nil,
          get?: boolean()
        }

  def schema do
    [
      action: [
        type: :atom,
        required: true,
        doc: "The action to expose."
      ],
      subject: [
        type: :string,
        doc: """
        Request subject (after the resource's subject_prefix). Defaults to the
        action name.
        """
      ],
      endpoint: [
        type: :string,
        doc: """
        Endpoint name when served as a NATS service (`AshNats.Rpc.Service`).
        Must match `[a-zA-Z0-9_-]+`. Defaults to `<resource>_<action>`.
        """
      ],
      get?: [
        type: :boolean,
        default: false,
        doc: """
        For read actions: reply with a single record (Ash.read_one) instead of
        a list. When the request includes all lookup keys (primary key, or the
        `identity` option), they are applied as a filter.
        """
      ],
      identity: [
        type: :atom,
        doc: """
        Identity used to look up the record (for `get?: true` reads and
        update/destroy exposures) instead of the primary key.
        """
      ],
      load: [
        type: :any,
        doc: """
        An Ash load statement applied to successful results before they are
        serialized into the reply (relationships, calculations, aggregates).
        """
      ]
    ]
  end
end
