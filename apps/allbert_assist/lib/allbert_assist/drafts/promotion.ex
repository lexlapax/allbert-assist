defmodule AllbertAssist.Drafts.Promotion do
  @moduledoc """
  Live promotion helpers for reviewed non-code drafts.

  These helpers are called only from registered confirmation-gated actions.
  Draft metadata and YAML never grant authority by themselves.
  """

  alias AllbertAssist.Drafts.Store
  alias AllbertAssist.Memory
  alias AllbertAssist.Memory.Entry
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings.YamlCodec
  alias AllbertAssist.Skills
  alias AllbertAssist.Workflows.Validator

  @type skill_target :: %{
          required(:name) => String.t(),
          required(:path) => String.t(),
          required(:skill_md_path) => String.t()
        }
  @type workflow_target :: %{required(:path) => String.t()}

  @doc "Promote an instruction-only skill draft to the local skills root."
  @spec promote_skill(String.t(), map()) ::
          {:ok,
           %{
             required(:draft) => Store.non_code_draft_summary(),
             required(:skill) => skill_target(),
             required(:result) => skill_target()
           }}
          | {:error, term()}
  def promote_skill(id, context \\ %{}) when is_binary(id) and is_map(context) do
    with {:ok, draft} <- Store.show_draft(id, kind: "skill"),
         :ok <- require_promotable(draft),
         payload <- Map.fetch!(draft, :payload),
         {:ok, skill} <- write_skill(payload, context),
         {:ok, promoted} <-
           Store.promote_draft(id,
             kind: "skill",
             promotion: %{target: "skill", path: skill.skill_md_path, promoted_by: actor(context)}
           ) do
      {:ok, %{draft: promoted, skill: skill, result: skill}}
    end
  end

  @doc "Promote a workflow draft to the live workflows root."
  @spec promote_workflow(String.t(), map()) ::
          {:ok,
           %{
             required(:draft) => map(),
             required(:workflow) => map(),
             required(:path) => String.t(),
             required(:result) => workflow_target()
           }}
          | {:error, term()}
  def promote_workflow(id, context \\ %{}) when is_binary(id) and is_map(context) do
    with {:ok, draft} <- Store.show_draft(id, kind: "workflow"),
         :ok <- require_promotable(draft),
         %{"workflow" => workflow} <- Map.fetch!(draft, :payload),
         {:ok, workflow} <- Validator.validate(workflow),
         {:ok, path} <- write_workflow(workflow),
         {:ok, promoted} <-
           Store.promote_draft(id,
             kind: "workflow",
             promotion: %{target: "workflow", path: path, promoted_by: actor(context)}
           ) do
      {:ok, %{draft: promoted, workflow: workflow, path: path, result: %{path: path}}}
    else
      :error -> {:error, :workflow_payload_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Promote a memory draft by appending or updating through the Memory facade."
  @spec promote_memory(String.t(), map()) ::
          {:ok,
           %{
             required(:draft) => map(),
             required(:memory) => map(),
             required(:result) => map()
           }}
          | {:error, term()}
  def promote_memory(id, context \\ %{}) when is_binary(id) and is_map(context) do
    with {:ok, draft} <- show_memory_draft(id),
         :ok <- require_promotable(draft),
         %{"memory" => memory} <- Map.fetch!(draft, :payload),
         {:ok, entry} <- write_memory(draft.kind, memory, context),
         entry_map <- Entry.to_map(Entry.from_map(entry)),
         {:ok, promoted} <-
           Store.promote_draft(id,
             kind: draft.kind,
             promotion: %{target: "memory", path: entry_map.path, promoted_by: actor(context)}
           ) do
      {:ok, %{draft: promoted, memory: entry_map, result: entry_map}}
    else
      :error -> {:error, :memory_payload_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp show_memory_draft(id) do
    case Store.show_draft(id, kind: "memory_promotion") do
      {:ok, draft} -> {:ok, draft}
      {:error, _reason} -> Store.show_draft(id, kind: "memory_update")
    end
  end

  defp require_promotable(%{tier: "draft", live_authority: false}), do: :ok
  defp require_promotable(%{tier: tier}), do: {:error, {:draft_not_promotable, tier}}
  defp require_promotable(_draft), do: {:error, :invalid_draft}

  defp write_skill(payload, context) do
    name = payload |> Map.get("name", Map.fetch!(payload, "id")) |> Skills.normalize_name()
    root = Path.join(Paths.skills_root(), name)
    skill_md_path = Path.join(root, "SKILL.md")

    if File.exists?(skill_md_path) do
      {:error, {:skill_exists, name}}
    else
      with :ok <- File.mkdir_p(root),
           :ok <- File.write(skill_md_path, skill_markdown(payload, name, context)) do
        {:ok, %{name: name, path: root, skill_md_path: skill_md_path}}
      end
    end
  end

  defp write_workflow(%{"id" => id} = workflow) when is_binary(id) do
    path = Path.join([Paths.home(), "workflows", id <> ".yaml"])

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, YamlCodec.encode!(workflow)) do
      {:ok, path}
    end
  end

  defp write_workflow(_workflow), do: {:error, :workflow_id_required}

  defp write_memory("memory_update", %{"path" => path} = memory, context)
       when is_binary(path) and path != "" do
    Memory.update_entry(path, %{
      summary: Map.get(memory, "summary"),
      body: Map.get(memory, "body"),
      user_id: actor(context)
    })
  end

  defp write_memory(_kind, memory, context) do
    Memory.append(%{
      category: memory_category(Map.get(memory, "category")),
      summary: Map.get(memory, "summary", Map.get(memory, "body", "Self-improvement memory")),
      body: Map.get(memory, "body", Map.get(memory, "summary", "Self-improvement memory")),
      source_signal_id: "self_improvement_draft",
      actor: actor(context),
      agent: inspect(__MODULE__),
      channel:
        context |> Map.get(:channel, Map.get(context, "channel", :confirmation)) |> to_string()
    })
  end

  defp memory_category("preferences"), do: :preferences
  defp memory_category("skills"), do: :skills
  defp memory_category("identity"), do: :identity
  defp memory_category(_category), do: :notes

  defp skill_markdown(payload, name, context) do
    description = Map.get(payload, "description", "Self-improvement skill #{name}.")
    instructions = Map.get(payload, "instructions", description)

    """
    ---
    name: #{name}
    description: #{description}
    compatibility: Allbert v0.47+ operator-confirmed instruction-only local skill.
    metadata:
      allbert.kind: instruction_only
      allbert.version: "0.47.0"
      allbert.source: self_improvement
      allbert.source_suggestion_id: #{Map.get(payload, "source_suggestion_id", "unknown")}
      allbert.promoted_by: #{actor(context)}
    ---

    ## Workflow

    #{instructions}
    """
    |> String.trim()
    |> Kernel.<>("\n")
  end

  defp actor(context) do
    Map.get(context, :operator_id) || Map.get(context, "operator_id") ||
      Map.get(context, :user_id) || Map.get(context, "user_id") ||
      Map.get(context, :actor) || Map.get(context, "actor") || "local"
  end
end
