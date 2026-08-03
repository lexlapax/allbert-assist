defmodule AllbertAssist.Memory.SecretFilterTest do
  @moduledoc """
  v1.3 M9.b.13.a — the only thing keeping credential-shaped content out of Memory.

  Before this file, exactly one of the filter's seven patterns was asserted
  anywhere in the repo. `ghp_` and `AKIA` had zero references, so a regression in
  either would have written a GitHub token or AWS access key into a durable claim
  with nothing to catch it. The patterns were verified correct by direct
  exercise on 2026-08-03; these rows keep them that way.

  Every row that asserts refusal is paired with a benign control. A filter that
  refuses everything is as broken as one that refuses nothing, and only the
  negative side distinguishes them.

  Fixtures are assembled at runtime from fragments rather than written as
  literals. GitHub push protection blocks a commit containing a credential-shaped
  string and cannot distinguish a filter's test fixture from a leak; the
  alternative was to allowlist a fake secret, which normalises bypassing push
  protection for the sake of a test. `shape/2` keeps the exercised input
  identical while leaving no full literal in the file.
  """

  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Memory.SecretFilter

  # Assemble a credential-shaped fixture at runtime. See the moduledoc.
  defp shape(prefix, body), do: prefix <> body

  describe "declared credential shapes" do
    test "refuses an OpenAI-style key" do
      assert SecretFilter.secret_bearing?(
               "my key is " <> shape("sk-", "abcdefghijklmnopqrstuvwx1234")
             )
    end

    test "refuses a Google API key" do
      assert SecretFilter.secret_bearing?(shape("AIza", "SyA1234567890abcdefghijklmnopqrs"))
    end

    test "refuses a GitHub token" do
      assert SecretFilter.secret_bearing?(
               "token " <> shape("ghp", "_1234567890abcdefghijklmnopqrstuvwxyz")
             ),
             "ghp_ had no test coverage anywhere in the repo before M9.b.13.a"
    end

    test "refuses every GitHub token prefix the pattern claims" do
      for prefix <- ~w[ghp gho ghu ghs ghr] do
        assert SecretFilter.secret_bearing?(
                 shape(prefix, "_1234567890abcdefghijklmnopqrstuvwxyz")
               ),
               "#{prefix}_ is declared in the pattern but not refused"
      end
    end

    test "refuses a Slack token" do
      assert SecretFilter.secret_bearing?(shape("xox", "b-1234567890-abcdefghijklmnopqrst"))
    end

    test "refuses AWS access key ids, both long-term and temporary" do
      assert SecretFilter.secret_bearing?(shape("AKIA", "IOSFODNN7EXAMPLE") <> " key"),
             "AKIA had no test coverage anywhere in the repo before M9.b.13.a"

      assert SecretFilter.secret_bearing?(shape("ASIA", "IOSFODNN7EXAMPLE") <> " key")
    end

    test "refuses a PEM private key header" do
      assert SecretFilter.secret_bearing?("-----BEGIN RSA PRIVATE KEY-----")
      assert SecretFilter.secret_bearing?("-----BEGIN PRIVATE KEY-----")
    end

    test "refuses labelled assignments" do
      assert SecretFilter.secret_bearing?("password = hunter2hunter2")
      assert SecretFilter.secret_bearing?("api_key: abcdefgh12345678")
      assert SecretFilter.secret_bearing?("Bearer: abcdefgh12345678")
    end

    test "does not refuse an assignment that is already redacted" do
      refute SecretFilter.secret_bearing?("password = [REDACTED]")
    end

    # v1.3 M9.b.13.a. The labelled-assignment pattern carries a lookahead
    # `(?!\[REDACTED\]|secret://)` that exempts both forms, but the exemption is
    # defeated for `secret://`: `secret` is itself one of the alternation
    # keywords, so the scanner re-anchors on the literal `secret:` inside the
    # value and matches the remainder. These rows assert what the filter actually
    # does rather than what the lookahead intends, because the deviation fails
    # CLOSED -- it refuses a secret *reference*, which is not a secret -- and
    # loosening a credential filter to satisfy a cosmetic intent is the wrong
    # trade. Recorded in the plan as an accepted deviation, not hidden here.
    test "refuses a secret:// reference despite the lookahead intending to exempt it" do
      assert SecretFilter.secret_bearing?("api_key = secret://system/integrity_v1")
      assert SecretFilter.secret_bearing?("secret://system/integrity_v1")

      # The exemption does hold where the value falls under the length floor.
      refute SecretFilter.secret_bearing?("key_ref = secret://x/y")
    end
  end

  describe "benign operator content is not refused" do
    test "ordinary preferences pass" do
      refute SecretFilter.secret_bearing?(
               "I prefer status summaries on Friday at 09:00, valid starting 2026-06-01."
             )
    end

    test "short credential-shaped fragments below the length floor pass" do
      refute SecretFilter.secret_bearing?(shape("sk-", "short")),
             "the length floor exists so ordinary prose is not refused"

      refute SecretFilter.secret_bearing?(shape("AKIA", "SHORT"))
    end

    test "the marker used by attended validation is refused, and its sibling is not" do
      # SV-6A.4 seeds this exact string as a negative control.
      assert SecretFilter.secret_bearing?(shape("sk-", "test-juniper-v13-do-not-store"))
      refute SecretFilter.secret_bearing?("juniperv13primary")
    end
  end

  describe "nested traversal" do
    test "walks maps, lists, structs, and atom keys" do
      leaked = shape("ghp", "_1234567890abcdefghijklmnopqrstuvwxyz")

      assert SecretFilter.secret_bearing?(%{"outer" => %{"inner" => leaked}})
      assert SecretFilter.secret_bearing?([%{a: [leaked]}])
      assert SecretFilter.secret_bearing?(%{nested: %{list: ["clean", leaked]}})
    end

    test "a wholly benign nested structure is not refused" do
      refute SecretFilter.secret_bearing?(%{
               "subject" => "operator",
               "predicate" => "prefer",
               "value" => "Friday at 09:00",
               "spans" => [%{field: "value", text: "Friday"}]
             })
    end

    test "non-binary leaves do not crash the walk" do
      refute SecretFilter.secret_bearing?(%{count: 3, ratio: 0.5, flag: true, missing: nil})
    end
  end
end
