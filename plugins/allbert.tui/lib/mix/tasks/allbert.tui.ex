defmodule Mix.Tasks.Allbert.Tui do
  @moduledoc """
  Run the local Allbert terminal TUI channel.

  ## Usage

      mix allbert.tui
  """

  use Mix.Task

  alias AllbertAssist.Channels.TUI.Adapter

  @shortdoc "Run the local Allbert terminal TUI"
  @supervisor AllbertAssist.Channels.Supervisor

  @impl true
  def run(args) do
    case args do
      [] ->
        enable_supervised_tui_child!()
        Mix.Task.run("app.start")
        wait_for_tui_exit!()
        :ok

      _args ->
        Mix.raise("Usage: mix allbert.tui")
    end
  end

  defp enable_supervised_tui_child! do
    opts = Application.get_env(:allbert_assist, @supervisor, [])
    channel_child_opts = opts |> Keyword.get(:channel_child_opts, %{}) |> normalize_child_opts()

    existing_tui_child_opts = Map.get(channel_child_opts, "tui", []) || []

    tui_child_opts =
      Keyword.merge(
        existing_tui_child_opts,
        enabled?: true,
        auto_input?: true,
        emit_banner?: true,
        live_screen?: true,
        restart: :transient
      )

    Application.put_env(
      :allbert_assist,
      @supervisor,
      opts
      |> Keyword.put(:channel_child_opts, Map.put(channel_child_opts, "tui", tui_child_opts))
    )
  end

  defp normalize_child_opts(opts) when is_map(opts), do: opts
  defp normalize_child_opts(_opts), do: %{}

  defp wait_for_tui_exit! do
    case Adapter.run_supervised_forever(@supervisor) do
      :normal -> :ok
      :shutdown -> :ok
      {:shutdown, _reason} -> :ok
      {:error, reason} -> Mix.raise("TUI channel is not running: #{inspect(reason)}")
      reason -> Mix.raise("TUI channel exited unexpectedly: #{inspect(reason)}")
    end
  end
end
