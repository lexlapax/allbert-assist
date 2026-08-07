defmodule Mix.Tasks.Allbert.LicensesTest do
  use ExUnit.Case, async: false

  @moduletag :external_runtime_serial

  alias AllbertAssist.CLI.Commands
  alias AllbertAssist.Licenses
  alias Mix.Tasks.Allbert.Licenses, as: LicensesTask

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "allbert-license-task-test-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(tmp, "apps/allbert_assist/priv/licenses"))
    File.write!(Path.join(tmp, "LICENSE"), "fixture license\n")
    File.write!(Path.join(tmp, "NOTICE"), "fixture notice\n")
    File.write!(Path.join(tmp, "MIT.txt"), "fixture MIT text\n")
    File.write!(Path.join(tmp, "review.lock"), "reviewed\n")

    catalog = %{
      "schema_version" => 1,
      "claim" => "Best-effort inventory fixture.",
      "reviewed_inputs" => [
        %{
          "id" => "fixture-lock",
          "path" => "review.lock",
          "sha256" => digest("reviewed\n")
        }
      ],
      "texts" => [
        %{
          "id" => "MIT",
          "license_id" => "MIT",
          "path" => "MIT.txt",
          "sha256" => digest("fixture MIT text\n")
        }
      ],
      "components" => [
        %{
          "id" => "external-fixture",
          "name" => "External fixture",
          "kind" => "external",
          "license_expression" => "NOASSERTION",
          "bundled" => false,
          "text_ids" => [],
          "forbidden_paths" => []
        }
      ]
    }

    catalog_path = Path.join(tmp, "apps/allbert_assist/priv/licenses/catalog.json")
    File.write!(catalog_path, Jason.encode!(catalog, pretty: true) <> "\n")

    on_exit(fn ->
      Mix.Task.reenable("allbert.licenses")
      File.rm_rf(tmp)
    end)

    %{root: tmp, catalog: catalog, catalog_path: catalog_path}
  end

  test "generates and checks the committed union", %{root: root} do
    assert :ok = LicensesTask.run(["--root", root])
    union = Path.join(root, "THIRD-PARTY-LICENSES.md")
    assert File.read!(union) =~ "external-fixture"

    Mix.Task.reenable("allbert.licenses")
    assert :ok = LicensesTask.run(["--root", root, "--check"])

    File.write!(union, "drift\n")
    Mix.Task.reenable("allbert.licenses")

    assert_raise Mix.Error, ~r/union_drift/, fn ->
      LicensesTask.run(["--root", root, "--check"])
    end
  end

  test "fails closed on catalog text drift", %{root: root} do
    File.write!(Path.join(root, "MIT.txt"), "changed\n")

    assert_raise Mix.Error, ~r/license_text_digest_mismatch/, fn ->
      LicensesTask.run(["--root", root, "--check"])
    end
  end

  test "rejects invalid options" do
    assert_raise Mix.Error, ~r/Invalid option/, fn ->
      LicensesTask.run(["--network"])
    end
  end

  test "the real source union is current and the task starts no new application" do
    root = Path.expand("../../../../..", __DIR__)
    before = Application.started_applications()

    assert {:ok, %{mode: :check}} = Licenses.generate_repo(repo_root: root, check: true)
    assert {:ok, catalog} = Licenses.load_catalog(repo_root: root)
    assert {:ok, products} = Licenses.repo_products(catalog, repo_root: root)

    bandit = Enum.find(catalog["components"], &(&1["id"] == "beam-bandit"))
    [bandit_text_id] = bandit["text_ids"]
    bandit_text = Enum.find(products.texts, &(&1["id"] == bandit_text_id))
    assert bandit_text["contents"] =~ "Copyright (c) 2020 Mat Trudel"

    notice = File.read!(Path.join(root, "NOTICE"))
    assert notice =~ "Copyright 2014-2020 Benoît Chesneau"
    assert notice =~ "Copyright (c) 2018, Chris McCord and Erlang Solutions"
    assert Application.started_applications() == before
  end

  test "top-level licenses dispatch runs in a clean VM before Req or Allbert starts", %{
    root: root,
    catalog: catalog
  } do
    release = Path.join(root, "release")
    File.mkdir_p!(release)
    {:ok, target} = Licenses.build_target()
    File.mkdir_p!(Path.join(release, "erts-#{target["erts_version"]}"))
    File.write!(Path.join(release, "payload.bin"), "fixture\n")
    assert {:ok, _result} = Licenses.generate_repo(repo_root: root)

    assert {:ok, _result} =
             Licenses.finalize(
               catalog,
               [],
               target,
               repo_root: root,
               release_root: release
             )

    assert {:ok, :builtin} = Commands.lookup(["licenses"])

    isolated_release =
      Path.join(
        System.tmp_dir!(),
        "allbert-packaged-license-test-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.rename!(release, isolated_release)
    File.rm_rf!(root)
    on_exit(fn -> File.rm_rf(isolated_release) end)

    project_root = Path.expand("../../../../..", __DIR__)
    code_paths = Path.wildcard(Path.join(project_root, "_build/test/lib/*/ebin"))

    script = """
    {_stream, _output, code} = AllbertAssist.Pack.ProductCLI.run_entry(["licenses", "--json"])
    forbidden =
      Application.started_applications()
      |> Enum.map(&elem(&1, 0))
      |> Enum.filter(&(&1 in [:req, :allbert_assist, :allbert_assist_web, :ecto_sql]))
    IO.puts("code=\#{code} forbidden=\#{inspect(forbidden)}")
    """

    args = Enum.flat_map(code_paths, &["-pa", &1]) ++ ["-e", script]

    {output, 0} =
      System.cmd(System.find_executable("elixir"), args,
        cd: isolated_release,
        env: [{"RELEASE_ROOT", isolated_release}],
        stderr_to_stdout: true
      )

    assert output =~ "code=0 forbidden=[]"
  end

  defp digest(contents), do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
end
