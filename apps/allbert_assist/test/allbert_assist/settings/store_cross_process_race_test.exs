defmodule AllbertAssist.Settings.StoreCrossProcessRaceTest do
  use ExUnit.Case, async: false

  @moduletag :external_runtime_serial

  alias AllbertAssist.Settings.YamlCodec

  test "separate BEAM settings transactions preserve disjoint writes" do
    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-settings-xproc-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    entered = Path.join(home, "holder-entered")
    writer_started = Path.join(home, "writer-started")
    File.mkdir_p!(home)

    on_exit(fn -> File.rm_rf!(home) end)

    holder_expression = """
    wait = fn wait, path ->
      if File.exists?(path), do: :ok, else: (Process.sleep(25); wait.(wait, path))
    end
    AllbertAssist.Settings.StoreLock.with_lock(AllbertAssist.Settings.Store.root(), fn ->
      File.write!(#{inspect(entered)}, "entered")
      wait.(wait, #{inspect(writer_started)})
      Process.sleep(1_000)
      {:ok, settings} = AllbertAssist.Settings.Store.read_user_settings()
      settings = AllbertAssist.Settings.Schema.put_dotted(settings, "intent.direct_answer_model_enabled", true)
      :ok = AllbertAssist.Settings.Store.write_atomic(
        AllbertAssist.Settings.Store.settings_path(),
        AllbertAssist.Settings.YamlCodec.encode!(settings)
      )
    end)
    """

    holder = run_external(holder_expression, home)

    wait_for!(entered)

    writer_expression = """
    File.write!(#{inspect(writer_started)}, "started")
    {:ok, _merged, _user, _diagnostics} =
      AllbertAssist.Settings.Store.put_user_setting(
        "intent.model_assist_enabled",
        true,
        %{audit?: false}
      )
    """

    writer = run_external(writer_expression, home)

    assert {"", 0} = Task.await(holder, 15_000)
    assert {"", 0} = Task.await(writer, 15_000)

    assert {:ok, settings} =
             YamlCodec.read_file(Path.join([home, "settings", "settings.yml"]))

    assert get_in(settings, ["intent", "direct_answer_model_enabled"])
    assert get_in(settings, ["intent", "model_assist_enabled"])
  end

  defp run_external(expression, home) do
    Task.async(fn ->
      System.cmd(
        "mix",
        ["run", "--no-compile", "--no-deps-check", "--no-start", "-e", expression],
        cd: File.cwd!(),
        env: [{"ALLBERT_HOME", home}, {"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )
    end)
  end

  defp wait_for!(path, attempts \\ 200)
  defp wait_for!(_path, 0), do: raise("timed out waiting for cross-process barrier")

  defp wait_for!(path, attempts) do
    if File.exists?(path) do
      :ok
    else
      Process.sleep(25)
      wait_for!(path, attempts - 1)
    end
  end
end
