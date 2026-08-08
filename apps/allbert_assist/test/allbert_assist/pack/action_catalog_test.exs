defmodule AllbertAssist.Pack.ActionCatalogTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Pack.ActionCatalog

  test "residual Pack declarations are derived from compiled owners and shipped Plugin claims" do
    assert {:ok, modules} = ActionCatalog.residual_modules()

    assert length(modules) == 244
    assert Enum.map(modules, & &1.registry_order()) == Enum.to_list(1..244)
    assert hd(modules) == AllbertAssist.Actions.Intent.DirectAnswer
    assert List.last(modules) == AllbertAssist.Actions.Voice.EnsureVoiceToken
  end

  test "the complete compiled action inventory stays globally contiguous" do
    assert {:ok, modules} = ActionCatalog.compiled_modules()
    assert length(modules) == 281
    assert Enum.map(modules, & &1.registry_order()) == Enum.to_list(1..281)
  end
end
