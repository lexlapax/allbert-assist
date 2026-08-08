defmodule AllbertAssist.Settings.FragmentOwners.FirstModel do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "first_model.curated_floor_gb" => %{
      default: 8,
      max: 512,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "first_model.curated_model" => %{
      default: "llama3.2:3b",
      sensitive?: false,
      type: :string,
      writable?: true
    }
  }
  @defaults %{"first_model" => %{"curated_floor_gb" => 8, "curated_model" => "llama3.2:3b"}}
  @safe_write_keys ["first_model.curated_model", "first_model.curated_floor_gb"]
  @safe_write_rows [{70, "first_model.curated_model"}, {71, "first_model.curated_floor_gb"}]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:first_model",
      owner: "first_model",
      source: :core,
      group: "first_model",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "First Model"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
