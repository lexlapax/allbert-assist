defmodule AllbertAssist.Workspace.EmittersResearchTest do
  @moduledoc """
  v1.0.1 M4.2.4 — unit coverage for `Emitters.research_result/1`: the
  research-delegate completion canvas card. Best-effort delivery of an
  already-authorized result: emitted as a `scope: :canvas` `:analysis_card`
  fragment from the allowed objective-agent emitter `research.specialist`,
  with the source reduced to its HOST (no remote URLs in workspace props) and
  the body truncated inside the 512-byte fallback_text cap. Missing workspace
  context (no thread_id) skips silently.
  """

  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Objectives.AgentRegistry
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Workspace
  alias AllbertAssist.Workspace.Emitters
  alias AllbertAssist.Workspace.Fragment.Guard
  alias Jido.Signal.Bus

  # The registered research delegate agent id — allowed as a fragment emitter
  # through Guard.objective_agent_emitter?/1 (AgentRegistry lookup).
  @emitter_id "research.specialist"

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-emitters-research-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))
    Guard.reset_for_test()

    registered_here? =
      case AgentRegistry.register(@emitter_id, self(), __MODULE__) do
        {:ok, _entry} -> true
        {:error, :already_registered} -> false
      end

    on_exit(fn ->
      if registered_here?, do: AgentRegistry.unregister(@emitter_id)
      Guard.reset_for_test()
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf(home)
    end)

    :ok
  end

  test "completed research emits a host-only, truncated analysis card canvas tile" do
    assert {:ok, _subscription_id} =
             Bus.subscribe(AllbertAssist.SignalBus, "allbert.workspace.fragment.emitted")

    # > 600 chars, so the 400-char body truncation must engage.
    summary = String.duplicate("Elixir is a dynamic, functional language. ", 16)
    assert byte_size(summary) > 600

    assert :ok =
             Emitters.research_result(%{
               user_id: "alice",
               thread_id: "thr_research",
               objective_id: "obj_research_unit",
               target: "https://elixir-lang.org/docs/stable",
               summary: summary,
               sources: [
                 %{url: "https://elixir-lang.org/docs/stable", title: "Elixir Docs"},
                 %{url: "https://example.com/other", title: "Other"}
               ]
             })

    signal = receive_signal("allbert.workspace.fragment.emitted")
    envelope = signal.data.envelope

    assert envelope.id == "research_result_obj_research_unit"
    assert envelope.scope == :canvas
    assert envelope.kind == :analysis_card
    assert envelope.emitter_id == @emitter_id
    assert envelope.user_id == "alice"
    assert envelope.thread_id == "thr_research"
    assert envelope.metadata.objective_id == "obj_research_unit"

    [node] = envelope.surface.nodes
    assert node.component == :analysis_card
    assert node.props.status == "completed"
    assert node.props.objective_id == "obj_research_unit"

    # The unsafe_prop_value guard forbids remote URLs in workspace props: the
    # first source is reduced to its HOST.
    assert node.props.source == "elixir-lang.org"
    assert node.props.body =~ "Source: elixir-lang.org"
    refute node.props.body =~ "https://"
    refute node.props.source =~ "https://"

    # Truncated inside the 512-byte fallback_text cap.
    assert node.props.body =~ "…"
    assert byte_size(node.props.body) <= 500
    assert byte_size(envelope.surface.fallback_text) <= 512

    # The fragment persisted as a durable canvas tile — no drop.
    assert {:ok, tiles} = Workspace.canvas_tiles("thr_research", "alice")
    assert [tile] = Enum.filter(tiles, &(&1.kind == "analysis_card"))
    assert tile.id == "research_result_obj_research_unit"
    assert tile.metadata["emitter_id"] == @emitter_id

    persisted_props = get_in(tile.body, ["surface", "nodes", Access.at(0), "props"])
    assert persisted_props["source"] == "elixir-lang.org"
    refute inspect(tile.body) =~ "https://"
    refute inspect(tile.metadata) =~ "https://"
  end

  test "missing thread_id returns :ok and emits nothing (best-effort skip)" do
    assert {:ok, _subscription_id} =
             Bus.subscribe(AllbertAssist.SignalBus, "allbert.workspace.fragment.emitted")

    assert :ok =
             Emitters.research_result(%{
               user_id: "alice",
               objective_id: "obj_no_thread",
               summary: "A summary without a thread.",
               sources: [%{url: "https://elixir-lang.org", title: "Elixir"}]
             })

    refute_receive {:signal, %{type: "allbert.workspace.fragment.emitted"}}, 100
    assert {:ok, []} = Workspace.canvas_tiles("missing-thread", "alice")
  end

  test "nil sources emit a card without a source host" do
    assert {:ok, _subscription_id} =
             Bus.subscribe(AllbertAssist.SignalBus, "allbert.workspace.fragment.emitted")

    assert :ok =
             Emitters.research_result(%{
               user_id: "alice",
               thread_id: "thr_research_nil_sources",
               objective_id: "obj_nil_sources",
               summary: "Short summary.",
               sources: nil
             })

    envelope = receive_signal("allbert.workspace.fragment.emitted").data.envelope

    [node] = envelope.surface.nodes
    assert node.props.body == "Short summary."
    refute Map.has_key?(node.props, :source)
    refute node.props.body =~ "https://"

    assert {:ok, [tile]} = Workspace.canvas_tiles("thr_research_nil_sources", "alice")
    assert tile.kind == "analysis_card"
  end

  test "non-map payloads and empty payloads are safe" do
    assert :ok = Emitters.research_result(nil)
    assert :ok = Emitters.research_result("not a map")
    assert :ok = Emitters.research_result(%{})
  end

  defp receive_signal(type) do
    receive do
      {:signal, %{type: ^type} = signal} -> signal
      {:signal, _signal} -> receive_signal(type)
    after
      1_000 -> flunk("expected signal #{type}")
    end
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
