defmodule AllbertAssist.Coding.Config do
  @moduledoc """
  Settings-backed defaults for the v0.57 coding tool substrate.
  """

  alias AllbertAssist.Settings

  @defaults %{
    cwd_jail: ".",
    read_default_limit: 2_000,
    read_max_bytes: 120_000,
    search_max_results: 100,
    search_max_output_bytes: 120_000,
    search_respect_gitignore?: true,
    search_respect_allbertignore?: true,
    write_max_bytes: 120_000,
    edit_max_replacements: 1,
    bash_timeout_ms: 120_000,
    bash_max_output_bytes: 120_000,
    bash_allow_raw_shell?: false,
    streaming_enabled?: true,
    streaming_turn_complete_fallback?: true,
    turn_supervised?: true,
    turn_max_ms: 120_000,
    steer_enabled?: true,
    cancel_grace_ms: 2_000
  }

  @doc "Return the configured cwd jail root, before path expansion."
  @spec cwd_jail(map()) :: String.t()
  def cwd_jail(context \\ %{}) do
    context_value(context, :cwd_jail) ||
      context_value(context, :workspace_root) ||
      setting("coding.workspace.cwd_jail", @defaults.cwd_jail)
  end

  @doc "Return the default line limit for chunked reads."
  @spec read_default_limit() :: pos_integer()
  def read_default_limit,
    do: positive_integer("coding.read.default_limit", @defaults.read_default_limit)

  @doc "Return the maximum bytes a read action may return."
  @spec read_max_bytes() :: pos_integer()
  def read_max_bytes, do: positive_integer("coding.read.max_bytes", @defaults.read_max_bytes)

  @doc "Return the maximum grep/glob result count."
  @spec search_max_results() :: pos_integer()
  def search_max_results,
    do: positive_integer("coding.search.max_results", @defaults.search_max_results)

  @doc "Return the maximum grep/glob rendered output bytes."
  @spec search_max_output_bytes() :: pos_integer()
  def search_max_output_bytes,
    do: positive_integer("coding.search.max_output_bytes", @defaults.search_max_output_bytes)

  @doc "Return true when `.gitignore` should be honored."
  @spec respect_gitignore?() :: boolean()
  def respect_gitignore?,
    do: boolean("coding.search.respect_gitignore", @defaults.search_respect_gitignore?)

  @doc "Return true when `.allbertignore` should be honored."
  @spec respect_allbertignore?() :: boolean()
  def respect_allbertignore?,
    do: boolean("coding.search.respect_allbertignore", @defaults.search_respect_allbertignore?)

  @doc "Return the maximum bytes a single write/edit may persist."
  @spec write_max_bytes() :: pos_integer()
  def write_max_bytes, do: positive_integer("coding.write.max_bytes", @defaults.write_max_bytes)

  @doc "Return the maximum exact-match replacements for one edit call."
  @spec edit_max_replacements() :: pos_integer()
  def edit_max_replacements,
    do: positive_integer("coding.edit.max_replacements", @defaults.edit_max_replacements)

  @doc "Return the maximum wall-clock time for a bash action."
  @spec bash_timeout_ms() :: pos_integer()
  def bash_timeout_ms, do: positive_integer("coding.bash.timeout_ms", @defaults.bash_timeout_ms)

  @doc "Return the maximum bytes a bash action may return."
  @spec bash_max_output_bytes() :: pos_integer()
  def bash_max_output_bytes,
    do: positive_integer("coding.bash.max_output_bytes", @defaults.bash_max_output_bytes)

  @doc "Return true when raw shell strings may be considered at the local-coding tier."
  @spec bash_allow_raw_shell?() :: boolean()
  def bash_allow_raw_shell?,
    do: boolean("coding.bash.allow_raw_shell", @defaults.bash_allow_raw_shell?)

  @doc "Return true when coding stream-event live rendering is enabled."
  @spec streaming_enabled?() :: boolean()
  def streaming_enabled?, do: boolean("coding.streaming.enabled", @defaults.streaming_enabled?)

  @doc "Return true when streaming renderers should fall back to final split payloads."
  @spec streaming_turn_complete_fallback?() :: boolean()
  def streaming_turn_complete_fallback?,
    do:
      boolean(
        "coding.streaming.turn_complete_fallback",
        @defaults.streaming_turn_complete_fallback?
      )

  @doc "Return true when coding turns should run under the M5 supervised boundary."
  @spec turn_supervised?() :: boolean()
  def turn_supervised?, do: boolean("coding.turn.supervised", @defaults.turn_supervised?)

  @doc "Return the hard wall-clock ceiling for a supervised coding turn."
  @spec turn_max_ms() :: pos_integer()
  def turn_max_ms, do: positive_integer("coding.turn.max_ms", @defaults.turn_max_ms)

  @doc "Return true when coding turns can be cancelled or steered from the TUI."
  @spec steer_enabled?() :: boolean()
  def steer_enabled?, do: boolean("coding.steer.enabled", @defaults.steer_enabled?)

  @doc "Return the grace window before cancellation falls back to hard shutdown."
  @spec cancel_grace_ms() :: pos_integer()
  def cancel_grace_ms, do: positive_integer("coding.cancel.grace_ms", @defaults.cancel_grace_ms)

  defp positive_integer(key, default) do
    case setting(key, default) do
      value when is_integer(value) and value > 0 -> value
      _other -> default
    end
  end

  defp boolean(key, default) do
    case setting(key, default) do
      value when is_boolean(value) -> value
      _other -> default
    end
  end

  defp setting(key, default) do
    case Settings.get(key) do
      {:ok, value} -> value
      {:error, _reason} -> default
    end
  rescue
    _exception -> default
  end

  defp context_value(context, key) when is_map(context) do
    field(context, key) ||
      get_in(context, [:coding, key]) ||
      get_in(context, ["coding", Atom.to_string(key)])
  end

  defp context_value(_context, _key), do: nil

  defp field(map, key) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
      true -> nil
    end
  end
end
