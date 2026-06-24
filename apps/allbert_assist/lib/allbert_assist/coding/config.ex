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
    search_respect_allbertignore?: true
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
