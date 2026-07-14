defmodule AllbertAssist.CLI.FirstRunTest do
  @moduledoc """
  v0.62 M3 — the first-run detector resolves the six product states and the
  six first-model probe states (Locked Decision 6), read-only and network-free. The
  six model states are all reachable through injected probes (there is no synthetic
  `blocked` state).
  """
  use ExUnit.Case, async: false

  alias AllbertAssist.CLI.FirstRun

  @moduletag :cli_dispatcher

  describe "first_model_state/1 (all six states reachable via injection)" do
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
      # v1.0 M7.5: inject the model state (M7.9 pattern) — this test is about the
      # profile-review state machine, and a live probe made it depend on whatever
      # the host's Ollama happens to be running/serving.
      FirstRun.mark_onboarding_complete()
      assert FirstRun.detect(first_model_state: :byok_ready) == :profile_unreviewed

      # The real profile-review state flips it to product_ready.
      FirstRun.mark_profile_reviewed()
      assert FirstRun.detect(first_model_state: :byok_ready) == :product_ready
    after
      System.delete_env("ANTHROPIC_API_KEY")
    end

    test "v0.63 M7.9: detect/1 reuses an injected first_model_state (no live probe)",
         %{root: root} do
      File.mkdir_p!(Path.join([root, "db"]))
      File.write!(Path.join([root, "db", "allbert.sqlite3"]), "x")
      # No provider key + no local Ollama → the *live* probe resolves :runtime_missing,
      # which would route detect/0 to :first_model_not_ready.
      System.delete_env("ANTHROPIC_API_KEY")
      FirstRun.mark_onboarding_complete()
      FirstRun.mark_profile_reviewed()

      # Injecting a ready state must drive detect WITHOUT a live probe — only possible
      # if the injected value is honored (else this would be :first_model_not_ready).
      assert FirstRun.detect(first_model_state: :local_ready) == :product_ready
      # And a not-ready injected state still routes correctly, proving the arg is used.
      assert FirstRun.detect(first_model_state: :runtime_missing) == :first_model_not_ready

      assert FirstRun.detect_details(first_model_state: :model_missing) == %{
               state: :first_model_not_ready,
               first_model_state: :model_missing
             }
    end

    test "v0.63 M1: reset_onboarding clears the marker (Home preserved)", %{root: root} do
      File.mkdir_p!(Path.join([root, "db"]))
      File.write!(Path.join([root, "db", "allbert.sqlite3"]), "x")
      System.put_env("ANTHROPIC_API_KEY", "test-key")
      FirstRun.mark_onboarding_complete()
      FirstRun.mark_profile_reviewed()
      # v1.0 M7.5: injected model state (M7.9 pattern) — no live host probe.
      assert FirstRun.detect(first_model_state: :byok_ready) == :product_ready

      FirstRun.reset_onboarding()
      # Marker cleared → back to onboarding_incomplete; the DB (Home) is untouched.
      assert FirstRun.detect() == :onboarding_incomplete
      assert File.exists?(Path.join([root, "db", "allbert.sqlite3"]))
    after
      System.delete_env("ANTHROPIC_API_KEY")
    end

    test "v0.63 M7.1: a corrupt/truncated marker reads as empty without crashing", %{root: root} do
      File.mkdir_p!(Path.join([root, "db"]))
      File.write!(Path.join([root, "db", "allbert.sqlite3"]), "x")
      # Simulate a crash mid-write leaving truncated JSON.
      File.write!(Path.join([root, "onboarding.json"]), "{\"onboarding_complete\": tr")

      # It does not raise and is not mistaken for a valid completed marker.
      assert FirstRun.read_marker() == %{}
      assert FirstRun.detect() == :onboarding_incomplete
    end

    test "v0.63 M7.1: marker writes are atomic (no leftover temp file)", %{root: root} do
      File.mkdir_p!(Path.join([root, "db"]))
      File.write!(Path.join([root, "db", "allbert.sqlite3"]), "x")
      FirstRun.mark_onboarding_complete()

      assert FirstRun.read_marker()["onboarding_complete"] == true
      refute File.exists?(Path.join([root, "onboarding.json.tmp"]))
    end
  end
end
