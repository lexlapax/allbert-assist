defmodule AllbertAssist.Workflows.LoaderTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Workflows.Loader

  setup do
    original_home = System.get_env("ALLBERT_HOME")
    original_paths_config = Application.get_env(:allbert_assist, AllbertAssist.Paths)
    home = Path.join(System.tmp_dir!(), "allbert-loader-#{System.unique_integer([:positive])}")
    System.put_env("ALLBERT_HOME", home)
    Application.put_env(:allbert_assist, AllbertAssist.Paths, home: home)
    File.mkdir_p!(Path.join(home, "workflows"))

    on_exit(fn ->
      restore_env("ALLBERT_HOME", original_home)
      restore_app_env(AllbertAssist.Paths, original_paths_config)
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  test "loads a workflow file as a string-key map", %{home: home} do
    copy_fixture!("single_step", home)

    assert {:ok, workflow} = Loader.load("single_step")
    assert workflow["id"] == "single_step"
    assert [%{"action" => "direct_answer"}] = workflow["steps"]
  end

  test "missing workflows directory lists empty with diagnostic", %{home: home} do
    File.rm_rf!(Path.join(home, "workflows"))

    assert {:ok, [], [diagnostic]} = Loader.list_workflows()
    assert diagnostic.reason == :no_workflows_dir
  end

  test "rejects malformed workflow ids and missing workflow files" do
    assert {:error, error} = Loader.load("NotOk")
    assert error.reason == :invalid_id_pattern

    assert {:error, error} = Loader.load("missing")
    assert error.reason == :workflow_not_found
  end

  test "rejects anchors before parsing", %{home: home} do
    path = Path.join([home, "workflows", "anchored.yaml"])
    File.write!(path, "id: anchored\nversion: 1\nx: &anchor 1\nsteps: []\n")

    assert {:error, error} = Loader.load("anchored")
    assert error.reason == :invalid_yaml_feature
  end

  test "rejects YAML files above configured byte cap before parsing", %{home: home} do
    path = Path.join([home, "workflows", "oversized.yaml"])
    File.write!(path, String.duplicate("a", 262_145))

    assert {:error, error} = Loader.load("oversized")
    assert error.reason == :cap_exceeded
    assert error.pointer == "/"
  end

  defp copy_fixture!(id, home) do
    File.cp!(
      Path.expand("../../fixtures/v0.44/workflows/#{id}.yaml", __DIR__),
      Path.join([home, "workflows", "#{id}.yaml"])
    )
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
