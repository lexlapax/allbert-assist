defmodule AllbertAssist.Workspace.FragmentTest do
  use AllbertAssist.DataCase, async: false

  import ExUnit.CaptureLog

  alias AllbertAssist.Objectives.AgentRegistry
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Workspace
  alias AllbertAssist.Workspace.Fragment
  alias AllbertAssist.Workspace.Fragment.Envelope
  alias AllbertAssist.Workspace.Fragment.Guard
  alias AllbertAssist.Workspace.Fragment.SigningSecret
  alias Jido.Signal
  alias Jido.Signal.Bus

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    home =
      Path.join(System.tmp_dir!(), "allbert-fragment-test-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))
    Guard.reset_for_test()

    on_exit(fn ->
      Guard.reset_for_test()
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  test "emits a valid signed fragment envelope" do
    assert {:ok, _subscription_id} =
             Bus.subscribe(AllbertAssist.SignalBus, "allbert.workspace.fragment.emitted")

    envelope = signed_envelope()

    assert :ok = Fragment.emit(envelope)

    assert_receive {:signal, signal}, 1_000
    assert signal.type == "allbert.workspace.fragment.emitted"
    assert signal.data.envelope.id == envelope.id
    assert signal.data.user_id == envelope.user_id
    assert signal.data.thread_id == envelope.thread_id

    assert {:ok, [tile]} = Workspace.canvas_tiles(envelope.thread_id, envelope.user_id)
    assert tile.id == envelope.id
  end

  test "duplicate same-body fragments are idempotent" do
    envelope = signed_envelope(%{id: "frag_duplicate_same"})

    assert :ok = Fragment.emit(envelope)
    assert :ok = Fragment.emit(envelope)

    assert {:ok, [tile]} = Workspace.canvas_tiles(envelope.thread_id, envelope.user_id)
    assert tile.id == envelope.id
  end

  test "duplicate different-body fragments fail without overwriting stored body" do
    first =
      signed_envelope(%{
        id: "frag_duplicate_different",
        surface:
          valid_surface([%Node{id: "fragment-text", component: :text, props: %{text: "first"}}])
      })

    second =
      signed_envelope(%{
        id: first.id,
        user_id: first.user_id,
        thread_id: first.thread_id,
        surface:
          valid_surface([%Node{id: "fragment-text", component: :text, props: %{text: "second"}}])
      })

    assert :ok = Fragment.emit(first)
    assert {:error, :fragment_body_conflict} = Fragment.emit(second)

    assert {:ok, [tile]} = Workspace.canvas_tiles(first.thread_id, first.user_id)
    assert tile.body["surface"]["nodes"] |> List.first() |> get_in(["props", "text"]) == "first"
  end

  test "rejects invalid envelope shape and emits a bounded dropped signal" do
    assert {:ok, _subscription_id} =
             Bus.subscribe(AllbertAssist.SignalBus, "allbert.workspace.fragment.dropped")

    log =
      capture_log([level: :warning], fn ->
        assert {:error, :invalid_envelope} = Fragment.emit(%Envelope{})
      end)

    assert log =~ "workspace fragment dropped"
    assert log =~ "reason=:invalid_envelope"

    assert_receive {:signal,
                    %Signal{
                      type: "allbert.workspace.fragment.dropped",
                      data: %{reason: :invalid_envelope, fragment_id: nil}
                    }},
                   1_000
  end

  test "rejects unsigned envelopes as signature invalid" do
    assert {:ok, unsigned} = Envelope.new(valid_attrs())

    assert {:error, :signature_invalid} = Fragment.emit(unsigned)
  end

  test "rejects envelopes signed with the wrong secret" do
    assert {:ok, envelope} = Envelope.sign(valid_attrs(), "not-the-runtime-secret")

    assert {:error, :signature_invalid} = Fragment.emit(envelope)
  end

  test "rejects surfaces with unknown catalog components" do
    envelope =
      signed_envelope(%{
        surface: valid_surface([%Node{id: "bad-node", component: :unknown_component}])
      })

    assert {:error, :surface_invalid} = Fragment.emit(envelope)
  end

  test "rejects emitters outside the action and objective-agent allow-list" do
    envelope = signed_envelope(%{emitter_id: "unknown-emitter"})

    assert {:error, :emitter_not_allowed} = Fragment.emit(envelope)
  end

  test "allows boot-registered action emitters by module id and action name" do
    assert MapSet.member?(
             Guard.action_emitter_ids(),
             "AllbertAssist.Actions.Intent.DirectAnswer"
           )

    assert MapSet.member?(Guard.action_emitter_ids(), "direct_answer")

    assert :ok =
             Fragment.emit(
               signed_envelope(%{emitter_id: "AllbertAssist.Actions.Intent.DirectAnswer"})
             )

    assert :ok = Fragment.emit(signed_envelope(%{emitter_id: "direct_answer", user_id: "other"}))
  end

  test "allows currently registered objective delegate emitters" do
    id = "objective-agent-#{System.unique_integer([:positive])}"
    assert {:ok, _entry} = AgentRegistry.register(id, self(), __MODULE__)

    on_exit(fn -> AgentRegistry.unregister(id) end)

    assert :ok = Fragment.emit(signed_envelope(%{emitter_id: id}))
  end

  test "enforces the configured per-emitter user rate limit" do
    assert {:ok, _setting} =
             Settings.put("workspace.fragment.rate_limit_per_second", 1, %{audit?: false})

    envelope = signed_envelope()

    assert :ok = Fragment.emit(envelope)
    assert {:error, :rate_limited} = Fragment.emit(envelope)
  end

  test "enforces the configured receiver rate limit independently" do
    assert {:ok, _setting} =
             Settings.put("workspace.fragment.receiver_rate_limit_per_second", 1, %{
               audit?: false
             })

    envelope = signed_envelope()
    assert {:ok, signal} = fragment_signal(envelope)

    assert {:ok, ^envelope} = Fragment.validate_received(signal)
    assert {:error, :rate_limited} = Fragment.validate_received(signal)
  end

  test "accepts fragments signed with the previous secret during rotation overlap" do
    envelope = signed_envelope()

    %{previous_fingerprint: previous_fingerprint, previous_expires_at: previous_expires_at} =
      SigningSecret.rotate!()

    assert is_binary(previous_fingerprint)
    assert DateTime.compare(previous_expires_at, DateTime.utc_now()) == :gt
    assert :ok = Fragment.emit(envelope)
  end

  test "enforces the configured payload size cap" do
    assert {:ok, _setting} =
             Settings.put("workspace.fragment.payload_max_bytes", 1024, %{audit?: false})

    envelope =
      signed_envelope(%{
        metadata: %{body: String.duplicate("x", 3_000)}
      })

    assert {:error, :payload_too_large} = Fragment.emit(envelope)
  end

  test "returns invalid envelope for non-envelope input" do
    assert {:error, :invalid_envelope} = Fragment.emit(%{surface: valid_surface()})
  end

  defp signed_envelope(attrs \\ %{}) do
    secret = SigningSecret.ensure!()
    attrs = Map.merge(valid_attrs(), attrs)
    assert {:ok, envelope} = Envelope.sign(attrs, secret)
    envelope
  end

  defp fragment_signal(envelope) do
    Signal.new(
      "allbert.workspace.fragment.emitted",
      %{
        user_id: envelope.user_id,
        thread_id: envelope.thread_id,
        envelope: envelope
      },
      source: "/allbert/workspace/test"
    )
  end

  defp valid_attrs do
    %{
      surface: valid_surface(),
      emitter_id: "AllbertAssist.Actions.Intent.DirectAnswer",
      user_id: "user-#{System.unique_integer([:positive])}",
      thread_id: "thread-#{System.unique_integer([:positive])}",
      scope: :canvas,
      kind: :text,
      emitted_at: ~U[2026-05-18 00:00:00Z]
    }
  end

  defp valid_surface(
         nodes \\ [%Node{id: "fragment-text", component: :text, props: %{text: "hello"}}]
       ) do
    %Surface{
      id: :fragment,
      app_id: :allbert,
      label: "Fragment",
      path: "/agent",
      kind: :canvas,
      status: :available,
      nodes: nodes,
      fallback_text: "Fragment fallback"
    }
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
