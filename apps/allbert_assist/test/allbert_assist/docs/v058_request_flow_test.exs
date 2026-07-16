defmodule AllbertAssist.Docs.V058RequestFlowTest do
  use ExUnit.Case, async: true
  @moduletag :external_runtime_serial

  @request_flow Path.expand("../../../../../docs/plans/archives/v0.58-request-flow.md", __DIR__)

  test "S6 evidence secret-scan regex is accepted by ripgrep" do
    markdown = File.read!(@request_flow)

    assert [_, pattern] =
             Regex.run(~r/! rg -n '([^']+)' "\$V058_EVIDENCE_DIR"/, markdown)

    assert {:ok, _regex} = Regex.compile(pattern)

    if rg = System.find_executable("rg") do
      root = Path.join(System.tmp_dir!(), "allbert-v058-rg-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      File.write!(Path.join(root, "clean.txt"), "token=[REDACTED]\n")

      try do
        assert {_output, status} = System.cmd(rg, ["-n", pattern, root], stderr_to_stdout: true)
        assert status in [0, 1]
      after
        File.rm_rf!(root)
      end
    end
  end
end
