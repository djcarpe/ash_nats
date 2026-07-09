defmodule AshNats.Exposure do
  @moduledoc """
  Target struct for the `expose` DSL entity — an action served over NATS
  request/reply.
  """

  defstruct [:action, :subject, :endpoint, :__spark_metadata__, get?: false]

  @type t :: %__MODULE__{
          action: atom(),
          subject: String.t() | nil,
          endpoint: String.t() | nil,
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
        a list.
        """
      ]
    ]
  end
end
