defmodule AllbertAssist.Memory.ClaimWriterPropagationTest do
  @moduledoc """
  v1.3 M9.b.12.a — every canonical claim writer must advance the projection.

  Two shipped defects had one shape: canonical claim state moved and the
  projection did not, so retrieval's canonical recheck correctly refused to
  serve a stale candidate and the claim became unretrievable until a full
  rebuild. M9.b.10 was the missing first generation; M9.b.11 was archive and
  restore. Auditing every `Claims.append/3` caller afterwards found three more
  that had never propagated — both `ClaimConfirmation` entry points and draft
  promotion — which is why this is a census rather than three more fixes.

  This mirrors the `Repo.transaction` census in `sqlite_topology_test.exs`,
  which is the guard that caught the M9.b.5 callsite drift. A new claim writer
  now fails here rather than shipping a claim nobody can read back.
  """

  use ExUnit.Case, async: true
  @moduletag :pure_async

  @repo_root Path.expand("../../../../..", __DIR__)
  @lib_glob "apps/allbert_assist/lib/**/*.ex"

  # Dev gates drive the projection directly (`Projection.rebuild/1`) because they
  # seed fixtures wholesale rather than transitioning one operator claim. They are
  # exempt by inspection, not by accident; anything added here needs the same.
  @exempt_writers %{
    "apps/allbert_assist/lib/allbert_assist/dev_gates/v13_zero_shot_eval.ex" =>
      "dev gate; rebuilds the whole projection itself after seeding"
  }

  defp claim_writers do
    @repo_root
    |> Path.join(@lib_glob)
    |> Path.wildcard()
    |> Enum.filter(&(File.read!(&1) =~ ~r/Claims\.append\s*\(/))
    |> Enum.map(&Path.relative_to(&1, @repo_root))
    |> Enum.sort()
  end

  defp propagates?(relative_path) do
    source = @repo_root |> Path.join(relative_path) |> File.read!()

    source =~ ~r/ProjectionSync\.refresh\s*\(/ or
      source =~ ~r/Projection\.replace_after_forgets?\s*\(/ or
      source =~ ~r/Projection\.rebuild\s*\(/
  end

  test "there is at least one canonical claim writer to police" do
    assert claim_writers() != [],
           "the census found no Claims.append callers; the detection is broken, not the code"
  end

  test "every canonical claim writer advances the projection or is an explicit exemption" do
    offenders =
      claim_writers()
      |> Enum.reject(&Map.has_key?(@exempt_writers, &1))
      |> Enum.reject(&propagates?/1)

    assert offenders == [],
           """
           These append canonical claim revisions without advancing the Memory projection:

             #{Enum.join(offenders, "\n  ")}

           A claim written this way is canonically correct and unreadable: the projection
           keeps the prior revision digest, the canonical recheck refuses to serve it, and
           nothing repairs it. Call AllbertAssist.Memory.ProjectionSync.refresh/1 after the
           append returns — not inside Claims.append/3, which holds a per-claim lock.
           """
  end

  test "every recorded exemption is still a claim writer" do
    stale = Map.keys(@exempt_writers) -- claim_writers()

    assert stale == [],
           "exemptions recorded for files that no longer write claims: #{inspect(stale)}"
  end
end
