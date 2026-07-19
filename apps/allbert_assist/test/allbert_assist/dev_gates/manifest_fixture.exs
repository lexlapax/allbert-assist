defmodule AllbertAssist.DevGates.ManifestFixture do
  # Parsing fixture for TestManifestTest — NOT a compiled test module: the
  # filename does not match *_test.exs, so neither `mix test` nor the
  # inventory scan picks it up. Shapes mirror cli/areas/onboarding_test.exs
  # (module lane plus one dual-lane describetag block) and add a test-level
  # lane tag with a skip tag.
  use ExUnit.Case, async: false

  @moduletag :app_env_serial

  test "module lane only" do
    assert true
  end

  describe "dual-lane block" do
    @describetag :external_runtime_serial

    setup do
      {:ok, marker: :fixture}
    end

    test "first dual-lane", %{marker: marker} do
      assert marker == :fixture
    end

    property "second dual-lane" do
      assert true
    end
  end

  describe "tagged block" do
    @tag :db_serial
    @tag skip: "needs external hardware"
    test "test-level lane and skip" do
      assert true
    end

    test "untagged neighbor keeps multiplicity one" do
      assert true
    end
  end

  test "after describe returns to module scope" do
    assert true
  end
end
