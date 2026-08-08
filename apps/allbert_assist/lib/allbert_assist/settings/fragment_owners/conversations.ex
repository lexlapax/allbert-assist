defmodule AllbertAssist.Settings.FragmentOwners.Conversations do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "conversations.unified_history.include_e2ee_origin" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    }
  }
  @defaults %{"conversations" => %{"unified_history" => %{"include_e2ee_origin" => false}}}
  @safe_write_keys ["conversations.unified_history.include_e2ee_origin"]
  @safe_write_rows [{21, "conversations.unified_history.include_e2ee_origin"}]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:conversations",
      owner: "conversations",
      source: :core,
      group: "conversations",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Conversations"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
