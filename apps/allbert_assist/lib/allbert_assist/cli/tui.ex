defmodule AllbertAssist.CLI.Tui do
  @moduledoc """
  Release-safe launcher for the mix-free terminal operator console
  (v0.62 M8.7 / ADR 0070). `launch/0` enables the supervised TUI channel child,
  starts the runtime, and blocks on the interactive session until it exits — the
  same behaviour as `mix allbert.tui`, but with no `Mix.*` calls so the packaged
  `allbert tui` can run it (the launcher overlay invokes it in a real TTY).
  """

  alias AllbertAssist.Channels.TUI.Adapter
  alias AllbertAssist.CLI.FirstRun
  alias AllbertAssist.Onboarding

  @supervisor AllbertAssist.Channels.Supervisor

  @doc "Launch the interactive TUI console; blocks until the session exits."
  @spec launch() :: :ok | {:error, term()}
  def launch do
    # v1.0.1 M4.1(A): the dispatcher evals this under `release eval` where OTP
    # apps are LOADED but not STARTED, and `readiness_guard/0` reaches the Ollama
    # first-model probe (Req → Req.FinchSupervisor). Every other CLI verb gets
    # `:req` from `CLI.run_entry/1` (v0.63 M8.1); `tui` bypasses that entry
    # point, so start the HTTP client here too — idempotent, HTTP-only.
    ensure_http_started()

    with :ok <- readiness_guard() do
      enable_supervised_tui_child!()
      {:ok, _started} = Application.ensure_all_started(:allbert_assist)

      case Adapter.run_supervised_forever(@supervisor) do
        :normal -> :ok
        :shutdown -> :ok
        {:shutdown, _reason} -> :ok
        other -> {:error, other}
      end
    end
  end

  @doc false
  @spec ensure_http_started() :: :ok
  def ensure_http_started do
    _ = Application.ensure_all_started(:req)
    :ok
  end

  @doc false
  @spec readiness_guard() :: :ok | {:error, {:first_run_not_ready, FirstRun.state()}}
  def readiness_guard do
    details = FirstRun.detect_details()

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
