defmodule AllbertAssist.Resources.GrantsTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Resources.Grants
  alias AllbertAssist.Resources.Ref
  alias AllbertAssist.Resources.Scope
  alias AllbertAssist.Settings

  setup do
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-resource-grants-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    on_exit(fn ->
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "Settings Central validates remembered grant records" do
    assert {:ok, []} = Settings.get("resource_grants.remembered")

    assert {:error,
            {:invalid_setting, "resource_grants.remembered",
             {:unknown_operation_class, "do_anything"}}} =
             Settings.put(
               "resource_grants.remembered",
               [
                 %{
                   "id" => "grant_bad",
                   "origin_kind" => "remote_url",
                   "scope" => %{"kind" => "exact_url", "value" => "https://example.com/a"},
                   "canonical_scope" => "https://example.com/a",
                   "operation_class" => "do_anything",
                   "access_mode" => "fetch",
                   "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
                 }
               ],
               %{audit?: false}
             )
  end

  test "exact file grants do not expand to parent directories", %{root: root} do
    file = Path.join([root, "workspace", "docs", "a.txt"])
    sibling = Path.join([root, "workspace", "docs", "b.txt"])

    assert {:ok, grant} =
             Grants.remember(read_file_ref(file),
               reason: "remember exact file",
               origin_channel: :cli,
               resolver_channel: :cli,
               audit?: false
             )

    assert grant["scope"] == %{"kind" => "exact_file", "value" => Path.expand(file)}
    assert {:ok, ^grant} = find(read_file_ref(file), :read_only)
    assert {:error, :no_matching_grant} = find(read_file_ref(sibling), :read_only)
  end

  test "directory subtree grants canonicalize traversal and deny symlink escape", %{root: root} do
    allowed = Path.join([root, "workspace", "allowed"])
    outside = Path.join([root, "workspace", "outside"])
    inside_file = Path.join(allowed, "notes.txt")
    outside_file = Path.join(outside, "secret.txt")
    symlink = Path.join(allowed, "link-to-secret.txt")

    File.mkdir_p!(allowed)
    File.mkdir_p!(outside)
    File.write!(inside_file, "inside")
    File.write!(outside_file, "outside")
    assert :ok = File.ln_s(outside_file, symlink)

    assert {:ok, grant} =
             Grants.remember(
               %{
                 origin_kind: :local_path,
                 canonical_id: allowed,
                 operation_class: :read_local_path,
                 access_mode: :read,
                 scope: Scope.directory_subtree(allowed),
                 downstream_consumer: :file_reader
               },
               audit?: false
             )

    assert {:ok, ^grant} = find(read_file_ref(inside_file), :read_only)

    traversal = Path.join([allowed, "..", "outside", "secret.txt"])
    assert {:error, :no_matching_grant} = find(read_file_ref(traversal), :read_only)
    assert {:error, :no_matching_grant} = find(read_file_ref(symlink), :read_only)
  end

  test "exact URL grants do not expand to host" do
    exact = external_ref("https://example.com/docs/a?x=1")
    other_path = external_ref("https://example.com/docs/b?x=1")

    assert {:ok, grant} = Grants.remember(exact, audit?: false)

    assert grant["scope"] == %{
             "kind" => "exact_url",
             "value" => "https://example.com/docs/a?x=1"
           }

    assert {:ok, ^grant} = find(exact, :external_network)
    assert {:error, :no_matching_grant} = find(other_path, :external_network)
  end

  test "URL prefix grants cannot cross scheme host or redirect target" do
    ref = summarize_ref("https://example.com/docs/a")

    assert {:ok, grant} =
             Grants.remember(
               %{
                 origin_kind: :remote_url,
                 canonical_id: "https://example.com/docs/",
                 operation_class: :summarize_url,
                 access_mode: :summarize,
                 scope: Scope.url_prefix("https://example.com/docs/"),
                 downstream_consumer: :summarizer
               },
               audit?: false
             )

    assert {:ok, ^grant} = find(ref, :external_network)

    assert {:error, :no_matching_grant} =
             find(summarize_ref("http://example.com/docs/a"), :external_network)

    assert {:error, :no_matching_grant} =
             find(summarize_ref("https://evil.example/docs/a"), :external_network)

    assert {:error, {:redirect_outside_scope, "https://evil.example/docs/a"}} =
             find(ref, :external_network, redirect_url: "https://evil.example/docs/a")
  end

  test "source profile grants match only the same source" do
    source_ref =
      %{id: "skills_sh", base_url: "https://skills.sh", api_url: "https://skills.sh/api"}
      |> Ref.online_skill_source(:online_skill_search, %{query: "memory"})
      |> List.first()

    other_source_ref =
      %{id: "other_registry", base_url: "https://example.com", api_url: "https://example.com/api"}
      |> Ref.online_skill_source(:online_skill_search, %{query: "memory"})
      |> List.first()

    assert {:ok, grant} = Grants.remember(source_ref, audit?: false)
    assert {:ok, ^grant} = find(source_ref, :external_network)
    assert {:error, :no_matching_grant} = find(other_source_ref, :external_network)
  end

  test "operation mismatch keeps URL summary grants from authorizing imports" do
    summarize = summarize_ref("https://example.com/skills/demo/SKILL.md")
    import = Ref.remote_skill_import("https://example.com/skills/demo/SKILL.md")

    assert {:ok, _setting} =
             Settings.put("permissions.online_skill_import", "allowed", %{audit?: false})

    assert {:ok, _grant} = Grants.remember(summarize, audit?: false)
    assert {:error, :no_matching_grant} = find(import, :online_skill_import)
  end

  test "local and remote skill import grants remain separate" do
    local = Ref.local_skill_import(Path.join(System.tmp_dir!(), "local-skill"))
    remote = Ref.remote_skill_import("https://example.com/skills/demo/SKILL.md")

    assert {:ok, _setting} =
             Settings.put("permissions.online_skill_import", "allowed", %{audit?: false})

    assert {:ok, _grant} = Grants.remember(local, audit?: false)
    assert {:error, :no_matching_grant} = find(remote, :online_skill_import)
  end

  test "expired and revoked grants are denied" do
    expired_url = external_ref("https://example.com/expired")
    revoked_url = external_ref("https://example.com/revoked")

    assert {:ok, expired} =
             Grants.remember(expired_url,
               id: "grant_expired",
               expires_at: DateTime.add(DateTime.utc_now(), -60, :second),
               audit?: false
             )

    expired_id = expired["id"]
    assert {:error, {:grant_expired, ^expired_id}} = find(expired_url, :external_network)

    assert {:ok, grant} = Grants.remember(revoked_url, id: "grant_revoked", audit?: false)
    assert {:ok, revoked} = Grants.revoke(grant["id"], audit?: false)
    assert revoked["revoked_at"]
    revoked_id = grant["id"]
    assert {:error, {:grant_revoked, ^revoked_id}} = find(revoked_url, :external_network)
  end

  test "Security Central policy drift denies before grant use" do
    ref = external_ref("https://example.com/status")

    assert {:ok, grant} = Grants.remember(ref, audit?: false)
    assert {:ok, ^grant} = find(ref, :external_network)

    assert {:ok, _setting} =
             Settings.put("permissions.external_network", "denied", %{audit?: false})

    assert {:error, {:policy_denied, decision}} = find(ref, :external_network)
    assert decision.permission == :external_network
    assert decision.decision == :denied
  end

  test "remember options are operation-scoped handoff data" do
    assert {:ok, options} = Grants.remember_options(summarize_ref("https://example.com/docs/a"))

    assert Enum.all?(options, &(&1.operation_class == "summarize_url"))
    assert Enum.any?(options, &(&1.scope["kind"] == "exact_url"))
    assert Enum.any?(options, &(&1.scope["kind"] == "url_prefix"))
  end

  defp read_file_ref(path) do
    path = Path.expand(path)

    %{
      origin_kind: :local_path,
      canonical_id: path,
      operation_class: :read_local_path,
      access_mode: :read,
      scope: Scope.exact_file(path),
      downstream_consumer: :file_reader
    }
  end

  defp external_ref(url) do
    %{
      origin_kind: :remote_url,
      canonical_id: url,
      operation_class: :external_service_request,
      access_mode: :fetch,
      scope: Scope.exact_url(url),
      downstream_consumer: :req_http
    }
  end

  defp summarize_ref(url) do
    %{
      origin_kind: :remote_url,
      canonical_id: url,
      operation_class: :summarize_url,
      access_mode: :summarize,
      scope: Scope.exact_url(url),
      downstream_consumer: :summarizer
    }
  end

  defp find(ref, permission, opts \\ []) do
    opts = Keyword.put(opts, :permission, permission)
    Grants.find_applicable(ref, opts)
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
