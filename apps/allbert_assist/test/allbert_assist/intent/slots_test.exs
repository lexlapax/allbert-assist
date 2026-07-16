defmodule AllbertAssist.Intent.SlotsTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Intent.Slots

  describe "normalize/1" do
    test "passes through a map" do
      assert Slots.normalize(%{"title" => "v054"}) == %{"title" => "v054"}
    end

    test "decodes a JSON-object string" do
      assert Slots.normalize(~s({"title":"v054"})) == %{"title" => "v054"}
    end

    test "degrades malformed / non-map payloads to an empty map" do
      # This is the crash class: a timed-out / partial model decode can emit a
      # list, scalar, or garbage string instead of a slot map.
      assert Slots.normalize(["title", "body"]) == %{}
      assert Slots.normalize("not json") == %{}
      assert Slots.normalize(~s(["a","b"])) == %{}
      assert Slots.normalize(42) == %{}
      assert Slots.normalize(nil) == %{}
      assert Slots.normalize("") == %{}
    end
  end

  describe "merge/3 — router policy (:existing_atom, put_new)" do
    test "keeps existing-atom keys and drops unknown keys" do
      # :title exists as an atom here (referenced below); :nonexistent_slot_xyz does not.
      _ = :title

      params =
        Slots.merge(%{}, %{"title" => "v054", "nonexistent_slot_xyz" => "x"},
          key_mode: :existing_atom
        )

      assert params[:title] == "v054"
      refute Map.has_key?(params, "nonexistent_slot_xyz")
    end

    test "never overwrites a param the caller already set" do
      params = Slots.merge(%{title: "caller"}, %{"title" => "model"}, key_mode: :existing_atom)
      assert params.title == "caller"
    end

    test "a malformed slot payload leaves params untouched (no crash)" do
      assert Slots.merge(%{title: "caller"}, ["garbage"]) == %{title: "caller"}
    end
  end

  describe "to_params/2 — engine policy (:lenient)" do
    test "keeps unknown string keys as-is" do
      params = Slots.to_params(%{"totally_unknown_key_abc" => "v"}, :lenient)
      assert params["totally_unknown_key_abc"] == "v"
    end

    test "degrades a non-map payload to an empty params map" do
      assert Slots.to_params(["garbage"], :lenient) == %{}
    end
  end
end
