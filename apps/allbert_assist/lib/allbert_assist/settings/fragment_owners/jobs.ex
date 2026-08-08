defmodule AllbertAssist.Settings.FragmentOwners.Jobs do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "jobs.default_state" => %{
      allowed_values: ["paused", "active"],
      default: "paused",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "jobs.schedule_policy" => %{
      allowed_values: ["operator_approved", "paused"],
      default: "operator_approved",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "jobs.timezone" => %{
      default: "America/Los_Angeles",
      sensitive?: false,
      type: :timezone,
      writable?: true
    }
  }
  @defaults %{
    "jobs" => %{
      "default_state" => "paused",
      "schedule_policy" => "operator_approved",
      "timezone" => "America/Los_Angeles"
    }
  }
  @safe_write_keys ["jobs.timezone", "jobs.default_state", "jobs.schedule_policy"]
  @safe_write_rows [
    {397, "jobs.timezone"},
    {398, "jobs.default_state"},
    {399, "jobs.schedule_policy"}
  ]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:jobs",
      owner: "jobs",
      source: :core,
      group: "jobs",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Jobs"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
