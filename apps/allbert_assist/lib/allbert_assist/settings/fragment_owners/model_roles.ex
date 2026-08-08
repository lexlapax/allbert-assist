defmodule AllbertAssist.Settings.FragmentOwners.ModelRoles do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "model_roles.capable.profile" => %{
      default: nil,
      sensitive?: false,
      type: :concrete_profile_ref_or_nil,
      writable?: true
    },
    "model_roles.fast.profile" => %{
      default: nil,
      sensitive?: false,
      type: :concrete_profile_ref_or_nil,
      writable?: true
    },
    "model_roles.schema_version" => %{
      default: 1,
      max: 1,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: false
    },
    "model_roles.thinking.profile" => %{
      default: nil,
      sensitive?: false,
      type: :concrete_profile_ref_or_nil,
      writable?: true
    }
  }
  @defaults %{
    "model_roles" => %{
      "capable" => %{"profile" => nil},
      "fast" => %{"profile" => nil},
      "schema_version" => 1,
      "thinking" => %{"profile" => nil}
    }
  }
  @safe_write_keys [
    "model_roles.fast.profile",
    "model_roles.capable.profile",
    "model_roles.thinking.profile"
  ]
  @safe_write_rows [
    {67, "model_roles.fast.profile"},
    {68, "model_roles.capable.profile"},
    {69, "model_roles.thinking.profile"}
  ]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:model_roles",
      owner: "model_roles",
      source: :core,
      group: "model_roles",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Model Roles"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
