defmodule AllbertAssist.DynamicPlugins.Codegen.Targets.Action do
  @moduledoc """
  Path and source helpers for generated action drafts.

  This module is deterministic. It normalizes names and stamps the reserved
  dynamic namespace onto advisory source before the source enters draft storage.
  """

  @generated_prefix "AllbertAssist.DynamicPlugins.Generated"

  @doc "Return the generated action module for a slug."
  @spec module_name(String.t()) :: String.t()
  def module_name(slug), do: "#{@generated_prefix}.#{Macro.camelize(slug)}.Action"

  @doc "Return the generated action test module for a slug."
  @spec test_module_name(String.t()) :: String.t()
  def test_module_name(slug), do: "#{@generated_prefix}.#{Macro.camelize(slug)}.ActionTest"

  @doc "Normalize a generated action name to the registered action-name shape."
  @spec action_name(String.t(), String.t() | nil) :: String.t()
  def action_name(slug, proposed) do
    proposed
    |> case do
      value when is_binary(value) and value != "" -> value
      _other -> "dynamic_#{slug}"
    end
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
    |> String.trim("_")
    |> ensure_action_prefix(slug)
  end

  @doc "Draft-relative source path."
  @spec source_path() :: String.t()
  def source_path, do: "source/lib/action.ex"

  @doc "Draft-relative test path."
  @spec test_path() :: String.t()
  def test_path, do: "source/test/action_test.exs"

  @doc "Compile-visible generated action path in the staged project."
  @spec compiled_source_path(String.t()) :: String.t()
  def compiled_source_path(slug) do
    "apps/allbert_assist/lib/allbert_assist/dynamic_plugins/generated/#{slug}/action.ex"
  end

  @doc "Compile-visible generated test path in the staged project."
  @spec compiled_test_path(String.t()) :: String.t()
  def compiled_test_path(slug) do
    "apps/allbert_assist/test/allbert_assist/dynamic_plugins/generated/#{slug}/action_test.exs"
  end

  @doc "Replace deterministic placeholders in generated source."
  @spec stamp_source(String.t(), map()) :: String.t()
  def stamp_source(source, replacements) when is_binary(source) and is_map(replacements) do
    Enum.reduce(replacements, source, fn {key, value}, acc ->
      key = to_string(key)
      value = to_string(value)

      acc
      |> String.replace("{{#{key}}}", value)
      |> String.replace("__#{key}__", value)
    end)
  end

  defp ensure_action_prefix("", slug), do: "dynamic_#{slug}"

  defp ensure_action_prefix(<<first::binary-size(1), _rest::binary>> = value, slug)
       when first in ~w[0 1 2 3 4 5 6 7 8 9],
       do: "dynamic_#{slug}_#{value}"

  defp ensure_action_prefix(value, _slug), do: value
end
