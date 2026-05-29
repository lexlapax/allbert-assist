defmodule AllbertAssist.DynamicPlugins.LoaderTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations
  alias AllbertAssist.DynamicPlugins
  alias AllbertAssist.DynamicPlugins.ActionsOverlay
  alias AllbertAssist.DynamicPlugins.Audit
  alias AllbertAssist.DynamicPlugins.MetadataStore
  alias AllbertAssist.DynamicPlugins.TrustedValidator
  alias AllbertAssist.Memory
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_memory_config = Application.get_env(:allbert_assist, Memory)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    home = temp_path("home")

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Memory, root: home)
    Application.delete_env(:allbert_assist, Settings)
    ActionsOverlay.clear()

    on_exit(fn ->
      ActionsOverlay.clear()
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Memory, original_memory_config)
      restore_app_env(Settings, original_settings_config)
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  test "integrates a gate-passed read-only action and rollback removes authority", %{
    home: home
  } do
    enable_live_loader!()
    fixture = write_gate_passed_action_draft("loader_happy")

    assert {:ok, %{status: :needs_confirmation, confirmation_id: integration_id}} =
             Runner.run("integrate_dynamic_draft", %{slug: fixture.slug}, cli_context())

    assert {:ok, %{status: :completed, confirmation: %{"status" => "approved"}}} =
             Runner.run(
               "approve_confirmation",
               %{id: integration_id, reason: "reviewed"},
               cli_context()
             )

    assert {:ok, module} = Registry.resolve(fixture.action_name)
    assert inspect(module) == fixture.module

    assert {:ok, %{status: :completed, message: "hello"}} =
             Runner.run(fixture.action_name, %{text: "hello"}, cli_context())

    assert {:ok, integration} = DynamicPlugins.show_integration(fixture.slug)
    assert integration.tier == "integrated"

    assert {:ok, %{status: :needs_confirmation, confirmation_id: rollback_id}} =
             Runner.run("rollback_dynamic_integration", %{slug: fixture.slug}, cli_context())

    assert {:ok, %{status: :completed, confirmation: %{"status" => "approved"}}} =
             Runner.run(
               "approve_confirmation",
               %{id: rollback_id, reason: "rollback reviewed"},
               cli_context()
             )

    action_name = fixture.action_name
    assert {:error, {:unknown_action, ^action_name}} = Registry.resolve(fixture.action_name)

    assert {:ok, rolled_back} = DynamicPlugins.show_integration(fixture.slug)
    assert rolled_back.tier == "rolled_back"

    audit = File.read!(Audit.audit_path())
    assert audit =~ "registered"
    assert audit =~ "integrated"
    assert audit =~ "rolled_back"
    refute audit =~ home
  end

  test "integrates and runs a useful read-only action with pure generated logic" do
    enable_live_loader!()
    fixture = write_gate_passed_action_draft("loader_useful", source_kind: :useful_pure)

    assert {:ok, %{status: :needs_confirmation, confirmation_id: integration_id}} =
             Runner.run("integrate_dynamic_draft", %{slug: fixture.slug}, cli_context())

    assert {:ok, %{status: :completed, confirmation: %{"status" => "approved"}}} =
             Runner.run(
               "approve_confirmation",
               %{id: integration_id, reason: "reviewed useful generated logic"},
               cli_context()
             )

    assert {:ok,
            %{
              status: :completed,
              message: "Spuri: high score=12 tags=ALPHA, BETA",
              actions: []
            }} =
             Runner.run(
               fixture.action_name,
               %{name: " Spuri ", score: 10, tags: ["alpha", "beta"]},
               cli_context()
             )
  end

  test "integrates and runs a delegated memory_write action through a reviewed facade" do
    enable_live_loader!()

    assert {:ok, _setting} =
             Settings.put(
               "dynamic_codegen.allowed_action_permissions",
               ["read_only", "memory_write"],
               %{audit?: false}
             )

    assert {:ok, _setting} =
             Settings.put("dynamic_codegen.allowed_facades", ["append_memory"], %{audit?: false})

    fixture =
      write_gate_passed_action_draft("loader_delegate_memory", source_kind: :delegated_memory)

    assert {:ok, %{status: :needs_confirmation, confirmation_id: integration_id}} =
             Runner.run("integrate_dynamic_draft", %{slug: fixture.slug}, cli_context())

    assert {:ok, %{status: :completed, confirmation: %{"status" => "approved"}}} =
             Runner.run(
               "approve_confirmation",
               %{id: integration_id, reason: "reviewed delegated memory write"},
               cli_context()
             )

    assert {:ok, response} =
             Runner.run(
               fixture.action_name,
               %{memory: "Prefer terse release notes.", source_text: "remember"},
               cli_context()
             )

    assert response.status == :completed
    assert [%{name: "append_memory", permission: :memory_write, durable: true}] = response.actions
  end

  test "trusted validator keeps effectful neighbors denied while pure stdlib is allowed" do
    pure = write_gate_passed_action_draft("loader_pure_validation", source_kind: :useful_pure)
    unsafe_atom = write_gate_passed_action_draft("loader_to_atom", source_kind: :string_to_atom)

    unsafe_fun =
      write_gate_passed_action_draft("loader_effectful_fun", source_kind: :effectful_fun)

    assert {:ok, pure_manifest} = MetadataStore.get_manifest(pure.slug)
    assert {:ok, _validation} = TrustedValidator.validate(pure.draft, pure_manifest)

    assert {:ok, atom_manifest} = MetadataStore.get_manifest(unsafe_atom.slug)

    assert {:error,
            {:trusted_validation_failed, "source/lib/action.ex",
             {:unsupported_remote_call, "String", :to_atom}}} =
             TrustedValidator.validate(unsafe_atom.draft, atom_manifest)

    assert {:ok, fun_manifest} = MetadataStore.get_manifest(unsafe_fun.slug)

    assert {:error,
            {:trusted_validation_failed, "source/lib/action.ex",
             {:protected_remote_call, "System", :cmd}}} =
             TrustedValidator.validate(unsafe_fun.draft, fun_manifest)
  end

  test "trusted validator denies protected runtime calls" do
    enable_live_loader!()
    fixture = write_gate_passed_action_draft("loader_denied", source_kind: :protected_call)

    assert {:ok, %{status: :needs_confirmation, confirmation_id: integration_id}} =
             Runner.run("integrate_dynamic_draft", %{slug: fixture.slug}, cli_context())

    assert {:ok,
            %{
              status: :completed,
              confirmation: %{
                "status" => "approved",
                "operator_resolution" => %{
                  "target_resumed?" => false,
                  "target_status" => "denied",
                  "target_result" => %{"status" => "denied"}
                }
              }
            }} =
             Runner.run(
               "approve_confirmation",
               %{id: integration_id, reason: "unsafe call"},
               cli_context()
             )

    action_name = fixture.action_name
    assert {:error, {:unknown_action, ^action_name}} = Registry.resolve(fixture.action_name)

    assert {:ok, draft} = DynamicPlugins.get_draft(fixture.slug)
    assert draft.static_validation["status"] == "failed"
    assert File.read!(Audit.audit_path()) =~ "integration_denied"
  end

  test "disable and reconcile decisions are audited", %{home: home} do
    enable_live_loader!()
    fixture = write_gate_passed_action_draft("loader_disable_audit")

    assert {:ok, %{status: :needs_confirmation, confirmation_id: integration_id}} =
             Runner.run("integrate_dynamic_draft", %{slug: fixture.slug}, cli_context())

    assert {:ok, %{status: :completed}} =
             Runner.run(
               "approve_confirmation",
               %{id: integration_id, reason: "reviewed"},
               cli_context()
             )

    assert {:ok, %{status: :completed}} =
             Runner.run("disable_dynamic_live_loader", %{}, cli_context())

    enable_live_loader!()
    ActionsOverlay.clear()

    assert {:ok, %{integrations: [%{status: :completed}]}} =
             DynamicPlugins.reconcile_integrations()

    audit = File.read!(Audit.audit_path())
    assert audit =~ "live_loader_disabled"
    assert audit =~ "reconcile_completed"
    refute audit =~ home
  end

  test "integration approvals are restricted to high-trust same-channel surfaces" do
    enable_live_loader!()
    fixture = write_gate_passed_action_draft("loader_surface")

    assert {:ok, %{status: :needs_confirmation, confirmation_id: integration_id}} =
             Runner.run("integrate_dynamic_draft", %{slug: fixture.slug}, cli_context())

    assert {:ok,
            %{status: :denied, error: {:dynamic_integration_approval_surface_denied, "telegram"}}} =
             Runner.run(
               "approve_confirmation",
               %{id: integration_id, reason: "approve elsewhere"},
               %{actor: "local", channel: :telegram, surface: "telegram"}
             )

    action_name = fixture.action_name
    assert {:error, {:unknown_action, ^action_name}} = Registry.resolve(fixture.action_name)
  end

  test "same-channel LiveView approval can resume integration and rollback" do
    enable_live_loader!()
    fixture = write_gate_passed_action_draft("loader_liveview")

    assert {:ok, %{status: :needs_confirmation, confirmation_id: integration_id}} =
             Runner.run("integrate_dynamic_draft", %{slug: fixture.slug}, live_view_context())

    assert {:ok, %{status: :completed, confirmation: %{"status" => "approved"}}} =
             Runner.run(
               "approve_confirmation",
               %{id: integration_id, reason: "reviewed in workspace"},
               live_view_context()
             )

    assert {:ok, module} = Registry.resolve(fixture.action_name)
    assert inspect(module) == fixture.module

    assert {:ok, %{status: :needs_confirmation, confirmation_id: rollback_id}} =
             Runner.run(
               "rollback_dynamic_integration",
               %{slug: fixture.slug},
               live_view_context()
             )

    assert {:ok, %{status: :completed, confirmation: %{"status" => "approved"}}} =
             Runner.run(
               "approve_confirmation",
               %{id: rollback_id, reason: "rollback reviewed in workspace"},
               live_view_context()
             )

    action_name = fixture.action_name
    assert {:error, {:unknown_action, ^action_name}} = Registry.resolve(fixture.action_name)
  end

  test "direct integration resume cannot spoof approval context while confirmation is pending" do
    enable_live_loader!()
    fixture = write_gate_passed_action_draft("loader_spoof")

    assert {:ok, %{status: :needs_confirmation, confirmation_id: integration_id}} =
             Runner.run("integrate_dynamic_draft", %{slug: fixture.slug}, cli_context())

    assert {:ok,
            %{
              status: :denied,
              error: {:confirmation_not_approved_for_dynamic_resume, ^integration_id, "pending"}
            }} =
             Runner.run(
               "integrate_dynamic_draft",
               %{slug: fixture.slug},
               Map.put(cli_context(), :confirmation, %{approved?: true, id: integration_id})
             )

    assert {:ok, %{"status" => "pending"}} = Confirmations.read(integration_id)

    action_name = fixture.action_name
    assert {:error, {:unknown_action, ^action_name}} = Registry.resolve(fixture.action_name)
  end

  test "direct rollback resume cannot spoof approval context while confirmation is pending" do
    enable_live_loader!()
    fixture = write_gate_passed_action_draft("loader_rollback_spoof")

    assert {:ok, %{status: :needs_confirmation, confirmation_id: integration_id}} =
             Runner.run("integrate_dynamic_draft", %{slug: fixture.slug}, cli_context())

    assert {:ok, %{status: :completed}} =
             Runner.run(
               "approve_confirmation",
               %{id: integration_id, reason: "reviewed"},
               cli_context()
             )

    assert {:ok, %{status: :needs_confirmation, confirmation_id: rollback_id}} =
             Runner.run("rollback_dynamic_integration", %{slug: fixture.slug}, cli_context())

    assert {:ok,
            %{
              status: :denied,
              error: {:confirmation_not_approved_for_dynamic_resume, ^rollback_id, "pending"}
            }} =
             Runner.run(
               "rollback_dynamic_integration",
               %{slug: fixture.slug},
               Map.put(cli_context(), :confirmation, %{approved?: true, id: rollback_id})
             )

    assert {:ok, %{"status" => "pending"}} = Confirmations.read(rollback_id)
    assert {:ok, module} = Registry.resolve(fixture.action_name)
    assert inspect(module) == fixture.module
  end

  defp enable_live_loader! do
    assert {:ok, _settings} =
             Settings.write_user_settings(%{
               "dynamic_codegen" => %{
                 "enabled" => true,
                 "live_loader_enabled" => true
               }
             })
  end

  defp write_gate_passed_action_draft(slug, opts \\ []) do
    unique = System.unique_integer([:positive])
    slug = "#{slug}_#{unique}"
    module_suffix = Macro.camelize(slug)
    module = "AllbertAssist.DynamicPlugins.Generated.#{module_suffix}.Action"
    action_name = "dynamic_#{slug}"
    source_rel = "source/lib/action.ex"

    source_compiled =
      "apps/allbert_assist/lib/allbert_assist/dynamic_plugins/generated/#{slug}/action.ex"

    source_abs = Path.join(MetadataStore.draft_root(slug), source_rel)

    File.mkdir_p!(Path.dirname(source_abs))

    source_kind = Keyword.get(opts, :source_kind, :valid)
    File.write!(source_abs, source_body(module, action_name, source_kind))

    assert {:ok, source_hash} = MetadataStore.hash_file(source_abs)

    assert {:ok, draft} =
             DynamicPlugins.put_draft(%{
               slug: slug,
               revision: "rev_test",
               producer: "test",
               tier: "gate_passed",
               target_shapes: ["action"],
               source_hashes: %{source_rel => source_hash},
               compiled_paths: [source_compiled],
               scan_paths: [source_rel],
               gate: %{"status" => "passed", "sandbox_report_id" => "fixture-report"}
             })

    assert :ok =
             MetadataStore.put_manifest(slug, %{
               "target_shapes" => ["action"],
               "modules" => [module],
               "actions" => [
                 %{
                   "name" => action_name,
                   "module" => module,
                   "permission" => source_permission(source_kind),
                   "exposure" => "internal"
                 }
               ],
               "files" => [
                 %{"source_path" => source_rel, "compiled_path" => source_compiled}
               ],
               "tests" => []
             })

    %{slug: draft.slug, module: module, action_name: action_name, draft: draft}
  end

  defp source_body(module, action_name, :valid) do
    """
    defmodule #{module} do
      use AllbertAssist.Action,
        permission: :read_only,
        exposure: :internal,
        execution_mode: :read_only,
        skill_backed?: false,
        confirmation: :not_required,
        name: "#{action_name}",
        description: "Dynamic loader fixture.",
        category: "dynamic_plugins",
        tags: ["dynamic", "fixture"],
        schema: [text: [type: :string, required: false]],
        output_schema: [
          message: [type: :string, required: true],
          status: [type: :atom, required: true],
          actions: [type: {:list, :map}, required: true]
        ]

      @impl true
      def run(params, _context) do
        {:ok, %{message: Map.get(params, :text, "ok"), status: :completed, actions: []}}
      end
    end
    """
  end

  defp source_body(module, action_name, :protected_call) do
    """
    defmodule #{module} do
      use AllbertAssist.Action,
        permission: :read_only,
        exposure: :internal,
        execution_mode: :read_only,
        skill_backed?: false,
        confirmation: :not_required,
        name: "#{action_name}",
        description: "Dynamic loader fixture.",
        category: "dynamic_plugins",
        tags: ["dynamic", "fixture"],
        schema: [],
        output_schema: [
          message: [type: :string, required: true],
          status: [type: :atom, required: true],
          actions: [type: {:list, :map}, required: true]
        ]

      @impl true
      def run(_params, _context) do
        System.cmd("echo", ["no"])
        {:ok, %{message: "no", status: :completed, actions: []}}
      end
    end
    """
  end

  defp source_body(module, action_name, :useful_pure) do
    """
    defmodule #{module} do
      use AllbertAssist.Action,
        permission: :read_only,
        exposure: :internal,
        execution_mode: :read_only,
        skill_backed?: false,
        confirmation: :not_required,
        name: "#{action_name}",
        description: "Dynamic loader useful pure fixture.",
        category: "dynamic_plugins",
        tags: ["dynamic", "fixture"],
        schema: [
          name: [type: :string, required: false],
          score: [type: :integer, required: false],
          tags: [type: {:list, :string}, required: false]
        ],
        output_schema: [
          message: [type: :string, required: true],
          status: [type: :atom, required: true],
          actions: [type: {:list, :map}, required: true]
        ]

      @impl true
      def run(params, _context) do
        name = String.trim(Map.get(params, :name, "item"))
        tags = Map.get(params, :tags, [])
        normalized_tags = Enum.map(tags, fn tag -> String.upcase(to_string(tag)) end)
        adjusted_score = Map.get(params, :score, 0) + Enum.count(normalized_tags)

        tier =
          if adjusted_score >= 10 do
            "high"
          else
            "normal"
          end

        message = "\#{name}: \#{tier} score=\#{adjusted_score} tags=\#{Enum.join(normalized_tags, ", ")}"
        {:ok, %{message: message, status: :completed, actions: []}}
      end
    end
    """
  end

  defp source_body(module, action_name, :delegated_memory) do
    """
    defmodule #{module} do
      use AllbertAssist.Action,
        permission: :memory_write,
        exposure: :internal,
        execution_mode: :memory_write,
        skill_backed?: false,
        confirmation: :not_required,
        resumable?: false,
        name: "#{action_name}",
        description: "Dynamic loader delegated memory fixture.",
        category: "dynamic_plugins",
        tags: ["dynamic", "fixture", "delegated"],
        schema: [
          memory: [type: :string, required: true],
          source_text: [type: :string, required: false]
        ],
        output_schema: [
          message: [type: :string, required: true],
          status: [type: :atom, required: true],
          actions: [type: {:list, :map}, required: true]
        ]

      @impl true
      def run(params, context) do
        delegate_params = %{
          memory: Map.get(params, :memory, ""),
          source_text: Map.get(params, :source_text)
        }

        AllbertAssist.DynamicPlugins.Delegate.run("append_memory", delegate_params, context)
      end
    end
    """
  end

  defp source_body(module, action_name, :string_to_atom) do
    """
    defmodule #{module} do
      use AllbertAssist.Action,
        permission: :read_only,
        exposure: :internal,
        execution_mode: :read_only,
        skill_backed?: false,
        confirmation: :not_required,
        name: "#{action_name}",
        description: "Dynamic loader unsafe atom fixture.",
        category: "dynamic_plugins",
        tags: ["dynamic", "fixture"],
        schema: [],
        output_schema: [
          message: [type: :string, required: true],
          status: [type: :atom, required: true],
          actions: [type: {:list, :map}, required: true]
        ]

      @impl true
      def run(_params, _context) do
        value = String.to_atom("unsafe_dynamic_atom")
        {:ok, %{message: Atom.to_string(value), status: :completed, actions: []}}
      end
    end
    """
  end

  defp source_body(module, action_name, :effectful_fun) do
    """
    defmodule #{module} do
      use AllbertAssist.Action,
        permission: :read_only,
        exposure: :internal,
        execution_mode: :read_only,
        skill_backed?: false,
        confirmation: :not_required,
        name: "#{action_name}",
        description: "Dynamic loader unsafe function fixture.",
        category: "dynamic_plugins",
        tags: ["dynamic", "fixture"],
        schema: [],
        output_schema: [
          message: [type: :string, required: true],
          status: [type: :atom, required: true],
          actions: [type: {:list, :map}, required: true]
        ]

      @impl true
      def run(_params, _context) do
        Enum.map(["no"], fn value -> System.cmd("echo", [value]) end)
        {:ok, %{message: "no", status: :completed, actions: []}}
      end
    end
    """
  end

  defp source_permission(:delegated_memory), do: "memory_write"
  defp source_permission(_source_kind), do: "read_only"

  defp cli_context, do: %{actor: "local", channel: :cli, surface: "cli"}

  defp live_view_context do
    %{
      actor: "local",
      operator_id: "local",
      channel: :live_view,
      surface: "AllbertAssistWeb.WorkspaceLive"
    }
  end

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "allbert-dynamic-loader-#{name}-#{System.unique_integer([:positive])}"
    )
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
