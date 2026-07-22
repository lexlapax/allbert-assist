defmodule AllbertAssist.CLI.Tui do
  @moduledoc """
  Release-safe launcher for the mix-free terminal operator console
  (v0.62 M8.7 / ADR 0070). `launch/0` enables the supervised TUI channel child,
  starts the runtime, and blocks on the interactive session until it exits — the
  same behaviour as `mix allbert.tui`, but with no `Mix.*` calls so the packaged
  `allbert tui` can run it (the launcher overlay invokes it in a real TTY).
  """

  alias AllbertAssist.App.Bootstrap, as: AppBootstrap
  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.TUI.Adapter
  alias AllbertAssist.CLI.FirstRun
  alias AllbertAssist.Onboarding
  alias AllbertAssist.Settings.Fragments, as: SettingsFragments

  @supervisor AllbertAssist.Channels.Supervisor

  @doc "Launch the interactive TUI console; blocks until the session exits."
  @spec launch() :: :ok | {:error, term()}
  def launch do
    with :ok <- prepare() do
      case Adapter.run_supervised_forever(@supervisor) do
        :normal -> :ok
        :shutdown -> :ok
        {:shutdown, _reason} -> :ok
        other -> {:error, other}
      end
    end
  end

  @doc false
  def prepare do
    # The release launcher uses `eval`, so the application is loaded but not
    # started. Readiness resolves plugin-owned Settings fragments and therefore
    # must run after the complete registry/bootstrap spine is alive. Starting
    # only :req made host-local Ollama work but discarded a persisted configured
    # endpoint in a fresh process (v1.0.5 RC.2 WSL2 failure).
    ensure_http_started()
    exclude_tui_during_boot!()

    case Application.ensure_all_started(:allbert_assist) do
      {:ok, _started} ->
        prepare_started_runtime()

      {:error, reason} ->
        {:error, {:runtime_start_failed, reason}}
    end
  end

  defp prepare_started_runtime do
    with :ok <- AppBootstrap.await_ready() do
      SettingsFragments.clear_cache()

      with :ok <- readiness_guard(), do: start_supervised_tui_child!()
    end
  end

  @doc false
  @spec ensure_http_started() :: :ok
  def ensure_http_started do
    _ = Application.ensure_all_started(:req)
    :ok
  end

  @doc false
  @spec readiness_guard(keyword()) ::
          :ok | {:error, {:first_run_not_ready, FirstRun.state()}}
  def readiness_guard(opts \\ []) do
    details = FirstRun.detect_details(opts)

    if details.state == :product_ready do
      :ok
    else
      IO.puts(:stderr, guard_message(details))
      {:error, {:first_run_not_ready, details.state}}
    end
  end

  defp guard_message(%{state: :first_model_not_ready, first_model_state: model_state}) do
    readiness = Onboarding.readiness_label(first_model_state: model_state)
    guidance = Onboarding.model_guidance_for(readiness, :quickstart)

    "Allbert TUI is waiting for setup. #{guidance.headline} Run `allbert onboard` or open `/workspace?destination=workspace:models`."
  end

  defp guard_message(%{state: :home_missing}) do
    "Allbert TUI is waiting for setup. Start the packaged service or run `allbert serve --open`, then complete `allbert onboard`."
  end

  defp guard_message(%{state: :schema_incompatible}) do
    "Allbert TUI is waiting for setup. Allbert Home needs upgrade repair before the console can launch."
  end

  defp guard_message(%{state: :profile_unreviewed}) do
    "Allbert TUI is waiting for setup. Review the profile in the web workspace or run `allbert onboard`."
  end

  defp guard_message(%{state: :onboarding_incomplete}) do
    "Allbert TUI is waiting for setup. Complete web onboarding or run `allbert onboard`."
  end

  # The adapter resolves Settings in init. Keep it out of the supervision tree
  # until app/plugin registration and the readiness decision are complete, then
  # add the same transient child used by `mix allbert.tui`.
  defp exclude_tui_during_boot! do
    opts = Application.get_env(:allbert_assist, @supervisor, [])
    excluded = opts |> Keyword.get(:exclude_channels, []) |> List.wrap()

    Application.put_env(
      :allbert_assist,
      @supervisor,
      Keyword.put(opts, :exclude_channels, Enum.uniq(["tui" | excluded]))
    )
  end

  defp start_supervised_tui_child! do
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

    child_opts =
      opts
      |> Keyword.delete(:exclude_channels)
      |> Keyword.put(:channel_child_opts, Map.put(channel_child_opts, "tui", tui_child_opts))

    case Enum.find(Channels.channel_child_specs(child_opts), &(&1.id == "tui")) do
      nil -> {:error, :tui_channel_unavailable}
      child_spec -> normalize_start_child(Supervisor.start_child(@supervisor, child_spec))
    end
  end

  defp normalize_start_child({:ok, _pid}), do: :ok
  defp normalize_start_child({:ok, _pid, _info}), do: :ok
  defp normalize_start_child({:error, {:already_started, _pid}}), do: :ok
  defp normalize_start_child({:error, :already_present}), do: :ok
  defp normalize_start_child({:error, reason}), do: {:error, {:tui_start_failed, reason}}
end
