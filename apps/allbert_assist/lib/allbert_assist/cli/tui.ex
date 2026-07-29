defmodule AllbertAssist.CLI.Tui do
  @moduledoc """
  Mix-free entrypoint for the daemon-backed terminal client (v1.2.1 M0.b3).

  The terminal process owns only TTY input, bounded rendering, and the local
  Attach socket. It never starts the Allbert application, Repo, an Adapter, or
  any embedded writer. Runtime work remains in the already-running daemon.
  """

  alias AllbertAssist.CLI.FirstRun
  alias AllbertAssist.CLI.Tui.Client
  alias AllbertAssist.Onboarding
  alias AllbertAssist.Security.Redactor

  @log_level_help "debug, info, warning, error, or none"
  @silent_log_level :emergency

  @doc "Attach the interactive terminal client to the running daemon."
  @spec launch() :: :ok | {:error, term()}
  def launch do
    with :ok <- configure_operator_logging() do
      Client.run()
    end
  end

  @doc false
  @spec launch(keyword()) :: :ok | {:error, term()}
  def launch(opts) when is_list(opts), do: Client.run(opts)

  @doc false
  @spec configure_operator_logging() :: :ok | {:error, {:invalid_tui_log_level, String.t()}}
  def configure_operator_logging do
    with {:ok, level} <- operator_log_level() do
      Application.put_env(:logger, :level, level)
      Logger.configure(level: level)
      _result = :logger.set_primary_config(:level, level)
      :ok
    end
  end

  @doc false
  @spec launch!((-> :ok | {:error, term()})) :: :ok
  def launch!(launch_fun \\ &launch/0) when is_function(launch_fun, 0) do
    case launch_fun.() do
      :ok ->
        :ok

      {:error, reason} ->
        raise error_message(reason)

      other ->
        raise error_message({:unexpected_client_result, other})
    end
  end

  @doc false
  @spec error_message(term()) :: String.t()
  def error_message(:not_available) do
    "No Allbert daemon is available for this Home. Start or repair `allbert serve`; " <>
      "the TUI did not start an embedded runtime."
  end

  def error_message({:open_rejected, :already_attached, _message}) do
    "A TUI session is already attached to this Allbert Home. Close it before attaching another."
  end

  def error_message({:open_rejected, :identity_denied, message}) do
    "The daemon denied this TUI identity. #{bounded(Redactor.redact(message))} " <>
      "Review `channels.tui.enabled`, `channels.tui.profile`, and `channels.tui.identity_map`."
  end

  def error_message({:open_rejected, code, message})
      when code in [:invalid_open, :unsupported_kind, :version_mismatch, :protocol_mismatch] do
    "The TUI client and daemon do not share a usable session protocol (#{code}): " <>
      "#{bounded(Redactor.redact(message))} Use the client from the same Allbert install, " <>
      "then restart or upgrade the daemon."
  end

  def error_message({:open_rejected, code, message})
      when code in [:token_mismatch, :home_mismatch, :uid_mismatch] do
    "The daemon rejected the local attachment identity (#{code}): " <>
      "#{bounded(Redactor.redact(message))} Confirm the client and daemon use the same " <>
      "Allbert Home and operator account, then restart the service."
  end

  def error_message({:open_rejected, :capacity, message}) do
    "The daemon's bounded attachment handshake capacity is busy: " <>
      "#{bounded(Redactor.redact(message))} Retry after current attachment attempts finish."
  end

  def error_message({:open_rejected, :runtime_unavailable, message}) do
    "The daemon could not open the TUI runtime session: " <>
      "#{bounded(Redactor.redact(message))} Check `allbert admin service status` and daemon logs."
  end

  def error_message({:open_rejected, code, message}) do
    "The daemon rejected the TUI session (#{code}): #{bounded(Redactor.redact(message))}"
  end

  def error_message(:no_tty), do: "The TUI requires an interactive terminal."

  def error_message({:ambiguous_close, reason, pending}) do
    "The daemon connection closed with #{pending} input receipt(s) still unresolved " <>
      "(#{bounded(inspect(Redactor.redact(reason)))}). No input was automatically re-executed."
  end

  def error_message({:daemon_closed, code, message}) do
    "The daemon closed the TUI session (#{code}): #{bounded(Redactor.redact(message))}"
  end

  def error_message({:invalid_tui_log_level, value}) do
    "ALLBERT_TUI_LOG_LEVEL=#{inspect(bounded(value))} is invalid; use #{@log_level_help}"
  end

  def error_message(reason) do
    "TUI client could not continue: #{bounded(inspect(Redactor.redact(reason)))}"
  end

  # Retained as a compatibility seam for callers that used the old readiness
  # guard. Readiness now belongs to the daemon and never gates client attach.
  @doc false
  def readiness_guard(_opts \\ []), do: :ok

  # The daemon-owned Adapter retains this bounded first-run banner helper. It
  # is never called by the terminal client and grants no client-side Settings
  # or runtime access.
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
    "Allbert Home is not initialized. Start the packaged service or run `allbert serve --open`; " <>
      "the TUI is not gated by onboarding."
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

  defp operator_log_level do
    case System.get_env("ALLBERT_TUI_LOG_LEVEL", "warning")
         |> String.trim()
         |> String.downcase() do
      "debug" -> {:ok, :debug}
      "info" -> {:ok, :info}
      "warning" -> {:ok, :warning}
      "warn" -> {:ok, :warning}
      "error" -> {:ok, :error}
      "none" -> {:ok, @silent_log_level}
      "" -> {:ok, :warning}
      other -> {:error, {:invalid_tui_log_level, other}}
    end
  end

  defp bounded(value) when is_binary(value) do
    value
    |> String.replace(~r/[\r\n]+/u, " ")
    |> terminal_text()
    |> String.slice(0, 1_024)
  rescue
    _error -> inspect(value, printable_limit: 1_024)
  end

  defp bounded(value), do: value |> inspect() |> bounded()

  defp terminal_text(value) do
    value
    |> String.to_charlist()
    |> Enum.map(fn codepoint ->
      if codepoint in 0..31 or codepoint in 127..159, do: 0xFFFD, else: codepoint
    end)
    |> List.to_string()
  rescue
    _error -> inspect(value, printable_limit: 1_024)
  end
end
