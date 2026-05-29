defmodule AllbertAssist.DynamicPlugins.MetadataStoreTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.DynamicPlugins
  alias AllbertAssist.DynamicPlugins.MetadataStore
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings.YamlCodec

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    home = temp_path("home")
    Application.put_env(:allbert_assist, Paths, home: home)

    on_exit(fn ->
      restore_app_env(Paths, original_paths_config)
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  test "writes and lists draft metadata under Allbert Home", %{home: home} do
    assert {:ok, draft} =
             DynamicPlugins.put_draft(%{
               slug: "weather_summary",
               revision: "rev_test_001",
               producer: "test",
               target_shapes: ["action"]
             })

    assert draft.root == Path.join([home, "dynamic_plugins", "drafts", "weather_summary"])
    assert File.regular?(Path.join(draft.root, "metadata.yaml"))

    assert [%{slug: "weather_summary", revision: "rev_test_001", tier: "draft"}] =
             DynamicPlugins.list_drafts()

    assert {:ok, %{producer: "test", target_shapes: ["action"]}} =
             DynamicPlugins.show_draft("weather_summary")
  end

  test "rejects unsafe slugs and invalid tiers" do
    assert {:error, {:invalid_slug, "../escape"}} =
             DynamicPlugins.put_draft(%{slug: "../escape", revision: "rev_test"})

    assert {:error, {:invalid_tier, "trusted"}} =
             DynamicPlugins.put_draft(%{slug: "safe_slug", revision: "rev_test", tier: "trusted"})
  end

  test "discard is terminal and integrated drafts require rollback first" do
    assert {:ok, _draft} =
             DynamicPlugins.put_draft(%{slug: "discard_me", revision: "rev_test"})

    assert {:ok, discarded} = DynamicPlugins.discard_draft("discard_me")
    assert discarded.tier == "discarded"

    assert {:error, :discarded_terminal} =
             MetadataStore.transition_tier("discard_me", "draft")

    assert {:ok, _draft} =
             DynamicPlugins.put_draft(%{
               slug: "live_draft",
               revision: "rev_test",
               tier: "integrated"
             })

    assert {:error, :rollback_required} = DynamicPlugins.discard_draft("live_draft")
  end

  test "verifies source hashes and detects tampering" do
    source_rel = Path.join(["source", "lib", "fixture.ex"])
    source_abs = Path.join(MetadataStore.draft_root("hash_check"), source_rel)
    File.mkdir_p!(Path.dirname(source_abs))
    File.write!(source_abs, "defmodule Fixture do\nend\n")

    assert {:ok, hash} = MetadataStore.hash_file(source_abs)

    assert {:ok, _draft} =
             DynamicPlugins.put_draft(%{
               slug: "hash_check",
               revision: "rev_test",
               source_hashes: %{source_rel => hash}
             })

    assert :ok = DynamicPlugins.verify_source_hashes("hash_check")

    File.write!(source_abs, "defmodule Fixture do\n  def changed, do: true\nend\n")

    assert {:error, {:source_hash_mismatch, [%{path: ^source_rel}]}} =
             DynamicPlugins.verify_source_hashes("hash_check")
  end

  test "reads integration metadata from the integrated root" do
    root = Path.join([Paths.dynamic_plugins_integrated_root(), "live_tool", "rev_test"])
    File.mkdir_p!(root)

    File.write!(
      Path.join(root, "metadata.yaml"),
      YamlCodec.encode!(%{
        "slug" => "live_tool",
        "revision" => "rev_test",
        "tier" => "integrated",
        "producer" => "test"
      })
    )

    assert {:ok, %{slug: "live_tool", revision: "rev_test", tier: "integrated"}} =
             DynamicPlugins.show_integration("live_tool")
  end

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "allbert-dynamic-plugins-#{name}-#{System.unique_integer([:positive])}"
    )
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
