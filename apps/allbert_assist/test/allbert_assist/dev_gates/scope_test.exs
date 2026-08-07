defmodule AllbertAssist.DevGates.ScopeSelectorTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.DevGates.ScopeSelector

  test "classification unions overlapping exact-prefix rules and only widens" do
    docs = ScopeSelector.classify_paths(["docs/operator/models.md"])
    refute docs["aggregate_required"]
    assert docs["matched_rules"] == ["documentation"]
    assert docs["required_gates"] == ["preflight", "docs"]

    settings =
      ScopeSelector.classify_paths([
        "apps/allbert_assist/lib/allbert_assist/settings/schema.ex"
      ])

    assert settings["aggregate_required"]
    assert settings["matched_rules"] == ["core", "settings_spine"]
    assert "app_env_serial" in settings["lanes"]
    assert settings["required_gates"] == ["preflight", "release.v132"]

    manifest = ScopeSelector.classify_paths(["docs/validation/test-manifest.csv"])
    assert manifest["aggregate_required"]
    assert manifest["matched_rules"] == ["documentation", "gate_definitions"]

    license_union = ScopeSelector.classify_paths(["THIRD-PARTY-LICENSES.md"])
    assert license_union["aggregate_required"]
    assert license_union["matched_rules"] == ["release_workflow"]
    assert license_union["owners"] == ["release"]
    assert license_union["lanes"] == ["external_runtime_serial"]
    assert license_union["diagnostics"] == []

    unknown = ScopeSelector.classify_paths(["unexpected/new-root.txt"])
    assert unknown["aggregate_required"]
    assert unknown["matched_rules"] == []
    assert unknown["required_gates"] == ["preflight", "release.v132"]
    assert unknown["diagnostics"] == ["unknown paths fail closed: unexpected/new-root.txt"]

    artifacts =
      ScopeSelector.classify_paths([
        "plugins/allbert.artifacts/test/allbert_artifacts/plugin_test.exs"
      ])

    refute artifacts["aggregate_required"]
    assert artifacts["matched_rules"] == ["artifacts_plugin"]
    assert artifacts["owners"] == ["artifacts"]
    assert artifacts["lanes"] == ["db_serial", "global_process_serial"]
    assert artifacts["diagnostics"] == []

    kernel =
      ScopeSelector.classify_paths([
        "apps/allbert_kernel/lib/allbert_assist/pack/kernel.ex"
      ])

    assert kernel["aggregate_required"]
    assert kernel["matched_rules"] == ["kernel"]
    assert kernel["owners"] == ["kernel"]

    assert kernel["lanes"] == [
             "app_env_serial",
             "global_process_serial",
             "home_fs_serial",
             "pure_async"
           ]

    composition =
      ScopeSelector.classify_paths([
        "apps/allbert_composition/lib/allbert_assist/pack/product_bootstrap.ex"
      ])

    assert composition["aggregate_required"]
    assert composition["matched_rules"] == ["composition"]
    assert composition["owners"] == ["composition"]

    assert composition["lanes"] == [
             "app_env_serial",
             "external_runtime_serial",
             "global_process_serial",
             "pure_async"
           ]
  end

  test "selector includes committed, staged, unstaged, rename, deletion, and untracked paths" do
    root = git_repo!()
    on_exit(fn -> File.rm_rf!(root) end)
    base = git!(root, ["rev-parse", "HEAD"]) |> String.trim()

    File.write!(Path.join(root, "README.md"), "committed\n")
    git!(root, ["add", "README.md"])
    git!(root, ["commit", "--quiet", "-m", "committed change"])
    git!(root, ["mv", "docs/old.md", "docs/new.md"])
    File.rm!(Path.join(root, "apps/allbert_assist/lib/sample.ex"))
    File.write!(Path.join(root, "unknown.file"), "unknown\n")

    result = ScopeSelector.select!(root, base)
    paths = Enum.map(result["changed_paths"], & &1["path"])

    assert "README.md" in paths
    assert "docs/old.md" in paths
    assert "docs/new.md" in paths
    assert "apps/allbert_assist/lib/sample.ex" in paths
    assert "unknown.file" in paths
    assert result["aggregate_required"]
    assert result["diagnostics"] == ["unknown paths fail closed: unknown.file"]

    sources = Map.new(result["changed_paths"], &{&1["path"], &1["source"]})
    assert sources["README.md"] == "committed"
    assert sources["docs/new.md"] == "staged"
    assert sources["apps/allbert_assist/lib/sample.ex"] == "unstaged"
    assert sources["unknown.file"] == "untracked"
  end

  test "invalid or missing base fails nonzero instead of narrowing" do
    assert_raise Mix.Error, "scope --base must be a 7-40 character hexadecimal commit id", fn ->
      ScopeSelector.select!("/tmp", "HEAD")
    end

    root = git_repo!()
    on_exit(fn -> File.rm_rf!(root) end)

    assert_raise Mix.Error, ~r/git rev-parse .* failed/, fn ->
      ScopeSelector.select!(root, String.duplicate("f", 40))
    end
  end

  test "a real but non-ancestor base fails nonzero" do
    root = git_repo!()
    on_exit(fn -> File.rm_rf!(root) end)
    main = git!(root, ["branch", "--show-current"]) |> String.trim()

    git!(root, ["checkout", "--quiet", "-b", "side"])
    File.write!(Path.join(root, "side.txt"), "side\n")
    git!(root, ["add", "side.txt"])
    git!(root, ["commit", "--quiet", "-m", "side"])
    side = git!(root, ["rev-parse", "HEAD"]) |> String.trim()
    git!(root, ["checkout", "--quiet", main])
    File.write!(Path.join(root, "main.txt"), "main\n")
    git!(root, ["add", "main.txt"])
    git!(root, ["commit", "--quiet", "-m", "main"])

    assert_raise Mix.Error, ~r/not an ancestor/, fn ->
      ScopeSelector.select!(root, side)
    end
  end

  defp git_repo! do
    root = Path.join(System.tmp_dir!(), "allbert-scope-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "docs"))
    File.mkdir_p!(Path.join(root, "apps/allbert_assist/lib"))
    git!(root, ["init", "--quiet"])
    git!(root, ["config", "user.email", "test@example.invalid"])
    git!(root, ["config", "user.name", "Allbert Test"])
    File.write!(Path.join(root, "docs/old.md"), "old\n")
    File.write!(Path.join(root, "apps/allbert_assist/lib/sample.ex"), "sample\n")
    git!(root, ["add", "."])
    git!(root, ["commit", "--quiet", "-m", "initial"])
    root
  end

  defp git!(root, args) do
    assert {output, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    output
  end
end
