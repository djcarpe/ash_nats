if Code.ensure_loaded?(Igniter.Mix.Task) do
  defmodule Mix.Tasks.AshNats.Install do
    @moduledoc """
    Installs AshNats: configures the default connection, adds a
    `Gnat.ConnectionSupervisor` to the application supervision tree, and sets
    up the formatter.

        mix igniter.install ash_nats
    """
    @shortdoc "Installs AshNats"

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :ash,
        adds_deps: [{:gnat, "~> 1.8"}],
        example: "mix igniter.install ash_nats"
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      igniter
      |> Igniter.Project.Formatter.import_dep(:ash_nats)
      |> Igniter.Project.Config.configure_new(
        "config.exs",
        :ash_nats,
        [:connection],
        :gnat
      )
      |> Igniter.Project.Application.add_new_child(
        {Gnat.ConnectionSupervisor,
         {:code,
          quote do
            %{
              name: :gnat,
              connection_settings: [%{host: "localhost", port: 4222}]
            }
          end}}
      )
    end
  end
else
  defmodule Mix.Tasks.AshNats.Install do
    @moduledoc "Installs AshNats. Requires igniter to run."
    @shortdoc "Installs AshNats"

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_nats.install' requires igniter. Please install igniter and try again:

          mix archive.install hex igniter_new
          mix igniter.install ash_nats
      """)

      exit({:shutdown, 1})
    end
  end
end
