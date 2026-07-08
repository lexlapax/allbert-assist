defmodule AllbertAssist.Actions.ApplyPersonaProfileTest do
  @moduledoc """
  v0.63 M4 — `apply_persona_profile` is seed-only and confirmation-gated: it shows a
  review diff and writes nothing until an approved confirmation resumes it. Only
  `@safe_write_keys` are seeded; no authority, egress, channel, or secret is granted.
  """
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Actions.Settings.ApplyPersonaProfile
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  @env_vars [
    "ALLBERT_HOME",
    "ALLBERT_HOME_DIR",
    "ALLBERT_SETTINGS_ROOT",
    "ALLBERT_SETTINGS_MASTER_KEY"
  ]

  setup do
    original_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_settings = Application.get_env(:allbert_assist, Settings)

    Enum.each(@env_vars, &System.delete_env/1)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)

    home = Path.join(System.tmp_dir!(), "allbert-persona-#{System.unique_integer([:positive])}")
    System.put_env("ALLBERT_HOME", home)

    on_exit(fn ->
      File.rm_rf!(home)
      restore_env(original_env)
      restore_app_env(Paths, original_paths)
      restore_app_env(Settings, original_settings)
    end)

    :ok
  end

  test "dry_run returns a review diff and writes nothing" do
    before = Settings.get("coding.default_approval_mode")

    assert {:ok, response} =
             ApplyPersonaProfile.run(%{persona_id: "developer", dry_run: true}, context())

    assert response.status == :completed
    refute response.review.executed
    assert response.review.persona_id == "developer"
    assert response.review.change_count > 0

    # Each change carries current → proposed and a changed? flag.
    assert Enum.all?(response.review.changes, &Map.has_key?(&1, :proposed))
    assert Enum.any?(response.review.changes, &(&1.key == "coding.default_approval_mode"))

    # Seed-only: suggestions are highlights, and the persona grants nothing.
    assert is_list(response.review.suggested_apps)
    assert response.review.grants.authority == false
    assert response.review.grants.egress == false
    assert response.review.grants.secret == false

    # Nothing was written.
    assert Settings.get("coding.default_approval_mode") == before
  end

  test "unknown persona is denied" do
    assert {:ok, response} = ApplyPersonaProfile.run(%{persona_id: "nope"}, context())
    assert response.status == :denied
  end

  test "M7.1: an approved resume whose persona_id differs from the reviewed one is denied" do
    # Simulates a tampered confirmation record: resume params say "developer" but the
    # reviewed params_summary said "general".
    tampered =
      context()
      |> Map.put(:confirmation, %{approved?: true, params_summary: %{"persona_id" => "general"}})

    assert {:ok, response} = ApplyPersonaProfile.run(%{persona_id: "developer"}, tampered)
    assert response.status == :denied
    assert response.review.error == :reviewed_persona_mismatch

    # A matching resume still applies.
    matching =
      context()
      |> Map.put(:confirmation, %{approved?: true, params_summary: %{"persona_id" => "developer"}})

    assert {:ok, ok} = ApplyPersonaProfile.run(%{persona_id: "developer"}, matching)
    assert ok.status == :completed
  end

  test "the confirmation path writes nothing; approval seeds the safe-write keys" do
    before = Settings.get("operator.communication_style")

    assert {:ok, pending} =
             Runner.run("apply_persona_profile", %{persona_id: "developer"}, context())

    assert pending.status == :needs_confirmation
    assert pending.confirmation_id
    refute pending.review.executed
    # Still nothing written while pending.
    assert Settings.get("operator.communication_style") == before

    assert {:ok, approved} =
             Runner.run(
               "approve_confirmation",
               %{id: pending.confirmation_id, reason: "persona apply approval"},
               context()
             )

    assert approved.status == :completed
    # The generic resume actually re-ran the target action (no adapter_unavailable).
    assert get_in(approved, [:confirmation, "operator_resolution", "target_resumed?"]) == true

    assert get_in(approved, [:confirmation, "operator_resolution", "target_status"]) ==
             "completed"

    # The pinned developer seeds are now live in Settings Central.
    assert Settings.get("operator.communication_style") == {:ok, "concise"}
    assert Settings.get("coding.default_approval_mode") == {:ok, "plan"}
    assert Settings.get("coding.model_profile") == {:ok, "pi_coding_local"}

    assert Settings.get("model_preferences.tasks.coding") ==
             {:ok, ["pi_coding_local", "coding_local", "coding", "capable", "local"]}
  end

  defp context do
    %{actor: "local", channel: :cli, request: %{operator_id: "local", channel: :cli}}
  end

  defp restore_env(original_env) do
    Enum.each(original_env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
