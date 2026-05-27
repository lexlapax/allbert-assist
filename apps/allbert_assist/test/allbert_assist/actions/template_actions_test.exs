defmodule AllbertAssist.Actions.TemplateActionsTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.DynamicPlugins
  alias AllbertAssist.DynamicPlugins.Audit
  alias AllbertAssist.DynamicPlugins.MetadataStore
  alias AllbertAssist.DynamicPlugins.TrustedValidator
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Signals

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    home = temp_path("home")

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.delete_env(:allbert_assist, Settings)

    on_exit(fn ->
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Settings, original_settings_config)
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  test "template actions are registered runtime boundaries" do
    assert {:ok, render} = Registry.capability("render_template")
    assert render.permission == :read_only
    assert render.execution_mode == :template_render

    assert {:ok, validate} = Registry.capability("validate_template")
    assert validate.permission == :read_only

    assert {:ok, scaffold} = Registry.capability("scaffold_template")
    assert scaffold.permission == :skill_write

    assert {:ok, create} = Registry.capability("create_from_template")
    assert create.permission == :dynamic_codegen_request
    assert create.execution_mode == :template_dynamic_draft
  end

  test "render and validate actions stay read-only" do
    assert {:ok, render} =
             Runner.run(
               "render_template",
               %{pattern_id: "llm_tool", params: %{"name" => "Render Tool"}},
               context()
             )

    assert render.status == :completed
    assert Enum.any?(render.rendered.files, &(&1.path == "source/test/action_test.exs"))

    assert {:ok, validate} =
             Runner.run(
               "validate_template",
               %{
                 pattern_id: "plugin",
                 params: %{"name" => "No Live Plugin"},
                 mode: "live_integration"
               },
               context()
             )

    assert validate.status == :denied
    assert validate.error == {:unsupported_live_integration_pattern, "plugin"}
  end

  test "scaffold_template writes inert files only when template creation is enabled", %{
    home: home
  } do
    target = Path.join(home, "scaffolded-plugin")

    assert {:ok, denied} =
             Runner.run(
               "scaffold_template",
               %{pattern_id: "plugin", params: %{"name" => "Action Plugin"}, target: target},
               context()
             )

    assert denied.status == :denied
    assert denied.error == :template_create_disabled
    refute File.exists?(target)

    enable_template_create!()

    assert {:ok, created} =
             Runner.run(
               "scaffold_template",
               %{pattern_id: "plugin", params: %{"name" => "Action Plugin"}, target: target},
               context()
             )

    assert created.status == :completed
    assert File.regular?(Path.join(target, "allbert_plugin.json"))

    assert {:ok, existing} =
             Runner.run(
               "scaffold_template",
               %{pattern_id: "plugin", params: %{"name" => "Action Plugin"}, target: target},
               context()
             )

    assert existing.status == :denied
    assert {:target_exists, _preview} = existing.error
  end

  test "create_from_template writes a v0.37 templated dynamic draft" do
    enable_template_create!()
    enable_live_template_stack!()

    assert {:ok, response} =
             Runner.run(
               "create_from_template",
               %{
                 pattern_id: "llm_tool",
                 mode: "live_integration",
                 params: %{
                   "name" => "Weather Tool",
                   "description" => "Return a concise weather answer.",
                   "instruction" => "Return a concise weather answer.",
                   "permission" => "read_only"
                 }
               },
               context()
             )

    assert response.status == :completed
    assert response.draft.producer == "template_pattern"
    assert response.draft.template_pattern_id == "llm_tool"
    assert response.draft.tier == "draft"
    assert response.draft.gate_status == "not_run"

    assert Enum.map(response.next_actions, & &1.name) == [
             "run_dynamic_draft_trial",
             "run_dynamic_draft_gate",
             "integrate_dynamic_draft"
           ]

    assert File.regular?(Path.join(response.draft.root, "source/lib/action.ex"))
    assert File.regular?(Path.join(response.draft.root, "source/test/action_test.exs"))

    assert File.read!(Path.join(response.draft.root, "metadata.yaml")) =~
             "template_pattern_id: llm_tool"

    assert {:ok, draft} = DynamicPlugins.get_draft(response.draft.slug)
    assert draft.producer == "template_pattern"
    assert draft.template_pattern_id == "llm_tool"

    assert Enum.sort(Map.keys(draft.source_hashes)) == [
             "source/lib/action.ex",
             "source/test/action_test.exs"
           ]

    assert {:ok, manifest} = MetadataStore.get_manifest(draft.slug)

    assert manifest["focused_test_paths"] == [
             "apps/allbert_assist/test/allbert_assist/dynamic_plugins/generated/#{draft.slug}/action_test.exs"
           ]

    assert {:ok, validation} = TrustedValidator.validate(draft, manifest)
    assert [%{permission: "read_only"}] = validation.actions
    assert File.read!(Audit.audit_path()) =~ "template_draft_created"

    assert {:ok, signal} =
             Signals.dynamic_codegen_lifecycle(:template_draft_created, %{operator_id: "local"})

    assert signal.type == "allbert.dynamic_codegen.template_draft_created"
  end

  test "create_from_template denies disabled or unsupported live integration before writing", %{
    home: home
  } do
    assert {:ok, disabled} =
             Runner.run(
               "create_from_template",
               %{pattern_id: "llm_tool", params: %{"name" => "Disabled Tool"}},
               context()
             )

    assert disabled.status == :denied
    assert disabled.error == :template_create_disabled

    enable_template_create!()

    assert {:ok, codegen_disabled} =
             Runner.run(
               "create_from_template",
               %{pattern_id: "llm_tool", params: %{"name" => "Codegen Disabled Tool"}},
               context()
             )

    assert codegen_disabled.status == :denied
    assert codegen_disabled.error == :dynamic_codegen_disabled

    enable_dynamic_codegen!()

    assert {:ok, live_loader_disabled} =
             Runner.run(
               "create_from_template",
               %{pattern_id: "llm_tool", params: %{"name" => "Loader Disabled Tool"}},
               context()
             )

    assert live_loader_disabled.status == :denied
    assert live_loader_disabled.error == :dynamic_live_loader_disabled

    enable_dynamic_live_loader!()

    assert {:ok, sandbox_disabled} =
             Runner.run(
               "create_from_template",
               %{pattern_id: "llm_tool", params: %{"name" => "Sandbox Disabled Tool"}},
               context()
             )

    assert sandbox_disabled.status == :denied
    assert sandbox_disabled.error == :sandbox_elixir_disabled

    enable_sandbox_elixir!()

    assert {:ok, unsupported} =
             Runner.run(
               "create_from_template",
               %{
                 pattern_id: "plugin",
                 mode: "live_integration",
                 params: %{"name" => "Plugin Live"}
               },
               context()
             )

    assert unsupported.status == :denied
    assert unsupported.error == {:unsupported_live_integration_pattern, "plugin"}
    refute File.exists?(Path.join([home, "dynamic_plugins", "drafts", "plugin_live"]))
  end

  defp enable_template_create! do
    assert {:ok, _setting} = Settings.put("templates.create.enabled", true, %{audit?: false})
  end

  defp enable_dynamic_codegen! do
    assert {:ok, _setting} = Settings.put("dynamic_codegen.enabled", true, %{audit?: false})
  end

  defp enable_dynamic_live_loader! do
    assert {:ok, _setting} =
             Settings.put("dynamic_codegen.live_loader_enabled", true, %{audit?: false})
  end

  defp enable_sandbox_elixir! do
    assert {:ok, _setting} = Settings.put("sandbox.elixir.enabled", true, %{audit?: false})
  end

  defp enable_live_template_stack! do
    enable_dynamic_codegen!()
    enable_dynamic_live_loader!()
    enable_sandbox_elixir!()
  end

  defp context,
    do: %{actor: "local", operator_id: "local", channel: :live_view, surface: "/workspace"}

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "allbert-template-actions-#{name}-#{System.unique_integer([:positive])}"
    )
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
