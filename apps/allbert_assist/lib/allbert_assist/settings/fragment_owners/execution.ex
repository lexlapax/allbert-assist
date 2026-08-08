defmodule AllbertAssist.Settings.FragmentOwners.Execution do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "execution.cancel.grace_ms" => %{
      default: 5000,
      max: 60000,
      min: 100,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "execution.local.allowed_commands" => %{
      default: ["pwd", "ls", "find", "rg", "cat", "sed", "head", "tail", "wc"],
      sensitive?: false,
      type: :string_list,
      writable?: true
    },
    "execution.local.allowed_roots" => %{
      default: [],
      sensitive?: false,
      type: :string_list,
      writable?: true
    },
    "execution.local.blocked_arg_patterns" => %{
      default: [
        "-i",
        "--in-place",
        "-delete",
        "-exec",
        "-execdir",
        "-c",
        "-e",
        "--eval",
        "&&",
        "||",
        ";",
        "|",
        ">",
        ">>",
        "<",
        "$(",
        "`",
        "&"
      ],
      sensitive?: false,
      type: :string_list,
      writable?: true
    },
    "execution.local.command_profiles" => %{
      default: %{},
      sensitive?: false,
      type: :command_profiles,
      writable?: true
    },
    "execution.local.default_timeout_ms" => %{
      default: 5000,
      sensitive?: false,
      type: :timeout_ms,
      writable?: true
    },
    "execution.local.enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "execution.local.env_allowlist" => %{
      default: ["PATH", "LANG", "LC_ALL", "MIX_ENV"],
      sensitive?: false,
      type: :string_list,
      writable?: true
    },
    "execution.local.max_output_bytes" => %{
      default: 65536,
      sensitive?: false,
      type: :positive_integer,
      writable?: true
    },
    "execution.local.max_timeout_ms" => %{
      default: 30000,
      sensitive?: false,
      type: :timeout_ms,
      writable?: true
    },
    "execution.local.require_confirmation" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "execution.local.require_path_operands_in_allowed_roots" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "execution.skill_scripts.enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "execution.skill_scripts.interpreter_profiles" => %{
      default: %{},
      sensitive?: false,
      type: :interpreter_profiles,
      writable?: true
    },
    "execution.skill_scripts.require_confirmation" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    }
  }
  @defaults %{
    "execution" => %{
      "cancel" => %{"grace_ms" => 5000},
      "local" => %{
        "allowed_commands" => ["pwd", "ls", "find", "rg", "cat", "sed", "head", "tail", "wc"],
        "allowed_roots" => [],
        "blocked_arg_patterns" => [
          "-i",
          "--in-place",
          "-delete",
          "-exec",
          "-execdir",
          "-c",
          "-e",
          "--eval",
          "&&",
          "||",
          ";",
          "|",
          ">",
          ">>",
          "<",
          "$(",
          "`",
          "&"
        ],
        "command_profiles" => %{},
        "default_timeout_ms" => 5000,
        "enabled" => false,
        "env_allowlist" => ["PATH", "LANG", "LC_ALL", "MIX_ENV"],
        "max_output_bytes" => 65536,
        "max_timeout_ms" => 30000,
        "require_confirmation" => true,
        "require_path_operands_in_allowed_roots" => true
      },
      "skill_scripts" => %{
        "enabled" => false,
        "interpreter_profiles" => %{},
        "require_confirmation" => true
      }
    }
  }
  @safe_write_keys [
    "execution.cancel.grace_ms",
    "execution.local.enabled",
    "execution.local.allowed_roots",
    "execution.local.allowed_commands",
    "execution.local.command_profiles",
    "execution.local.blocked_arg_patterns",
    "execution.local.require_path_operands_in_allowed_roots",
    "execution.local.default_timeout_ms",
    "execution.local.max_timeout_ms",
    "execution.local.max_output_bytes",
    "execution.local.env_allowlist",
    "execution.local.require_confirmation",
    "execution.skill_scripts.enabled",
    "execution.skill_scripts.require_confirmation",
    "execution.skill_scripts.interpreter_profiles"
  ]
  @safe_write_rows [
    {20, "execution.cancel.grace_ms"},
    {310, "execution.local.enabled"},
    {311, "execution.local.allowed_roots"},
    {312, "execution.local.allowed_commands"},
    {313, "execution.local.command_profiles"},
    {314, "execution.local.blocked_arg_patterns"},
    {315, "execution.local.require_path_operands_in_allowed_roots"},
    {316, "execution.local.default_timeout_ms"},
    {317, "execution.local.max_timeout_ms"},
    {318, "execution.local.max_output_bytes"},
    {319, "execution.local.env_allowlist"},
    {320, "execution.local.require_confirmation"},
    {321, "execution.skill_scripts.enabled"},
    {322, "execution.skill_scripts.require_confirmation"},
    {323, "execution.skill_scripts.interpreter_profiles"}
  ]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:execution",
      owner: "execution",
      source: :core,
      group: "execution",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Execution"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
