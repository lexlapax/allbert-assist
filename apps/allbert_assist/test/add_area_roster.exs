defmodule AddAreaRoster do
  def run() do
    fixture_path = "/Users/spuri/projects/lexlapax/allbert-assist/apps/allbert_assist/test/fixtures/v1.4/m1a3_effect_boundaries.json"

    fixture = fixture_path
    |> File.read!()
    |> Jason.decode!()

    # Add area.ex as a roster row and remove its classification
    area_row = %{
      "admission_mode" => "ready_carried",
      "carrier_policy" => "documents dispatch/2 receives :allbert_pack_epoch",
      "compatibility_provenance" => nil,
      "entrypoint" => "behavior contract",
      "focused_test" => "AllbertAssist.CLI.AreaTest",
      "id" => "cli-area",
      "missing_or_stale_result" => "no area dispatch effect",
      "owner" => "AllbertAssist.CLI.Area",
      "phase" => "ready",
      "source_path" => "apps/allbert_assist/lib/allbert_assist/cli/area.ex"
    }

    # Add row
    updated_rows = fixture["rows"] ++ [area_row]
    |> Enum.sort_by(fn r -> r["id"] end)

    # Remove area.ex classification
    updated_classifications = fixture["candidate_classifications"]
    |> Enum.reject(fn c ->
      c["source_path"] == "apps/allbert_assist/lib/allbert_assist/cli/area.ex"
    end)

    updated = fixture
    |> Map.put("rows", updated_rows)
    |> Map.put("candidate_classifications", updated_classifications)

    json = Jason.encode!(updated, pretty: true)
    File.write!(fixture_path, json)

    IO.puts("Added area.ex as roster row")
  end
end

AddAreaRoster.run()
