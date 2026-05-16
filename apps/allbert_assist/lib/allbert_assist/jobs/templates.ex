defmodule AllbertAssist.Jobs.Templates do
  @moduledoc """
  CLI-instantiated scheduled job templates.

  Templates expand into ordinary `scheduled_jobs` rows. They are not seeded and
  the scheduler does not treat them specially after creation.
  """

  @daily_brief_prompt """
                      Prepare a concise local daily brief from the information Allbert can already inspect safely. Include priorities, known open loops, and concrete next steps. Do not fetch external resources unless a normal approval workflow asks for it.
                      """
                      |> String.trim()

  @templates [
    %{
      name: "daily-brief",
      target_type: "runtime_prompt",
      description: "Side-effect-free runtime prompt for a local daily brief."
    },
    %{
      name: "registry-health",
      target_type: "registered_action",
      description: "Read-only action, skill, and settings registry health."
    },
    %{
      name: "trace-summary",
      target_type: "registered_action",
      description: "Read-only trace file and scheduled job-run summary."
    },
    %{
      name: "memory-index-rebuild",
      target_type: "registered_action",
      description: "Read-only rebuild of the derived markdown memory index."
    }
  ]

  @doc "Return supported CLI templates."
  def templates, do: @templates

  @doc "Expand a template name into job attrs."
  def expand("daily-brief", opts) do
    {:ok,
     %{
       name: Map.get(opts, :name) || "daily-brief",
       description: Map.get(opts, :description) || "Daily brief",
       target_type: "runtime_prompt",
       target: %{text: Map.get(opts, :prompt) || @daily_brief_prompt},
       metadata: %{template_name: "daily-brief"}
     }}
  end

  def expand("registry-health", opts) do
    {:ok,
     %{
       name: Map.get(opts, :name) || "registry-health",
       description: Map.get(opts, :description) || "Registry health",
       target_type: "registered_action",
       target: %{action_name: "registry_health", params: %{}},
       metadata: %{template_name: "registry-health"}
     }}
  end

  def expand("trace-summary", opts) do
    {:ok,
     %{
       name: Map.get(opts, :name) || "trace-summary",
       description: Map.get(opts, :description) || "Trace summary",
       target_type: "registered_action",
       target: %{action_name: "trace_summary", params: %{}},
       metadata: %{template_name: "trace-summary"}
     }}
  end

  def expand("memory-index-rebuild", opts) do
    {:ok,
     %{
       name: Map.get(opts, :name) || "memory-index-rebuild",
       description: Map.get(opts, :description) || "Memory index rebuild",
       target_type: "registered_action",
       target: %{action_name: "compile_memory_index", params: %{}},
       metadata: %{template_name: "memory-index-rebuild"}
     }}
  end

  def expand(template, _opts), do: {:error, {:unknown_template, template}}
end
