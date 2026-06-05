defmodule AllbertResearch.Plugin do
  @moduledoc """
  Shipped v0.46 research delegate plugin.

  The plugin contributes Settings Central schema and starts the supervised
  `research.specialist` delegate agent. It registers no new actions and grants
  no browser authority; the agent's commands orchestrate existing actions
  through `AllbertAssist.Actions.Runner.run/3`.
  """

  use AllbertAssist.Plugin

  @impl true
  def plugin_id, do: "allbert.research"

  @impl true
  def display_name, do: "Allbert Research"

  @impl true
  def version, do: "0.46.0"

  @impl true
  def validate(_opts), do: :ok

  @impl true
  def child_spec(_opts), do: AllbertResearch.Supervisor.child_spec([])

  @impl true
  def settings_schema do
    [
      schema("research.enabled", :boolean, false),
      schema("research.schema_version", :positive_integer, 1, writable?: false),
      schema("research.max_sources", :bounded_integer, 3, min: 1, max: 8),
      schema("research.max_extract_bytes_per_source", :bounded_integer, 524_288,
        min: 1_024,
        max: 1_048_576
      ),
      schema("research.summary.engine", :enum, "extractive_fallback",
        writable?: false,
        allowed_values: ["extractive_fallback"]
      )
    ]
  end

  defp schema(key, type, default, opts \\ []) do
    %{
      key: key,
      type: type,
      default: default,
      writable?: Keyword.get(opts, :writable?, true),
      sensitive?: Keyword.get(opts, :sensitive?, false)
    }
    |> maybe_put(:allowed_values, Keyword.get(opts, :allowed_values))
    |> maybe_put(:min, Keyword.get(opts, :min))
    |> maybe_put(:max, Keyword.get(opts, :max))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
