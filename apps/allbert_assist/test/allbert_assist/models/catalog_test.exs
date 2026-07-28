defmodule AllbertAssist.Models.CatalogTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Models.Catalog
  alias AllbertAssist.Settings

  test "merges curated, local runtime, configured, and hosted metadata without network calls" do
    profile = %{
      name: "custom-local",
      provider: "ollama",
      model: "private:latest",
      capabilities: ["text"]
    }

    assert {:ok, catalog} =
             Catalog.list(
               pulled_models: ["llama3.2:3b", "runtime-only:1b"],
               profiles: [profile]
             )

    assert catalog.version == 1
    assert Enum.any?(catalog.entries, &(&1.source == :curated and &1.pulled?))
    assert Enum.any?(catalog.entries, &(&1.source == :runtime and &1.model == "runtime-only:1b"))

    assert Enum.any?(
             catalog.entries,
             &(&1.source == :configured and &1.profile == "custom-local")
           )

    assert Enum.any?(catalog.entries, &(&1.source == :hosted_metadata))
  end

  test "degrades when the shipped source is absent and retains other sources" do
    assert {:ok, catalog} =
             Catalog.list(
               catalog_path: "/definitely/not/a/catalog.json",
               pulled_models: ["runtime-only:1b"],
               profiles: [],
               llm_db?: false
             )

    assert [%{code: :curated_catalog_unavailable}] = catalog.diagnostics
    assert [%{source: :runtime, model: "runtime-only:1b"}] = catalog.entries
  end

  test "registered action is read-only and supports purpose filtering" do
    assert {:ok, module} = Registry.resolve("list_model_catalog")
    assert module == AllbertAssist.Actions.Settings.ListModelCatalog
    assert {:ok, capability} = Registry.capability("list_model_catalog")
    assert capability.permission == :read_only

    context = %{
      user_id: "local",
      session_id: "catalog-test",
      channel: "cli",
      surface: "test",
      roles: [:owner]
    }

    assert {:ok, before_settings} = Settings.read_user_settings()
    assert {:ok, response} = Runner.run("list_model_catalog", %{purpose: "fast"}, context)
    assert response.status == :completed
    assert response.entries != []
    assert Enum.all?(response.entries, &("fast" in &1.purposes))
    assert response.surface_payload =~ "Model catalog v1:"
    assert response.surface_payload =~ "ollama:llama3.2:3b"
    assert Settings.read_user_settings() == {:ok, before_settings}
  end
end
