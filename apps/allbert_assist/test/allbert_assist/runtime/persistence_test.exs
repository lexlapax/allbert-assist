defmodule AllbertAssist.Runtime.PersistenceTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Paths
  alias AllbertAssist.Runtime.Persistence
  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Workspace.BodyStore
  alias AllbertAssist.Workspace.Fragment.Envelope

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-runtime-persistence-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: home)

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  test "workspace body facade preserves YAML body paths and normalization" do
    relative_path = Persistence.canvas_body_path("user 1", "thread/1", "tile:1")
    body = %{title: "Hello", nested: %{kind: :analysis_card}}

    assert relative_path == BodyStore.canvas_body_path("user 1", "thread/1", "tile:1")
    assert :ok = Persistence.write_body(relative_path, body)
    assert {:ok, read_body} = Persistence.read_body(relative_path)

    assert read_body == Persistence.normalize_body(body)
    assert read_body == BodyStore.normalize_body(body)
  end

  test "fragment body facade round-trips persisted Surface trees" do
    {:ok, envelope} =
      Envelope.new(%{
        id: "frag-test",
        emitter_id: "runtime-persistence-test",
        user_id: "user-test",
        thread_id: "thread-test",
        scope: :canvas,
        kind: :analysis_card,
        emitted_at: ~U[2026-05-22 12:00:00Z],
        surface: surface(),
        metadata: %{source: :test}
      })

    body = Persistence.encode_fragment_body(envelope)

    relative_path =
      Persistence.canvas_body_path(envelope.user_id, envelope.thread_id, envelope.id)

    assert :ok = Persistence.write_body(relative_path, body)
    assert {:ok, stored_body} = Persistence.read_body(relative_path)
    assert {:ok, decoded} = Persistence.surface_from_fragment_body(stored_body)

    assert decoded.id == envelope.surface.id
    assert decoded.app_id == envelope.surface.app_id

    assert [%Node{component: :text, props: %{"text" => "Persisted analysis"}}] =
             decoded.nodes
  end

  test "atomic write facade preserves current safe-write helper", %{home: home} do
    path = Path.join([home, "runtime", "artifact.txt"])

    assert :ok = Persistence.write_atomic(path, "artifact")
    assert File.read!(path) == "artifact"
  end

  defp surface do
    %Surface{
      id: :analysis,
      app_id: :stocksage,
      label: "Analysis",
      path: "/apps/workspace/test",
      kind: :analysis,
      status: :available,
      nodes: [
        %Node{
          id: "node-test",
          component: :text,
          props: %{text: "Persisted analysis"},
          children: [],
          bindings: []
        }
      ],
      fallback_text: "Analysis",
      metadata: %{}
    }
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
