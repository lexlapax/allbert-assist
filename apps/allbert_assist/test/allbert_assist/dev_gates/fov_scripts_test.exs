defmodule AllbertAssist.DevGates.FovScriptsTest do
  @moduledoc """
  Executable checks over the attended FOV runbook scripts.

  v1.3 M9.b.7. One attended run surfaced three defects that all lived in
  150-to-371-line runbook blocks no test executed: FOV-1 read a settings key
  that no longer exists, FOV-7R asserted properties the renderer cannot satisfy,
  and FOV-8's evidence manifest hashed a file FOV-1 had stopped producing. Each
  reached the operator's terminal before anything noticed. These rows execute
  the cheap, decidable parts of that surface so the next one does not.
  """

  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Settings.Schema

  @root Path.expand("../../../../..", __DIR__)
  @fov_dir Path.join(@root, "scripts/validation")
  @scripts ~w[v13_fov1_roles.sh v13_fov7r_durable.sh v13_fov8_close.sh]

  defp script(name), do: @fov_dir |> Path.join(name) |> File.read!()

  test "every extracted FOV script is present and parses as bash" do
    for name <- @scripts do
      path = Path.join(@fov_dir, name)
      assert File.regular?(path), "missing extracted script #{name}"

      assert {_output, 0} = System.cmd("bash", ["-n", path], stderr_to_stdout: true),
             "#{name} is not valid bash"
    end
  end

  test "every settings key an FOV script reads still exists in the schema" do
    defaults = Schema.defaults()

    referenced =
      @scripts
      |> Enum.flat_map(fn name ->
        ~r/\b((?:model_preferences|objectives|intent|models)\.[a-z0-9_.]+)/
        |> Regex.scan(script(name))
        |> Enum.map(&List.last/1)
      end)
      |> Enum.uniq()

    assert referenced != [], "expected the FOV scripts to read some settings keys"

    # The FOV-1 defect: the runbook read model_preferences.tasks.fanout_review
    # for a whole milestone after the chain was deleted.
    missing = Enum.reject(referenced, &(Schema.get_dotted(defaults, &1) != nil))

    assert missing == [],
           "FOV scripts read settings keys that no longer exist: #{inspect(missing)}"
  end

  test "every evidence file the FOV-8 manifest hashes is produced by an earlier step" do
    close = script("v13_fov8_close.sh")

    manifest =
      close
      |> String.split("shasum -a 256 \\", parts: 2)
      |> List.last()
      |> String.split("> \"$FOV_ROOT/evidence-sha256.txt\"", parts: 2)
      |> List.first()
      |> String.split("\n")
      |> Enum.map(&(&1 |> String.trim() |> String.trim_trailing("\\") |> String.trim()))
      |> Enum.filter(&String.ends_with?(&1, [".txt", ".log", ".sqlite3"]))
      |> Enum.reject(&String.contains?(&1, " "))

    assert length(manifest) > 10, "expected the FOV-8 manifest to list evidence files"

    produced =
      (script("v13_fov1_roles.sh") <> script("v13_fov7r_durable.sh") <> close)
      |> then(&Regex.scan(~r/\$FOV_ROOT\/([A-Za-z0-9_.\-]+)/, &1))
      |> Enum.map(&List.last/1)
      |> MapSet.new()

    # Files under home/ are daemon/runtime artifacts rather than step outputs.
    # The FOV-8 defect: the manifest hashed fanout-review.txt long after FOV-1
    # stopped writing it, so the step could not pass on any machine.
    # FOV-0 writes source-sha.txt before any extracted script runs.
    fov0_outputs = MapSet.new(["source-sha.txt"])

    orphaned =
      manifest
      |> Enum.reject(&String.starts_with?(&1, "home/"))
      |> Enum.reject(&MapSet.member?(produced, &1))
      |> Enum.reject(&MapSet.member?(fov0_outputs, &1))

    assert orphaned == [],
           "FOV-8 hashes evidence no earlier step writes: #{inspect(orphaned)}"
  end

  test "the runbook invokes the extracted scripts rather than inlining them" do
    flow = Path.join(@root, "docs/plans/v1.3-request-flow.md") |> File.read!()

    for name <- @scripts do
      assert flow =~ "scripts/validation/#{name}",
             "the request flow does not invoke scripts/validation/#{name}"
    end
  end
end
