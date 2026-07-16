defmodule AllbertAssist.Artifacts.BackfillTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Artifacts
  alias AllbertAssist.Artifacts.Backfill
  alias AllbertAssist.Artifacts.MetadataIndex
  alias AllbertAssist.Artifacts.Store
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  @moduletag :app_env_serial

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADElEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
       )

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
        "allbert-artifact-backfill-#{System.unique_integer([:positive])}"
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

  test "backfills retained voice vision and generated-image roots without deleting legacy files",
       %{
         home: home
       } do
    voice = Path.join([home, "audio", "cap_a", "hello.wav"])
    vision = Path.join([home, "images", "img_a", "frame.png"])
    vision_duplicate = Path.join([home, "images", "img_b", "frame-copy.png"])
    generated = Path.join([home, "generated_images", "gen_a", "image.png"])
    browser_cache = Path.join([home, "cache", "browser", "download.png"])

    write!(voice, <<"RIFF", "retained voice">>)
    write!(vision, @png)
    write!(vision_duplicate, @png)
    write!(generated, <<"generated image bytes">>)
    write!(browser_cache, <<"browser cache only">>)

    assert {:ok, summary} = Backfill.run()

    assert summary.status == :completed
    assert summary.candidate_count == 4
    assert summary.ingested_count == 4
    assert summary.unique_sha256_count == 3

    assert File.regular?(voice)
    assert File.regular?(vision)
    assert File.regular?(vision_duplicate)
    assert File.regular?(generated)
    assert File.regular?(browser_cache)

    assert {:ok, retained_voice} = Artifacts.list(origin: "retained_voice_audio")
    assert [%{metadata: %{mime: "audio/wav"}}] = retained_voice

    assert {:ok, retained_vision} = Artifacts.list(origin: "retained_vision_media")
    assert [%{metadata: %{mime: "image/png"}}] = retained_vision

    assert {:ok, retained_generated} = Artifacts.list(origin: "retained_generated_image")
    assert [%{metadata: %{mime: "image/png"}}] = retained_generated

    all_artifacts = summary.artifacts
    shas = Enum.map(all_artifacts, & &1.sha256)
    assert Store.sha256(File.read!(browser_cache)) not in shas

    for %{sha256: sha256} <- all_artifacts do
      assert Store.exists?(sha256)
      assert {:ok, metadata} = MetadataIndex.lookup(sha256)
      media = metadata.provenance["media_retention"]
      assert byte_size(media["relative_path_sha256"]) == 64
      refute inspect(metadata) =~ "cap_a"
      refute inspect(metadata) =~ "img_a"
      refute inspect(metadata) =~ "img_b"
      refute inspect(metadata) =~ "gen_a"
      refute inspect(metadata) =~ browser_cache
    end
  end

  test "missing retained roots produce an empty successful summary" do
    File.rm_rf!(Paths.audio_root())
    File.rm_rf!(Paths.images_root())
    File.rm_rf!(Paths.generated_images_root())

    assert {:ok, summary} = Backfill.run()

    assert summary.status == :completed
    assert summary.candidate_count == 0
    assert summary.ingested_count == 0
    assert summary.unique_sha256_count == 0
    assert Enum.all?(summary.sources, &(&1.root_exists? == false))
  end

  defp write!(path, bytes) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
  end

  defp enable_artifacts! do
    assert {:ok, _setting} = Settings.put("artifacts.enabled", true, %{audit?: false})
    assert {:ok, _setting} = Settings.put("artifacts.retention_enabled", true, %{audit?: false})
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
