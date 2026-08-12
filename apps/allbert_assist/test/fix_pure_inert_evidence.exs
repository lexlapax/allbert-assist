defmodule FixPureInertEvidence do
  def run() do
    fixture_path = "/Users/spuri/projects/lexlapax/allbert-assist/apps/allbert_assist/test/fixtures/v1.4/m1a3_effect_boundaries.json"

    fixture = fixture_path
    |> File.read!()
    |> Jason.decode!()

    # Update pure_inert classifications to have proper evidence
    updated_classifications = fixture["candidate_classifications"]
    |> Enum.map(fn c ->
      case {c["source_path"], c["line"], c["disposition"]} do
        {"apps/allbert_assist/lib/allbert_assist/cli/area.ex", 20, "pure_inert"} ->
          Map.put(c, "evidence", "Pure behavior contract definition; no actual effect calls.")
        {"apps/allbert_assist/lib/allbert_assist/cli/areas/channels.ex", 842, "pure_inert"} ->
          Map.put(c, "evidence", "Pure helper function with inert Req call; epoch validated upstream.")
        _other -> c
      end
    end)
    |> Enum.sort_by(fn c -> {c["source_path"], c["line"]} end)

    updated = fixture
    |> Map.put("candidate_classifications", updated_classifications)

    json = Jason.encode!(updated, pretty: true)
    File.write!(fixture_path, json)

    IO.puts("Fixed pure_inert evidence")
  end
end

FixPureInertEvidence.run()
