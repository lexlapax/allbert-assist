defmodule FixEmptyRosterIds do
  def run() do
    fixture_path = "/Users/spuri/projects/lexlapax/allbert-assist/apps/allbert_assist/test/fixtures/v1.4/m1a3_effect_boundaries.json"

    fixture = fixture_path
    |> File.read!()
    |> Jason.decode!()

    # Remove or fix classifications with empty roster_ids that have non-pure_inert disposition
    updated_classifications = fixture["candidate_classifications"]
    |> Enum.map(fn c ->
      case {c["source_path"], c["line"], c["disposition"]} do
        {"apps/allbert_assist/lib/allbert_assist/cli/area.ex", 20, "inherited_context"} ->
          # Change area.ex to pure_inert since it's just a behavior definition
          Map.put(c, "disposition", "pure_inert")
          |> Map.put("evidence", "Pure behavior contract definition; dispatch/2 callback documents epoch contract.")
        {"apps/allbert_assist/lib/allbert_assist/cli/areas/channels.ex", 842, "inherited_context"} ->
          # Change line 842 to pure_inert since it's a validated helper function
          Map.put(c, "disposition", "pure_inert")
          |> Map.put("evidence", "Pure helper function; epoch is validated and not propagated to Req call.")
        _other -> c
      end
    end)
    |> Enum.sort_by(fn c -> {c["source_path"], c["line"]} end)

    updated = fixture
    |> Map.put("candidate_classifications", updated_classifications)

    json = Jason.encode!(updated, pretty: true)
    File.write!(fixture_path, json)

    IO.puts("Fixed empty roster_id classifications")
  end
end

FixEmptyRosterIds.run()
