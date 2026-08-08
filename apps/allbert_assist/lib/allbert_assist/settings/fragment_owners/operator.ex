defmodule AllbertAssist.Settings.FragmentOwners.Operator do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "operator.communication_style" => %{
      allowed_values: ["concise", "balanced", "detailed"],
      default: "concise",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "operator.display_name" => %{
      default: "local",
      sensitive?: false,
      type: :string,
      writable?: true
    },
    "operator.handoff_detail" => %{
      allowed_values: ["brief", "concrete_next_steps", "full_context"],
      default: "concrete_next_steps",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "operator.timezone" => %{
      default: "America/Los_Angeles",
      sensitive?: false,
      type: :timezone,
      writable?: true
    }
  }
  @defaults %{
    "operator" => %{
      "communication_style" => "concise",
      "display_name" => "local",
      "handoff_detail" => "concrete_next_steps",
      "timezone" => "America/Los_Angeles"
    }
  }
  @safe_write_keys [
    "operator.display_name",
    "operator.timezone",
    "operator.communication_style",
    "operator.handoff_detail"
  ]
  @safe_write_rows [
    {1, "operator.display_name"},
    {2, "operator.timezone"},
    {3, "operator.communication_style"},
    {4, "operator.handoff_detail"}
  ]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:operator",
      owner: "operator",
      source: :core,
      group: "operator",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Operator"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
