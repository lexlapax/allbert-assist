defmodule AllbertAssist.Settings.FragmentOwners.Templates do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "templates.allowed_patterns" => %{
      default: ["plugin", "app", "llm_tool", "flow", "objective"],
      sensitive?: false,
      type: :string_list,
      writable?: true
    },
    "templates.create.enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    }
  }
  @defaults %{
    "templates" => %{
      "allowed_patterns" => ["plugin", "app", "llm_tool", "flow", "objective"],
      "create" => %{"enabled" => false}
    }
  }
  @safe_write_keys ["templates.create.enabled", "templates.allowed_patterns"]
  @safe_write_rows [{370, "templates.create.enabled"}, {371, "templates.allowed_patterns"}]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:templates",
      owner: "templates",
      source: :core,
      group: "templates",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Templates"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
