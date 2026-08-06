defmodule AllbertAssist.DevGates.Preflight do
  @moduledoc """
  Frozen composition for the cheapest-first v1.3.2 developer preflight.

  The Mix task executes these definitions. Keeping the normalized contract in a
  small module makes attestation and structure tests independent of prose or
  source-text matching.
  """

  alias AllbertAssist.DevGates.FixtureRegistry
  alias AllbertAssist.DevGates.PreflightAttestation
  alias AllbertAssist.DevGates.PreflightGuard
  alias AllbertAssist.DevGates.ScopeSelector

  @base_steps [
    %{
      id: "forced_compile",
      cwd: :root,
      executable: "mix",
      args: ["compile", "--force", "--warnings-as-errors"]
    },
    %{id: "format", cwd: :root, executable: "mix", args: ["format", "--check-formatted"]},
    %{id: "whitespace", cwd: :root, executable: "git", args: ["diff", "--check"]},
    %{id: "docs", cwd: :root, executable: "mix", args: ["allbert.test", "docs"]},
    %{
      id: "registry_and_param_contract",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/actions/registry_test.exs",
        "test/allbert_assist/actions/param_contract_test.exs"
      ]
    },
    %{
      id: "owner_cwd_test_load",
      cwd: :root,
      executable: "mix",
      args: ["allbert.test", "preflight.test-load"]
    },
    %{
      id: "lane_tags",
      cwd: :root,
      executable: "mix",
      args: ["allbert.test", "inventory", "--check-tags", "--output", "/dev/null"]
    },
    %{
      id: "test_manifest",
      cwd: :root,
      executable: "mix",
      args: ["allbert.test", "inventory", "--check-manifest"]
    }
  ]

  @historical_stop_checks %{
    "42adfef3" => ["docs", "fixture_historical_security_release_and_intent_contracts"],
    "70b9bbf8" => ["registry_and_param_contract"],
    "b9f60352" => ["fixture_memory_projection_and_schema_floor"],
    "a86d721c" => ["fixture_historical_security_release_and_intent_contracts"],
    "10f392de" => ["owner_cwd_test_load"],
    "34c7452f" => ["fixture_historical_security_release_and_intent_contracts"],
    "e9a39696" => ["compatibility"]
  }

  def step_definitions do
    @base_steps ++
      Enum.map(FixtureRegistry.entries(), fn entry ->
        %{
          id: "fixture_#{entry.id}",
          cwd: :root,
          executable: "mix",
          args: ["allbert.test", "preflight.fixture", entry.id]
        }
      end)
  end

  def contract_digest do
    %{
      "schema_version" => 1,
      "steps" => Enum.map(step_definitions(), &stringify_step/1),
      "guarded_commands" => PreflightGuard.rules(),
      "fixture_sentinels" => FixtureRegistry.contract_rows(),
      "historical_stop_checks" => @historical_stop_checks,
      "scope_rules" => ScopeSelector.contract_rows()
    }
    |> PreflightAttestation.digest_term()
  end

  def historical_stop_checks, do: @historical_stop_checks

  defp stringify_step(step) do
    %{
      "id" => step.id,
      "cwd" => Atom.to_string(step.cwd),
      "executable" => step.executable,
      "args" => step.args
    }
  end
end
