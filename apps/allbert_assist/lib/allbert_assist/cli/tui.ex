defmodule AllbertAssist.CLI.Tui do
  @moduledoc """
  Release-safe launcher for the mix-free terminal operator console
  (v0.62 M8.7 / ADR 0070). `launch/0` enables the supervised TUI channel child,
  starts the runtime, and blocks on the interactive session until it exits — the
  same behaviour as `mix allbert.tui`, but with no `Mix.*` calls so the packaged
  `allbert tui` can run it (the launcher overlay invokes it in a real TTY).
  """

  alias AllbertAssist.Channels.TUI.Adapter

  @supervisor AllbertAssist.Channels.Supervisor

  @doc "Launch the interactive TUI console; blocks until the session exits."
  @spec launch() :: :ok | {:error, term()}
  def launch do
    enable_supervised_tui_child!()
    {:ok, _started} = Application.ensure_all_started(:allbert_assist)

    case Adapter.run_supervised_forever(@supervisor) do
      :normal -> :ok
      :shutdown -> :ok
      {:shutdown, _reason} -> :ok
      other -> {:error, other}
    end
  end

  # Mutates the Channels.Supervisor config to enable the TUI child before the
  # supervisor starts (mirrors mix allbert.tui). Release-safe: Application env
  # only, no Mix.
  defp enable_supervised_tui_child! do
    opts = Application.get_env(:allbert_assist, @supervisor, [])

    channel_child_opts =
      case Keyword.get(opts, :channel_child_opts, %{}) do
        map when is_map(map) -> map
        _other -> %{}
      end

    existing = Map.get(channel_child_opts, "tui", []) || []

    tui_child_opts =
      Keyword.merge(existing,
        enabled?: true,
        auto_input?: true,
        input_driver?: true,
        escape_monitor?: false,
        emit_banner?: true,
        live_screen?: false,
        restart: :transient
      )

    Application.put_env(
      :allbert_assist,
      @supervisor,
      Keyword.put(opts, :channel_child_opts, Map.put(channel_child_opts, "tui", tui_child_opts))
    )
  end
end
