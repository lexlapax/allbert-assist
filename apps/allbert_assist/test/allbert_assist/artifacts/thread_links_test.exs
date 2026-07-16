defmodule AllbertAssist.Artifacts.ThreadLinksTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Artifacts.MetadataIndex
  alias AllbertAssist.Artifacts.ThreadLink
  alias AllbertAssist.Conversations
  alias AllbertAssist.Paths
  alias AllbertAssist.Repo
  alias AllbertAssist.Settings

  @env_vars ["ALLBERT_HOME", "ALLBERT_HOME_DIR", "ALLBERT_SETTINGS_ROOT"]

  setup do
    original_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_artifacts_config = Application.get_env(:allbert_assist, AllbertAssist.Artifacts)

    Enum.each(@env_vars, &System.delete_env/1)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)
    Application.delete_env(:allbert_assist, AllbertAssist.Artifacts)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-artifact-thread-links-#{System.unique_integer([:positive])}"
      )

    System.put_env("ALLBERT_HOME", home)
    MetadataIndex.reset_cache!()
    Paths.ensure_home!()
    enable_artifacts!()

    on_exit(fn ->
      MetadataIndex.reset_cache!()
      File.rm_rf!(home)
      restore_env(original_env)
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Settings, original_settings_config)
      restore_app_env(AllbertAssist.Artifacts, original_artifacts_config)
    end)

    {:ok, home: home}
  end

  test "put inside a thread records a message-precise created_by link and sidecar provenance" do
    %{thread: thread, message: message, context: context, signal_id: signal_id} = thread_context()

    assert {:ok, put} =
             Runner.run(
               "put_artifact",
               %{bytes: "thread artifact", metadata: %{mime: "text/plain", origin: "test"}},
               context
             )

    sha256 = put.artifact.sha256

    assert [link] =
             Repo.all(from link in ThreadLink, where: link.artifact_sha256 == ^sha256)

    assert link.thread_id == thread.id
    assert link.message_id == message.id
    assert link.user_id == thread.user_id
    assert link.role == "created_by"
    assert link.metadata["input_signal_id"] == signal_id

    assert {:ok, metadata} = MetadataIndex.lookup(sha256)
    provenance = metadata.provenance["artifact_thread"]
    assert provenance["thread_id"] == thread.id
    assert provenance["message_id"] == message.id
    assert provenance["input_signal_id"] == signal_id
    refute Map.has_key?(provenance, "content")
  end

  test "duplicate puts are idempotent and support by-thread plus reverse lookup" do
    %{thread: thread, message: message, context: context} = thread_context()

    assert {:ok, first} =
             Runner.run(
               "put_artifact",
               %{
                 bytes: "deduped thread artifact",
                 metadata: %{mime: "text/plain", origin: "test"}
               },
               context
             )

    assert {:ok, second} =
             Runner.run(
               "put_artifact",
               %{
                 bytes: "deduped thread artifact",
                 metadata: %{mime: "text/plain", origin: "test"}
               },
               context
             )

    sha256 = first.artifact.sha256
    assert second.artifact.sha256 == sha256

    assert Repo.aggregate(
             from(link in ThreadLink, where: link.artifact_sha256 == ^sha256),
             :count
           ) == 1

    assert {:ok, listed} =
             Runner.run("list_artifacts", %{thread_id: thread.id}, context)

    assert listed.status == :completed
    assert listed.count == 1
    assert [%{sha256: ^sha256}] = listed.artifacts

    assert {:ok, reverse} = Runner.run("artifact_threads", %{sha256: sha256}, context)

    assert reverse.status == :completed
    assert reverse.count == 1

    assert [
             %{
               sha256: ^sha256,
               thread_id: thread_id,
               message_id: message_id,
               role: "created_by"
             }
           ] = reverse.links

    assert thread_id == thread.id
    assert message_id == message.id
  end

  test "unresolved input signals create thread-level links with signal metadata" do
    {:ok, thread} = Conversations.create_general_thread("alice", "Artifact fallback")
    context = context(thread, "sig-missing-row")

    assert {:ok, put} =
             Runner.run(
               "put_artifact",
               %{bytes: "thread-level artifact", metadata: %{mime: "text/plain"}},
               context
             )

    sha256 = put.artifact.sha256

    assert [link] =
             Repo.all(from link in ThreadLink, where: link.artifact_sha256 == ^sha256)

    assert link.thread_id == thread.id
    assert link.message_id == nil
    assert link.metadata["input_signal_id"] == "sig-missing-row"

    assert {:ok, metadata} = MetadataIndex.lookup(sha256)
    assert metadata.provenance["artifact_thread"]["message_id"] == nil
    assert metadata.provenance["artifact_thread"]["input_signal_id"] == "sig-missing-row"
  end

  test "thread filter does not bypass artifact_read permission" do
    %{thread: thread, context: context} = thread_context()

    assert {:ok, put} =
             Runner.run(
               "put_artifact",
               %{bytes: "permission artifact", metadata: %{mime: "text/plain"}},
               context
             )

    assert Repo.aggregate(
             from(link in ThreadLink, where: link.artifact_sha256 == ^put.artifact.sha256),
             :count
           ) == 1

    assert {:ok, _setting} = Settings.put("permissions.artifact_read", "denied", %{audit?: false})

    assert {:ok, denied} =
             Runner.run("list_artifacts", %{thread_id: thread.id}, context)

    assert denied.status == :denied
    assert denied.error == :permission_denied
    assert denied.permission_decision.permission == :artifact_read
  end

  defp thread_context do
    signal_id = "sig-artifact-#{System.unique_integer([:positive])}"
    {:ok, thread} = Conversations.create_general_thread("alice", "Artifact provenance")

    {:ok, message} =
      Conversations.append_user_message(thread, "store this", input_signal_id: signal_id)

    %{thread: thread, message: message, context: context(thread, signal_id), signal_id: signal_id}
  end

  defp context(thread, signal_id) do
    %{
      actor: thread.user_id,
      channel: :test,
      request: %{
        operator_id: thread.user_id,
        user_id: thread.user_id,
        thread_id: thread.id,
        session_id: "sess-artifacts",
        input_signal_id: signal_id
      }
    }
  end

  defp enable_artifacts! do
    assert {:ok, _setting} = Settings.put("artifacts.enabled", true, %{audit?: false})
    assert {:ok, _setting} = Settings.put("artifacts.retention_enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("permissions.artifact_read", "allowed", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("permissions.artifact_write", "allowed", %{audit?: false})
  end

  defp restore_env(env) do
    Enum.each(env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
