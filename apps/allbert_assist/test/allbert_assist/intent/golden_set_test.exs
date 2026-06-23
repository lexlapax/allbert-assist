defmodule AllbertAssist.Intent.GoldenSetTest do
  @moduledoc """
  v0.54 M9.2 — deterministic, model-free guard over the golden-set anchors.

  This is the CI-safe consistency check (no Ollama): the fixture is well-formed,
  ids are unique, and every `:execute` anchor targets a descriptor-backed (i.e.
  actually routable) action. The live accuracy numbers come from
  `mix allbert.intent bench`, not this test.
  """
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  alias AllbertAssist.Extensions.Registry, as: Ext
  alias AllbertAssist.Intent.Bench
  alias AllbertAssist.Intent.Router.FakeRouter
  alias AllbertAssist.Intent.Router.Outcome
  alias AllbertAssist.TestSupport.ProviderPreconditions

  setup do
    ProviderPreconditions.ensure_stocksage_descriptors!()
    ProviderPreconditions.ensure_notes_files_descriptors!()
    ProviderPreconditions.ensure_browser_descriptors!()
    :ok
  end

  test "fixture loads and every case is well-formed" do
    cases = Bench.load_cases()
    assert length(cases) >= 25

    for c <- cases do
      assert is_binary(c.id) and c.id != ""
      assert is_binary(c.category)
      assert is_binary(c.utterance) and c.utterance != ""
      assert c.expected.kind in [:execute, :clarify, :answer, :none]
      if c.expected.kind == :execute, do: assert(is_binary(c.expected.action))
    end
  end

  test "anchor ids are unique" do
    ids = Bench.load_cases() |> Enum.map(& &1.id)
    assert length(ids) == length(Enum.uniq(ids))
  end

  test "every :execute anchor targets a descriptor-backed (routable) action" do
    descriptor_actions =
      Ext.registered_intent_descriptors() |> MapSet.new(& &1.action_name)

    for %{expected: %{kind: :execute, action: action}} = c <- Bench.load_cases() do
      assert MapSet.member?(descriptor_actions, action),
             "#{c.id}: expected execute action #{inspect(action)} has no descriptor (not routable)"
    end
  end

  test "live bench forces two-stage router strategy even under deterministic test config" do
    original = %{
      router: Application.get_env(:allbert_assist, :intent_router),
      outcome: Application.get_env(:allbert_assist, :intent_router_fake_outcome),
      override: Application.get_env(:allbert_assist, :intent_router_strategy_override)
    }

    fixture =
      Path.join(
        System.tmp_dir!(),
        "allbert-bench-strategy-#{System.unique_integer([:positive])}.terms"
      )

    on_exit(fn ->
      restore_env(:intent_router, original.router)
      restore_env(:intent_router_fake_outcome, original.outcome)
      restore_env(:intent_router_strategy_override, original.override)
      File.rm(fixture)
    end)

    File.write!(
      fixture,
      inspect(
        [
          %{
            id: "bench-strategy-001",
            category: "notes",
            utterance: "create a note",
            expected: %{kind: :execute, action: "write_note"}
          }
        ],
        pretty: true,
        limit: :infinity
      )
    )

    Application.put_env(:allbert_assist, :intent_router_strategy_override, :deterministic)
    Application.put_env(:allbert_assist, :intent_router, FakeRouter)

    Application.put_env(
      :allbert_assist,
      :intent_router_fake_outcome,
      Outcome.execute("write_note")
    )

    assert %{
             cases: [result],
             summary: %{total: 1, passed: 1, accuracy: 1.0, router_strategy: :two_stage_local}
           } =
             Bench.run(fixture: fixture)

    assert result.actual.kind == :execute

    assert Application.get_env(:allbert_assist, :intent_router_strategy_override) ==
             :deterministic
  end

  test "bench fixture loader rejects executable fixture content without running it" do
    fixture =
      Path.join(
        System.tmp_dir!(),
        "allbert-bench-executable-#{System.unique_integer([:positive])}.terms"
      )

    env_key = "ALLBERT_BENCH_EXECUTED"
    original_env = System.get_env(env_key)
    System.delete_env(env_key)

    on_exit(fn ->
      File.rm(fixture)

      if original_env do
        System.put_env(env_key, original_env)
      else
        System.delete_env(env_key)
      end
    end)

    File.write!(
      fixture,
      """
      [
        System.put_env("#{env_key}", "yes")
      ]
      """
    )

    assert_raise ArgumentError, ~r/not data-only literal terms/, fn ->
      Bench.load_cases(fixture: fixture)
    end

    refute System.get_env(env_key)
  end

  defp restore_env(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore_env(key, value), do: Application.put_env(:allbert_assist, key, value)
end
