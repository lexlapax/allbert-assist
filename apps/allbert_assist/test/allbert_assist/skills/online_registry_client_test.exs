defmodule AllbertAssist.Skills.Online.RegistryClientTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Skills.Online.RegistryClient
  alias AllbertAssist.Skills.Online.Source

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_client_config = Application.get_env(:allbert_assist, RegistryClient)
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-online-client-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    Application.put_env(:allbert_assist, RegistryClient,
      req_options: [plug: {Req.Test, __MODULE__}]
    )

    on_exit(fn ->
      restore_env(RegistryClient, original_client_config)
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    put_online_policy!()
    {:ok, source: source!()}
  end

  test "searches skills.sh API shape and filters locally", %{source: source} do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/search"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"skills" => [skill_json(), other_skill_json()]})
      )
    end)

    assert {:ok, result} = RegistryClient.search(source, "find skills")
    assert [candidate] = result.results
    assert candidate.id == "vercel-labs/skills/find-skills"
    assert candidate.install_count == 1_000_000
  end

  test "fetches skill detail files through Req", %{source: source} do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/skills/vercel-labs%2Fskills%2Ffind-skills"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(detail_json()))
    end)

    assert {:ok, detail} = RegistryClient.show(source, "vercel-labs/skills/find-skills")
    assert detail.skill_md =~ "name: find-skills"
    assert Map.has_key?(detail.files, "scripts/search.js")
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

  defp source! do
    assert {:ok, source} = Source.load("skills_sh")
    source
  end

  defp skill_json do
    %{
      "id" => "vercel-labs/skills/find-skills",
      "name" => "find-skills",
      "owner" => "vercel-labs",
      "repository" => "skills",
      "description" => "Find skills from the registry.",
      "install_count" => 1_000_000,
      "license" => "MIT"
    }
  end

  defp other_skill_json do
    %{"id" => "other/repo/thing", "name" => "thing", "description" => "Unrelated"}
  end

  defp detail_json do
    %{
      "id" => "vercel-labs/skills/find-skills",
      "name" => "find-skills",
      "owner" => "vercel-labs",
      "repository" => "skills",
      "files" => %{
        "SKILL.md" => skill_md(),
        "scripts/search.js" => "console.log('search');\n"
      }
    }
  end

  defp skill_md do
    """
    ---
    name: find-skills
    description: Find skills from the registry.
    license: MIT
    ---

    Search the registry and show candidates.
    """
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
