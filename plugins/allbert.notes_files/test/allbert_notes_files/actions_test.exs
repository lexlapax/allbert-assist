defmodule AllbertNotesFiles.ActionsTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Memory
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Settings

  setup do
    original_confirmations = Application.get_env(:allbert_assist, Confirmations)
    original_memory = Application.get_env(:allbert_assist, Memory)
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_settings = Application.get_env(:allbert_assist, Settings)
    original_plugins = PluginRegistry.registered_plugins()
    app_registered? = AppRegistry.known_app_id?(:notes_files)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-notes-files-actions-#{System.unique_integer([:positive])}"
      )

    notes_root = Path.join(root, "notes")

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    Application.put_env(:allbert_assist, Memory, root: Path.join(root, "memory"))
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    PluginRegistry.clear()
    assert {:ok, "allbert.notes_files"} = PluginRegistry.register_module(AllbertNotesFiles.Plugin)

    unless app_registered? do
      assert {:ok, :notes_files} = AppRegistry.register(AllbertNotesFiles.App)
    end

    assert {:ok, _setting} =
             Settings.put("permissions.notes_file_write", "needs_confirmation", %{audit?: false})

    on_exit(fn ->
      restore_env(Confirmations, original_confirmations)
      restore_env(Memory, original_memory)
      restore_env(Paths, original_paths)
      restore_env(Settings, original_settings)
      PluginRegistry.clear()
      Enum.each(original_plugins, &PluginRegistry.register_entry/1)
      unless app_registered?, do: AppRegistry.unregister(:notes_files)
      File.rm_rf!(root)
    end)

    File.mkdir_p!(notes_root)
    {:ok, root: root, notes_root: notes_root}
  end

  test "search_notes and read_note are read-only and resource-referenced", %{notes_root: notes_root} do
    File.write!(Path.join(notes_root, "onboarding.md"), "# Onboarding\n\nBring the checklist.")
    File.write!(Path.join(notes_root, "scratch.txt"), "Temporary note.")

    assert {:ok, search} =
             Runner.run("search_notes", %{query: "onboarding", limit: 10}, context())

    assert search.status == :completed
    assert [%{title: "Onboarding", relative_path: "onboarding.md"} = note] = search.notes
    assert note.resource_ref.operation_class == :read_local_path

    assert [%{operation_class: :read_local_path, scope: %{kind: :directory_subtree}}] =
             search.resource_refs

    assert {:ok, read} = Runner.run("read_note", %{path: "onboarding.md"}, context())
    assert read.status == :completed
    assert read.note.body =~ "Bring the checklist."
    assert [%{operation_class: :read_local_path, access_mode: :read}] = read.resource_refs
  end

  test "read_note rejects paths outside the configured notes root", %{notes_root: notes_root} do
    File.write!(Path.join(notes_root, "safe.md"), "# Safe\n\nInside root.")

    assert {:ok, response} = Runner.run("read_note", %{path: "../outside.md"}, context())

    assert response.status == :error
    assert response.error == :path_outside_notes_root
  end

  test "write_note creates confirmation before writing and approved resume writes file", %{
    root: root,
    notes_root: notes_root
  } do
    target_path = Path.join(notes_root, "scratch.md")

    assert {:ok, pending} =
             Runner.run("write_note", %{title: "Scratch", body: "hello"}, context())

    assert pending.status == :needs_confirmation
    assert pending.permission_decision.decision == :needs_confirmation
    refute File.exists?(target_path)

    assert {:ok, record} = Confirmations.read(pending.confirmation_id)
    assert record["target_action"]["name"] == "write_note"
    assert record["target_permission"] == "notes_file_write"
    assert record["target_execution_mode"] == "notes_file_write"
    assert record["params_summary"]["app_id"] == "notes_files"

    assert [ref] = record["params_summary"]["resource_refs"]
    assert ref["operation_class"] == "write_local_path"
    assert ref["access_mode"] == "write"
    assert ref["downstream_consumer"] == "notes_files"

    assert {:ok, approved} =
             Runner.run(
               "approve_confirmation",
               %{id: pending.confirmation_id, reason: "test"},
               context()
             )

    assert approved.status == :completed
    assert approved.confirmation["status"] == "approved"
    assert File.read!(target_path) == "# Scratch\n\nhello\n"

    target_result = approved.confirmation["operator_resolution"]["target_result"]
    assert target_result["relative_path"] == "scratch.md"
    assert target_result["status"] == "written"
    assert memory_notes(root) == []
  end

  test "denied notes_file_write policy prevents confirmation and write", %{notes_root: notes_root} do
    assert {:ok, _setting} =
             Settings.put("permissions.notes_file_write", "denied", %{audit?: false})

    assert {:ok, response} =
             Runner.run("write_note", %{title: "Denied", body: "nope"}, context())

    assert response.status == :denied
    assert Confirmations.list(status: :pending) == []
    refute File.exists?(Path.join(notes_root, "denied.md"))
  end

  defp context do
    %{
      active_app: :notes_files,
      actor: "local",
      channel: :test,
      surface: "notes_files_test",
      request: %{
        active_app: :notes_files,
        operator_id: "local",
        channel: :test
      }
    }
  end

  defp memory_notes(root) do
    root
    |> Path.join("memory/notes")
    |> case do
      path ->
        if File.dir?(path) do
          path
          |> File.ls!()
          |> Enum.reject(&String.starts_with?(&1, "."))
        else
          []
        end
    end
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
