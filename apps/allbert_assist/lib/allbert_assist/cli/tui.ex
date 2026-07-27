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
  alias AllbertAssist.Channels.TUI.IdentityBootstrap
  alias AllbertAssist.CLI.FirstRun
  alias AllbertAssist.Onboarding
  alias AllbertAssist.Security.Redactor
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
  @spec launch!((-> :ok | {:error, term()})) :: :ok
  def launch!(launch_fun \\ &launch/0) when is_function(launch_fun, 0) do
    case launch_fun.() do
      :ok ->
        :ok

      {:error, reason} ->
        raise "TUI runtime could not start: #{inspect(Redactor.redact(reason))}"

      other ->
        raise "TUI runtime could not start: #{inspect(Redactor.redact(other))}"
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
    original_supervisor_config = Application.fetch_env(:allbert_assist, @supervisor)
    exclude_tui_during_boot!()

    try do
      case Application.ensure_all_started(:allbert_assist) do
        {:ok, _started} ->
          prepare_started_runtime()

        {:error, reason} ->
          {:error, {:runtime_start_failed, reason}}
      end
    after
      restore_supervisor_config(original_supervisor_config)
    end
  end

  defp prepare_started_runtime do
    with :ok <- AppBootstrap.await_ready() do
      SettingsFragments.clear_cache()

      with {:ok, bootstrap} <- bootstrap_local_launch(effective_profile()),
           :ok <- require_enabled_launch(bootstrap),
           :ok <- readiness_guard(),
           do: start_supervised_tui_child!()
    end
  end

  @doc false
  @spec bootstrap_local_launch(String.t()) :: {:ok, map()} | {:error, term()}
  def bootstrap_local_launch(profile \\ effective_profile()),
    do: IdentityBootstrap.prepare_local_launch(profile)

  @doc false
  @spec effective_profile() :: String.t()
  def effective_profile do
    opts = supervisor_config()

    child_profile =
      opts
      |> Keyword.get(:channel_child_opts, %{})
      |> child_opts_for_tui()
      |> Keyword.get(:profile)

    settings_profile =
      case Channels.channel_settings("tui") do
        {:ok, settings} -> Map.get(settings, "profile", "default")
        {:error, _reason} -> "default"
      end

    normalize_profile(child_profile || settings_profile)
  end

  @doc false
  @spec ensure_http_started() :: :ok
  def ensure_http_started do
    _ = Application.ensure_all_started(:req)
    :ok
  end

  @doc false
  @spec readiness_guard(keyword()) :: :ok
  def readiness_guard(_opts \\ []), do: :ok

  @doc false
  @spec startup_guidance(keyword()) :: String.t() | nil
  def startup_guidance(opts \\ []) do
    case FirstRun.detect_details(opts) do
      %{state: :product_ready} -> nil
      details -> guard_message(details)
    end
  end

  defp guard_message(%{state: :first_model_not_ready, first_model_state: model_state}) do
    readiness = Onboarding.readiness_label(first_model_state: model_state)
    guidance = Onboarding.model_guidance_for(readiness, :quickstart)

    "#{guidance.headline} Open Models or run `allbert onboard`; chat remains available with the bounded fallback."
  end

  defp guard_message(%{state: :home_missing}) do
    "Allbert Home is not initialized. Start the packaged service or run `allbert serve --open`; the TUI is not gated by onboarding."
  end

  defp guard_message(%{state: :schema_incompatible}) do
    "Allbert Home needs upgrade repair. Chat stays open, but durable features may be unavailable."
  end

  defp guard_message(%{state: :profile_unreviewed}) do
    "Profile review is optional. Use `allbert onboard` to customize it; chat remains available."
  end

  defp guard_message(%{state: :onboarding_incomplete}) do
    "Onboarding is optional. Run `allbert onboard` to customize Allbert; chat remains available."
  end

  defp require_enabled_launch(%{disposition: :explicitly_disabled}) do
    {:error,
     {:tui_explicitly_disabled,
      "Re-enable with `allbert admin settings set channels.tui.enabled true` " <>
        "or `mix allbert.settings set channels.tui.enabled true`."}}
  end

  defp require_enabled_launch(_bootstrap), do: :ok

  # The adapter resolves Settings in init. Keep it out of the supervision tree
  # until app/plugin registration and the readiness decision are complete, then
  # add the same transient child used by `mix allbert.tui`.
  defp exclude_tui_during_boot! do
    opts = supervisor_config()
    excluded = opts |> Keyword.get(:exclude_channels, []) |> List.wrap()

    Application.put_env(
      :allbert_assist,
      @supervisor,
      Keyword.put(opts, :exclude_channels, Enum.uniq(["tui" | excluded]))
    )
  end

  defp restore_supervisor_config({:ok, opts}),
    do: Application.put_env(:allbert_assist, @supervisor, opts)

  defp restore_supervisor_config(:error),
    do: Application.delete_env(:allbert_assist, @supervisor)

  defp start_supervised_tui_child! do
    opts = supervisor_config()

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

  defp supervisor_config do
    case Application.get_env(:allbert_assist, @supervisor, []) do
      opts when is_list(opts) -> opts
      _other -> []
    end
  end

  defp child_opts_for_tui(child_opts) when is_map(child_opts) do
    case Map.get(child_opts, "tui", []) do
      opts when is_list(opts) -> opts
      _other -> []
    end
  end

  defp child_opts_for_tui(_other), do: []

  defp normalize_profile(profile) do
    profile
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "default"
      normalized -> normalized
    end
  end
end
