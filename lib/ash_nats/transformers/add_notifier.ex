defmodule AshNats.Transformers.AddNotifier do
  @moduledoc """
  Adds `AshNats.Notifier` to the resource's notifiers so users don't have to
  list it manually in `use Ash.Resource, notifiers: [...]`.
  """

  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  @impl true
  def transform(dsl_state) do
    notifiers = Transformer.get_persisted(dsl_state, :notifiers, [])

    if AshNats.Notifier in notifiers do
      {:ok, dsl_state}
    else
      {:ok, Transformer.persist(dsl_state, :notifiers, [AshNats.Notifier | notifiers])}
    end
  end
end
