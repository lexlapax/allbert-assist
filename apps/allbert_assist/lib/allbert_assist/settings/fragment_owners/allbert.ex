defmodule AllbertAssist.Settings.FragmentOwners.Allbert do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "allbert.jido.debug_trace" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    }
  }
  @defaults %{"allbert" => %{"jido" => %{"debug_trace" => false}}}
  @safe_write_keys ["allbert.jido.debug_trace"]
  @safe_write_rows [{5, "allbert.jido.debug_trace"}]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:allbert",
      owner: "allbert",
      source: :core,
      group: "allbert",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Allbert"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
