defmodule AllbertAssist.Memory.LexicalTest do
  @moduledoc """
  v1.3 M9.b.13.a — the tokenizer both the Memory projection and its callers share.

  It had no direct coverage. Retrieval matches on these terms, so a change here
  silently changes what Memory can recall: dropping a term makes a claim
  unfindable, and keeping a stop word makes every claim match. Neither surfaces
  as an error, which is why it needs rows of its own rather than incidental
  exercise through the projection.
  """

  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Memory.Lexical

  test "lowercases and splits on any non-alphanumeric boundary" do
    assert Lexical.terms("Project Juniper: status-summaries!") ==
             ~w[project juniper status summaries]
  end

  test "keeps digits and alphanumeric markers intact" do
    # `at` survives: the stop-word list covers a/an/and/are/about/do/for/from/
    # in/is/me/my/of/on/the/to/what/you and deliberately not every preposition.
    assert Lexical.terms("marker juniperv13primary at 09:00") ==
             ~w[marker juniperv13primary at 09 00]
  end

  test "drops stop words" do
    assert Lexical.terms("what is the status of my project") == ~w[status project]
  end

  test "a query made only of stop words yields no terms" do
    # Retrieval treats an empty term list as "nothing to match", so this is the
    # difference between recalling nothing and recalling everything.
    assert Lexical.terms("what is the a an and to") == []
  end

  test "de-duplicates while preserving first-seen order" do
    assert Lexical.terms("juniper juniper status juniper") == ~w[juniper status]
  end

  test "unicode and punctuation collapse to boundaries rather than terms" do
    assert Lexical.terms("café — naïve") == ~w[caf na ve]
  end

  test "non-binary input yields no terms rather than raising" do
    assert Lexical.terms(nil) == []
    assert Lexical.terms(%{}) == []
    assert Lexical.terms(123) == []
  end

  test "empty and whitespace-only input yield no terms" do
    assert Lexical.terms("") == []
    assert Lexical.terms("   \n\t ") == []
  end
end
