defmodule AllbertAssist.Marketplace.TemplatesTest do
  use ExUnit.Case, async: false
  @moduletag :home_fs_serial

  alias AllbertAssist.Marketplace
  alias AllbertAssist.Marketplace.Templates

  setup do
    home = temp_path("home")

    on_exit(fn ->
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  test "installed marketplace template metadata is listed without execution authority", %{
    home: home
  } do
    assert {:ok, install} = Marketplace.install_bundle("allbert/workspace-brief", home: home)

    assert File.regular?(
             Path.join(home, "marketplace/templates/allbert-workspace-brief/template.md")
           )

    assert install.installed["install_state"] == "disabled_untrusted"

    assert {:ok, [template]} = Templates.list_installed(home: home)

    assert template.entry_id == "allbert/workspace-brief"
    assert template.version == "1.0.0"
    assert template.name == "Workspace Brief"
    assert template.pattern_id == "marketplace_workspace_brief"
    assert template.authority == "metadata_only"
    refute template.live_integration?
    assert Enum.map(template.parameters, & &1.name) == ["title", "objective", "context"]
    assert Enum.map(template.files, & &1.path) == ["metadata.json", "template.md"]
  end

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "allbert-marketplace-template-#{name}-#{System.unique_integer([:positive])}"
    )
  end
end
