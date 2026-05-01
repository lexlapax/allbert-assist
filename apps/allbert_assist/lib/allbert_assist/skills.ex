defmodule AllbertAssist.Skills do
  @moduledoc """
  Readable v0.01 skill declarations exposed to the intent agent.

  These are intentionally small and static until the v0.02 skill registry adds
  file-backed declarations and richer permission metadata.
  """

  @skills [
    %{
      name: "direct_answer",
      title: "Direct Answer",
      description: "Answer plain local-assistant prompts without taking side effects.",
      permission: :read_only,
      status: :available
    },
    %{
      name: "append_memory",
      title: "Append Memory",
      description:
        "Save explicit memory requests and low-risk personal preference heuristics as durable markdown.",
      permission: :memory_write,
      status: :available
    },
    %{
      name: "read_recent_memory",
      title: "Read Recent Memory",
      description: "Read recent markdown-backed memory entries.",
      permission: :read_only,
      status: :available
    },
    %{
      name: "list_skills",
      title: "List Skills",
      description: "List the safe v0.01 capabilities that Allbert can inspect or select.",
      permission: :read_only,
      status: :available
    },
    %{
      name: "read_skill",
      title: "Read Skill",
      description: "Read one static v0.01 skill declaration by name.",
      permission: :read_only,
      status: :available
    },
    %{
      name: "plan_shell_command",
      title: "Plan Shell Command",
      description: "Draft a command plan or safety note without executing any shell command.",
      permission: :command_plan,
      status: :available
    },
    %{
      name: "external_network_request",
      title: "External Network Request",
      description:
        "Recognize external network requests and require confirmation without making a call.",
      permission: :external_network,
      status: :needs_confirmation
    }
  ]

  @doc "Return all v0.01 skill declarations."
  def list, do: @skills

  @doc "Find a skill declaration by name or title."
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(name) when is_binary(name) do
    normalized = normalize_name(name)

    case Enum.find(@skills, &skill_matches?(&1, normalized)) do
      nil -> {:error, :not_found}
      skill -> {:ok, skill}
    end
  end

  def get(_name), do: {:error, :not_found}

  defp skill_matches?(skill, name) do
    skill.name == name || normalize_name(skill.title) == name
  end

  defp normalize_name(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end
end
