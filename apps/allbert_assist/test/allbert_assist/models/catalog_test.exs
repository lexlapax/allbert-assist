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

    assert Enum.map(catalog.roles, &{&1.reference, &1.status}) == [
             {"role:fast", :unconfigured},
             {"role:capable", :unconfigured},
             {"role:thinking", :unconfigured}
           ]

    assert Enum.all?(catalog.entries, &Map.has_key?(&1, :assigned_roles))
    assert Enum.any?(catalog.entries, &(&1.source == :curated and &1.pulled?))
    assert Enum.any?(catalog.entries, &(&1.source == :runtime and &1.model == "runtime-only:1b"))

    assert Enum.any?(
             catalog.entries,
             &(&1.source == :configured and &1.profile == "custom-local")
           )

    assert Enum.any?(catalog.entries, &(&1.source == :hosted_metadata))
  end

  test "annotates configured profiles from the central role DTO" do
    profile = %{
      name: "custom-local",
      provider: "ollama",
      model: "private:latest",
      capabilities: ["text_generation"]
    }

    roles = [
      %{
        role: "fast",
        reference: "role:fast",
        settings_key: "model_roles.fast.profile",
        profile: "custom-local",
        status: :assigned
      },
      %{
        role: "capable",
        reference: "role:capable",
        settings_key: "model_roles.capable.profile",
        profile: nil,
        status: :unconfigured
      },
      %{
        role: "thinking",
        reference: "role:thinking",
        settings_key: "model_roles.thinking.profile",
        profile: nil,
        status: :unconfigured
      }
    ]

    assert {:ok, catalog} =
             Catalog.list(pulled_models: [], profiles: [profile], roles: roles)

    assert %{assigned_roles: ["fast"]} =
             Enum.find(catalog.entries, &(&1.id == "profile:custom-local"))

    assert catalog.roles == roles
  end

  test "configured local profiles distinguish not-pulled from runtime-ready" do
    profile = %{
      name: "direct_answer_local",
      provider: "local_ollama",
      provider_endpoint_kind: "local_endpoint",
      provider_target: :host_ollama,
      model: "qwen2.5:7b",
      capabilities: ["text_generation"]
    }

    assert {:ok, missing} = Catalog.list(pulled_models: [], profiles: [profile])

    assert %{status: :not_pulled, configured?: true, pulled?: false, pullable?: true} =
             Enum.find(missing.entries, &(&1.id == "profile:direct_answer_local"))

    assert %{pullable?: true, direct_answer_repair?: true} =
             Enum.find(missing.entries, &(&1.id == "ollama:qwen2.5:7b"))

    assert {:ok, ready} = Catalog.list(pulled_models: ["qwen2.5:7b"], profiles: [profile])

    assert %{status: :ready, configured?: true, pulled?: true, pullable?: false} =
             Enum.find(ready.entries, &(&1.id == "profile:direct_answer_local"))
  end

  test "configured custom endpoints never inherit host Ollama inventory or pull controls" do
    assert {:ok, _setting} =
             Settings.put(
               "providers.local_ollama.base_url",
               "http://127.0.0.1:11435/v1",
               %{audit?: false}
             )

    assert {:ok, catalog} = Catalog.list(pulled_models: ["qwen2.5:7b"])

    assert %{
             status: :configured,
             configured?: true,
             pulled?: false,
             pullable?: false
           } = Enum.find(catalog.entries, &(&1.id == "profile:direct_answer_local"))

    assert %{direct_answer_repair?: false} =
             Enum.find(catalog.entries, &(&1.id == "ollama:qwen2.5:7b"))
  end

  test "DirectAnswer purpose exposes the qualified Qwen catalog entry" do
    context = %{
      user_id: "local",
      session_id: "catalog-direct-answer-test",
      channel: "cli",
      surface: "test",
      roles: [:owner]
    }

    assert {:ok, response} =
             Runner.run("list_model_catalog", %{purpose: "direct_answer"}, context)

    assert Enum.any?(response.entries, fn entry ->
             entry.id == "ollama:qwen2.5:7b" and entry.model == "qwen2.5:7b"
           end)

    assert response.surface_payload =~ "ollama:qwen2.5:7b"
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
    assert response.surface_payload =~ "Model roles:"
    assert response.surface_payload =~ "role:fast: unconfigured"
    assert response.surface_payload =~ "ollama:llama3.2:3b"

    assert Enum.map(response.roles, & &1.reference) ==
             ~w[role:fast role:capable role:thinking]

    assert Settings.read_user_settings() == {:ok, before_settings}
  end
end
