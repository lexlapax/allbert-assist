defmodule AllbertAssist.Settings.FragmentOwners.Search do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "search.enabled" => %{default: true, sensitive?: false, type: :boolean, writable?: true},
    "search.origin_grants" => %{
      default: ["local_operator"],
      sensitive?: false,
      type: :v13_origin_scopes,
      writable?: true
    },
    "search.snippet.max_bytes" => %{
      default: 320,
      max: 1024,
      min: 64,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    }
  }
  @defaults %{
    "search" => %{
      "enabled" => true,
      "origin_grants" => ["local_operator"],
      "snippet" => %{"max_bytes" => 320}
    }
  }
  @safe_write_keys ["search.enabled", "search.origin_grants", "search.snippet.max_bytes"]
  @safe_write_rows [
    {452, "search.enabled"},
    {453, "search.origin_grants"},
    {454, "search.snippet.max_bytes"}
  ]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:search",
      owner: "search",
      source: :core,
      group: "search",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Search"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
