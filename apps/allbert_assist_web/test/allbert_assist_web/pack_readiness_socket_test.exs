defmodule AllbertAssistWeb.LiveSocketTest do
  use ExUnit.Case, async: true

  test "uses the one targeted readiness-disconnect socket topic" do
    assert AllbertAssistWeb.LiveSocket.id(%Phoenix.Socket{}) == "allbert_pack_readiness"
  end
end
