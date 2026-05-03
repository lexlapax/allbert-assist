defmodule AllbertAssist.Skills.Online.SourceTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Skills.Online.Source

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(System.tmp_dir!(), "allbert-online-source-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "loads enabled skills.sh profile from Settings Central" do
    put_online_policy!()

    assert {:ok, source} = Source.load("skills_sh")
    assert source.enabled?
    assert source.base_url == "https://skills.sh"
    assert source.api_url == "https://skills.sh/api"
    assert :ok = Source.validate_enabled(source)
  end

  test "denies disabled online import policy" do
    assert {:ok, source} = Source.load("skills_sh")
    assert Source.validate_enabled(source) == {:error, :online_skill_import_disabled}
  end

  test "denies unallowlisted source" do
    put_online_policy!()

    assert {:error, {:online_skill_source_not_allowed, "other"}} = Source.load("other")
  end

  defp put_online_policy! do
    settings = %{
      "skills" => %{
        "online_import" => %{
          "enabled" => true,
          "allowed_sources" => ["skills_sh"],
          "sources" => %{"skills_sh" => %{"enabled" => true}}
        }
      }
    }

    assert {:ok, _settings} = Settings.write_user_settings(settings)
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
