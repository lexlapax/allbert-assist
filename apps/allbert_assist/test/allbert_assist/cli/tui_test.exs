defmodule AllbertAssist.CLI.TuiTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  import ExUnit.CaptureIO

  alias AllbertAssist.CLI.FirstRun
  alias AllbertAssist.CLI.Tui
  alias AllbertAssist.Paths

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
