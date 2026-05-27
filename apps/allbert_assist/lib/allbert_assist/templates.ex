defmodule AllbertAssist.Templates do
  @moduledoc """
  Public facade for v0.38 templated creation.

  Developer scaffolds and operator create flows should enter through this
  facade, then route effectful writes or live integration through registered
  actions. Rendering vetted templates is deterministic and grants no authority.
  """

  alias AllbertAssist.Templates.Registry
  alias AllbertAssist.Templates.Renderer

  @doc "List reviewed template patterns."
  @spec list_patterns(keyword()) :: [map()]
  defdelegate list_patterns(opts \\ []), to: Registry, as: :list

  @doc "Resolve a reviewed template pattern by id."
  @spec resolve_pattern(String.t() | atom(), keyword()) ::
          {:ok, atom()} | {:error, {:unknown_template_pattern, term()}}
  defdelegate resolve_pattern(id, opts \\ []), to: Registry, as: :resolve

  @doc "Render a reviewed template pattern into an ordered file preview."
  @spec render(String.t() | atom(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def render(pattern_id, params, opts \\ [])

  def render(pattern_id, params, opts) when is_map(params) do
    with {:ok, pattern} <- Registry.resolve(pattern_id, opts) do
      Renderer.render(pattern, params, opts)
    end
  end

  def render(_pattern_id, _params, _opts), do: {:error, :invalid_render_input}

  @doc "Return rendered file paths and sizes without writing anything."
  @spec preview(String.t() | atom(), map(), keyword()) ::
          {:ok,
           %{
             pattern_id: term(),
             params: term(),
             live_integration?: term(),
             target_shapes: term(),
             files: [map()]
           }}
          | {:error, term()}
  def preview(pattern_id, params, opts \\ []) do
    with {:ok, rendered} <- render(pattern_id, params, opts) do
      {:ok,
       %{
         pattern_id: rendered.pattern_id,
         params: rendered.params,
         live_integration?: rendered.live_integration?,
         target_shapes: rendered.target_shapes,
         files: Enum.map(rendered.files, &Map.take(&1, [:path, :bytes]))
       }}
    end
  end
end
