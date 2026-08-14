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

  # v1.4 M13.4. These two are the reason the step exists in this shape. Loading
  # is the only gate that sees the test tree at all, and both defect classes
  # below reached main under gates that were green, because `forced_compile`
  # and `compile_warnings_as_errors` compile `lib` only.
  test "a test-tree compiler warning fails the load" do
    unaliased = """
    Running ExUnit with seed: 1
        warning: ReadyEffectContext.attach/1 is undefined (module ReadyEffectContext is not available)
        └─ test/allbert_assist/runtime/tui_session_test.exs:810:37
    0 tests, 0 failures (3 excluded)
    """

    assert {:error, "core", 1, failed} = TestLoad.result("core", unaliased, 0)
    assert failed =~ "owner-CWD load emitted test-tree compiler warnings"
    assert failed =~ "ReadyEffectContext.attach/1 is undefined"

    unused = "  warning: unused alias ShippedRegistries\n0 tests, 0 failures (1 excluded)\n"
    assert {:error, "core", 1, _output} = TestLoad.result("core", unused, 0)
  end

  test "the load-filter notice Mix prints for explicit files is not a warning" do
    # Every owner load names its files, so Mix emits this on every clean run.
    # If it counted, the step would fail always and prove nothing.
    output = """
    warning: the following files do not match any of the configured `:test_load_filters`:
      test/support/fixture.ex
    0 tests, 0 failures (3 excluded)
    """

    assert {:ok, "core", ^output} = TestLoad.result("core", output, 0)
  end
end
