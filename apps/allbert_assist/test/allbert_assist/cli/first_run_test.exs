defmodule AllbertAssist.CLI.FirstRunTest do
  @moduledoc """
  v0.62 M3 — the first-run detector resolves the six product states and the
  seven first-model states (Locked Decision 6), read-only and network-free. The
  seven model states are all reachable through injected probes.
  """
  use ExUnit.Case, async: false

  alias AllbertAssist.CLI.FirstRun

  @moduletag :cli_dispatcher

  describe "first_model_state/1 (all seven states reachable via injection)" do
    test "local_ready when the model is present" do
      assert FirstRun.first_model_state(ollama_probe: fn -> :model_ready end) == :local_ready
    end

    test "runtime_unhealthy when the server is up but unhealthy" do
      assert FirstRun.first_model_state(ollama_probe: fn -> :unhealthy end) == :runtime_unhealthy
    end

    test "model_missing when runtime present, model absent, hardware ok" do
      assert FirstRun.first_model_state(
               ollama_probe: fn -> :model_missing end,
               hardware_ok?: fn -> true end
             ) == :model_missing
    end

    test "below_hardware_floor when the model is absent and hardware is under floor" do
      assert FirstRun.first_model_state(
               ollama_probe: fn -> :model_missing end,
               hardware_ok?: fn -> false end
             ) == :below_hardware_floor
    end

    test "byok_ready when no runtime but a provider key is present" do
      assert FirstRun.first_model_state(
               ollama_probe: fn -> :missing end,
               byok_ready?: fn -> true end
             ) == :byok_ready
    end

    test "runtime_missing when no runtime and no BYOK key" do
      assert FirstRun.first_model_state(
               ollama_probe: fn -> :missing end,
               byok_ready?: fn -> false end
             ) == :runtime_missing
    end
  end

  describe "detect/0" do
    setup do
      root = Path.join(System.tmp_dir!(), "firstrun-#{System.unique_integer([:positive])}")
      saved = Application.get_env(:allbert_assist, AllbertAssist.Paths)
      Application.put_env(:allbert_assist, AllbertAssist.Paths, home: root)

      on_exit(fn ->
        if saved, do: Application.put_env(:allbert_assist, AllbertAssist.Paths, saved)
        File.rm_rf!(root)
      end)

      {:ok, root: root}
    end

    test "home_missing when Home has no database", %{root: _root} do
      assert FirstRun.detect() == :home_missing
    end

    test "onboarding_incomplete once Home has a DB but no onboarding marker", %{root: root} do
      File.mkdir_p!(Path.join([root, "db"]))
      File.write!(Path.join([root, "db", "allbert.sqlite3"]), "x")
      assert FirstRun.detect() == :onboarding_incomplete
    end

    test "v0.63 M1: profile review is a real, separate state; complete alone is not product_ready",
         %{root: root} do
      File.mkdir_p!(Path.join([root, "db"]))
      File.write!(Path.join([root, "db", "allbert.sqlite3"]), "x")
      System.put_env("ANTHROPIC_API_KEY", "test-key")

      # Completing onboarding no longer forces profile_reviewed (placeholder retired).
      FirstRun.mark_onboarding_complete()
      assert FirstRun.detect() == :profile_unreviewed

      # The real profile-review state flips it to product_ready.
      FirstRun.mark_profile_reviewed()
      assert FirstRun.detect() == :product_ready
    after
      System.delete_env("ANTHROPIC_API_KEY")
    end

    test "v0.63 M1: reset_onboarding clears the marker (Home preserved)", %{root: root} do
      File.mkdir_p!(Path.join([root, "db"]))
      File.write!(Path.join([root, "db", "allbert.sqlite3"]), "x")
      System.put_env("ANTHROPIC_API_KEY", "test-key")
      FirstRun.mark_onboarding_complete()
      FirstRun.mark_profile_reviewed()
      assert FirstRun.detect() == :product_ready

      FirstRun.reset_onboarding()
      # Marker cleared → back to onboarding_incomplete; the DB (Home) is untouched.
      assert FirstRun.detect() == :onboarding_incomplete
      assert File.exists?(Path.join([root, "db", "allbert.sqlite3"]))
    after
      System.delete_env("ANTHROPIC_API_KEY")
    end
  end
end
