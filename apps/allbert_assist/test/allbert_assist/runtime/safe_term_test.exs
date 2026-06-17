defmodule AllbertAssist.Runtime.SafeTermTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Runtime.SafeTerm

  test "to_list normalizes improper list tails" do
    assert SafeTerm.to_list([:a, :b | :tail]) == [:a, :b, :tail]
  end

  test "map_list maps improper list tails without raising" do
    assert SafeTerm.map_list([1, 2 | 3], &(&1 * 2)) == [2, 4, 6]
  end

  test "filter_list filters improper list tails without raising" do
    assert SafeTerm.filter_list([1, "two" | 3], &is_integer/1) == [1, 3]
  end

  test "wrap_list preserves scalar wrap behavior and normalizes list values" do
    assert SafeTerm.wrap_list(:item) == [:item]
    assert SafeTerm.wrap_list([:a | :tail]) == [:a, :tail]
    assert SafeTerm.wrap_list(nil) == []
  end
end
