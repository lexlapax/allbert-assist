defmodule AllbertAssist.Coding.M1ReadSearchActionsTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Coding.PathPolicy
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

    File.mkdir_p!(Path.join(workspace, "lib/private"))
    File.mkdir_p!(Path.join(workspace, "notes"))
    File.mkdir_p!(outside)

    File.write!(Path.join(workspace, ".gitignore"), "ignored.txt\n")
    File.write!(Path.join(workspace, ".allbertignore"), "lib/private/\n")
    File.write!(Path.join(workspace, "README.md"), "hello\nneedle visible\nthird\n")
    File.write!(Path.join(workspace, "ignored.txt"), "needle ignored\n")

    File.write!(
      Path.join(workspace, "lib/code.ex"),
      "defmodule Demo do\n  @token \"sk-secretABC123\"\n  def needle, do: :ok\nend\n"
    )

    File.write!(Path.join(workspace, "lib/private/secret.ex"), "needle private\n")
    File.write!(Path.join(workspace, "notes/todo.txt"), "needle todo\n")
    File.write!(Path.join(workspace, "binary.dat"), <<0, 1, 2, 3>>)
    File.write!(Path.join(outside, "outside.txt"), "outside secret\n")
    File.ln_s!(Path.join(outside, "outside.txt"), Path.join(workspace, "escape.txt"))

    System.put_env("ALLBERT_HOME", home)

    on_exit(fn ->
      File.rm_rf!(home)
      restore_env(original_env)
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Settings, original_settings_config)
    end)

    {:ok, home: home, workspace: workspace}
  end

  test "M1 Settings Central keys are safe writable and validate" do
    for {key, value} <- [
          {"coding.workspace.cwd_jail", "."},
          {"coding.read.default_limit", 2_000},
          {"coding.read.max_bytes", 120_000},
          {"coding.search.max_results", 100},
          {"coding.search.max_output_bytes", 120_000},
          {"coding.search.respect_gitignore", true},
          {"coding.search.respect_allbertignore", true}
        ] do
      assert key in Schema.safe_write_keys()
      assert %{writable?: true, sensitive?: false} = Schema.schema()[key]
      assert :ok = Schema.validate_key_value(key, value)
    end
  end

  test "read grep and glob are registered internal coding capabilities" do
    agent_action_names = Enum.map(Registry.agent_modules(), & &1.name())

    for name <- ["read", "grep", "glob"] do
      assert {:ok, capability} = Registry.capability(name)
      assert capability.permission == :coding_file_read
      assert capability.exposure == :internal
      refute name in agent_action_names
    end
  end

  test "read resolves through Runner, chunks text, redacts content, and omits absolute paths", %{
    workspace: workspace
  } do
    assert {:ok, response} =
             Runner.run(
               "read",
               %{path: "lib/code.ex", offset: 1, limit: 2},
               context(workspace)
             )

    assert response.status == :completed
    assert response.runner_metadata.action_name == "read"
    assert response.runner_metadata.permission_decision.permission == :coding_file_read
    assert response.actions |> hd() |> Map.fetch!(:permission) == :coding_file_read
    assert response.file.relative_path == "lib/code.ex"
    assert response.file.returned_lines == 2
    assert response.model_payload =~ "@token \"[REDACTED]\""
    refute response.model_payload =~ "sk-secretABC123"
    refute response.model_payload =~ workspace
  end

  test "read denies path traversal, symlink escape, and binary files", %{workspace: workspace} do
    assert {:ok, traversal} =
             Runner.run("read", %{path: "../outside/outside.txt"}, context(workspace))

    assert traversal.status == :denied
    assert traversal.actions |> hd() |> Map.fetch!(:denial_reason) == :path_outside_cwd_jail

    assert {:ok, symlink} = Runner.run("read", %{path: "escape.txt"}, context(workspace))
    assert symlink.status == :denied
    assert symlink.actions |> hd() |> Map.fetch!(:denial_reason) == :path_outside_cwd_jail

    assert {:ok, binary} = Runner.run("read", %{path: "binary.dat"}, context(workspace))
    assert binary.status == :denied
    assert binary.actions |> hd() |> Map.fetch!(:denial_reason) == :binary_file
  end

  test "path policy exposes the shared bounded read substrate for later @file use", %{
    workspace: workspace
  } do
    assert {:ok, file} =
             PathPolicy.read_file("README.md", context(workspace), offset: 0, limit: 1)

    assert file.relative_path == "README.md"
    assert file.content == "hello\n"
    assert file.returned_lines == 1
    assert file.truncated? == true
  end

  test "grep honors ignore policy, caps output, and redacts matches", %{workspace: workspace} do
    assert {:ok, response} =
             Runner.run(
               "grep",
               %{pattern: "needle", max_results: 3, max_output_bytes: 4_096},
               context(workspace)
             )

    assert response.status == :completed
    assert response.grep.match_count == 3

    assert Enum.map(response.grep.matches, & &1.path) == [
             "README.md",
             "lib/code.ex",
             "notes/todo.txt"
           ]

    refute response.model_payload =~ "ignored.txt"
    refute response.model_payload =~ "lib/private/secret.ex"
    refute response.model_payload =~ workspace

    assert {:ok, capped} =
             Runner.run("grep", %{pattern: "needle", max_results: 1}, context(workspace))

    assert capped.status == :completed
    assert capped.grep.truncated?
    assert capped.grep.match_count == 1
  end

  test "glob is cwd-jailed, ignore-aware, bounded, and relative", %{workspace: workspace} do
    assert {:ok, response} =
             Runner.run("glob", %{pattern: "**/*.{ex,txt}", max_results: 10}, context(workspace))

    assert response.status == :completed
    paths = Enum.map(response.glob.matches, & &1.path)
    assert "lib/code.ex" in paths
    assert "notes/todo.txt" in paths
    refute "ignored.txt" in paths
    refute "lib/private/secret.ex" in paths
    refute Enum.any?(paths, &String.starts_with?(&1, "/"))
    refute response.model_payload =~ workspace

    assert {:ok, escaped} = Runner.run("glob", %{pattern: "../*.txt"}, context(workspace))
    assert escaped.status == :denied
    assert escaped.actions |> hd() |> Map.fetch!(:denial_reason) == :glob_path_escape
  end

  test "permission setting can block read tools before filesystem access", %{workspace: workspace} do
    assert {:ok, _setting} =
             Settings.put("permissions.coding_file_read", "denied", %{audit?: false})

    assert {:ok, response} = Runner.run("read", %{path: "README.md"}, context(workspace))

    assert response.status == :denied
    assert response.permission_decision.decision == :denied
    assert response.actions |> hd() |> Map.fetch!(:execution) == :not_started
  end

  defp context(workspace) do
    %{
      actor: "local",
      operator_id: "local",
      user_id: "local",
      channel: %{name: :tui, trust: :local},
      surface: :tui,
      cwd_jail: workspace,
      coding: %{cwd_jail: workspace, pi_mode_enabled: true, trusted_operator_id: "local"},
      session: %{main?: true}
    }
  end

  defp temp_path(prefix) do
    Path.join(
      System.tmp_dir!(),
      "allbert-v057-m1-#{prefix}-#{System.unique_integer([:positive])}"
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
