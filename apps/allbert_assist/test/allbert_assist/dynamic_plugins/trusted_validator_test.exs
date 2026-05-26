defmodule AllbertAssist.DynamicPlugins.TrustedValidatorTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.DynamicPlugins
  alias AllbertAssist.DynamicPlugins.MetadataStore
  alias AllbertAssist.DynamicPlugins.TrustedValidator
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    home = temp_path("home")

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.delete_env(:allbert_assist, Settings)

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  test "accepts a delegated memory_write action when permission and facade are enabled" do
    allow_permissions!(["read_only", "memory_write"])
    allow_facades!(["append_memory"])
    fixture = write_action_draft("validator_delegate_memory", :delegate_memory, "memory_write")

    assert {:ok, validation} = TrustedValidator.validate(fixture.draft, fixture.manifest)
    assert validation.actions == [fixture.action_spec]
  end

  test "rejects delegated write permissions when the operator setting is still read_only only" do
    fixture = write_action_draft("validator_delegate_default", :delegate_memory, "memory_write")

    assert {:error, {:unsupported_dynamic_action_permissions, ["memory_write"]}} =
             TrustedValidator.validate(fixture.draft, fixture.manifest)
  end

  test "rejects delegated facades that are not enabled" do
    allow_permissions!(["read_only", "memory_write"])
    fixture = write_action_draft("validator_delegate_disabled", :delegate_memory, "memory_write")

    assert {:error,
            {:trusted_validation_failed, "source/lib/action.ex",
             {:dynamic_delegate_facade_not_allowed, "append_memory"}}} =
             TrustedValidator.validate(fixture.draft, fixture.manifest)
  end

  test "rejects non-literal delegated facade names" do
    allow_permissions!(["read_only", "memory_write"])
    allow_facades!(["append_memory"])

    fixture =
      write_action_draft("validator_delegate_variable", :delegate_variable_facade, "memory_write")

    assert {:error,
            {:trusted_validation_failed, "source/lib/action.ex",
             :dynamic_delegate_facade_name_not_literal}} =
             TrustedValidator.validate(fixture.draft, fixture.manifest)
  end

  test "rejects generated permission and delegated facade mismatches" do
    allow_permissions!(["read_only", "memory_write", "external_network"])
    allow_facades!(["append_memory", "external_network_request"])

    fixture =
      write_action_draft(
        "validator_delegate_mismatch",
        :delegate_external,
        "memory_write"
      )

    assert {:error,
            {:trusted_validation_failed, "source/lib/action.ex",
             {:dynamic_delegate_permission_mismatch,
              %{
                permission: :memory_write,
                facade: "external_network_request",
                facade_permission: :external_network
              }}}} =
             TrustedValidator.validate(fixture.draft, fixture.manifest)
  end

  test "rejects response action metadata that does not match generated permission" do
    allow_permissions!(["read_only", "memory_write"])
    allow_facades!(["append_memory"])

    fixture =
      write_action_draft(
        "validator_response_mismatch",
        :delegate_response_mismatch,
        "memory_write"
      )

    assert {:error,
            {:trusted_validation_failed, "source/lib/action.ex",
             {:dynamic_action_response_permission_mismatch,
              %{permission: :memory_write, response_permissions: [:external_network]}}}} =
             TrustedValidator.validate(fixture.draft, fixture.manifest)
  end

  defp allow_permissions!(permissions) do
    assert {:ok, _setting} =
             Settings.put("dynamic_codegen.allowed_action_permissions", permissions, %{
               audit?: false
             })
  end

  defp allow_facades!(facades) do
    assert {:ok, _setting} =
             Settings.put("dynamic_codegen.allowed_facades", facades, %{audit?: false})
  end

  defp write_action_draft(slug, source_kind, permission) do
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

    action_spec = %{
      name: action_name,
      module: module,
      permission: permission,
      exposure: "internal"
    }

    manifest = %{
      "target_shapes" => ["action"],
      "modules" => [module],
      "actions" => [action_spec],
      "files" => [%{"source_path" => source_rel, "compiled_path" => source_compiled}],
      "tests" => []
    }

    %{draft: draft, manifest: manifest, action_spec: action_spec}
  end

  defp source_body(module, action_name, source_kind) do
    permission =
      case source_kind do
        :delegate_external -> :memory_write
        _other -> :memory_write
      end

    run_body =
      case source_kind do
        :delegate_memory ->
          """
              delegate_params = %{
                memory: Map.get(params, :memory, ""),
                source_text: Map.get(params, :source_text)
              }

              AllbertAssist.DynamicPlugins.Delegate.run("append_memory", delegate_params, context)
          """

        :delegate_variable_facade ->
          """
              facade = "append_memory"
              delegate_params = %{memory: Map.get(params, :memory, "")}
              AllbertAssist.DynamicPlugins.Delegate.run(facade, delegate_params, context)
          """

        :delegate_external ->
          """
              delegate_params = %{url: Map.get(params, :url, "https://example.com/status")}
              AllbertAssist.DynamicPlugins.Delegate.run("external_network_request", delegate_params, context)
          """

        :delegate_response_mismatch ->
          """
              delegate_params = %{memory: Map.get(params, :memory, "")}

              case AllbertAssist.DynamicPlugins.Delegate.run("append_memory", delegate_params, context) do
                {:ok, response} ->
                  {:ok, Map.put(response, :actions, [%{name: "wrong", permission: :external_network}])}

                {:error, reason} ->
                  {:error, reason}
              end
          """
      end

    """
    defmodule #{module} do
      use AllbertAssist.Action,
        permission: :#{permission},
        exposure: :internal,
        execution_mode: :#{permission},
        skill_backed?: false,
        confirmation: :not_required,
        resumable?: false,
        name: "#{action_name}",
        description: "Dynamic delegated validator fixture.",
        category: "dynamic_plugins",
        tags: ["dynamic", "fixture", "delegated"],
        schema: [
          memory: [type: :string, required: false],
          source_text: [type: :string, required: false],
          url: [type: :string, required: false]
        ],
        output_schema: [
          message: [type: :string, required: true],
          status: [type: :atom, required: true],
          actions: [type: {:list, :map}, required: true]
        ]

      @impl true
      def run(params, context) do
    #{run_body}
      end
    end
    """
  end

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "allbert-trusted-validator-#{name}-#{System.unique_integer([:positive])}"
    )
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
