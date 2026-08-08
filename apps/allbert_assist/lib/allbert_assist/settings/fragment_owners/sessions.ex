defmodule AllbertAssist.Settings.FragmentOwners.Sessions do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "sessions.scratchpad_ttl_minutes" => %{
      default: 30,
      max: 1440,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    }
  }
  @defaults %{"sessions" => %{"scratchpad_ttl_minutes" => 30}}
  @safe_write_keys ["sessions.scratchpad_ttl_minutes"]
  @safe_write_rows [{400, "sessions.scratchpad_ttl_minutes"}]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:sessions",
      owner: "sessions",
      source: :core,
      group: "sessions",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Sessions"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
