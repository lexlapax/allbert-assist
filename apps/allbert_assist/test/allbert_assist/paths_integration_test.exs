defmodule AllbertAssist.PathsIntegrationTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Memory
  alias AllbertAssist.Paths

  # This row asserts that the residual Memory facade derives its root from
  # Allbert Home. The subject is Memory, not Paths, so it stays with the
  # residual rather than following Paths into the kernel.

  setup do
    original_home = System.get_env("ALLBERT_HOME")
    original_paths_config = Application.get_env(:allbert_assist, Paths)

    System.delete_env("ALLBERT_HOME")
    # The suite points Allbert Home at a shared temporary root through this
    # key, and a configured home outranks the environment variable this row
    # sets.
    Application.delete_env(:allbert_assist, Paths)

    on_exit(fn ->
      if original_home,
        do: System.put_env("ALLBERT_HOME", original_home),
        else: System.delete_env("ALLBERT_HOME")

      if original_paths_config,
        do: Application.put_env(:allbert_assist, Paths, original_paths_config),
        else: Application.delete_env(:allbert_assist, Paths)
    end)
  end

  test "memory root derives from Allbert Home when no specific override exists" do
    home = temp_path("home")

    System.put_env("ALLBERT_HOME", home)

    assert Memory.root() == Path.join(home, "memory")
  end

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "allbert-paths-#{name}-#{System.pid()}-#{System.unique_integer([:positive])}"
    )
  end
end
