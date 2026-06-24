defmodule AllbertAssist.Coding.M2WriteEditActionsTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Schema

  @env_vars [
    "ALLBERT_HOME",
    "ALLBERT_HOME_DIR",
    "ALLBERT_SETTINGS_ROOT",
    "ALLBERT_SETTINGS_MASTER_KEY"
  ]

  setup do
    original_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    Enum.each(@env_vars, &System.delete_env/1)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)

    home = temp_path("home")
    workspace = Path.join(home, "workspace")
    outside = Path.join(home, "outside")

    File.mkdir_p!(Path.join(workspace, "lib"))
    File.mkdir_p!(outside)

    File.write!(Path.join(workspace, "lib/code.ex"), "alpha\nneedle\nomega\n")
    File.write!(Path.join(workspace, "lib/repeated.txt"), "same\nsame\n")
    File.write!(Path.join(workspace, "binary.dat"), <<0, 1, 2, 3>>)
    File.write!(Path.join(workspace, "existing.txt"), "already here\n")
    File.write!(Path.join(outside, "outside.txt"), "outside secret\n")
    File.ln_s!(Path.join(outside, "outside.txt"), Path.join(workspace, "escape.txt"))
    File.ln_s!(outside, Path.join(workspace, "outlink"))

    System.put_env("ALLBERT_HOME", home)

    on_exit(fn ->
      File.rm_rf!(home)
      restore_env(original_env)
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Settings, original_settings_config)
    end)

    {:ok, home: home, workspace: workspace}
  end

  test "M2 Settings Central keys are safe writable and validate" do
    for {key, value} <- [
          {"coding.write.max_bytes", 120_000},
          {"coding.edit.max_replacements", 1},
          {"permissions.coding_file_write", "needs_confirmation"}
        ] do
      assert key in Schema.safe_write_keys()
      assert %{writable?: true, sensitive?: false} = Schema.schema()[key]
      assert :ok = Schema.validate_key_value(key, value)
    end
  end

  test "write creates a confirmation, exposes redacted split payloads, and mutates only after approval",
       %{workspace: workspace} do
    target = Path.join(workspace, "new_note.txt")
    content = "hello\nsafe content\n"

    assert {:ok, response} =
             Runner.run(
               "write",
               %{path: "new_note.txt", content: content},
               context(workspace)
             )

    assert response.status == :needs_confirmation
    assert response.permission_decision.decision == :needs_confirmation
    assert response.confirmation_id
    refute File.exists?(target)
    assert response.model_payload =~ "--- /dev/null"

    assert {:ok, approval} =
             Runner.run(
               "approve_confirmation",
               %{id: response.confirmation_id},
               context(workspace)
             )

    assert approval.status == :completed
    assert File.read!(target) == content

    assert {:ok, secret_response} =
             Runner.run(
               "write",
               %{path: "secret_note.txt", content: "hello\nsk-secretABC123\n"},
               context(workspace)
             )

    assert secret_response.status == :needs_confirmation
    assert secret_response.model_payload =~ "[REDACTED]"
    refute secret_response.model_payload =~ "sk-secretABC123"
    assert get_in(secret_response.confirmation, ["resume_params_ref", "content"]) == "[REDACTED]"
    refute File.exists?(Path.join(workspace, "secret_note.txt"))
  end

  test "edit creates a confirmation, redacts exact-match strings, and applies after approval",
       %{workspace: workspace} do
    path = Path.join(workspace, "lib/code.ex")
    old_text = "needle\n"
    new_text = "needle safe edit\n"

    assert {:ok, response} =
             Runner.run(
               "edit",
               %{path: "lib/code.ex", old_text: old_text, new_text: new_text},
               context(workspace)
             )

    assert response.status == :needs_confirmation
    assert File.read!(path) == "alpha\nneedle\nomega\n"
    assert response.model_payload =~ "exact replacements=1"
    assert get_in(response.confirmation, ["resume_params_ref", "old_text"]) == "[REDACTED]"
    assert get_in(response.confirmation, ["resume_params_ref", "new_text"]) == "[REDACTED]"

    assert {:ok, approval} =
             Runner.run(
               "approve_confirmation",
               %{id: response.confirmation_id},
               context(workspace)
             )

    assert approval.status == :completed
    assert File.read!(path) == "alpha\nneedle safe edit\nomega\n"

    assert {:ok, secret_response} =
             Runner.run(
               "edit",
               %{
                 path: "lib/code.ex",
                 old_text: "needle safe edit",
                 new_text: "needle sk-secretABC123"
               },
               context(workspace)
             )

    assert secret_response.status == :needs_confirmation
    assert secret_response.model_payload =~ "[REDACTED]"
    refute secret_response.model_payload =~ "sk-secretABC123"
  end

  test "write refuses traversal, symlink parent escape, and overwrite", %{workspace: workspace} do
    for {path, reason} <- [
          {"../outside/new.txt", :path_outside_cwd_jail},
          {"outlink/new.txt", :path_outside_cwd_jail},
          {"existing.txt", :file_exists}
        ] do
      assert {:ok, response} =
               Runner.run("write", %{path: path, content: "x\n"}, context(workspace))

      assert response.status == :denied
      assert response.actions |> hd() |> Map.fetch!(:denial_reason) == reason
    end
  end

  test "edit refuses symlink escape, binary files, missing matches, and over-broad matches",
       %{workspace: workspace} do
    for {path, old_text, reason} <- [
          {"escape.txt", "outside", :path_outside_cwd_jail},
          {"binary.dat", "x", :binary_file},
          {"lib/code.ex", "missing", :exact_match_not_found},
          {"lib/repeated.txt", "same", {:too_many_exact_matches, 2, 1}}
        ] do
      assert {:ok, response} =
               Runner.run(
                 "edit",
                 %{path: path, old_text: old_text, new_text: "replacement"},
                 context(workspace)
               )

      assert response.status == :denied
      assert response.actions |> hd() |> Map.fetch!(:denial_reason) == reason
    end
  end

  test "permission denial blocks write before filesystem validation", %{workspace: workspace} do
    assert {:ok, _setting} =
             Settings.put("permissions.coding_file_write", "denied", %{audit?: false})

    assert {:ok, response} =
             Runner.run(
               "write",
               %{path: "../outside/new.txt", content: "should not inspect path\n"},
               context(workspace)
             )

    assert response.status == :denied
    assert response.permission_decision.decision == :denied
    assert response.actions |> hd() |> Map.fetch!(:execution) == :not_started
    refute Map.has_key?(response.actions |> hd(), :denial_reason)
  end

  defp context(workspace) do
    %{
      actor: "local",
      operator_id: "local",
      user_id: "local",
      channel: %{name: :tui, trust: :local},
      surface: :tui,
      cwd_jail: workspace,
      coding: %{cwd_jail: workspace}
    }
  end

  defp temp_path(prefix) do
    Path.join(
      System.tmp_dir!(),
      "allbert-v057-m2-#{prefix}-#{System.unique_integer([:positive])}"
    )
  end

  defp restore_env(original_env) do
    Enum.each(original_env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
