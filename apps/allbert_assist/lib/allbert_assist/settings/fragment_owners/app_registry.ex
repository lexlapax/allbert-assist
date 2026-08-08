defmodule AllbertAssist.Settings.FragmentOwners.AppRegistry do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "app_registry.registration_enabled" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    }
  }
  @defaults %{"app_registry" => %{"registration_enabled" => true}}
  @safe_write_keys ["app_registry.registration_enabled"]
  @safe_write_rows [{389, "app_registry.registration_enabled"}]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:app_registry",
      owner: "app_registry",
      source: :core,
      group: "app_registry",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "App Registry"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
