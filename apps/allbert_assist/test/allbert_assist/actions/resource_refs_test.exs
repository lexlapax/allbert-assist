defmodule AllbertAssist.Actions.ResourceRefsTest do
  use ExUnit.Case, async: true
  @moduletag :external_runtime_serial

  alias AllbertAssist.Confirmations.ResourceMetadata
  alias AllbertAssist.Resources.Grant
  alias AllbertAssist.Resources.OperationClass
  alias AllbertAssist.Resources.Ref
  alias AllbertAssist.Resources.ResourceURI
  alias AllbertAssist.Resources.Scope

  @digest String.duplicate("a", 64)

  test "scope rejects a missing value instead of stringifying nil" do
    assert {:error, :missing_scope_value} = Scope.new(:exact_file, nil)
  end

  test "shell cwd and path operands create local resource refs" do
    cwd = Path.expand(Path.join(System.tmp_dir!(), "allbert-resource-ref-shell"))
    readme = Path.join(cwd, "README.md")

    refs =
      Ref.from_shell_command_summary(%{
        executable: "ls",
        resolved_cwd: cwd,
        command_class: :read_only,
        sandbox_level: 1,
        timeout_ms: 1_000,
        max_output_bytes: 4_096,
        path_operands: [%{original: "README.md", resolved: readme, allowed?: true}]
      })

    cwd_ref = find_ref!(refs, :local_path, :run_shell_command)
    assert cwd_ref.resource_uri == ResourceURI.file!(cwd)
    assert cwd_ref.access_mode == :execute
    assert cwd_ref.scope == %{kind: :directory_subtree, value: cwd}
    assert cwd_ref.downstream_consumer == :shell_runner
    assert cwd_ref.limits == %{timeout_ms: 1_000, max_output_bytes: 4_096}

    operand_ref = find_ref!(refs, :local_path, :read_local_path)
    assert operand_ref.resource_uri == ResourceURI.file!(readme)
    assert operand_ref.access_mode == :read
    assert operand_ref.scope == %{kind: :exact_file, value: readme}
    assert operand_ref.metadata == %{original: "README.md", allowed?: true}
  end

  test "skill script resources create local skill refs with digest" do
    refs =
      Ref.from_skill_script_summary(%{
        skill_name: "demo-script",
        script_path: "scripts/hello",
        script_sha256: @digest,
        byte_size: 123,
        resolved_executable: "/tmp/allbert/skills/demo-script/scripts/hello",
        resolved_cwd: "/tmp/allbert/runs/run-1/cwd",
        cwd_source: :internal,
        timeout_ms: 2_000,
        max_output_bytes: 8_192,
        sandbox_level: 1
      })

    script_ref = find_ref!(refs, :local_skill_resource, :run_skill_script)
    assert script_ref.resource_uri == "skill://demo-script/scripts/hello"
    assert script_ref.access_mode == :execute
    assert script_ref.scope == %{kind: :skill_resource_id, value: "demo-script:scripts/hello"}
    assert script_ref.digest == @digest
    assert script_ref.downstream_consumer == :skill_script_runner

    cwd_ref = find_ref!(refs, :local_path, :run_skill_script)
    assert cwd_ref.resource_uri == ResourceURI.file!("/tmp/allbert/runs/run-1/cwd")
    assert cwd_ref.access_mode == :execute
    assert cwd_ref.scope == %{kind: :directory_subtree, value: "/tmp/allbert/runs/run-1/cwd"}
  end

  test "external request summaries create remote URL refs with method host path and caps" do
    [ref] =
      Ref.from_external_request_summary(%{
        method: "GET",
        profile: "docs",
        canonical_url: "https://example.com/status?token=secret",
        display_url: "https://example.com/status?[REDACTED]",
        url: "https://example.com/status?[REDACTED]",
        host: "example.com",
        path: "/status",
        query?: true,
        timeout_ms: 5_000,
        max_response_bytes: 16_384,
        allow_redirects?: false,
        max_redirects: 0,
        retry_policy: %{mode: :disabled},
        request_digest: "sha256:request"
      })

    assert ref.origin_kind == :remote_url
    assert ref.resource_uri == "https://example.com/status?token=secret"
    assert ref.operation_class == :external_service_request
    assert ref.access_mode == :fetch
    assert ref.method == "GET"
    assert ref.source_profile == "docs"
    assert ref.canonical_id == "https://example.com/status?token=secret"
    assert ref.scope == %{kind: :exact_url, value: "https://example.com/status?token=secret"}
    assert ref.limits == %{timeout_ms: 5_000, max_response_bytes: 16_384}
    assert ref.metadata.display_url == "https://example.com/status?[REDACTED]"
    assert ref.display_uri == "https://example.com/status?[REDACTED]"
    assert ref.metadata.host == "example.com"
    assert ref.metadata.path == "/status"
    assert ref.redaction.query?
  end

  test "online skill import creates remote source import refs" do
    [ref] =
      Ref.online_skill_source(
        %{
          id: "skills_sh",
          base_url: "https://skills.sh",
          api_url: "https://skills.sh/api",
          max_listing_results: 25,
          max_download_bytes: 262_144
        },
        :online_skill_import,
        %{id: "vercel-labs/skills/find-skills"}
      )

    assert ref.origin_kind == :remote_source
    assert ref.resource_uri == "allbert://sources/online_skill/skills_sh"
    assert ref.operation_class == :online_skill_import
    assert ref.access_mode == :import
    assert ref.scope == %{kind: :source_profile, value: "skills_sh"}
    assert ref.downstream_consumer == :online_skill_registry
    assert ref.limits == %{max_listing_results: 25, max_download_bytes: 262_144}
    assert ref.metadata.id == "vercel-labs/skills/find-skills"
  end

  test "package install summaries create registry and target-root refs" do
    refs =
      Ref.from_package_install_summary(%{
        manager: "npm",
        packages: ["left-pad@1.3.0"],
        target_root: "/tmp/allbert-project",
        resolved_target_root: "/tmp/allbert-project",
        save_mode: :dev,
        timeout_ms: 10_000,
        max_output_bytes: 65_536
      })

    package_ref = find_ref!(refs, :package_registry, :package_install)
    assert package_ref.access_mode == :install
    assert package_ref.resource_uri == "pkg:npm/left-pad@1.3.0"
    assert package_ref.canonical_id == "npm:left-pad@1.3.0"
    assert package_ref.scope == %{kind: :source_profile, value: "npm"}
    assert package_ref.metadata == %{package: "left-pad@1.3.0", save_mode: :dev}

    target_ref = find_ref!(refs, :local_path, :package_install)
    assert target_ref.access_mode == :write
    assert target_ref.resource_uri == ResourceURI.file!("/tmp/allbert-project")
    assert target_ref.scope == %{kind: :package_target_root, value: "/tmp/allbert-project"}
  end

  test "local directory skill import and remote URL skill import cannot share a grant" do
    local_ref = Ref.local_skill_import("/tmp/allbert/skills/local-demo")
    remote_ref = Ref.remote_skill_import("https://example.com/skills/demo/SKILL.md")

    local_grant = Grant.from_ref(local_ref)
    remote_grant = Grant.from_ref(remote_ref)

    assert local_ref.origin_kind == :local_path
    assert local_ref.resource_uri == ResourceURI.file!("/tmp/allbert/skills/local-demo")
    assert local_ref.operation_class == :import_local_skill
    assert local_ref.scope.kind == :directory_subtree

    assert remote_ref.origin_kind == :remote_url
    assert remote_ref.resource_uri == "https://example.com/skills/demo/SKILL.md"
    assert remote_ref.operation_class == :import_skill
    assert remote_ref.scope.kind == :exact_url

    refute Grant.same_authority?(local_grant, remote_grant)
  end

  test "operation classes cannot be invented outside the known vocabulary" do
    assert {:error, {:unknown_operation_class, :invented_operation}} =
             OperationClass.operation_class(:invented_operation)

    assert_raise ArgumentError, ~r/unknown_operation_class/, fn ->
      Ref.new!(%{
        resource_uri: "https://example.com/item",
        origin_kind: :remote_url,
        canonical_id: "https://example.com/item",
        operation_class: :invented_operation,
        scope: Scope.exact_url("https://example.com/item")
      })
    end
  end

  test "MCP operation vocabulary has explicit access modes and scopes" do
    assert OperationClass.operation_class!("mcp-tool-call") == :mcp_tool_call
    assert OperationClass.operation_class!("mcp_resource_read") == :mcp_resource_read
    assert OperationClass.default_access_mode(:mcp_tool_call) == :call
    assert OperationClass.default_access_mode(:mcp_resource_read) == :read
    assert OperationClass.access_mode!("call") == :call
    assert OperationClass.scope_kind!("mcp_server") == :mcp_server
    assert OperationClass.scope_kind!("mcp-tool") == :mcp_tool
  end

  test "browser operation vocabulary has explicit access modes and session scope" do
    assert OperationClass.origin_kind!("browser_session") == :browser_session
    assert OperationClass.scope_kind!("browser-session") == :browser_session
    assert OperationClass.operation_class!("browser-navigate") == :browser_navigate
    assert OperationClass.operation_class!("browser_extract") == :browser_extract
    assert OperationClass.default_access_mode(:browser_navigate) == :fetch
    assert OperationClass.default_access_mode(:browser_extract) == :read
    assert OperationClass.default_access_mode(:browser_screenshot) == :read
    assert OperationClass.default_access_mode(:browser_interact) == :execute
    assert OperationClass.default_access_mode(:browser_form_fill) == :write
    assert OperationClass.default_access_mode(:browser_download) == :write
  end

  test "Plan/Build operation vocabulary has explicit access modes and scopes" do
    assert OperationClass.origin_kind!("plan-run") == :plan_run
    assert OperationClass.scope_kind!("plan_run") == :plan_run
    assert OperationClass.scope_kind!("workflow-ref") == :workflow_ref
    assert OperationClass.operation_class!("workflow-expand") == :workflow_expand
    assert OperationClass.operation_class!("plan_preview") == :plan_preview
    assert OperationClass.operation_class!("plan-run-start") == :plan_run_start
    assert OperationClass.operation_class!("plan_cancel") == :plan_cancel
    assert OperationClass.default_access_mode(:workflow_expand) == :read
    assert OperationClass.default_access_mode(:plan_preview) == :read
    assert OperationClass.default_access_mode(:plan_run_start) == :execute
    assert OperationClass.default_access_mode(:plan_cancel) == :execute
  end

  test "Marketplace operation vocabulary has explicit access modes and entry scope" do
    assert OperationClass.origin_kind!("marketplace-entry") == :marketplace_entry
    assert OperationClass.scope_kind!("marketplace_entry") == :marketplace_entry
    assert OperationClass.operation_class!("marketplace-browse") == :marketplace_browse

    assert OperationClass.operation_class!("marketplace_install_bundle") ==
             :marketplace_install_bundle

    assert OperationClass.operation_class!("marketplace-rollback") == :marketplace_rollback
    assert OperationClass.default_access_mode(:marketplace_browse) == :read
    assert OperationClass.default_access_mode(:marketplace_install_bundle) == :write
    assert OperationClass.default_access_mode(:marketplace_rollback) == :write
  end

  test "MCP resource URIs are supported resource identities" do
    resource_uri = ResourceURI.mcp!("local-server", "file:///resources/doc.md")

    assert resource_uri == "mcp://local-server/file:%2F%2F%2Fresources%2Fdoc.md"
    assert {:ok, normalized} = ResourceURI.normalize(resource_uri)
    assert normalized == resource_uri

    assert {:ok, derived} = ResourceURI.derived_fields(resource_uri)
    assert derived.origin_kind == :mcp_resource
    assert derived.server_id == "local-server"
    assert derived.server_resource_uri == "file:///resources/doc.md"
    refute derived.unsupported?

    mcp_ref =
      Ref.new!(%{
        resource_uri: resource_uri,
        operation_class: :mcp_resource_read,
        access_mode: :read,
        scope: Scope.mcp_server("local-server"),
        downstream_consumer: :mcp_resource_reader
      })

    assert mcp_ref.origin_kind == :mcp_resource
    assert mcp_ref.canonical_id == mcp_ref.resource_uri
    refute mcp_ref.unsupported?
    assert mcp_ref.metadata == %{}
  end

  test "browser session URIs are supported resource identities but not navigation grants" do
    resource_uri = ResourceURI.browser_session!("session-123")

    assert resource_uri == "browser://session/session-123"
    assert {:ok, ^resource_uri} = ResourceURI.normalize(resource_uri)

    assert {:ok, ^resource_uri} =
             ResourceURI.scope_uri(
               :browser_session,
               :browser_session,
               "session-123",
               resource_uri
             )

    assert {:ok, derived} = ResourceURI.derived_fields(resource_uri)
    assert derived.origin_kind == :browser_session
    assert derived.canonical_id == resource_uri
    assert derived.session_id == "session-123"
    refute derived.unsupported?

    browser_ref =
      Ref.new!(%{
        resource_uri: resource_uri,
        operation_class: :browser_extract,
        access_mode: :read,
        scope: Scope.browser_session(resource_uri),
        downstream_consumer: :browser_session
      })

    assert browser_ref.origin_kind == :browser_session
    assert browser_ref.canonical_id == browser_ref.resource_uri
    assert browser_ref.scope.kind == :browser_session
  end

  test "browser session URI normalization rejects malformed session identity" do
    for uri <- [
          "browser://session/",
          "browser://session/abc/extra",
          "browser://other/abc",
          "browser://session/abc?x=1",
          "browser://session/abc#frag",
          "browser://session/not ok"
        ] do
      assert {:error, _reason} = ResourceURI.normalize(uri)
    end
  end

  test "workflow and plan run URIs are supported resource identities" do
    workflow_uri = ResourceURI.workflow!("nightly-briefing")
    objective_id = "obj_00000000-0000-4000-8000-000000000044"
    plan_uri = ResourceURI.plan_run!(objective_id)

    assert workflow_uri == "workflow://nightly-briefing"
    assert plan_uri == "plan://run/#{objective_id}"
    assert {:ok, ^workflow_uri} = ResourceURI.normalize(workflow_uri)
    assert {:ok, ^plan_uri} = ResourceURI.normalize(plan_uri)

    assert {:ok, ^workflow_uri} =
             ResourceURI.scope_uri(:plan_run, :workflow_ref, "nightly-briefing", plan_uri)

    assert {:ok, ^plan_uri} = ResourceURI.scope_uri(:plan_run, :plan_run, objective_id, plan_uri)

    assert {:ok, workflow_derived} = ResourceURI.derived_fields(workflow_uri)
    assert workflow_derived.origin_kind == :plan_run
    assert workflow_derived.canonical_id == workflow_uri
    assert workflow_derived.workflow_id == "nightly-briefing"
    refute workflow_derived.unsupported?

    assert {:ok, plan_derived} = ResourceURI.derived_fields(plan_uri)
    assert plan_derived.origin_kind == :plan_run
    assert plan_derived.canonical_id == plan_uri
    assert plan_derived.objective_id == objective_id
    refute plan_derived.unsupported?
  end

  test "workflow and plan run URI normalization rejects malformed identity" do
    for uri <- [
          "workflow://",
          "workflow://Nightly",
          "workflow://nightly/extra",
          "workflow://nightly?x=1",
          "workflow://nightly#frag",
          "workflow://not ok",
          "plan://run/",
          "plan://run/abc",
          "plan://run/obj_00000000-0000-4000-8000-000000000044/extra",
          "plan://other/obj_00000000-0000-4000-8000-000000000044",
          "plan://run/obj_00000000-0000-4000-8000-000000000044?x=1",
          "plan://run/obj_00000000-0000-4000-8000-000000000044#frag"
        ] do
      assert {:error, _reason} = ResourceURI.normalize(uri)
    end
  end

  test "marketplace entry URIs are supported resource identities" do
    resource_uri = ResourceURI.marketplace_entry!("allbert/write-weekly-note")

    assert resource_uri == "marketplace://entry/allbert/write-weekly-note"
    assert {:ok, ^resource_uri} = ResourceURI.normalize(resource_uri)

    assert {:ok, ^resource_uri} =
             ResourceURI.scope_uri(
               :marketplace_entry,
               :marketplace_entry,
               "allbert/write-weekly-note",
               resource_uri
             )

    assert {:ok, ^resource_uri} =
             ResourceURI.scope_uri(
               :marketplace_entry,
               :marketplace_entry,
               resource_uri,
               resource_uri
             )

    assert {:ok, derived} = ResourceURI.derived_fields(resource_uri)
    assert derived.origin_kind == :marketplace_entry
    assert derived.canonical_id == "allbert/write-weekly-note"
    assert derived.entry_id == "allbert/write-weekly-note"
    refute derived.unsupported?

    marketplace_ref =
      Ref.new!(%{
        resource_uri: resource_uri,
        operation_class: :marketplace_browse,
        access_mode: :read,
        scope: Scope.marketplace_entry(resource_uri),
        downstream_consumer: :marketplace_catalog
      })

    assert marketplace_ref.origin_kind == :marketplace_entry
    assert marketplace_ref.canonical_id == "allbert/write-weekly-note"
    assert marketplace_ref.scope.kind == :marketplace_entry
  end

  test "marketplace entry URI normalization rejects malformed identity" do
    for uri <- [
          "marketplace://entry/",
          "marketplace://entry/allbert",
          "marketplace://entry/allbert/write-weekly-note/extra",
          "marketplace://other/allbert/write-weekly-note",
          "marketplace://entry/Allbert/write-weekly-note",
          "marketplace://entry/allbert/not ok",
          "marketplace://entry/allbert/write-weekly-note?x=1",
          "marketplace://entry/allbert/write-weekly-note#frag"
        ] do
      assert {:error, _reason} = ResourceURI.normalize(uri)
    end
  end

  test "unsupported future agent URI schemes are representable but inert" do
    agent_ref =
      Ref.new!(%{
        resource_uri: "agent+https://agent.example/tasks/review",
        operation_class: :inspect_document,
        access_mode: :read,
        scope: Scope.exact_url("agent+https://agent.example/tasks/review"),
        downstream_consumer: :agent_delegate
      })

    assert agent_ref.origin_kind == :agent_endpoint
    assert agent_ref.unsupported?
  end

  test "resource metadata renderer summarizes refs without raw payloads" do
    refs =
      Ref.online_skill_source(
        %{id: "skills_sh", base_url: "https://skills.sh", api_url: "https://skills.sh/api"},
        :online_skill_search,
        %{query: "memory"}
      )

    lines = ResourceMetadata.resource_lines(%{resource_refs: refs})

    assert lines == [
             "Resource remote_source online_skill_search fetch source_profile:skills_sh consumer=online_skill_registry"
           ]
  end

  test "resource metadata renderer uses display URL for URL refs" do
    refs =
      Ref.from_external_request_summary(%{
        method: "GET",
        profile: "docs",
        canonical_url: "https://example.com/status?token=secret",
        display_url: "https://example.com/status?[REDACTED]"
      })

    assert ResourceMetadata.resource_lines(%{resource_refs: refs}) == [
             "Resource remote_url external_service_request fetch exact_url:https://example.com/status?[REDACTED] consumer=req_http"
           ]
  end

  defp find_ref!(refs, origin_kind, operation_class) do
    Enum.find(refs, fn ref ->
      ref.origin_kind == origin_kind and ref.operation_class == operation_class
    end) || flunk("missing #{origin_kind}/#{operation_class} in #{inspect(refs)}")
  end
end
