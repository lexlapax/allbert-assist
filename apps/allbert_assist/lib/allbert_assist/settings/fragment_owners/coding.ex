defmodule AllbertAssist.Settings.FragmentOwners.Coding do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "coding.bash.allow_raw_shell" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "coding.bash.max_output_bytes" => %{
      default: 120_000,
      max: 1_000_000,
      min: 1024,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "coding.bash.timeout_ms" => %{
      default: 120_000,
      max: 600_000,
      min: 100,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "coding.cancel.grace_ms" => %{
      default: 2000,
      max: 60000,
      min: 100,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "coding.command_grants.default_ttl_ms" => %{
      default: 86_400_000,
      max: 2_592_000_000,
      min: 60000,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "coding.command_grants.max_entries_per_repo" => %{
      default: 100,
      max: 1000,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "coding.default_approval_mode" => %{
      allowed_values: ["default", "accept-edits", "accept_edits", "plan", "tier"],
      default: "default",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "coding.edit.max_replacements" => %{
      default: 1,
      max: 1000,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "coding.model_profile" => %{
      default: "pi_coding_local",
      sensitive?: false,
      type: :string,
      writable?: true
    },
    "coding.pi_mode.enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "coding.prompt.token_budget" => %{
      default: 1000,
      max: 4000,
      min: 256,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "coding.prompt.tokenizer" => %{
      allowed_values: ["simple_words"],
      default: "simple_words",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "coding.read.default_limit" => %{
      default: 2000,
      max: 20000,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "coding.read.max_bytes" => %{
      default: 120_000,
      max: 1_000_000,
      min: 1024,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "coding.search.max_output_bytes" => %{
      default: 120_000,
      max: 1_000_000,
      min: 1024,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "coding.search.max_results" => %{
      default: 100,
      max: 10000,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "coding.search.respect_allbertignore" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "coding.search.respect_gitignore" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "coding.steer.enabled" => %{default: true, sensitive?: false, type: :boolean, writable?: true},
    "coding.streaming.enabled" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "coding.streaming.turn_complete_fallback" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "coding.trusted_operator_id" => %{
      default: nil,
      sensitive?: false,
      type: :string_or_nil,
      writable?: true
    },
    "coding.turn.max_ms" => %{
      default: 120_000,
      max: 600_000,
      min: 100,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "coding.turn.supervised" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "coding.workspace.cwd_jail" => %{
      default: ".",
      sensitive?: false,
      type: :string,
      writable?: true
    },
    "coding.write.max_bytes" => %{
      default: 120_000,
      max: 1_000_000,
      min: 1024,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    }
  }
  @defaults %{
    "coding" => %{
      "bash" => %{
        "allow_raw_shell" => false,
        "max_output_bytes" => 120_000,
        "timeout_ms" => 120_000
      },
      "cancel" => %{"grace_ms" => 2000},
      "command_grants" => %{"default_ttl_ms" => 86_400_000, "max_entries_per_repo" => 100},
      "default_approval_mode" => "default",
      "edit" => %{"max_replacements" => 1},
      "model_profile" => "pi_coding_local",
      "pi_mode" => %{"enabled" => false},
      "prompt" => %{"token_budget" => 1000, "tokenizer" => "simple_words"},
      "read" => %{"default_limit" => 2000, "max_bytes" => 120_000},
      "search" => %{
        "max_output_bytes" => 120_000,
        "max_results" => 100,
        "respect_allbertignore" => true,
        "respect_gitignore" => true
      },
      "steer" => %{"enabled" => true},
      "streaming" => %{"enabled" => true, "turn_complete_fallback" => true},
      "trusted_operator_id" => nil,
      "turn" => %{"max_ms" => 120_000, "supervised" => true},
      "workspace" => %{"cwd_jail" => "."},
      "write" => %{"max_bytes" => 120_000}
    }
  }
  @safe_write_keys [
    "coding.workspace.cwd_jail",
    "coding.read.default_limit",
    "coding.read.max_bytes",
    "coding.search.max_results",
    "coding.search.max_output_bytes",
    "coding.search.respect_gitignore",
    "coding.search.respect_allbertignore",
    "coding.write.max_bytes",
    "coding.edit.max_replacements",
    "coding.bash.timeout_ms",
    "coding.bash.max_output_bytes",
    "coding.bash.allow_raw_shell",
    "coding.pi_mode.enabled",
    "coding.trusted_operator_id",
    "coding.default_approval_mode",
    "coding.command_grants.default_ttl_ms",
    "coding.command_grants.max_entries_per_repo",
    "coding.prompt.token_budget",
    "coding.prompt.tokenizer",
    "coding.model_profile",
    "coding.turn.supervised",
    "coding.turn.max_ms",
    "coding.streaming.enabled",
    "coding.streaming.turn_complete_fallback",
    "coding.steer.enabled",
    "coding.cancel.grace_ms"
  ]
  @safe_write_rows [
    {75, "coding.workspace.cwd_jail"},
    {76, "coding.read.default_limit"},
    {77, "coding.read.max_bytes"},
    {78, "coding.search.max_results"},
    {79, "coding.search.max_output_bytes"},
    {80, "coding.search.respect_gitignore"},
    {81, "coding.search.respect_allbertignore"},
    {82, "coding.write.max_bytes"},
    {83, "coding.edit.max_replacements"},
    {84, "coding.bash.timeout_ms"},
    {85, "coding.bash.max_output_bytes"},
    {86, "coding.bash.allow_raw_shell"},
    {87, "coding.pi_mode.enabled"},
    {88, "coding.trusted_operator_id"},
    {89, "coding.default_approval_mode"},
    {90, "coding.command_grants.default_ttl_ms"},
    {91, "coding.command_grants.max_entries_per_repo"},
    {92, "coding.prompt.token_budget"},
    {93, "coding.prompt.tokenizer"},
    {94, "coding.model_profile"},
    {95, "coding.turn.supervised"},
    {96, "coding.turn.max_ms"},
    {97, "coding.streaming.enabled"},
    {98, "coding.streaming.turn_complete_fallback"},
    {99, "coding.steer.enabled"},
    {100, "coding.cancel.grace_ms"}
  ]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:coding",
      owner: "coding",
      source: :core,
      group: "coding",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Coding"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
