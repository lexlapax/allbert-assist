defmodule AllbertAssist.Actions.MultiplyTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Actions.Multiply

  describe "run/2" do
    test "multiplies two integers" do
      assert {:ok, %{product: 42}} = Multiply.run(%{a: 6, b: 7}, %{})
    end

    test "handles zero" do
      assert {:ok, %{product: 0}} = Multiply.run(%{a: 0, b: 99}, %{})
    end

    test "handles negatives" do
      assert {:ok, %{product: -15}} = Multiply.run(%{a: -3, b: 5}, %{})
    end
  end
end
