defmodule AllbertAssist.CLI.TuiTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  import ExUnit.CaptureIO

  alias AllbertAssist.CLI.FirstRun
  alias AllbertAssist.CLI.Tui
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-cli-tui-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)

    on_exit(fn ->
      if original_paths_config,
        do: Application.put_env(:allbert_assist, Paths, original_paths_config),
        else: Application.delete_env(:allbert_assist, Paths)

      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "refuses to launch before Home is initialized" do
    output =
      capture_io(:stderr, fn ->
        assert {:error, {:first_run_not_ready, :home_missing}} = Tui.readiness_guard()
      end)

    assert output =~ "Allbert TUI is waiting for setup."
    assert output =~ "allbert onboard"
  end

  test "refuses to launch when onboarding is complete but no model path is ready", %{root: root} do
    with_no_model_provider_env(fn ->
      File.mkdir_p!(Path.join([root, "db"]))
      File.write!(Path.join([root, "db", "allbert.sqlite3"]), "x")
      FirstRun.mark_onboarding_complete()
      FirstRun.mark_profile_reviewed()

      assert {:ok, _} =
               Settings.put(
                 "providers.local_ollama.base_url",
                 "http://127.0.0.1:1/v1",
                 %{audit?: false}
               )

      output =
        capture_io(:stderr, fn ->
          assert {:error, {:first_run_not_ready, :first_model_not_ready}} =
                   Tui.readiness_guard()
        end)

      assert output =~ "No local model runtime is running yet."
      assert output =~ "workspace:models"
      refute output =~ "runtime_missing"
    end)
  end

  test "packaged preflight boots registries before checking a configured local endpoint", %{
    root: root
  } do
    {port, server} = start_ollama_server()
    database_path = Path.join([root, "db", "allbert.sqlite3"])

    File.mkdir_p!(Path.join(root, "db"))
    File.touch!(database_path)
    FirstRun.mark_onboarding_complete()
    FirstRun.mark_profile_reviewed()

    assert {:ok, _} =
             Settings.put(
               "providers.local_ollama.base_url",
               "http://127.0.0.1:#{port}/v1",
               %{audit?: false}
             )

    expression = """
    Application.delete_env(:allbert_assist, AllbertAssist.Paths)
    System.put_env("ALLBERT_HOME", #{inspect(root)})
    Application.delete_env(:allbert_assist, :first_model_state_override)
    result = AllbertAssist.CLI.Tui.prepare()
    IO.puts("tui_prepare=\#{inspect(result)}")
    """

    migration_expression = """
    Application.delete_env(:allbert_assist, AllbertAssist.Paths)
    System.put_env("ALLBERT_HOME", #{inspect(root)})
    Mix.Task.run("allbert.ecto.migrate", ["--quiet"])
    """

    {migration_output, migration_status} =
      System.cmd(
        "mix",
        [
          "run",
          "--no-compile",
          "--no-deps-check",
          "--no-start",
          "-e",
          migration_expression
        ],
        cd: File.cwd!(),
        env: [
          {"ALLBERT_HOME", root},
          {"DATABASE_PATH", database_path},
          {"MIX_ENV", "test"}
        ],
        stderr_to_stdout: true
      )

    assert migration_status == 0, migration_output

    {output, status} =
      System.cmd(
        "mix",
        ["run", "--no-compile", "--no-deps-check", "--no-start", "-e", expression],
        cd: File.cwd!(),
        env: [
          {"ALLBERT_HOME", root},
          {"DATABASE_PATH", database_path},
          {"MIX_ENV", "test"}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "tui_prepare=:ok", String.slice(output, -4_000, 4_000)
    assert Task.shutdown(server, :brutal_kill) in [nil, :ok]
  end

  defp start_ollama_server do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(listener)

    server =
      Task.async(fn ->
        serve_ollama(listener)
      end)

    {port, server}
  end

  defp serve_ollama(listener) do
    {:ok, socket} = :gen_tcp.accept(listener)
    {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
    assert request =~ "GET /api/tags "

    body = Jason.encode!(%{"models" => [%{"model" => "llama3.2:3b"}]})

    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
      )

    :gen_tcp.close(socket)
    serve_ollama(listener)
  end

  defp with_no_model_provider_env(fun) do
    keys = ~w(ANTHROPIC_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY GOOGLE_API_KEY GEMINI_API_KEY)
    saved = Map.new(keys, &{&1, System.get_env(&1)})
    saved_host = System.get_env("OLLAMA_HOST")

    Enum.each(keys, &System.delete_env/1)
    System.put_env("OLLAMA_HOST", "https://example.invalid")

    try do
      fun.()
    after
      Enum.each(saved, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      if saved_host,
        do: System.put_env("OLLAMA_HOST", saved_host),
        else: System.delete_env("OLLAMA_HOST")
    end
  end
end
