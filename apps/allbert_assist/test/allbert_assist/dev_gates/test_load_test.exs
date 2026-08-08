defmodule AllbertAssist.DevGates.TestLoadTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.DevGates.TestLoad

  test "owner command loads files while excluding every test" do
    assert TestLoad.command(["test/a_test.exs", "test/b_test.exs"]) == [
             "test",
             "--no-compile",
             "--exclude",
             "test",
             "test/a_test.exs",
             "test/b_test.exs"
           ]
  end

  test "nonzero load and accidentally executed tests both fail" do
    assert {:error, "core", 2, "missing helper"} =
             TestLoad.result("core", "missing helper", 2)

    output = "Running ExUnit with seed: 1\n1 test, 0 failures\n"
    assert {:error, "core", 1, failed_output} = TestLoad.result("core", output, 0)
    assert failed_output =~ "owner-CWD load executed tests"
  end

  test "a successful zero-execution load passes" do
    output = "All tests have been excluded.\n0 tests, 0 failures (3 excluded)\n"
    assert {:ok, "core", ^output} = TestLoad.result("core", output, 0)
  end
end
