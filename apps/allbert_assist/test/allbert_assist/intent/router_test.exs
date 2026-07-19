defmodule AllbertAssist.Intent.RouterTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Intent.ConversationContext
  alias AllbertAssist.Intent.PendingClarification
  alias AllbertAssist.Intent.Router
  alias AllbertAssist.Intent.Router.FakeRouter
  alias AllbertAssist.Intent.Router.Outcome
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Schema

  @router_keys ~w(
    intent.router_strategy intent.router_embedding_profile intent.router_model_profile
    intent.router_escalation_profile intent.router_top_k intent.router_min_confidence
    intent.router_model_timeout_ms intent.multiturn_enabled intent.context_window
    intent.disambiguation_margin intent.pending_clarification_ttl_ms
  )

  setup do
    original_home = System.get_env("ALLBERT_HOME")
    original_home_dir = System.get_env("ALLBERT_HOME_DIR")
    original_database_path = System.get_env("DATABASE_PATH")
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_router_config = Application.get_env(:allbert_assist, :intent_router)
    original_fake = Application.get_env(:allbert_assist, :intent_router_fake_outcome)
    original_override = Application.get_env(:allbert_assist, :intent_router_strategy_override)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-router-test-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    database_path = Path.join([home, "db", "allbert_router_test.db"])
    File.rm_rf!(home)
    File.mkdir_p!(Path.dirname(database_path))
    System.put_env("ALLBERT_HOME", home)
    System.put_env("ALLBERT_HOME_DIR", home)
    System.put_env("DATABASE_PATH", database_path)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)

    on_exit(fn ->
      File.rm_rf!(home)

      if original_home,
        do: System.put_env("ALLBERT_HOME", original_home),
        else: System.delete_env("ALLBERT_HOME")

      if original_home_dir,
        do: System.put_env("ALLBERT_HOME_DIR", original_home_dir),
        else: System.delete_env("ALLBERT_HOME_DIR")

      if original_database_path,
        do: System.put_env("DATABASE_PATH", original_database_path),
        else: System.delete_env("DATABASE_PATH")

      restore(Paths, original_paths_config)
      restore(Settings, original_settings_config)
      restore(:intent_router, original_router_config)
      restore(:intent_router_fake_outcome, original_fake)
      restore(:intent_router_strategy_override, original_override)
    end)

    :ok
  end

  describe "settings schema (M0 contracts)" do
    test "all new router/deepening keys are known and safe-writable with defaults" do
      defaults = Schema.defaults()

      for key <- @router_keys do
        assert Schema.known_key?(key), "#{key} should be a known key"
        assert Schema.safe_write_key?(key), "#{key} should be safe-writable"
        refute Schema.get_dotted(defaults, key) == nil, "#{key} should have a default"
      end
    end

    test "router_strategy default is two_stage_local and rejects an invalid enum value" do
      assert Schema.get_dotted(Schema.defaults(), "intent.router_strategy") == "two_stage_local"
      assert :ok = Schema.validate_key_value("intent.router_strategy", "two_stage_local")
      assert :ok = Schema.validate_key_value("intent.router_strategy", "deterministic")
      assert {:error, _} = Schema.validate_key_value("intent.router_strategy", "bogus")
    end

    test "settings round-trip for router_strategy" do
      assert {:ok, _} =
               Settings.put("intent.router_strategy", "two_stage_local", %{audit?: false})

      assert {:ok, "two_stage_local"} = Settings.get("intent.router_strategy")
      assert {:ok, _} = Settings.put("intent.router_strategy", "deterministic", %{audit?: false})
      assert {:ok, "deterministic"} = Settings.get("intent.router_strategy")
    end
  end

  describe "Router dispatch (M0)" do
    test "strategy/0 honors the test override (:deterministic)" do
      assert Router.strategy() == :deterministic
    end

    test "route/3 defers under the deterministic strategy" do
      assert {:ok, %Outcome{kind: :defer}} = Router.route(%{text: "hi"}, [])
    end

    test "route/3 delegates to the configured impl under :two_stage_local" do
      Application.put_env(:allbert_assist, :intent_router_strategy_override, :two_stage_local)
      Application.put_env(:allbert_assist, :intent_router, FakeRouter)

      Application.put_env(
        :allbert_assist,
        :intent_router_fake_outcome,
        Outcome.execute("create_note", %{"title" => "x"}, 0.9)
      )

      assert {:ok, %Outcome{kind: :execute, action_name: "create_note", confidence: 0.9}} =
               Router.route(%{text: "create a note"}, [])
    end
  end

  describe "Outcome constructors" do
    test "each kind builds the expected struct" do
      assert %Outcome{kind: :execute, action_name: "a", slots: %{"k" => 1}} =
               Outcome.execute("a", %{"k" => 1})

      assert %Outcome{kind: :clarify, shortlist: [%{id: "x"}], question: "which?"} =
               Outcome.clarify([%{id: "x"}], "which?")

      assert %Outcome{kind: :answer} = Outcome.answer()
      assert %Outcome{kind: :none} = Outcome.none()

      assert %Outcome{kind: :defer, reason: :strategy_deterministic} =
               Outcome.defer(:strategy_deterministic)
    end
  end

  describe "state contracts" do
    test "PendingClarification.expired? honors expires_at" do
      now = ~U[2026-06-16 00:00:00Z]

      future = %PendingClarification{
        thread_id: "t",
        options: [],
        expires_at: ~U[2026-06-16 00:05:00Z]
      }

      past = %PendingClarification{
        thread_id: "t",
        options: [],
        expires_at: ~U[2026-06-15 23:55:00Z]
      }

      refute PendingClarification.expired?(future, now)
      assert PendingClarification.expired?(past, now)
    end

    test "ConversationContext.empty/0 carries no prior-turn signal" do
      assert %ConversationContext{summary: "", prior_action: nil, turn_count: 0} =
               ConversationContext.empty()
    end
  end

  defp restore(key, nil) when is_atom(key), do: Application.delete_env(:allbert_assist, key)
  defp restore(key, value), do: Application.put_env(:allbert_assist, key, value)
end
