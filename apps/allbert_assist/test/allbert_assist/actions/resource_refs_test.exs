defmodule AllbertAssist.Actions.ResourceRefsTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Confirmations.ResourceMetadata
  alias AllbertAssist.Resources.Grant
  alias AllbertAssist.Resources.OperationClass
  alias AllbertAssist.Resources.Ref
  alias AllbertAssist.Resources.ResourceURI
  alias AllbertAssist.Resources.Scope

  @digest String.duplicate("a", 64)

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

  test "unsupported future URI schemes are representable but inert" do
    mcp_ref =
      Ref.new!(%{
        resource_uri: "mcp://local-server/resources/doc",
        operation_class: :inspect_document,
        access_mode: :read,
        scope: Scope.source_profile("mcp-local"),
        downstream_consumer: :mcp_resource_reader
      })

    agent_ref =
      Ref.new!(%{
        resource_uri: "agent+https://agent.example/tasks/review",
        operation_class: :inspect_document,
        access_mode: :read,
        scope: Scope.exact_url("agent+https://agent.example/tasks/review"),
        downstream_consumer: :agent_delegate
      })

    assert mcp_ref.origin_kind == :mcp_resource
    assert mcp_ref.unsupported?
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
