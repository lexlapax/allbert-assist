defmodule Mix.Tasks.AllbertEntryTest do
  use ExUnit.Case, async: false

  @moduletag :global_process_serial

  import ExUnit.CaptureIO

  test "source top-level help resolves through the composition-owned ProductCLI entry" do
    Mix.Task.reenable("allbert")

    output =
      capture_io(fn ->
        assert :ok = Mix.Tasks.Allbert.run(["--help"])
      end)

    assert output =~ "Allbert - local-first assistant workspace"
  end

  test "source Mix entry is compiled from composition rather than residual" do
    path = :code.which(Mix.Tasks.Allbert) |> to_string()

    assert path =~ "/allbert_composition/ebin/"
    refute path =~ "/allbert_assist/ebin/"
  end
end
