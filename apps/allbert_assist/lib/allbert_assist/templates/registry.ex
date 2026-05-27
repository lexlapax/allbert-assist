defmodule AllbertAssist.Templates.Registry do
  @moduledoc """
  Reviewed v0.38 template-pattern registry.

  The registry lists vetted pattern modules only. Pattern metadata is
  descriptive and never grants runtime authority.
  """

  alias AllbertAssist.Templates.Patterns.App
  alias AllbertAssist.Templates.Patterns.Plugin

  @default_patterns [Plugin, App]

  @doc "Return registered pattern modules."
  @spec modules(keyword()) :: [module()]
  def modules(opts \\ []) do
    opts
    |> Keyword.get(:patterns, configured_patterns())
    |> Enum.filter(&valid_pattern?/1)
  end

  @doc "Return operator/developer-facing pattern summaries."
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    opts
    |> modules()
    |> Enum.map(&summary/1)
    |> Enum.sort_by(& &1.id)
  end

  @doc "Resolve one pattern by id."
  @spec resolve(String.t() | atom(), keyword()) :: {:ok, module()} | {:error, term()}
  def resolve(id, opts \\ []) do
    normalized = normalize_id(id)

    case Enum.find(modules(opts), &(normalize_id(&1.id()) == normalized)) do
      nil -> {:error, {:unknown_template_pattern, id}}
      module -> {:ok, module}
    end
  end

  @doc "Return a bounded summary for one pattern module."
  @spec summary(atom()) :: %{
          id: term(),
          label: term(),
          description: term(),
          target_shapes: term(),
          live_integration?: term(),
          validation_profile: term(),
          parameters: term()
        }
  def summary(module) do
    %{
      id: module.id(),
      label: module.label(),
      description: module.description(),
      target_shapes: module.target_shapes(),
      live_integration?: module.live_integration?(),
      validation_profile: validation_profile(module),
      parameters: module.parameter_schema()
    }
  end

  defp configured_patterns do
    :allbert_assist
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:patterns, @default_patterns)
  end

  defp valid_pattern?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and
      Enum.all?(
        [
          :id,
          :label,
          :description,
          :parameter_schema,
          :files,
          :target_shapes,
          :live_integration?
        ],
        &function_exported?(module, &1, 0)
      )
  end

  defp valid_pattern?(_module), do: false

  defp validation_profile(module) do
    if function_exported?(module, :validation_profile, 0), do: module.validation_profile()
  end

  defp normalize_id(id) do
    id
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
    |> String.trim("_")
  end
end
