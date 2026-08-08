defmodule AllbertAssist.Settings.FragmentOwners.ResourceGrants do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "resource_grants.remembered" => %{
      default: [],
      sensitive?: false,
      type: :resource_grants,
      writable?: true
    }
  }
  @defaults %{"resource_grants" => %{"remembered" => []}}
  @safe_write_keys ["resource_grants.remembered"]
  @safe_write_rows [{372, "resource_grants.remembered"}]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:resource_grants",
      owner: "resource_grants",
      source: :core,
      group: "resource_grants",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Resource Grants"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
