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
end
