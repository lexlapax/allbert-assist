defmodule AllbertAssist.Intent.Router.ClarifyResolverTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Intent.Router.ClarifyResolver

  @options [
    %{kind: :action, id: "create_note", label: "Create note"},
    %{kind: :action, id: "search_notes", label: "Search notes"}
  ]

  test "binds an ordinal reply to the matching option" do
    assert {:ok, %{id: "create_note"}} = ClarifyResolver.resolve("the first one", @options)
    assert {:ok, %{id: "search_notes"}} = ClarifyResolver.resolve("second", @options)
    assert {:ok, %{id: "search_notes"}} = ClarifyResolver.resolve("2", @options)
  end

  test "binds a 'yes' reply only when there is a single option" do
    assert {:ok, %{id: "create_note"}} = ClarifyResolver.resolve("yes please", [hd(@options)])
    assert :no_match = ClarifyResolver.resolve("yes", @options)
  end

  test "binds on a distinctive label/action keyword" do
    assert {:ok, %{id: "search_notes"}} = ClarifyResolver.resolve("search them", @options)
    assert {:ok, %{id: "create_note"}} = ClarifyResolver.resolve("create one", @options)
  end

  test "returns :no_match for unrelated or ambiguous replies (re-classify fresh)" do
    assert :no_match = ClarifyResolver.resolve("what's the weather", @options)
    # bare 'note(s)' is a shared, non-distinctive token -> not a bind
    assert :no_match = ClarifyResolver.resolve("notes", @options)
    assert :no_match = ClarifyResolver.resolve("anything", [])
  end
end
