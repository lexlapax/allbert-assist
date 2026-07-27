defmodule AllbertAssist.Settings.ModelsFallbackTest do
  use ExUnit.Case, async: false
  @moduletag :db_serial

  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Models

  setup do
    original_home = System.get_env("ALLBERT_HOME")
    original_paths = Application.get_env(:allbert_assist, Paths)

    home =
      Path.join(System.tmp_dir!(), "allbert-model-fallback-#{System.unique_integer([:positive])}")

    System.put_env("ALLBERT_HOME", home)
    Application.delete_env(:allbert_assist, Paths)

    on_exit(fn ->
      if original_home,
        do: System.put_env("ALLBERT_HOME", original_home),
        else: System.delete_env("ALLBERT_HOME")

      if original_paths,
        do: Application.put_env(:allbert_assist, Paths, original_paths),
        else: Application.delete_env(:allbert_assist, Paths)

      File.rm_rf!(home)
    end)

    :ok
  end

  test "fallback and catalog settings have bounded additive defaults" do
    assert {:ok, false} = Settings.get("models.fallback.enabled")
    assert {:ok, false} = Settings.get("models.fallback.allow_local_to_hosted")
    assert {:ok, 1} = Settings.get("models.fallback.max_failovers_per_turn")
    assert {:ok, 1} = Settings.get("models.catalog.version")

    assert {:error, _reason} =
             Settings.put("models.fallback.max_failovers_per_turn", 0, %{audit?: false})

    assert {:ok, setting} =
             Settings.put("models.fallback.max_failovers_per_turn", 2, %{audit?: false})

    assert setting.value == 2
  end

  test "text candidates are local-first when no explicit primary was selected" do
    assert {:ok, _setting} = Settings.put("providers.openai.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("model_preferences.tasks.direct_answer", ["fast", "local"], %{
               audit?: false
             })

    assert {:ok, resolutions} = Models.candidates_for(:direct_answer)
    assert Enum.map(resolutions, & &1.profile.name) == ["local", "fast"]

    assert {:ok, resolution} = Models.for(:direct_answer)
    assert resolution.profile.name == "local"
  end
end
