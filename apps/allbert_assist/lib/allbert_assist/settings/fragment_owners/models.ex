defmodule AllbertAssist.Settings.FragmentOwners.Models do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "models.catalog.version" => %{
      default: 1,
      max: 1,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: false
    },
    "models.fallback.allow_local_to_hosted" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "models.fallback.enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "models.fallback.max_failovers_per_turn" => %{
      default: 1,
      max: 2,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    }
  }
  @defaults %{
    "models" => %{
      "catalog" => %{"version" => 1},
      "fallback" => %{
        "allow_local_to_hosted" => false,
        "enabled" => false,
        "max_failovers_per_turn" => 1
      }
    }
  }
  @safe_write_keys [
    "models.fallback.enabled",
    "models.fallback.allow_local_to_hosted",
    "models.fallback.max_failovers_per_turn"
  ]
  @safe_write_rows [
    {72, "models.fallback.enabled"},
    {73, "models.fallback.allow_local_to_hosted"},
    {74, "models.fallback.max_failovers_per_turn"}
  ]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:models",
      owner: "models",
      source: :core,
      group: "models",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Models"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
