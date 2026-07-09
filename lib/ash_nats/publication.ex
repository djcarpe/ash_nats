defmodule AshNats.Publication do
  @moduledoc """
  Target struct for the `publish` and `publish_all` DSL entities.
  """

  defstruct [:action, :subject, :event, :msg_id, :__spark_metadata__, mode: :core, headers: []]

  @type t :: %__MODULE__{
          action: atom(),
          subject: String.t() | [String.t() | atom()],
          event: String.t() | nil,
          msg_id: [String.t() | atom()] | mfa() | (Ash.Notifier.Notification.t() -> String.t()) | nil,
          mode: :core | :jetstream,
          headers: list() | mfa() | (Ash.Notifier.Notification.t() -> list())
        }

  def schema do
    [
      action: [
        type: :atom,
        required: true,
        doc: """
        Action name, or an action type (:create, :update, :destroy) to match
        every action of that type.
        """
      ],
      subject: [
        type: {:or, [:string, {:list, {:or, [:string, :atom]}}]},
        required: true,
        doc: """
        Subject to publish to. A string is used verbatim (after the resource's
        subject_prefix). A list of segments is joined with dots; atom segments
        are resolved from the record's fields at publish time.
        """
      ],
      mode: [
        type: {:in, [:core, :jetstream]},
        default: :core,
        doc: """
        :core fires Gnat.pub/4 (fire-and-forget). :jetstream uses Gnat.request/4
        and inspects the PubAck, logging an error on timeout or stream rejection.
        """
      ],
      headers: [
        type: {:or, [{:list, :any}, {:mfa_or_fun, 1}]},
        default: [],
        doc: """
        NATS headers as `{\"key\", \"value\"}` tuples, or a 1-arity function /
        `{m, f, args}` receiving the `Ash.Notifier.Notification` and returning
        such a list — use this for per-message values (trace context, tenant,
        actor id from `notification.changeset.context`, etc.).
        """
      ],
      msg_id: [
        type: {:or, [{:list, {:or, [:string, :atom]}}, {:mfa_or_fun, 1}]},
        doc: """
        Sets a `Nats-Msg-Id` header for JetStream deduplication. Either a
        segment list resolved from the record (like subjects, e.g.
        `[:id, \"shipped\"]`) or a function/MFA receiving the notification and
        returning a string. Only meaningful within the stream's dedup window.
        """
      ],
      event: [
        type: :string,
        doc: """
        Event name placed in the payload envelope. Defaults to
        \"<resource_short_name>.<action_name>\".
        """
      ]
    ]
  end
end
