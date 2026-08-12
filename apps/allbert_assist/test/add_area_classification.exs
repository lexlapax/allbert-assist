defmodule AddAreaClassification do
  def run() do
    fixture_path = "/Users/spuri/projects/lexlapax/allbert-assist/apps/allbert_assist/test/fixtures/v1.4/m1a3_effect_boundaries.json"

    fixture = fixture_path
    |> File.read!()
    |> Jason.decode!()

    # Add classification for area.ex
    area_classification = %{
      "boundary" => "AllbertAssist.CLI.Area",
      "disposition" => "inherited_context",
      "evidence" => "Behavior contract that documents dispatch/2 receives :allbert_pack_epoch.",
      "line" => 20,
      "source_path" => "apps/allbert_assist/lib/allbert_assist/cli/area.ex"
    }

    # Check if this classification already exists
    existing = fixture["candidate_classifications"]
    |> Enum.any?(fn c ->
      c["source_path"] == area_classification["source_path"] and
      c["line"] == area_classification["line"]
    end)

    updated_classifications = if existing do
      fixture["candidate_classifications"]
    else
      (fixture["candidate_classifications"] ++ [area_classification])
      |> Enum.sort_by(fn c -> {c["source_path"], c["line"]} end)
    end

    updated = fixture
    |> Map.put("candidate_classifications", updated_classifications)

    json = Jason.encode!(updated, pretty: true)
    File.write!(fixture_path, json)

    IO.puts("Added classification for area.ex")
  end
end

AddAreaClassification.run()
